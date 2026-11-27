import Darwin
import Foundation

enum AIQuotaAntigravity {
    static func executable(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> URL? {
        // Finder-launched apps usually do not inherit the user's shell PATH.
        let directories = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
            + searchPath.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        return directories.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent("agy") }.first { url in
            FileManager.default.isExecutableFile(atPath: url.path) &&
                (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    static func read() async throws -> AIQuotaSnapshot {
        guard let binary = executable() else { throw AIQuotaError.antigravityMissing }
        return try await read(binary: binary)
    }

    static func read(binary: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
                     timeout: TimeInterval = 20) async throws -> AIQuotaSnapshot {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            let keep: Set<String> = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL",
                "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR",
                "SSL_CERT_FILE", "SSL_CERT_DIR", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY",
                "http_proxy", "https_proxy", "no_proxy", "all_proxy"]
            var env = environment.filter { keep.contains($0.key) }
            env["NO_COLOR"] = "1"
            let cli = QuotaCLIInvocation(binary: binary, environment: env, deadline: deadline,
                                         missingError: .antigravityMissing)
            let version = try cli.run(["--version"])
            guard version.exitCode == 0 else { throw version.failure }
            guard hasUsageCommand(version.stdout) else { throw AIQuotaError.antigravityOutdated }
            // In older versions an unrecognized slash command could be sent as a prompt.
            let report = try cli.run(["-p", "/usage", "--output-format", "json"])
            guard report.exitCode == 0 else { throw report.failure }
            try Task.checkCancellation()
            do { return try AIQuotaAntigravityParser.parse(report.stdout, now: Date()) }
            catch {
                if report.failure == .signIn { throw AIQuotaError.signIn }
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    private static func hasUsageCommand(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:(?:Antigravity(?: CLI)?|agy)(?: version)?[ :\t]+)?v?([0-9]+)\.([0-9]+)\.([0-9]+)(-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return false }
        let parts = (1...3).compactMap { index in
            Range(match.range(at: index), in: text).flatMap { Int(text[$0]) }
        }
        guard parts.count == 3 else { return false }
        let minimum = [1, 1, 11]
        return minimum.lexicographicallyPrecedes(parts) || (parts == minimum && match.range(at: 4).location == NSNotFound)
    }
}
