import AppKit
import DualDockCore

/// An owned windowless app changes its Dock eligibility without activation.
/// The parent uses the production AppStore, the real workspace and an isolated configuration.
@main
struct RunningAppObservationChecks {
    @MainActor static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    @MainActor private static func run() throws {
        let args = CommandLine.arguments
        let dir = URL(fileURLWithPath: args[2], isDirectory: true)
        let application = NSApplication.shared
        if args[1] == "--policy-helper" {
            application.setActivationPolicy(.accessory)
            let timeout = ProcessInfo.processInfo.systemUptime + 20
            _ = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { _ in
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent("stop").path)
                    || ProcessInfo.processInfo.systemUptime > timeout {
                    application.terminate(nil)
                }
                for (flag, policy) in [("regular", NSApplication.ActivationPolicy.regular), ("accessory", .accessory)] {
                    let request = dir.appendingPathComponent(flag)
                    if FileManager.default.fileExists(atPath: request.path) {
                        try? FileManager.default.removeItem(at: request)
                        _ = application.setActivationPolicy(policy)
                    }
                }
            }
            application.run()
            return
        }

        func wait(_ detail: String, until condition: () -> Bool) throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.015))
            }
            guard condition() else {
                throw NSError(domain: "RunningAppObservationChecks", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: detail])
            }
        }
        func request(_ name: String) throws { try Data().write(to: dir.appendingPathComponent(name)) }

        application.setActivationPolicy(.prohibited)
        application.finishLaunching()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: args[1])
        let id = Bundle(url: fixture)!.bundleIdentifier!
        var config = DockConfiguration()
        config.hideSystemDock = false
        config.showBadges = false
        try JSONEncoder().encode(config).write(to: dir.appendingPathComponent("configuration.json"))
        let store = AppStore(directory: dir)
        defer { store.stopBackgroundServices() }

        let options = NSWorkspace.OpenConfiguration()
        options.activates = false
        options.addsToRecentItems = false
        options.arguments = ["--policy-helper", dir.path]
        var launched: NSRunningApplication?
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: fixture, configuration: options) { app, error in
            launched = app
            launchError = error
        }
        defer {
            try? request("stop")
            if let launched { try? wait("Fixture did not quit during cleanup") { launched.isTerminated } }
        }
        try wait("Fixture did not launch") { launched != nil || launchError != nil }
        if let launchError { throw launchError }
        guard let helper = launched else { fatalError("No fixture process") }
        try wait("Fixture not registered as accessory") {
            NSWorkspace.shared.runningApplications.contains(helper) && helper.activationPolicy == .accessory
        }
        // Give startup notifications a chance to settle before the policy changes.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
        precondition(!store.runningApps.contains { $0.id == id })

        for _ in 0..<2 {
            try request("regular")
            try wait("Workspace did not promote fixture") { helper.activationPolicy == .regular }
            let registeredAt = ProcessInfo.processInfo.systemUptime
            try wait("Dock did not add the newly regular app") { store.runningApps.contains { $0.id == id } }
            print(String(format: "Dock ready %.0f ms after observing regular status",
                         (ProcessInfo.processInfo.systemUptime - registeredAt) * 1000))
            precondition(store.displayedEntries.filter { $0.apps.first?.id == id }.count == 1)
            try request("accessory")
            try wait("Workspace did not demote fixture") { helper.activationPolicy == .accessory }
            try wait("Dock retained the demoted app") { !store.runningApps.contains { $0.id == id } }
        }

        store.stopBackgroundServices()
        try request("regular")
        try wait("Fixture did not promote after shutdown") { helper.activationPolicy == .regular }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        precondition(!store.runningApps.contains { $0.id == id }, "Observer remained active after shutdown")
        try request("stop")
        try wait("Fixture did not quit") { helper.isTerminated }
        print("Running-app observation: two accessory/regular round trips, unique entries and shutdown verified")
    }
}
