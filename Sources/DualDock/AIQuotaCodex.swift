import Foundation
import Darwin

/// Only drives the documented app-server account APIs. No prompt/thread is created.
enum AIQuotaCodex {
    static func executable(override: String?) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let known = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", home + "/.local/bin/codex",
                     "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                     "/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex"]
        let paths = override.map { [$0] } ?? known
        return paths.map { URL(fileURLWithPath:$0) }.first { url in
            let name = url.lastPathComponent
            return (name == "codex" || name == "codex-cli" || name.hasPrefix("codex-aarch64-") || name.hasPrefix("codex-x86_64-"))
                && fm.isExecutableFile(atPath:url.path) && (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) != true
        }
    }

    static func read(binary: URL, environment: [String:String] = ProcessInfo.processInfo.environment,
                     timeout: TimeInterval = 12) async throws -> AIQuotaSnapshot {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority:.utility) {
                let process = Process(), input = Pipe(), output = Pipe()
                process.executableURL = binary
                process.arguments = ["app-server","--listen","stdio://"]
                process.currentDirectoryURL = FileManager.default.temporaryDirectory
                var env = environment.filter { key, _ in
                    ["HOME","PATH","CODEX_HOME","USER","LANG","TMPDIR","SSL_CERT_FILE","HTTP_PROXY","HTTPS_PROXY","NO_PROXY",
                     "http_proxy","https_proxy","no_proxy"].contains(key)
                }
                env["PATH"] = ([binary.deletingLastPathComponent().path, "/opt/homebrew/bin","/usr/local/bin","/usr/bin","/bin"] +
                               (env["PATH"] ?? "").components(separatedBy:":").filter { $0.hasPrefix("/") }).joined(separator:":")
                process.environment = env
                process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
                guard !cancellation.isCancelled else { throw CancellationError() }
                try process.run()
                defer {
                    try? input.fileHandleForWriting.close()
                    try? output.fileHandleForReading.close()
                    if process.isRunning {
                        process.terminate()
                        let end = ProcessInfo.processInfo.systemUptime + 0.25
                        while process.isRunning && ProcessInfo.processInfo.systemUptime < end { usleep(10_000) }
                        if process.isRunning { kill(process.processIdentifier,SIGKILL) }
                    }
                }
                _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                let deadline = ProcessInfo.processInfo.systemUptime + timeout
                var buffer = Data()
                var total = 0
                func send(_ message: [String:Any]) throws {
                    guard !cancellation.isCancelled else { throw CancellationError() }
                    var data = try JSONSerialization.data(withJSONObject:message)
                    data.append(10)
                    try input.fileHandleForWriting.write(contentsOf:data)
                }
                func response(_ id: Int) throws -> [String:Any] {
                    while ProcessInfo.processInfo.systemUptime < deadline {
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        if let eol = buffer.firstIndex(of:10) {
                            let line = Data(buffer[..<eol]); buffer.removeSubrange(...eol)
                            guard let obj = try? JSONSerialization.jsonObject(with:line) as? [String:Any],
                                  obj["id"] as? Int == id else { continue }
                            guard let result = obj["result"] as? [String:Any] else { throw AIQuotaError.unavailable }
                            return result
                        }
                        let fd = output.fileHandleForReading.fileDescriptor
                        var descriptor = pollfd(fd:fd,events:Int16(POLLIN),revents:0)
                        let ready = Darwin.poll(&descriptor,1,100)
                        if ready < 0 && errno == EINTR { continue }
                        if ready == 0 { continue }
                        guard ready > 0 else { throw AIQuotaError.unavailable }
                        var scratch = [UInt8](repeating:0,count:8192)
                        let n = Darwin.read(fd, &scratch, scratch.count)
                        if n < 0 && errno == EINTR { continue }
                        guard n > 0 else { throw AIQuotaError.unavailable }
                        total += n
                        guard total <= 2_097_152 else { throw AIQuotaError.invalid }
                        buffer.append(contentsOf:scratch.prefix(n))
                    }
                    throw AIQuotaError.timeout
                }
                try send(["id":1,"method":"initialize","params":["clientInfo":["name":"dualdock","title":"DualDock","version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "dev"]]])
                _ = try response(1)
                try send(["method":"initialized"])
                try send(["id":2,"method":"account/read","params":["refreshToken":false]])
                let identity = try response(2)
                guard let account = identity["account"] as? [String:Any],
                      let type = account["type"] as? String, type.lowercased().hasPrefix("chatgpt") else { throw AIQuotaError.signIn }
                try send(["id":3,"method":"account/rateLimits/read"])
                let limits = try response(3)
                // A local sign-out or account switch can occur while the server fetches limits.
                try send(["id":4,"method":"account/read","params":["refreshToken":false]])
                guard let current = try response(4)["account"] as? [String:Any],
                      current["type"] as? String == account["type"] as? String,
                      current["email"] as? String == account["email"] as? String else { throw AIQuotaError.signIn }
                return try AIQuotaParser.codex(JSONSerialization.data(withJSONObject:limits), now:Date())
            }.value
        } onCancel: { cancellation.cancel() }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }
}
