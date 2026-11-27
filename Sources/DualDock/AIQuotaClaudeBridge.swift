import Foundation
import Darwin
import CryptoKit

/// The only persistent output of a status-line event is a whitelist of limits.
enum AIQuotaClaudeBridge {
    static let argument = "--capture-claude-quota"
    static let snapshotFile = "claude-quota.json"
    static let connectionFile = "claude-quota-connection"
    private static let marker = "# DualDock quota bridge v1 "

    struct Connection: Codable {
        let token: UUID
        let commandHash: String
    }

    static var runtimeDirectory: URL {
        LocalPreviewConfiguration.isPreview
            ? Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("LocalData")
            : LocalPreviewConfiguration.releaseDataDirectory
    }

    static func connection(in directory:URL) -> Connection? {
        guard let bytes = try? Data(contentsOf:directory.appendingPathComponent(connectionFile)) else { return nil }
        return try? JSONDecoder().decode(Connection.self, from:bytes)
    }

    private static func hash(_ text:String) -> String {
        SHA256.hash(data:Data(text.utf8)).map { String(format:"%02x",$0) }.joined()
    }

    /// Serializes overlapping status-line invocations and disconnect. Keep the lock
    /// across generation verification AND rename, so a late writer cannot revive a revoked feed.
    private static func locked<T>(in directory:URL, _ operation:() throws -> T) throws -> T {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let fd = Darwin.open(directory.appendingPathComponent(".ai-quota.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AIQuotaError.writeFailed }
        defer { _ = Darwin.close(fd) }
        let end = ProcessInfo.processInfo.systemUptime + 0.3
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, ProcessInfo.processInfo.systemUptime < end else { throw AIQuotaError.conflict }
            usleep(5_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of:"'",with:"'\\''") + "'"
    }

    static var settingsFile: URL {
        let value = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? ""
        let base = value.hasPrefix("/") ? URL(fileURLWithPath:value) : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return base.appendingPathComponent("settings.json")
    }

    static func handleInvocation() -> Bool {
        let args = CommandLine.arguments
        guard args.dropFirst().first == argument else { return false }
        guard args.count == 3, let token = UUID(uuidString:args[2]) else { return true }
        let folder = runtimeDirectory
        do {
            guard connection(in:folder)?.token == token else { return true }
            var bytes = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount:8192), !chunk.isEmpty {
                guard bytes.count + chunk.count <= 524288 else { return true }
                bytes.append(chunk)
            }
            try capture(bytes:bytes, directory:folder, token:token, now:Date())
        } catch { /* A quota update must never interfere with the user's status line. */ }
        return true
    }

    static func capture(bytes:Data, directory:URL, token:UUID, now:Date) throws {
        guard bytes.count <= 524288 else { return }
        let snapshot = try AIQuotaParser.claude(bytes,now:now)
        try locked(in:directory) {
            guard connection(in:directory)?.token == token else { return }
            let file = directory.appendingPathComponent(snapshotFile)
            if let data = try? Data(contentsOf:file),
               let saved = try? JSONDecoder().decode(AIQuotaSnapshot.self,from:data), saved.updated > now { return }
            try JSONEncoder().encode(snapshot).write(to:file,options:.atomic)
        }
    }

    static func install(in file: URL, executable: URL, directory: URL) throws -> UUID {
        try locked(in:directory) {
            let token = UUID()
            var settings = try readSettings(file)
            let previous = settings["statusLine"] as? [String:Any]
            if settings["statusLine"] != nil && (previous?["type"] as? String != "command" || !(previous?["command"] is String)) {
                throw AIQuotaError.conflict
            }
            let original = previous?["command"] as? String
            // A different DualDock install may own the existing hook.
            if original?.hasPrefix(marker) == true { throw AIQuotaError.conflict }
            var entry = previous ?? ["type":"command"]
            let command = wrapped(executable:executable,token:token,original:original)
            entry["command"] = command
            settings["statusLine"] = entry
            let tokenURL = directory.appendingPathComponent(connectionFile)
            try? FileManager.default.removeItem(at:directory.appendingPathComponent(snapshotFile))
            try JSONEncoder().encode(Connection(token:token,commandHash:hash(command))).write(to:tokenURL,options:.atomic)
            do { try writeSettings(settings,at:file,expected:previous) }
            catch { try? FileManager.default.removeItem(at:tokenURL); throw error }
            return token
        }
    }

    static func remove(from file:URL, directory:URL, token:UUID) throws {
        try locked(in:directory) {
            guard let binding = connection(in:directory), binding.token == token else { return }
            var settings = try readSettings(file)
            if var entry = settings["statusLine"] as? [String:Any], let installed = entry["command"] as? String,
               hash(installed) == binding.commandHash {
                let expected = entry
                let divider = "\n# original statusLine\n"
                if installed.hasPrefix(marker + token.uuidString + " existing\n"),
                   let split = installed.range(of:divider), installed.hasSuffix("\n)") {
                    entry["command"] = String(installed[split.upperBound...].dropLast(2))
                    settings["statusLine"] = entry
                } else if Set(entry.keys) == ["type","command"] { settings.removeValue(forKey:"statusLine") }
                else { entry["command"] = ":"; settings["statusLine"] = entry }
                try writeSettings(settings,at:file,expected:expected)
            }
            // If the user's command has changed, leave it untouched and revoke collection.
            try FileManager.default.removeItem(at:directory.appendingPathComponent(connectionFile))
            try? FileManager.default.removeItem(at:directory.appendingPathComponent(snapshotFile))
        }
    }

    private static func wrapped(executable:URL, token:UUID, original:String?) -> String {
        let helper = quote(executable.path)+" "+argument+" "+quote(token.uuidString)
        if let original {
            // Only tee runs under bash. The existing command remains in Claude's own shell.
            // The drainer keeps tee functional if the preview has moved or is unavailable.
            let tee = #"/usr/bin/tee >({ "$1" "$2" "$3"; /bin/cat >/dev/null; } >/dev/null 2>&1)"#
            let pipe = "/bin/bash -c "+quote(tee)+" -- "+helper
            return marker+token.uuidString+" existing\n"+pipe+" | (\n# original statusLine\n"+original+"\n)"
        }
        return marker+token.uuidString+" new\n"+helper+" >/dev/null 2>&1"
    }

    private static func readSettings(_ file:URL) throws -> [String:Any] {
        guard FileManager.default.fileExists(atPath:file.path) else { return [:] }
        let props = try file.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey])
        guard props.isSymbolicLink != true, (props.fileSize ?? 0) <= 2_097_152,
              let json = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any] else { throw AIQuotaError.conflict }
        return json
    }

    private static func writeSettings(_ value:[String:Any], at file:URL, expected:[String:Any]?) throws {
        // Re-read at commit so concurrent edits to other settings survive.
        var fresh = try readSettings(file)
        let current = fresh["statusLine"] as? NSDictionary
        if let expected { guard current?.isEqual(to:expected) == true else { throw AIQuotaError.conflict } }
        else if fresh["statusLine"] != nil { throw AIQuotaError.conflict }
        fresh["statusLine"] = value["statusLine"]
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        let bytes = try JSONSerialization.data(withJSONObject:fresh,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
        let dir = file.deletingLastPathComponent()
        let temporary = dir.appendingPathComponent(".dualdock-settings-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw AIQuotaError.writeFailed }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at:temporary) }
        try handle.write(contentsOf:bytes)
        let permissions = (try? FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600
        guard fchmod(fd, mode_t(permissions & 0o777)) == 0 else { throw AIQuotaError.writeFailed }
        // Avoid replacing concurrent edits outside DualDock's own lock.
        var previous = fresh
        previous["statusLine"] = expected
        guard NSDictionary(dictionary:try readSettings(file)).isEqual(to:previous) else { throw AIQuotaError.conflict }
        guard rename(temporary.path,file.path) == 0 else { throw AIQuotaError.writeFailed }
    }
}
