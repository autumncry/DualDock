import AppKit
import DualDockCore

private final class NativeMetricsFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var mainThreadRead = false
    private var next: NativeDockMetricsReadResult
    var blockFirst: DispatchSemaphore?

    init(_ next: NativeDockMetricsReadResult) { self.next = next }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    var usedMainThread: Bool { lock.lock(); defer { lock.unlock() }; return mainThreadRead }
    func set(_ result: NativeDockMetricsReadResult) { lock.lock(); defer { lock.unlock() }; next = result }
    func read(_ input: NativeDockMetricsReadInput) -> NativeDockMetricsReadResult {
        lock.lock(); count += 1; let number = count; let result = next
        mainThreadRead = mainThreadRead || Thread.isMainThread; lock.unlock()
        if number == 1 { blockFirst?.wait() }
        return result
    }
}

@main
struct NativeDockMetricsServiceChecks {
    static let preferences = NativeDockPreferences(iconSize: 40, magnifiedIconSize: 89,
                                                    magnificationEnabled: true, axis: .vertical)
    static let measured = NativeDockMetrics(iconSize: 28.625, barThickness: 41,
        leadingPadding: 6.125, trailingPadding: 6.125, itemSpacing: 0, separatorLength: 12.875,
        magnifiedIconSize: 89, magnificationEnabled: true)

    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await checks()
            print("8 native Dock metrics service checks passed; injected readers only")
            exit(0)
        }
        CFRunLoopRun()
    }

    @MainActor private static func make(_ fixture: NativeMetricsFixture) -> NativeDockMetricsService {
        NativeDockMetricsService(reader: { fixture.read($0) }, inputProvider: {
            .init(dockProcessID: nil, accessibilityTrusted: false, screenLocked: true)
        })
    }

    @MainActor static func waitUntil(_ predicate: @escaping @MainActor () -> Bool, timeout: Double = 1) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        precondition(predicate(), "Native metrics check timed out")
    }

    @MainActor static func checks() async {
        do {
            let fixture = NativeMetricsFixture(.init(preferences: preferences, observed: measured))
            let service = make(fixture)
            var updates: [(NativeDockMetrics, NativeDockMetricsStatus)] = []
            service.onUpdate = { updates.append(($0, $1)) }
            service.refresh(); service.stop()
            precondition(fixture.calls == 0 && updates.isEmpty)
            service.start(); service.start()
            await waitUntil { updates.count == 1 }
            precondition(updates[0].0 == measured && updates[0].1 == .accessibility && !fixture.usedMainThread)
            service.refresh(); await waitUntil { fixture.calls == 2 }
            try? await Task.sleep(nanoseconds: 40_000_000)
            precondition(updates.count == 1)
            service.stop()
            print("PASS inert initialization, background reads and unchanged suppression")
        }
        do {
            let fixture = NativeMetricsFixture(.init(preferences: preferences, observed: measured))
            let service = make(fixture)
            var latest: (NativeDockMetrics, NativeDockMetricsStatus)?
            service.onUpdate = { latest = ($0, $1) }
            service.start(); await waitUntil { latest?.1 == .accessibility }
            fixture.set(.init(preferences: preferences, observed: nil))
            service.refresh(); await waitUntil { latest?.1 == .cached }
            precondition(latest?.0 == measured)
            fixture.set(.init(preferences: nil, observed: nil)); service.refresh()
            await waitUntil { fixture.calls == 3 }
            try? await Task.sleep(nanoseconds: 40_000_000)
            precondition(latest?.0 == measured && latest?.1 == .cached)
            service.stop()
            print("PASS lock, Dock restart and failed reads preserve last observed geometry")
        }
        do {
            let fixture = NativeMetricsFixture(.init(preferences: preferences, observed: measured))
            let service = make(fixture)
            var latest: NativeDockMetrics?
            service.onUpdate = { metrics, _ in latest = metrics }
            service.start(); await waitUntil { latest == measured }
            fixture.set(.init(preferences: .init(iconSize: 40, magnifiedIconSize: 100,
                                                 magnificationEnabled: false, axis: .vertical), observed: nil))
            service.refresh(); await waitUntil { latest?.magnificationEnabled == false }
            precondition(latest?.iconSize == measured.iconSize && latest?.magnifiedIconSize == 100)
            fixture.set(.init(preferences: nil, observed: nil)); service.refresh()
            await waitUntil { fixture.calls == 3 }
            try? await Task.sleep(nanoseconds: 30_000_000)
            precondition(latest?.magnificationEnabled == false && latest?.magnifiedIconSize == 100)
            service.stop()
            print("PASS explicit magnification preferences update without losing cached base geometry")
        }
        do {
            let fixture = NativeMetricsFixture(.init(preferences: preferences, observed: nil))
            let service = make(fixture)
            var latest: (NativeDockMetrics, NativeDockMetricsStatus)?
            service.onUpdate = { latest = ($0, $1) }
            service.start(); await waitUntil { latest?.1 == .preferences }
            precondition(latest?.0.iconSize == 40 && latest?.0.barThickness == 52)
            fixture.set(.init(preferences: nil, observed: nil)); service.refresh()
            await waitUntil { latest?.1 == .cached }
            precondition(latest?.0.iconSize == 40)
            service.stop()
            let unavailable = NativeMetricsFixture(.init(preferences: nil, observed: nil))
            let fallbackService = make(unavailable)
            fallbackService.onUpdate = { latest = ($0, $1) }
            fallbackService.start(); await waitUntil { latest?.1 == .fallback }
            precondition(latest?.0 == .fallback)
            fallbackService.stop()
            print("PASS preference and explicit heuristic fallbacks without new permission requests")
        }
        do {
            let fixture = NativeMetricsFixture(.init(preferences: preferences, observed: measured))
            let gate = DispatchSemaphore(value: 0); fixture.blockFirst = gate
            let service = make(fixture); var updates = 0
            service.onUpdate = { _, _ in updates += 1 }
            service.start(); await waitUntil { fixture.calls == 1 }
            service.stop(); gate.signal()
            try? await Task.sleep(nanoseconds: 80_000_000)
            precondition(updates == 0)
            print("PASS stop discards in-flight measurements")
        }
        do {
            let fixture = NativeMetricsFixture(.init(preferences: preferences, observed: measured))
            let gate = DispatchSemaphore(value: 0); fixture.blockFirst = gate
            let service = make(fixture); var values: [Double] = []
            service.onUpdate = { metrics, _ in values.append(metrics.iconSize) }
            service.start(); await waitUntil { fixture.calls == 1 }
            service.stop()
            let fresh = NativeDockMetrics(iconSize: 32, barThickness: 44, leadingPadding: 6,
                trailingPadding: 6, itemSpacing: 0, separatorLength: 12,
                magnifiedIconSize: 89, magnificationEnabled: true)
            fixture.set(.init(preferences: preferences, observed: fresh))
            service.start(); gate.signal()
            await waitUntil { values.last == 32 }
            precondition(!values.contains(measured.iconSize))
            service.stop()
            print("PASS restart uses a fresh generation and rejects stale measurements")
        }
        do {
            let fixture = NativeMetricsFixture(.init(preferences: preferences, observed: measured))
            let gate = DispatchSemaphore(value: 0); fixture.blockFirst = gate
            let service = make(fixture)
            service.start(); await waitUntil { fixture.calls == 1 }
            for _ in 0..<20 { service.refresh() }
            gate.signal(); await waitUntil { fixture.calls == 2 }
            try? await Task.sleep(nanoseconds: 40_000_000)
            precondition(fixture.calls == 2)
            service.stop()
            print("PASS busy refresh requests coalesce")
        }
        do {
            let fixture = NativeMetricsFixture(.init(preferences: preferences, observed: measured))
            let service = make(fixture); var status: NativeDockMetricsStatus?
            service.onUpdate = { _, value in status = value }
            service.start(); await waitUntil { status == .accessibility }
            fixture.set(.init(preferences: preferences, observed: nil))
            await waitUntil({ status == .cached }, timeout: 3)
            service.stop()
            print("PASS periodic refresh follows native changes")
        }
    }
}
