import Darwin
import Foundation

struct QuotaCLIOutput {
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

struct QuotaCLIInvocation {
    let binary: URL
    let environment: [String: String]
    let deadline: TimeInterval
    var missingError: AIQuotaError = .unavailable
    var workingDirectory: URL = FileManager.default.temporaryDirectory

    func run(_ arguments: [String]) throws -> QuotaCLIOutput {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw AIQuotaError.timeout }

        let process = Process()
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        do { try process.run() }
        catch {
            throw FileManager.default.fileExists(atPath: binary.path) ? AIQuotaError.unavailable : missingError
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
        var result = QuotaCLIOutput()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw AIQuotaError.timeout }
            let running = process.isRunning
            let ready = Darwin.poll(&descriptors, 2, running ? 70 : 0)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw AIQuotaError.unavailable }
            // A background helper may retain a write end. Once the CLI exits,
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
