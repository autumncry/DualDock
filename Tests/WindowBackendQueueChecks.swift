import AppKit
import DualDockCore

private final class ReadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [Int] = []
    private var cancellationObserved = false
    private var current = true

    func record(_ value: Int) { lock.lock(); operations.append(value); lock.unlock() }
    func observedCancellation() { lock.lock(); cancellationObserved = true; lock.unlock() }
    func invalidate() { lock.lock(); current = false; lock.unlock() }
    var isCurrent: Bool { lock.lock(); defer { lock.unlock() }; return current }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return operations }
    var observed: Bool { lock.lock(); defer { lock.unlock() }; return cancellationObserved }
}

/// Exercises the production serial read boundary with injected native work.
/// No NSWorkspace queries, AX access, visible panels or window mutations occur.
@main
struct WindowBackendQueueChecks {
    @MainActor static func main() async {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        func unavailable(_ value: DockWindowInventory) -> Bool {
            if case .unavailable = value { return true }; return false
        }
        func available(_ value: DockWindowInventory) -> Bool {
            if case .available = value { return true }; return false
        }
        func waitUntil(_ condition: () -> Bool) async {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        // Canceled menus must not each consume a native-read budget after an
        // earlier serial operation releases the worker.
        let queue = DispatchQueue(label: "test.dualdock.window-read-cancellation")
        let queued = ReadRecorder()
        let release = DispatchSemaphore(value: 0)
        queue.async { queued.record(-1); _ = release.wait(timeout: .now() + 2) }
        await waitUntil { queued.values == [-1] }
        check(queued.values == [-1], "serial queue gate did not start")
        let obsolete = (0..<12).map { index in
            Task {
                await WindowInteractionReadQueue.read(on: queue, while: { queued.isCurrent }) { _ in
                    queued.record(index)
                    return .available([])
                }
            }
        }
        // Give every request a chance to reach its dispatch continuation.
        for _ in 0..<20 { await Task.yield() }
        obsolete.forEach { $0.cancel() }
        let valid = Task {
            await WindowInteractionReadQueue.read(on: queue, while: { queued.isCurrent }) { _ in
                queued.record(100)
                return .available([])
            }
        }
        release.signal()
        for task in obsolete { check(unavailable(await task.value), "canceled queued read returned a usable inventory") }
        check(available(await valid.value), "canceling menus invalidated the subsequent valid read")
        check(queued.values == [-1, 100], "canceled queued reads still ran expensive native discovery")
        check(queued.isCurrent, "per-read cancellation advanced the shared action epoch")

        // In-flight discovery polls the same predicate before each bounded AX
        // request. Cancellation must release the queue for the next valid read.
        let active = ReadRecorder()
        let running = Task {
            await WindowInteractionReadQueue.read(on: queue, while: { active.isCurrent }) { allowed in
                active.record(1)
                let deadline = ProcessInfo.processInfo.systemUptime + 1
                while allowed(), ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                if !allowed() { active.observedCancellation() }
                return .available([])
            }
        }
        await waitUntil { active.values == [1] }
        check(active.values == [1], "active read did not start")
        let cancelledAt = ProcessInfo.processInfo.systemUptime
        running.cancel()
        let following = Task {
            await WindowInteractionReadQueue.read(on: queue, while: { active.isCurrent }) { _ in
                active.record(2)
                return .available([])
            }
        }
        check(unavailable(await running.value), "active canceled read published its result")
        check(available(await following.value), "valid read following active cancellation did not run")
        check(active.observed, "active native discovery did not observe cancellation")
        check(ProcessInfo.processInfo.systemUptime - cancelledAt < 0.5,
              "active cancellation left the valid read waiting for the full old budget")
        check(active.values == [1, 2] && active.isCurrent, "active cancellation invalidated another request")

        // A global stop has a separate epoch. Already-obsolete work never enters
        // discovery, but an independent fresh request can still use the worker.
        let stopped = ReadRecorder()
        stopped.invalidate()
        let superseded = await WindowInteractionReadQueue.read(on: queue, while: { stopped.isCurrent }) { _ in
            stopped.record(1)
            return .available([])
        }
        check(unavailable(superseded) && stopped.values.isEmpty, "obsolete global epoch entered discovery")
        let fresh = await WindowInteractionReadQueue.read(on: queue) { _ in .available([]) }
        check(available(fresh), "obsolete epoch poisoned a fresh independent read")

        print("Window backend queue: \(checks) checks, \(failures.count) failures; injected serial work only")
        failures.forEach { print("FAIL: \($0)") }
        if !failures.isEmpty { exit(1) }
    }
}
