import AppKit
import DualDockCore

/// The trial keeps its own user data next to its app in the local project.
/// Read the stable configuration once, before the trial's first launch.
enum LocalPreviewConfiguration {
    static let bundleID = "local.ronny.DualDock3Preview"
    static let releaseBundleID = "local.ronny.DualDock"

    // Only the packaged release uses the stable installation's settings and updater.
    static var isPreview: Bool { Bundle.main.bundleIdentifier != releaseBundleID }

    static func directory(bundle: URL, override: String?) throws -> URL {
        let root = bundle.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let url = (override.map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("LocalData"))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/") else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return url
    }

    @MainActor static func seed(directory: URL, originalURL: URL?, displayIDs: [String]) throws {
        let destination = directory.appendingPathComponent("configuration.json")
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = DockConfiguration()
        config.customSizing = .visualDefault
        if let originalURL, let data = try? Data(contentsOf: originalURL),
           let stable = try? JSONDecoder().decode(DockConfiguration.self, from: data),
           stable.version <= DockConfiguration.currentVersion {
            config = stable
        } else {
            config.insert(SystemDockService.importPinnedApps())
        }
        // Keep the two bars reachable when both apps are running.
        for id in Set(displayIDs).union(config.displaySettings.keys) {
            var settings = config.displaySettings[id] ?? DockDisplaySettings()
            switch settings.edge {
            case .bottom: settings.edge = .top
            case .top: settings.edge = .bottom
            case .left: settings.edge = .right
            case .right: settings.edge = .left
            }
            config.displaySettings[id] = settings
        }
        config.hideSystemDock = false
        try JSONEncoder().encode(config).write(to: destination, options: .withoutOverwriting)
    }
}
