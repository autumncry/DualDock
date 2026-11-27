import AppKit
import Darwin
import DualDockCore
import Foundation

/// Promote user settings once. Login hooks, recovery journals, and credentials
/// belong to the bundle that created them and are never imported from a trial.
enum TrialSettingsMigration {
    static let marker = ".release-v3-settings"
    static let files = ["configuration.json", "tool-shelf.json", "dock-pages.json",
                        "tool-provider-state.json", "focus-timer.json", "ai-quota-settings.json", "language.txt"]

    @MainActor static func candidates(previousBundles: [URL], support: URL) -> [URL] {
        let portableID = "local.ronny.DualDock3Preview"
        let separateID = "local.ronny.DualDock3"
        let separate = support.appendingPathComponent("DualDock 3", isDirectory: true)
        func dataFolder(of bundle: URL) -> URL? {
            switch Bundle(url: bundle)?.bundleIdentifier {
            case portableID: return bundle.deletingLastPathComponent().appendingPathComponent("LocalData", isDirectory: true)
            case separateID: return separate
            default: return nil
            }
        }
        let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: portableID)
        return (previousBundles + [registered].compactMap { $0 }).compactMap(dataFolder) + [separate]
    }

    static func keepExisting(in destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("current\n".utf8).write(to: destination.appendingPathComponent(marker), options: .atomic)
    }

    struct DockRecoveryIssue: LocalizedError {
        let message: LocalizedNotice
        let records: [URL]
        var errorDescription: String? { message.text }
    }

    @MainActor @discardableResult
    static func migrate(to destination: URL, candidates: [URL], dockEnvironment: SystemDockService.Environment? = nil,
                        trialIsRunning: @MainActor () -> Bool = { !LegacyTrialHandoff.runningInstances().isEmpty }) throws -> URL? {
        let fm = FileManager.default
        let installed = destination.standardizedFileURL
        guard !fm.fileExists(atPath: installed.appendingPathComponent(marker).path) else { return nil }
        let config = "configuration.json"
        guard let trial = candidates.first(where: {
            $0.standardizedFileURL.resolvingSymlinksInPath() != installed.resolvingSymlinksInPath() &&
                fm.fileExists(atPath: $0.appendingPathComponent(config).path)
        }) else {
            try keepExisting(in: installed)
            return nil
        }

        var incoming: [String: Data] = [:]
        for name in files {
            let source = trial.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            let type = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard type.isRegularFile == true, type.isSymbolicLink != true else { throw CocoaError(.fileReadInvalidFileName) }
            let bytes = try Data(contentsOf: source)
            if name == "language.txt" {
                guard let raw = String(data: bytes, encoding: .utf8), AppLanguage(rawValue: raw) != nil else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            } else {
                guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                if name == config {
                    let decoded = try JSONDecoder().decode(DockConfiguration.self, from: bytes)
                    guard object["entries"] != nil, decoded.version <= DockConfiguration.currentVersion else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                } else if name == "tool-shelf.json" {
                    struct Shelf: Decodable { var version: Int; var layout: DockToolsLayout }
                    let shelf = try JSONDecoder().decode(Shelf.self, from: bytes)
                    guard shelf.version == 1, shelf.layout.isValid else { throw CocoaError(.fileReadCorruptFile) }
                }
            }
            incoming[name] = bytes
        }

        let parent = installed.deletingLastPathComponent()
        let backups = parent.appendingPathComponent("DualDock Backups", isDirectory: true)
        try fm.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let candidate = backups.appendingPathComponent("before-v3-" + UUID().uuidString, isDirectory: true)
        let hadSettings = fm.fileExists(atPath: installed.path)
        var committed = false
        defer { if !committed { try? fm.removeItem(at: candidate) } }
        if hadSettings {
            let type = try installed.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard type.isDirectory == true, type.isSymbolicLink != true else { throw CocoaError(.fileWriteInvalidFileName) }
            try fm.copyItem(at: installed, to: candidate)
        } else {
            try fm.createDirectory(at: candidate, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        for (file, data) in incoming {
            let stagedFile = candidate.appendingPathComponent(file)
            if (try? stagedFile.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                try fm.removeItem(at: stagedFile)
            }
            try data.write(to: stagedFile, options: .atomic)
        }
        try Data("trial\n".utf8).write(to: candidate.appendingPathComponent(marker), options: .atomic)
        // A crashed trial cannot release its native Dock preferences on quit.
        // Stage all user settings first; a failed recovery leaves them untouched.
        let trialDock = SystemDockService(directory: trial, environment: dockEnvironment ?? .system)
        if trialDock.hasRecoveryRecord {
            let record = trial.appendingPathComponent("system-dock-recovery.json")
            let releaseRecord = installed.appendingPathComponent(record.lastPathComponent)
            guard !fm.fileExists(atPath: releaseRecord.path) else {
                throw DockRecoveryIssue(message: .init(
                    "试用版和正式版都有系统 Dock 恢复记录。请先备份两份记录，在原应用中核实并恢复原来的系统 Dock 设置，正常退出后再重试。",
                    "Both installations have Dock recovery records. Back up both records, verify and restore the original Dock settings in the corresponding apps, then quit them normally and retry."),
                    records: [record, releaseRecord])
            }
            guard !trialIsRunning() else {
                throw DockRecoveryIssue(message: .init(
                    "旧试用版正在运行。请正常退出它，让它保存并恢复系统 Dock 设置，然后重新打开 DualDock。",
                    "The preview is running. Quit it normally so it can restore the system Dock, then reopen DualDock."),
                    records: [record])
            }
            do {
                let properties = try record.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                let folder = try trial.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true, folder.isSymbolicLink != true else {
                    throw SystemDockService.ServiceError.invalidJournal
                }
                // Uses the journal's validated keys and only restores values still owned by the trial.
                try trialDock.recoverIfNeeded()
            } catch {
                throw DockRecoveryIssue(message: .init(
                    "未能完成试用版系统 Dock 的恢复。请保留恢复记录，在旧试用版中恢复系统 Dock 并正常退出，然后重试。",
                    "The preview's Dock recovery could not finish. Keep its record, restore the system Dock in the preview, quit normally, then retry.")
                    .appending(SystemDockService.ServiceError.notice(for: error)), records: [record])
            }
        }

        if hadSettings {
            // One filesystem transaction installs the complete configuration and leaves
            // the original directory, including all files unknown to us, at the backup URL.
            let status = renameatx_np(AT_FDCWD, installed.path, AT_FDCWD, candidate.path, UInt32(RENAME_SWAP))
            guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            committed = true
            return candidate
        }
        try fm.moveItem(at: candidate, to: installed)
        committed = true
        return nil
    }
}
