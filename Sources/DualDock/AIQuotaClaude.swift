import Foundation

enum AIQuotaClaude {
    static func read() async throws -> AIQuotaSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"] +
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        guard let candidate = dirs.lazy.map({ URL(fileURLWithPath: $0).appendingPathComponent("claude") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) &&
                (try? $0.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }) else {
            throw AIQuotaError.claudeMissing
        }
        return try await read(binary: candidate)
    }

    static func read(binary: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
                     timeout: TimeInterval = 20) async throws -> AIQuotaSnapshot {
        // Resolve a versioned native installer symlink once for this invocation.
        let executable = binary.resolvingSymlinksInPath()
        let worker = Task.detached(priority: .utility) {
            let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("DualDock-Usage-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: cwd) }
            let allowed = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "CLAUDE_CONFIG_DIR",
                           "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS", "HTTPS_PROXY", "HTTP_PROXY",
                           "ALL_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "all_proxy", "no_proxy",
                           "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"]
            var env = environment.filter { allowed.contains($0.key) }
            env["LANG"] = "en_US.UTF-8"
            env["LC_ALL"] = "en_US.UTF-8"
            env["TZ"] = "UTC"
            env["NO_COLOR"] = "1"
            env["DISABLE_TELEMETRY"] = "1"
            env["DISABLE_ERROR_REPORTING"] = "1"
            env["DISABLE_AUTOUPDATER"] = "1"
            let cli = QuotaCLIInvocation(binary: executable, environment: env,
                                         deadline: ProcessInfo.processInfo.systemUptime + timeout,
                                         missingError: .claudeMissing, workingDirectory: cwd)
            let version = try cli.run(["--version"])
            guard version.exitCode == 0 else { throw version.failure }
            // Unknown versions may send a slash command to a model even with --max-turns 0.
            // Widen only after testing the official binary's local command path offline.
            guard String(decoding: version.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    == "2.1.332 (Claude Code)" else { throw AIQuotaError.claudeUnsupported }

            let safe = ["--safe-mode", "--setting-sources", "", "--settings", #"{"disableAllHooks":true}"#]
            let auth = try cli.run(safe + ["auth", "status", "--json"])
            struct Login: Decodable { let loggedIn: Bool; let authMethod: String?; let apiProvider: String? }
            guard let identity = try? JSONDecoder().decode(Login.self, from: auth.stdout) else {
                throw auth.failure
            }
            guard identity.loggedIn, auth.exitCode == 0, identity.apiProvider == "firstParty",
                  identity.authMethod == "claude.ai" || identity.authMethod == "oauth_token" else { throw AIQuotaError.signIn }
            let output = try cli.run(safe + ["--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
                                              "--tools", "", "--max-turns", "0", "--no-session-persistence",
                                              "--output-format", "json", "-p", "/usage"])
            guard output.exitCode == 0 else { throw output.failure }
            return try AIQuotaClaudeParser.parse(output.stdout, now: Date())
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }
}
