import Darwin
import Foundation

enum AIQuotaCursor {
    static func binary(for source: CursorQuotaSource, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> URL? {
        let name = source == .cursorCLI ? "cursor-agent" : "grok"
        let directories = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
            + searchPath.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        return directories.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }.first { candidate in
            let target = candidate.resolvingSymlinksInPath()
            return FileManager.default.isExecutableFile(atPath: target.path)
                && (try? target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && (source == .xSubscription || !target.lastPathComponent.lowercased().contains("grok"))
        }
    }

    static func read(source: CursorQuotaSource) async throws -> AIQuotaSnapshot {
        guard let executable = binary(for: source) else { throw source == .cursorCLI ? AIQuotaError.cursorMissing : .grokMissing }
        return try await read(source: source, executable: executable)
    }

    static func read(source: CursorQuotaSource, executable: URL,
                     environment: [String: String] = ProcessInfo.processInfo.environment, timeout: TimeInterval = 25) async throws -> AIQuotaSnapshot {
        let task = Task.detached(priority: .utility) { () throws -> AIQuotaSnapshot in
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("dualdock-quota-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: workspace) }
            let keys = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "XDG_CONFIG_HOME", "XDG_STATE_HOME",
                        "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_RUNTIME_DIR", "CURSOR_CONFIG_DIR", "GROK_HOME",
                        "SSL_CERT_FILE", "SSL_CERT_DIR", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "ALL_PROXY",
                        "https_proxy", "http_proxy", "no_proxy", "all_proxy"]
            var env = environment.filter { keys.contains($0.key) }
            env["PATH"] = (env["PATH"] ?? "") + ":/usr/bin:/bin"
            env["TERM"] = "xterm-256color"
            env["LANG"] = "en_US.UTF-8"
            env["LC_ALL"] = "en_US.UTF-8"
            env["NO_OPEN_BROWSER"] = "1"
            let command = QuotaCLIInvocation(binary: executable, environment: env, deadline: deadline, workingDirectory: workspace)
            let version = try command.run(["--version"])
            guard version.exitCode == 0 else { throw version.failure }
            let tag = String(decoding: version.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            switch source {
            case .cursorCLI:
                guard tag.range(of: #"^20\d{2}\.\d{2}\.\d{2}-[a-fA-F0-9]+$"#, options: .regularExpression) != nil,
                      String(tag.prefix(10)) >= "2026.07.13" else { throw AIQuotaError.cursorOutdated }
                let help = try command.run(["--help"])
                guard String(decoding: help.stdout, as: UTF8.self).contains("Start the Cursor Agent") else { throw AIQuotaError.cursorOutdated }
                let status = try command.run(["status", "--format", "json"])
                guard status.exitCode == 0 else { throw status.failure }
                guard let identity = try? JSONSerialization.jsonObject(with: status.stdout) as? [String: Any],
                      let authenticated = identity["isAuthenticated"] as? Bool else { throw AIQuotaError.invalid }
                guard authenticated else { throw AIQuotaError.signIn }
                return try CursorQuotaTerminal.read(source: source, binary: executable, arguments: ["--trust"], environment: env,
                                                    workspace: workspace, deadline: deadline)
            case .xSubscription:
                guard tag.hasPrefix("grok ") else { throw AIQuotaError.grokMissing }
                let support = try command.run(["usage", "--help"])
                let help = String(decoding: support.stdout, as: UTF8.self)
                guard support.exitCode == 0 && help.contains("--json") && help.contains("plan") else { throw AIQuotaError.unavailable }
                let output = try command.run(["usage", "--json"])
                // A successful report that identifies another plan (or cannot
                // establish a shared plan) must never fall back to unrelated data.
                if output.exitCode == 0 { return try CursorQuotaReport.sharedJSON(output.stdout, now: Date()) }
                let message = String(decoding: output.stderr, as: UTF8.self)
                guard message.contains("Run /usage inside grok") else { throw output.failure }
                return try CursorQuotaTerminal.read(source: source, binary: executable,
                    arguments: ["--no-subagents", "--no-memory", "--disable-web-search"], environment: env,
                    workspace: workspace, deadline: deadline)
            }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
