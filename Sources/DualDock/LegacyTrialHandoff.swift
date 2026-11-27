import AppKit

/// Give the retired side-by-side builds time to flush their settings and release
/// any system Dock preferences they own before the production store opens.
@MainActor
enum LegacyTrialHandoff {
    static let bundleIdentifiers = ["local.ronny.DualDock3Preview", "local.ronny.DualDock3"]

    struct Instance {
        let bundle: URL?
        let quit: () -> Void
        let terminated: () -> Bool
    }

    static func runningInstances() -> [Instance] {
        bundleIdentifiers.flatMap { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .filter { !$0.isTerminated }
                .map { app in
                    Instance(bundle: app.bundleURL, quit: { _ = app.terminate() },
                             terminated: { app.isTerminated })
                }
        }
    }

    static func waitForExit(_ instances: [Instance], grace: TimeInterval = 4,
                            retry: () -> Bool) async -> Bool {
        while !Task.isCancelled {
            let pending = instances.filter { !$0.terminated() }
            if pending.isEmpty { return true }
            pending.forEach { $0.quit() }
            let deadline = ProcessInfo.processInfo.systemUptime + grace
            while pending.contains(where: { !$0.terminated() }) && ProcessInfo.processInfo.systemUptime < deadline {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return false }
            }
            if pending.allSatisfy({ $0.terminated() }) { return true }
            if !retry() { return false }
        }
        return false
    }
}
