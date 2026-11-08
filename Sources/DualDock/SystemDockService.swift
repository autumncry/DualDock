import AppKit
import Foundation
import DualDockCore

/// Owns only the two system Dock preferences changed by the hide switch.
/// A durable journal is written before either preference is touched.
@MainActor
final class SystemDockService {
    enum ServiceError: LocalizedError {
        case invalidJournal
        case synchronizationFailed
        case restartFailed(String)
        case rollbackFailed(original: String, recovery: String)

        var errorDescription: String? {
            switch self {
            case .invalidJournal:
                return "系统 Dock 恢复记录无法读取。请保留记录文件，检查后再开启隐藏选项。"
            case .synchronizationFailed:
                return "无法保存系统 Dock 设置。恢复记录已保留，可稍后重试恢复。"
            case .restartFailed(let detail):
                return "系统 Dock 设置已保存，但无法重新加载 Dock：\(detail)"
            case .rollbackFailed(let original, let recovery):
                return "隐藏系统 Dock 失败：\(original)；自动恢复也失败：\(recovery)"
            }
        }
    }

    /// Injectable so recovery is verifiable without changing the user's Dock.
    @MainActor
    struct Environment {
        var read: (String) -> Any?
        var write: (String, Any?) -> Void
        var synchronize: () -> Bool
        var restart: () throws -> Void

        static var system: Environment {
            let domain = "com.apple.dock" as CFString
            return Environment(
                read: { key in
                    CFPreferencesCopyValue(key as CFString, domain,
                                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                },
                write: { key, value in
                    CFPreferencesSetValue(key as CFString, value as CFPropertyList?, domain,
                                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                },
                synchronize: {
                    CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser,
                                             kCFPreferencesAnyHost)
                },
                restart: { try restartSystemDock() }
            )
        }
    }

    private struct PreferenceChange: Codable {
        let key: String
        let originalValue: Data?
        let appliedValue: Data
    }

    private struct RecoveryJournal: Codable {
        let version: Int
        let changes: [PreferenceChange]
    }

    private let journalURL: URL
    private let environment: Environment
    private static let appliedValues: [(key: String, value: NSNumber)] = [
        ("autohide", NSNumber(value: true)),
        ("autohide-delay", NSNumber(value: 1000.0))
    ]

    init(directory: URL) {
        self.journalURL = directory.appendingPathComponent("system-dock-recovery.json")
        self.environment = .system
    }

    init(directory: URL, environment: Environment) {
        self.journalURL = directory.appendingPathComponent("system-dock-recovery.json")
        self.environment = environment
    }

    var hasRecoveryRecord: Bool {
        FileManager.default.fileExists(atPath: journalURL.path)
    }

    func setHidden(_ hidden: Bool) throws {
        guard hidden else {
            try restore()
            return
        }

        if hasRecoveryRecord {
            let journal = try readJournal()
            let stillHidden = try journal.changes.allSatisfy { change in
                Self.equal(environment.read(change.key), try Self.decodeValue(change.appliedValue))
            }
            if stillHidden {
                // Preserve the original snapshot, but finish any interrupted reload.
                try finishEnabling()
                return
            }
            // An earlier rollback may have restored values without reloading Dock.
            // Finish that transaction first. A new explicit enable then snapshots
            // current settings, including any changes made outside DualDock.
            try restore()
        }

        let changes = try Self.appliedValues.map { setting in
            PreferenceChange(
                key: setting.key,
                originalValue: try environment.read(setting.key).map(Self.encodeValue),
                appliedValue: try Self.encodeValue(setting.value)
            )
        }
        let journal = RecoveryJournal(version: 1, changes: changes)
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(journal)
        try data.write(to: journalURL, options: .atomic)

        for setting in Self.appliedValues {
            environment.write(setting.key, setting.value)
        }
        try finishEnabling()
    }

    private func finishEnabling() throws {
        do {
            guard environment.synchronize() else {
                throw ServiceError.synchronizationFailed
            }
            try environment.restart()
        } catch {
            let originalError = error
            do {
                try restore()
            } catch {
                throw ServiceError.rollbackFailed(original: originalError.localizedDescription,
                                                  recovery: error.localizedDescription)
            }
            throw originalError
        }
    }

    func recoverIfNeeded() throws {
        try restore()
    }

    func restore() throws {
        guard hasRecoveryRecord else { return }
        let journal = try readJournal()
        // Validate and decode every value before changing any system preference.
        let decoded = try journal.changes.map { change in
            (key: change.key,
             original: try change.originalValue.map(Self.decodeValue),
             applied: try Self.decodeValue(change.appliedValue))
        }

        for setting in decoded {
            // A user or another Dock utility may have changed this setting since.
            // Restore only values that still equal the value DualDock installed.
            guard Self.equal(environment.read(setting.key), setting.applied) else { continue }
            environment.write(setting.key, setting.original)
        }

        // A previous attempt may have restored the values but failed to sync or
        // restart. Always finish those steps before deleting the recovery record.
        guard environment.synchronize() else {
            throw ServiceError.synchronizationFailed
        }
        try environment.restart()
        // Retain the record on any failure, allowing a later recovery attempt.
        try FileManager.default.removeItem(at: journalURL)
    }

    private func readJournal() throws -> RecoveryJournal {
        do {
            let journal = try JSONDecoder().decode(RecoveryJournal.self,
                                                  from: Data(contentsOf: journalURL))
            let allowedKeys = Self.appliedValues.map(\.key)
            guard journal.version == 1,
                  journal.changes.count == allowedKeys.count,
                  Set(journal.changes.map(\.key)) == Set(allowedKeys) else {
                throw ServiceError.invalidJournal
            }
            for change in journal.changes {
                guard let setting = Self.appliedValues.first(where: { $0.key == change.key }),
                      Self.equal(try Self.decodeValue(change.appliedValue), setting.value) else {
                    throw ServiceError.invalidJournal
                }
                if let original = change.originalValue { _ = try Self.decodeValue(original) }
            }
            return journal
        } catch {
            throw ServiceError.invalidJournal
        }
    }

    private static func encodeValue(_ value: Any) throws -> Data {
        // A dictionary wrapper supports scalar property-list values on every OS.
        try PropertyListSerialization.data(fromPropertyList: ["value": value],
                                           format: .binary, options: 0)
    }

    private static func decodeValue(_ data: Data) throws -> Any {
        guard let wrapper = try PropertyListSerialization.propertyList(from: data, options: [],
                                                                       format: nil) as? [String: Any],
              wrapper.count == 1, let value = wrapper["value"] else {
            throw ServiceError.invalidJournal
        }
        return value
    }

    private static func equal(_ first: Any?, _ second: Any?) -> Bool {
        switch (first, second) {
        case (nil, nil): return true
        case let (left as NSObject, right as NSObject): return left.isEqual(right)
        default: return false
        }
    }

    private static func restartSystemDock() throws {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").isEmpty else {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-u", NSUserName(), "Dock"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                ?? "退出状态 \(process.terminationStatus)"
            throw ServiceError.restartFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func importPinnedApps() -> [AppReference] {
        let domain = "com.apple.dock" as CFString
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard let tiles = CFPreferencesCopyValue("persistent-apps" as CFString, domain,
                                                kCFPreferencesCurrentUser,
                                                kCFPreferencesAnyHost) as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return tiles.compactMap { tile in
            guard let details = tile["tile-data"] as? [String: Any],
                  let url = resolveApplication(details),
                  let bundle = Bundle(url: url) else { return nil }
            let identifier = bundle.bundleIdentifier ?? url.path
            guard seen.insert(identifier).inserted else { return nil }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            return AppReference(id: identifier, name: name, path: url.path)
        }
    }

    private static func resolveApplication(_ details: [String: Any]) -> URL? {
        var candidates: [URL] = []
        if let file = details["file-data"] as? [String: Any],
           let location = file["_CFURLString"] as? String {
            if let url = URL(string: location), url.isFileURL {
                candidates.append(url)
            } else if location.hasPrefix("/") {
                candidates.append(URL(fileURLWithPath: location))
            }
        }
        for key in ["book", "bookmarkData"] {
            if let bookmark = details[key] as? Data {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark,
                                      options: [.withoutUI, .withoutMounting], relativeTo: nil,
                                      bookmarkDataIsStale: &stale) {
                    candidates.append(url)
                }
            }
        }
        if let identifier = details["bundle-identifier"] as? String,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            candidates.append(url)
        }
        return candidates.map(\.standardizedFileURL).first { url in
            guard url.isFileURL, url.pathExtension.lowercased() == "app",
                  let bundle = Bundle(url: url), let executable = bundle.executableURL else { return false }
            return FileManager.default.isExecutableFile(atPath: executable.path)
        }
    }
}
