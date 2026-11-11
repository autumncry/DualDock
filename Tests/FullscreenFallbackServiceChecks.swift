import AppKit

private final class FullscreenReaderFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var onMain = false
    private var result: [CGDirectDisplayID: Bool]
    let firstGate: DispatchSemaphore?
    private let blockedCall: Int

    init(_ result: [CGDirectDisplayID: Bool], blocked: Bool = false, blockedCall: Int = 1) {
        self.result = result
        self.blockedCall = blockedCall
        firstGate = blocked ? DispatchSemaphore(value: 0) : nil
    }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    var usedMainThread: Bool { lock.lock(); defer { lock.unlock() }; return onMain }
    func set(_ next: [CGDirectDisplayID: Bool]) { lock.lock(); result = next; lock.unlock() }
    func read(_ input: FullscreenFallbackInput) -> [CGDirectDisplayID: Bool] {
        lock.lock()
        count += 1
        let number = count
        let next = result
        onMain = onMain || Thread.isMainThread
        lock.unlock()
        if number == blockedCall { firstGate?.wait() }
        return next
    }
}

@main
struct FullscreenFallbackServiceChecks {
    static let a = FullscreenFallbackInput(displays: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 1800, height: 1169))], accessibilityTrusted: true, ownProcessID: 99)
    static let b = FullscreenFallbackInput(displays: [.init(id: 2, frame: CGRect(x: 1800, y: 0, width: 1920, height: 1080))], accessibilityTrusted: true, ownProcessID: 99)
    static let empty = FullscreenFallbackInput(displays: [], accessibilityTrusted: true, ownProcessID: 99)
    @MainActor static var count = 0

    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await run()
            print("\(count) fullscreen fallback checks passed; injected readers, no windows or system input")
            exit(0)
        }
        CFRunLoopRun()
    }

    @MainActor static func check(_ condition: Bool, _ message: String) {
        if !condition {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
        count += 1
    }

    @MainActor static func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if !predicate() {
            fputs("FAIL: Fullscreen fallback check timed out\n", stderr)
            exit(1)
        }
    }

    @MainActor static func run() async {
        do {
            let fixture = FullscreenReaderFixture([1: true], blocked: true)
            let service = FullscreenFallbackService(reader: { fixture.read($0) })
            var updates = 0
            service.onUpdate = { updates += 1 }
            check(service.update(empty).isEmpty && fixture.calls == 0, "Empty scope must not read AX")
            let start = ProcessInfo.processInfo.systemUptime
            check(service.update(a).isEmpty, "First request must return immediately without inventing a fullscreen flag")
            check(ProcessInfo.processInfo.systemUptime - start < 0.02, "Fallback blocked the main actor")
            await waitUntil { fixture.calls == 1 }
            // The reader is still blocked, but a main-actor task must stay runnable.
            check(!fixture.usedMainThread && updates == 0, "AX reader used main thread or published before completion")
            fixture.firstGate?.signal()
            await waitUntil { updates == 1 }
            check(service.update(a)[1] == true, "Completed fullscreen state missing")
            service.stop()
        }
        do {
            let fixture = FullscreenReaderFixture([1: true])
            let service = FullscreenFallbackService(reader: { fixture.read($0) }, now: { 10 }, refreshInterval: 1)
            var updates = 0
            service.onUpdate = { updates += 1 }
            _ = service.update(a)
            await waitUntil { updates == 1 }
            for _ in 0..<20 { _ = service.update(a) }
            check(fixture.calls == 1, "Unchanged snapshots bypassed the refresh interval")
            fixture.set([1: false])
            let start = ProcessInfo.processInfo.systemUptime
            service.invalidate()
            await waitUntil { updates == 2 }
            check(service.update(a)[1] == false, "Space change kept stale fullscreen state")
            check(ProcessInfo.processInfo.systemUptime - start < 0.15, "Invalidation waited for the old one-second cache")
            check(fixture.calls == 2, "Invalidation did not cause exactly one fresh read")
            service.stop()
        }
        do {
            let fixture = FullscreenReaderFixture([1: true], blocked: true)
            let service = FullscreenFallbackService(reader: { fixture.read($0) })
            var values: [Bool] = []
            service.onUpdate = { if let state = service.update(a)[1] { values.append(state) } }
            _ = service.update(a)
            await waitUntil { fixture.calls == 1 }
            fixture.set([1: false])
            for _ in 0..<20 { service.invalidate() }
            fixture.firstGate?.signal()
            await waitUntil { values == [false] }
            check(fixture.calls == 2, "Invalidations created a backlog of AX reads")
            check(values == [false], "An old fullscreen Space result flashed before the fresh desktop state")
            service.stop()
        }
        do {
            let fixture = FullscreenReaderFixture([1: true], blocked: true)
            let service = FullscreenFallbackService(reader: { fixture.read($0) })
            var updates = 0
            service.onUpdate = { updates += 1 }
            _ = service.update(a)
            await waitUntil { fixture.calls == 1 }
            fixture.set([2: false])
            check(service.update(b).isEmpty, "Changing display scope leaked a previous display state")
            fixture.firstGate?.signal()
            await waitUntil { updates == 1 }
            check(service.update(b) == [2: false] && fixture.calls == 2, "Stale display read was accepted")
            check(service.update(empty).isEmpty, "Known native metadata did not clear old fallback values")
            service.stop()
        }
        do {
            let fixture = FullscreenReaderFixture([1: true])
            let service = FullscreenFallbackService(reader: { fixture.read($0) }, now: { 10 })
            var updates = 0
            service.onUpdate = { updates += 1 }
            _ = service.update(a)
            await waitUntil { updates == 1 }
            fixture.set([:])
            service.invalidate()
            await waitUntil { fixture.calls == 2 }
            try? await Task.sleep(nanoseconds: 20_000_000)
            check(service.update(a)[1] == true && updates == 1, "Failed/partial fallback falsely showed the Dock")
            fixture.set([1: false, 9: true])
            service.invalidate()
            await waitUntil { updates == 2 }
            check(service.update(a) == [1: false], "Out-of-scope result leaked into display visibility")
            service.stop()
        }
        do {
            let fixture = FullscreenReaderFixture([1: true], blocked: true)
            let service = FullscreenFallbackService(reader: { fixture.read($0) })
            var updates = 0
            service.onUpdate = { updates += 1 }
            _ = service.update(a)
            await waitUntil { fixture.calls == 1 }
            service.stop()
            fixture.firstGate?.signal()
            try? await Task.sleep(nanoseconds: 20_000_000)
            check(updates == 0, "A stopped service published a late fullscreen state")
            fixture.set([2: false])
            _ = service.update(b)
            await waitUntil { updates == 1 }
            check(service.update(b) == [2: false], "Restart retained a stopped display state")
            service.stop()
        }
        do {
            var clock: TimeInterval = 10
            let fixture = FullscreenReaderFixture([1: true])
            let service = FullscreenFallbackService(reader: { fixture.read($0) }, now: { clock })
            var updates = 0
            service.onUpdate = { updates += 1 }
            _ = service.update(a)
            await waitUntil { updates == 1 }
            fixture.set([:])
            clock = 10.75
            service.invalidate()
            await waitUntil { fixture.calls == 2 }
            try? await Task.sleep(nanoseconds: 20_000_000)
            check(service.update(a)[1] == true, "A brief unknown result must retain the last confirmed state")
            clock = 11.01
            check(service.update(a)[1] == nil, "An unknown fallback kept fullscreen true past its one-second lifetime")
            service.stop()
        }
        do {
            var clock: TimeInterval = 20
            let both = FullscreenFallbackInput(displays: a.displays + b.displays,
                accessibilityTrusted: true, ownProcessID: 99)
            let fixture = FullscreenReaderFixture([1: true, 2: true])
            let service = FullscreenFallbackService(reader: { fixture.read($0) }, now: { clock })
            var updates = 0
            service.onUpdate = { updates += 1 }
            _ = service.update(both)
            await waitUntil { updates == 1 }
            clock = 20.75
            fixture.set([1: true])
            service.invalidate()
            await waitUntil { fixture.calls == 2 }
            try? await Task.sleep(nanoseconds: 20_000_000)
            check(updates == 1, "Refreshing an unchanged confirmation should not cause a visibility callback")
            fixture.set([:])
            clock = 21.01
            check(service.update(both) == [1: true], "A conclusive display refresh must not renew another display's unknown state")
            clock = 21.76
            check(service.update(both).isEmpty, "Repeated unknown reads extended the last successful confirmation")
            service.stop()
        }
        do {
            var clock: TimeInterval = 30
            let fixture = FullscreenReaderFixture([1: true], blocked: true, blockedCall: 2)
            let service = FullscreenFallbackService(reader: { fixture.read($0) }, now: { clock })
            var updates = 0
            var readingSnapshot = false
            var reentered = false
            service.onUpdate = { updates += 1; reentered = reentered || readingSnapshot }
            _ = service.update(a)
            await waitUntil { updates == 1 }
            clock = 30.5
            fixture.set([:])
            service.invalidate()
            await waitUntil { fixture.calls == 2 }
            clock = 31.01
            readingSnapshot = true
            let snapshot = service.update(a)
            readingSnapshot = false
            check(snapshot.isEmpty, "An in-flight AX read prevented a stale confirmation from expiring")
            check(!reentered, "Snapshot expiry reentered the visibility controller synchronously")
            service.stop()
            fixture.firstGate?.signal()
            try? await Task.sleep(nanoseconds: 20_000_000)
            check(updates == 1, "Stopped in-flight read revived expired state")
        }
        do {
            let service = FullscreenFallbackService()
            var updates = 0
            service.onUpdate = { updates += 1 }
            let denied = FullscreenFallbackInput(displays: a.displays, accessibilityTrusted: false, ownProcessID: 99)
            _ = service.update(denied)
            await waitUntil { updates == 1 }
            check(service.update(denied) == [1: false], "Missing accessibility permission left stale fullscreen data")
            service.stop()
        }
    }
}
