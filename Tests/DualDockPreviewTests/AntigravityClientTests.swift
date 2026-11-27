import Darwin
import Foundation
import XCTest
@testable import DualDock

final class AntigravityClientTests: XCTestCase {
    private let example = #"{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"Weekly","remaining_fraction":0.65,"reset_time":"2027-01-04T08:00:00Z"}]}]}}}"#

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("test agy " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func fixture(version: String = "1.5.18", onUsage: String) throws -> URL {
        let binary = try directory().appendingPathComponent("agy")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$0.calls"
        if [ "$#" -eq 1 ] && [ "$1" = "--version" ]; then
            echo '\(version)'
            exit 0
        fi
        [ "$#" -eq 4 ] && [ "$1" = "-p" ] && [ "$2" = "/usage" ] &&
          [ "$3" = "--output-format" ] && [ "$4" = "json" ] || exit 71
        if read -r line; then exit 72; fi
        \(onUsage)
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return binary
    }

    func testDiscoveryFromFinderEnvironmentAcceptsInstalledExecutableAndIgnoresDirectory() throws {
        let home = try directory(), local = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let agy = local.appendingPathComponent("agy")
        try FileManager.default.createDirectory(at: agy, withIntermediateDirectories: true)
        XCTAssertNotEqual(AIQuotaAntigravity.executable(home: home, searchPath: "/usr/bin:/bin"), agy)
        try FileManager.default.removeItem(at: agy)
        let target = try fixture(onUsage: "exit 0")
        try FileManager.default.createSymbolicLink(at: agy, withDestinationURL: target)
        XCTAssertEqual(AIQuotaAntigravity.executable(home: home, searchPath: "/usr/bin:/bin")?.path, agy.path)
    }

    func testVersionAndReadOnlyCommandWithFullStderrAndClosedStdin() async throws {
        let binary = try fixture(version: "1.1.11", onUsage: """
        /usr/bin/head -c 131072 /dev/zero >&2
        printf '%s' '\(example)'
        """)
        let reading = try await AIQuotaAntigravity.read(binary: binary, environment: [:], timeout: 4)
        let window = try XCTUnwrap(reading.windows.first)
        XCTAssertEqual(window.remainingPercent, 65)
        XCTAssertNotNil(window.reset)
        let trace = try String(contentsOfFile: binary.path + ".calls", encoding: .utf8)
        XCTAssertEqual(trace.components(separatedBy: .newlines).filter { !$0.isEmpty },
                       ["--version", "-p /usage --output-format json"])
    }

    func testOldUnknownAndPrereleaseVersionsNeverReceiveSlashCommand() async throws {
        for version in ["1.1.10", "1.1.11-beta.3", "unable to determine the CLI version"] {
            let binary = try fixture(version: version, onUsage: "exit 99")
            do {
                _ = try await AIQuotaAntigravity.read(binary: binary, environment: [:], timeout: 3)
                XCTFail("Expected the version gate to stop here")
            } catch let error as AIQuotaError { XCTAssertEqual(error, .antigravityOutdated) }
            XCTAssertEqual(try String(contentsOfFile: binary.path + ".calls", encoding: .utf8), "--version\n")
        }
    }

    func testFailureClassificationAndOutputLimit() async throws {
        for (action, expected): (String, AIQuotaError) in [
            ("echo 'Not authenticated; please sign in to Antigravity' >&2; exit 1", .signIn),
            ("echo 'dial tcp: connection refused' >&2; exit 1", .unavailable),
            ("printf 'invalid JSON'", .invalid),
            ("/usr/bin/head -c 1100000 /dev/zero", .invalid)
        ] {
            let binary = try fixture(onUsage: action)
            do {
                _ = try await AIQuotaAntigravity.read(binary: binary, environment: [:], timeout: 3)
                XCTFail("Expected the read to fail")
            } catch let error as AIQuotaError { XCTAssertEqual(error, expected) }
        }
    }

    func testTimeoutAndCancellationStopChildrenWithOpenPipes() async throws {
        for shouldCancel in [true, false] {
            let binary = try fixture(onUsage: """
            trap '' TERM
            /bin/sleep 20 &
            printf '%d %d\\n' "$$" "$!" > "$0.pids"
            wait
            """)
            let marker = binary.path + ".pids"
            let task = Task {
                try await AIQuotaAntigravity.read(binary: binary, environment: [:], timeout: shouldCancel ? 12 : 1)
            }
            for _ in 0..<160 {
                if FileManager.default.fileExists(atPath: marker) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let raw = try String(contentsOfFile: marker, encoding: .utf8)
            let pids = raw.split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
            XCTAssertEqual(pids.count, 2)
            if shouldCancel { task.cancel() }
            do {
                _ = try await task.value
                XCTFail("Expected the process to stop")
            } catch is CancellationError {
                XCTAssertTrue(shouldCancel)
            } catch let error as AIQuotaError {
                XCTAssertFalse(shouldCancel)
                XCTAssertEqual(error, .timeout)
            }
            for _ in 0..<100 {
                if pids.allSatisfy({ kill($0, 0) != 0 }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            for pid in pids { XCTAssertNotEqual(kill(pid, 0), 0, "CLI or its child did not exit") }
        }
    }
}
