import AppKit

private final class ReaderFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private var mainThreadRead = false
    private var nextResult = DockBadgeReadResult(labels: ["example.app": "5"], status: .available)
    var blockFirst: DispatchSemaphore?

    var calls: Int { lock.lock(); defer { lock.unlock() }; return callCount }
    var usedMainThread: Bool { lock.lock(); defer { lock.unlock() }; return mainThreadRead }

    func setResult(_ result: DockBadgeReadResult) {
        lock.lock(); defer { lock.unlock() }
        nextResult = result
    }

    func read(_ input: DockBadgeReadInput) -> DockBadgeReadResult {
        lock.lock()
        callCount += 1
        let number = callCount
        mainThreadRead = mainThreadRead || Thread.isMainThread
        let result = nextResult
        lock.unlock()
        if number == 1 { blockFirst?.wait() }
        return result
    }
}

@main
struct DockBadgeServiceChecks {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await checks()
            print("7 badge service checks passed; injected readers only")
            exit(0)
        }
        CFRunLoopRun()
    }

    @MainActor
    private static func service(_ fixture: ReaderFixture) -> DockBadgeService {
        DockBadgeService(reader: { fixture.read($0) }, inputProvider: {
            DockBadgeReadInput(applications: [DockBadgeApplication(bundleID: "example.app", processID: 123)],
                               dockProcessID: nil, accessibilityTrusted: false)
        })
    }

    @MainActor
    private static func waitUntil(_ predicate: @escaping @MainActor () -> Bool, timeout: Double = 1) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        precondition(predicate(), "Timed out waiting for expected badge service state")
    }

    @MainActor
    private static func checks() async {
        do {
            let fixture = ReaderFixture()
            let reader = service(fixture)
            var updates: [DockBadgeReadResult] = []
            reader.onUpdate = { updates.append(DockBadgeReadResult(labels: $0, status: $1)) }
            precondition(fixture.calls == 0 && updates.isEmpty)
            reader.setEnabled(false)
            reader.setEnabled(false)
            precondition(updates == [DockBadgeReadResult(labels: [:], status: .disabled)])
            reader.setEnabled(true)
            await waitUntil { updates.last?.labels["example.app"] == "5" }
            precondition(!fixture.usedMainThread)
            let count = updates.count
            reader.refresh()
            await waitUntil { fixture.calls >= 2 }
            try? await Task.sleep(nanoseconds: 30_000_000)
            precondition(updates.count == count, "Unchanged results should not redraw tiles")
            reader.stop()
            print("PASS inert initialization, background reads, unchanged-result suppression")
        }

        do {
            let fixture = ReaderFixture()
            let gate = DispatchSemaphore(value: 0)
            fixture.blockFirst = gate
            let reader = service(fixture)
            var updates: [DockBadgeReadResult] = []
            reader.onUpdate = { updates.append(DockBadgeReadResult(labels: $0, status: $1)) }
            reader.setEnabled(true)
            await waitUntil { fixture.calls == 1 }
            reader.setEnabled(false)
            precondition(updates.last?.status == .disabled && updates.last?.labels.isEmpty == true)
            gate.signal()
            try? await Task.sleep(nanoseconds: 100_000_000)
            precondition(updates.allSatisfy { $0.status == .disabled })
            print("PASS disable clears immediately and discards in-flight results")
        }

        do {
            let fixture = ReaderFixture()
            let gate = DispatchSemaphore(value: 0)
            fixture.blockFirst = gate
            let reader = service(fixture)
            var updates: [DockBadgeReadResult] = []
            reader.onUpdate = { updates.append(DockBadgeReadResult(labels: $0, status: $1)) }
            reader.setEnabled(true)
            await waitUntil { fixture.calls == 1 }
            reader.setEnabled(false)
            fixture.setResult(DockBadgeReadResult(labels: ["example.app": "9"], status: .available))
            reader.setEnabled(true)
            gate.signal()
            await waitUntil { updates.last?.labels["example.app"] == "9" }
            precondition(!updates.contains { $0.labels["example.app"] == "5" })
            reader.stop()
            print("PASS re-enable publishes a fresh generation, never stale labels")
        }

        do {
            let fixture = ReaderFixture()
            let gate = DispatchSemaphore(value: 0)
            fixture.blockFirst = gate
            let reader = service(fixture)
            reader.setEnabled(true)
            await waitUntil { fixture.calls == 1 }
            for _ in 0..<10 { reader.refresh() }
            gate.signal()
            await waitUntil { fixture.calls == 2 }
            try? await Task.sleep(nanoseconds: 60_000_000)
            precondition(fixture.calls == 2, "Busy refreshes should coalesce")
            reader.stop()
            print("PASS repeated refresh requests coalesce behind one serial read")
        }

        do {
            let fixture = ReaderFixture()
            let reader = service(fixture)
            var last: DockBadgeReadResult?
            reader.onUpdate = { last = DockBadgeReadResult(labels: $0, status: $1) }
            reader.setEnabled(true)
            await waitUntil { last?.labels["example.app"] == "5" }
            fixture.setResult(DockBadgeReadResult(labels: [:], status: .unavailable))
            reader.refresh()
            await waitUntil { last?.status == .unavailable }
            precondition(last?.labels.isEmpty == true)
            reader.stop()
            print("PASS unavailable source removes stale counts without inventing zero")
        }

        do {
            let fixture = ReaderFixture()
            fixture.setResult(DockBadgeReadResult(labels: [:], status: .permissionRequired))
            let reader = service(fixture)
            var last: DockBadgeStatus?
            reader.onUpdate = { _, status in last = status }
            reader.setEnabled(true)
            await waitUntil { last == .permissionRequired }
            reader.stop()
            print("PASS permission status is reported without requesting access")
        }

        do {
            let fixture = ReaderFixture()
            let reader = service(fixture)
            var last: String?
            reader.onUpdate = { labels, _ in last = labels["example.app"] }
            reader.setEnabled(true)
            await waitUntil { last == "5" }
            fixture.setResult(DockBadgeReadResult(labels: ["example.app": "7"], status: .available))
            await waitUntil({ last == "7" }, timeout: 3)
            reader.stop()
            print("PASS periodic refresh detects changed counts without an explicit refresh")
        }
    }
}
