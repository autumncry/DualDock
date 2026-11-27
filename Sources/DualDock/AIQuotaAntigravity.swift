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
            let cli = Invocation(binary: binary, environment: environment, deadline: deadline)
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

    private struct Output {
        var stdout = Data()
        var stderr = Data()
        var exitCode: Int32 = 0

        var failure: AIQuotaError {
            let diagnostic = (String(decoding: stderr, as: UTF8.self) + "\n" + String(decoding: stdout, as: UTF8.self)).lowercased()
            let signInMarkers = ["unauthenticated", "not authenticated", "not signed in", "not logged in", "login required",
                                 "please login", "please log in", "please sign in", "authentication required", "invalid_grant",
                                 "missing authentication credentials"]
            if signInMarkers.contains(where: diagnostic.contains) { return .signIn }
            if diagnostic.contains("deadline exceeded") || diagnostic.contains("request timed out") { return .timeout }
            return .unavailable
        }
    }

    private struct Invocation {
        let binary: URL
        let environment: [String: String]
        let deadline: TimeInterval

        func run(_ arguments: [String]) throws -> Output {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw AIQuotaError.timeout }

            let process = Process()
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice
            process.executableURL = binary
            process.arguments = arguments
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            let keep: Set<String> = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL",
                                     "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR",
                                     "SSL_CERT_FILE", "SSL_CERT_DIR", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY",
                                     "http_proxy", "https_proxy", "no_proxy", "all_proxy"]
            var env = environment.filter { keep.contains($0.key) }
            env["NO_COLOR"] = "1"
            process.environment = env
            do { try process.run() }
            catch {
                throw FileManager.default.fileExists(atPath: binary.path) ? AIQuotaError.unavailable : .antigravityMissing
            }
            let pid = process.processIdentifier
            // Foundation normally gives a new Process its own group on macOS.
            // Use the group only after verifying it belongs to this exact invocation.
            let privateGroup = getpgid(pid) == pid && pid != getpgrp()
            // Launch has duplicated the child ends. Drop our copies so we can observe EOF.
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            defer {
                try? stdout.fileHandleForReading.close()
                try? stderr.fileHandleForReading.close()
                if process.isRunning {
                    let target = privateGroup ? -pid : pid
                    _ = kill(target, SIGTERM)
                    let grace = ProcessInfo.processInfo.systemUptime + 0.3
                    while kill(target, 0) == 0 && ProcessInfo.processInfo.systemUptime < grace { usleep(10_000) }
                    if kill(target, 0) == 0 { _ = kill(target, SIGKILL) }
                }
            }

            var descriptors = [stdout, stderr].map {
                pollfd(fd: $0.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            }
            var result = Output()
            var chunk = [UInt8](repeating: 0, count: 8192)
            while true {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw AIQuotaError.timeout }
                let running = process.isRunning
                let ready = Darwin.poll(&descriptors, 2, running ? 70 : 0)
                if ready < 0 && errno == EINTR { continue }
                guard ready >= 0 else { throw AIQuotaError.unavailable }
                // A helper launched by agy may retain a write end. Once agy exits,
                // finish as soon as both pipes have been drained rather than waiting for that helper.
                if !running && ready == 0 { break }
                for index in descriptors.indices where descriptors[index].fd >= 0 && descriptors[index].revents != 0 {
                    let bytes = Darwin.read(descriptors[index].fd, &chunk, chunk.count)
                    if bytes < 0 && errno == EINTR { continue }
                    guard bytes >= 0 else { throw AIQuotaError.unavailable }
                    if bytes == 0 { descriptors[index].fd = -1; continue }
                    guard result.stdout.count + result.stderr.count + bytes <= 1_048_576 else { throw AIQuotaError.invalid }
                    if index == 0 { result.stdout.append(contentsOf: chunk.prefix(bytes)) }
                    else { result.stderr.append(contentsOf: chunk.prefix(bytes)) }
                }
            }
            result.exitCode = process.terminationStatus
            return result
        }
    }
}
