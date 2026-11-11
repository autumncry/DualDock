import AppKit

private final class ObstructionReaderFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var active = 0
    private var highestConcurrency = 0
    private var usedMain = false
    private var output: [CGRect]?
    private var gates: [Int: DispatchSemaphore] = [:]

    init(_ output: [CGRect]?) { self.output = output }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    var maxConcurrent: Int { lock.lock(); defer { lock.unlock() }; return highestConcurrency }
    var usedMainThread: Bool { lock.lock(); defer { lock.unlock() }; return usedMain }
    func set(_ output: [CGRect]?) { lock.lock(); self.output = output; lock.unlock() }
    func block(call: Int) -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        lock.lock(); gates[call] = gate; lock.unlock()
        return gate
    }
    func read() -> [CGRect]? {
        lock.lock()
        count += 1; active += 1
        highestConcurrency = max(highestConcurrency, active)
        usedMain = usedMain || Thread.isMainThread
        let gate = gates[count], result = output
        lock.unlock()
        gate?.wait()
        lock.lock(); active -= 1; lock.unlock()
        return result
    }
}

/// Injected rectangles only: no real window list, screenshots, user settings, or input.
@main
struct WindowObstructionServiceChecks {
    @MainActor static var count = 0
    static let a = CGRect(x: 100, y: 200, width: 300, height: 400)
    static let b = CGRect(x: -1000, y: -300, width: 800, height: 600)
    static let c = CGRect(x: 400, y: 500, width: 100, height: 100)

    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await run()
            print("\(count) window obstruction checks passed; injected geometry only, no system window reads or input")
            exit(0)
        }
        CFRunLoopRun()
    }

    @MainActor static func check(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        count += 1
    }

    @MainActor static func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        check(predicate(), "Asynchronous obstruction check timed out")
    }

    @MainActor static func settle() async { try? await Task.sleep(nanoseconds: 30_000_000) }

    @MainActor static func screenFrame(_ frame: CGRect) -> CGRect {
        let top = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        })?.frame.maxY ?? 0
        return CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
    }

    @MainActor static func run() async {
        do {
            let fixture = ObstructionReaderFixture([a, b])
            let gate = fixture.block(call: 1)
            let service = WindowObstructionService(reader: { fixture.read() })
            var updates = 0
            service.onUpdate = { updates += 1 }
            let started = ProcessInfo.processInfo.systemUptime
            service.refresh()
            check(ProcessInfo.processInfo.systemUptime - started < 0.025, "Reader blocked the main actor")
            await waitUntil { fixture.calls == 1 }
            check(!fixture.usedMainThread && updates == 0 && service.frames.isEmpty,
                  "Reader ran on main or published before completion")
            gate.signal()
            await waitUntil { updates == 1 }
            check(service.frames == [screenFrame(a), screenFrame(b)], "Injected geometry or coordinate conversion changed")
            for _ in 0..<20 { service.refresh() }
            await settle()
            check(fixture.calls == 1, "Ordinary refresh bypassed throttling")
            service.refresh(force: true)
            await waitUntil { fixture.calls == 2 }
            await settle()
            check(updates == 1, "Identical geometry should not publish another UI update")
            check(fixture.maxConcurrent == 1, "Reader requests ran concurrently")
            service.stop()
        }
        do {
            let fixture = ObstructionReaderFixture([a])
            let gate = fixture.block(call: 1)
            let service = WindowObstructionService(reader: { fixture.read() })
            var values: [[CGRect]] = []
            service.onUpdate = { values.append(service.frames) }
            service.refresh(force: true)
            await waitUntil { fixture.calls == 1 }
            for _ in 0..<20 { service.refresh() }
            fixture.set([b])
            for _ in 0..<20 { service.refresh(force: true) }
            check(fixture.calls == 1, "Busy refresh spawned another concurrent read")
            gate.signal()
            await waitUntil { values.last == [screenFrame(b)] }
            check(fixture.calls == 2 && fixture.maxConcurrent == 1, "Forced refreshes did not coalesce into one follow-up")
            service.stop()
        }
        do {
            let fixture = ObstructionReaderFixture([a])
            let service = WindowObstructionService(reader: { fixture.read() })
            var values: [[CGRect]] = []
            service.onUpdate = { values.append(service.frames) }
            service.refresh()
            await waitUntil { values.count == 1 }
            let gate = fixture.block(call: 2)
            fixture.set([b]); service.refresh(force: true)
            await waitUntil { fixture.calls == 2 }
            fixture.set([c])
            for _ in 0..<20 { service.invalidate(); service.refresh(force: true) }
            check(service.frames == [screenFrame(a)] && values.count == 1,
                  "Invalidation cleared obstruction while the new snapshot was still unavailable")
            gate.signal()
            await waitUntil { service.frames == [screenFrame(c)] }
            check(values == [[screenFrame(a)], [screenFrame(c)]], "A stale in-flight result flashed before the replacement")
            check(fixture.calls == 3, "Repeated invalidations created a backlog of reads")
            service.stop()
        }
        do {
            let fixture = ObstructionReaderFixture([a])
            let service = WindowObstructionService(reader: { fixture.read() })
            var updates = 0
            service.onUpdate = { updates += 1 }
            service.refresh()
            await waitUntil { updates == 1 }
            fixture.set(nil); service.invalidate(); service.refresh(force: true)
            await waitUntil { fixture.calls == 2 }
            await settle()
            check(service.frames == [screenFrame(a)] && updates == 1, "Read failure falsely cleared obstruction")
            fixture.set([]); service.invalidate(); service.refresh(force: true)
            await waitUntil { updates == 2 }
            check(service.frames.isEmpty, "A valid empty window list must clear obstruction")
            service.stop()
        }
        do {
            let fixture = ObstructionReaderFixture([a])
            let service = WindowObstructionService(reader: { fixture.read() })
            var updates = 0
            service.onUpdate = { updates += 1 }
            service.refresh()
            await waitUntil { updates == 1 }
            let gate = fixture.block(call: 2)
            fixture.set([b]); service.refresh(force: true)
            await waitUntil { fixture.calls == 2 }
            service.invalidate(clear: true)
            check(service.frames.isEmpty, "Explicit reset should clear cached geometry")
            fixture.set([c]); service.refresh(force: true)
            gate.signal()
            await waitUntil { service.frames == [screenFrame(c)] }
            check(updates == 2 && fixture.calls == 3, "Explicit reset accepted a stale read")
            service.stop()
        }
        do {
            let fixture = ObstructionReaderFixture([a])
            let gate = fixture.block(call: 1)
            let service = WindowObstructionService(reader: { fixture.read() })
            var updates = 0
            service.onUpdate = { updates += 1 }
            service.refresh()
            await waitUntil { fixture.calls == 1 }
            service.refresh(force: true)
            service.stop()
            check(service.frames.isEmpty, "Stop must release cached geometry")
            gate.signal()
            await settle()
            service.refresh(force: true); service.invalidate(); service.refresh(force: true)
            await settle()
            check(updates == 0 && fixture.calls == 1 && service.frames.isEmpty,
                  "Stopped service published a late result or started its pending read")
        }
        do {
            let fixture = ObstructionReaderFixture([a])
            let gate = fixture.block(call: 1)
            var service: WindowObstructionService? = WindowObstructionService(reader: { fixture.read() })
            let wasReleased = { [weak service] in service == nil }
            var updates = 0
            service?.onUpdate = { updates += 1 }
            service?.refresh()
            await waitUntil { fixture.calls == 1 }
            service = nil
            check(wasReleased(), "In-flight reader retained its owner")
            gate.signal()
            await settle()
            check(updates == 0, "Released owner received a late callback")
        }
    }
}
