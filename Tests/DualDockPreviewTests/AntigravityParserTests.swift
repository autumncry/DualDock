import Foundation
import XCTest
@testable import DualDock

final class AntigravityParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func parse(_ groups: [[String: Any]]) throws -> AIQuotaSnapshot {
        let report: [String: Any] = [
            "status": "SUCCESS",
            "response": "Ignore human-readable output",
            "usage": ["input_tokens": 43, "total_tokens": 92],
            "command": ["name": "usage", "data": ["groups": groups]]
        ]
        return try AIQuotaAntigravityParser.parse(JSONSerialization.data(withJSONObject: report), now: now)
    }

    func testOfficialUsageEnvelopeKeepsOnlyGeminiWindowsAndRealResetTimes() throws {
        let snapshot = try parse([
            ["name": "Claude and GPT models", "buckets": [
                ["id": "3p-weekly", "window": "weekly", "remaining_fraction": 1]
            ]],
            ["name": "Gemini Models", "description": "shared across Gemini models", "buckets": [
                ["id": "gemini-weekly", "name": "Weekly Limit Remaining", "window": "weekly",
                 "remaining_fraction": 0.625, "reset_time": "2026-12-10T08:00:00.123Z"],
                ["id": "gemini-5h", "name": "5 Hour Limit Remaining", "window": "5h",
                 "remaining_fraction": 0, "reset_time": "2026-12-01T10:00:00+02:00"]
            ]]
        ])
        XCTAssertEqual(snapshot.updated, now)
        XCTAssertEqual(snapshot.windows.map(\.id), ["gemini-5h", "gemini-weekly"])
        XCTAssertEqual(snapshot.windows.map(\.minutes), [300, 10080])
        XCTAssertEqual(snapshot.windows.map(\.remainingPercent), [0, 62.5])
        XCTAssertEqual(snapshot.windows.first?.reset,
                       ISO8601DateFormatter().date(from: "2026-12-01T08:00:00Z"))
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        XCTAssertEqual(snapshot.windows.last?.reset, fractional.date(from: "2026-12-10T08:00:00.123Z"))
    }

    func testMissingOrInvalidAllowancesAreNeverReportedAsExhausted() throws {
        let groups: [[String: Any]] = [
            ["name": "Gemini Models", "buckets": [
                ["id": "gemini-weekly", "window": "weekly", "reset_time": "2026-12-01T08:00:00Z"],
                ["id": "gemini-5h", "window": "5h", "remaining_fraction": true],
                ["id": "gemini-broken", "window": "weekly", "remaining_fraction": 1.2],
                ["id": "gemini-disabled", "window": "5h", "remaining_fraction": 0, "disabled": true]
            ]],
            ["name": "Gemini AI Credits", "buckets": [
                ["id": "gemini-credit", "window": "weekly", "remaining_amount": 123]
            ]],
            ["name": "Claude and GPT models", "buckets": [
                ["id": "gemini-weekly", "window": "weekly", "remaining_fraction": 0.8]
            ]],
            ["name": "Claude and GPT models", "buckets": [["id": "3p-weekly", "remaining_fraction": 0.8]]]
        ]
        XCTAssertThrowsError(try parse(groups)) { XCTAssertEqual($0 as? AIQuotaError, .unavailable) }
        XCTAssertThrowsError(try AIQuotaAntigravityParser.parse(Data(#"{"status":"SUCCESS","usage":{"total_tokens":14}}"#.utf8), now: now))
        XCTAssertThrowsError(try AIQuotaAntigravityParser.parse(Data(#"{"command":{"name":"credits","data":{"groups":[]}}}"#.utf8), now: now))
    }

    func testWeeklyOnlyPlanDoesNotInventAnotherWindowOrResetTime() throws {
        let row: [String: Any] = ["id": "gemini-weekly", "window": "Weekly", "remaining_fraction": 1]
        let snapshot = try parse([["name": "Gemini Models", "buckets": [row, row]]])
        XCTAssertEqual(snapshot.windows.map(\.id), ["gemini-weekly"])
        XCTAssertEqual(snapshot.windows.first?.minutes, 10080)
        XCTAssertEqual(snapshot.windows.first?.remainingPercent, 100)
        XCTAssertNil(snapshot.windows.first?.reset)
    }

    func testUnknownResetStaysAbsentAndZeroAmountIsNotAnAbsentAmount() throws {
        let snapshot = try parse([["name": "Gemini Models", "buckets": [
            ["id": "gemini-5h", "window": "5h", "remaining_fraction": 1.0, "reset_time": "1970-01-01T00:00:00Z"],
            ["id": "gemini-weekly", "window": "weekly", "remaining_amount": 0, "unit": "requests", "reset_time": "unknown"]
        ]]])
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 100)
        XCTAssertNil(snapshot.windows[0].reset)
        XCTAssertNil(snapshot.windows[1].remainingPercent)
        XCTAssertEqual(snapshot.windows[1].remainingCount, 0)
        XCTAssertEqual(snapshot.windows[1].unit, "requests")
        XCTAssertNil(snapshot.windows[1].reset)
    }
}
