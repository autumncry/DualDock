import XCTest
@testable import DualDock

final class ClaudeActiveQuotaTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-12-31T22:00:00Z")!
    private func report(_ text: String, command: String = "usage", turns: Int = 0) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type":"result", "local_command":command,
            "num_turns":turns, "is_error":false, "total_cost_usd":0, "usage":["input_tokens":0,"output_tokens":0], "result":text])
    }

    func testCurrentSessionWeekAndScopedPlanWindowInOfficialText() throws {
        let text = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 23% used · resets Jan 1 at 1:35am (UTC)
        Current week (all models): 46% used · resets Jan 5 at 9:05pm (Asia/Singapore)
        Current week (Sonnet only): 35% used · resets Jan 4 at 12am (UTC)
        Estimated tokens for a plugin: 94% used
        """
        let snapshot = try AIQuotaClaudeParser.parse(report(text), now: now)
        XCTAssertEqual(snapshot.windows.map(\.remainingPercent), [77,54,65])
        XCTAssertEqual(snapshot.windows.map(\.minutes), [300,10080,10080])
        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour","seven_day","seven_day/sonnet"])
        XCTAssertEqual(snapshot.windows.map(\.reset), ["2027-01-01T01:35:00Z","2027-01-05T13:05:00Z","2027-01-04T00:00:00Z"].map { ISO8601DateFormatter().date(from: $0) })
        XCTAssertNil(snapshot.sourceIsCached)
    }

    func testCacheAndInvalidInputNeverBecomeLiveQuota() throws {
        let lines = "Showing last-known usage\nCurrent session: 0% used · resets 9:55pm (UTC)\nCurrent week (all models): 100% used · resets unknown"
        let cached = try AIQuotaClaudeParser.parse(report(lines), now: now)
        XCTAssertEqual(cached.sourceIsCached, true)
        XCTAssertEqual(cached.windows.map(\.remainingPercent), [100,0])
        XCTAssertEqual(cached.windows.first?.reset, ISO8601DateFormatter().date(from:"2026-12-31T21:55:00Z"))
        XCTAssertNil(cached.windows.last?.reset)
        for data in try [report("Total cost: $0.23\nCache hit: 36%"), report(lines,command:"help"), report(lines,turns:1)] {
            XCTAssertThrowsError(try AIQuotaClaudeParser.parse(data, now: now))
        }
    }

    private func fixture(version: String, authMethod: String = "claude.ai") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("claude")
        let json = String(decoding: try report("Current session: 11% used"), as: UTF8.self)
        try """
        #!/bin/sh
        echo "$*" >> "$0.trace"
        case "$*" in
            --version) printf '%s\\n' '\(version)' ;;
            *'auth status --json') echo '{"loggedIn":true,"authMethod":"\(authMethod)","apiProvider":"firstParty"}' ;;
            *' -p /usage') printf '%s\\n' '\(json)' ;;
            *) exit 1 ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:script.path)
        return script
    }

    func testUsesOnlyAuditedBinaryAndSubscriptionBeforeSendingLocalCommand() async throws {
        let script = try fixture(version:"2.1.332 (Claude Code)")
        let snapshot = try await AIQuotaClaude.read(binary:script,environment:[:],timeout:3)
        XCTAssertEqual(snapshot.windows.first?.remainingPercent,89)
        let trace = try String(contentsOfFile:script.path+".trace",encoding:.utf8)
        XCTAssertTrue(trace.contains("--safe-mode"))
        XCTAssertTrue(trace.contains("--no-session-persistence"))
        XCTAssertTrue(trace.contains("--strict-mcp-config"))
        XCTAssertTrue(trace.contains("--output-format json -p /usage"))
        for (version, auth, error) in [("2.1.331 (Claude Code)","claude.ai",AIQuotaError.claudeUnsupported),
                                        ("2.1.333 (Claude Code)","claude.ai",.claudeUnsupported),
                                        ("2.1.332 (Claude Code)","api_key",.signIn)] {
            let unsafe = try fixture(version: version, authMethod: auth)
            do { _ = try await AIQuotaClaude.read(binary: unsafe,environment:[:]); XCTFail("Expected gate to reject this query") }
            catch let actual as AIQuotaError { XCTAssertEqual(actual,error) }
            XCTAssertFalse(try String(contentsOfFile:unsafe.path+".trace",encoding:.utf8).contains("/usage"))
        }
    }
}
