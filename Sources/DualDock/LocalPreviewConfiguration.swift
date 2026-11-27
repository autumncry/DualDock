import Foundation

enum LocalPreviewConfiguration {
    static let bundleID = "local.ronny.DualDock3Preview"
    static let releaseBundleID = "local.ronny.DualDock3"

    static var isPreview: Bool { Bundle.main.bundleIdentifier != releaseBundleID }

    static var releaseDataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DualDock 3", isDirectory: true)
    }

    /// A portable trial keeps its settings beside the bundle. The installed app
    /// has its own per-user Application Support directory.
    static func directory(bundle: URL, override: String?, preview: Bool) throws -> URL {
        if !preview {
            return override.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? releaseDataDirectory
        }
        let root = bundle.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let url = (override.map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("LocalData"))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/") else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return url
    }
}
