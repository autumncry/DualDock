import Foundation
import XCTest
@testable import DualDock

final class CursorQuotaTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private let vendorOutput = """
    Usage · Pro                                                        Resets Dec 3
    Monthly plan and on-demand usage
    Category        Current           Usage
    Included        75% used          ██████░░
      Auto          100% used         ████████
      API           0% used           ░░░░░░░░
    On-Demand       $4.00 / $20.00    █░░░░░░░
    """

    func testLegacyIncludedPoolsAndDateOnly() throws {
        let report = try XCTUnwrap(CursorQuotaReport.legacy(vendorOutput, now: instant))
        XCTAssertEqual(report.windows.map(\.remainingPercent), [25, 0, 100])
        XCTAssertEqual(report.windows.map(\.label), ["Included", "Auto", "API"])
        XCTAssertNil(report.windows[0].reset)
        XCTAssertEqual(report.windows[0].resetDescription, "Dec 3 (UTC)")
        XCTAssertNil(CursorQuotaReport.legacy("Personal spend for the current billing period\nIncluded: 90% used", now: instant))
        XCTAssertNil(CursorQuotaReport.legacy("Monthly plan and on-demand usage\nOn-Demand: 30% used", now: instant))
    }

    func testSharedPoolMustBeWeeklyAndSeparateFromSessionCost() throws {
        let valid = Data(#"{"period_type":"USAGE_PERIOD_TYPE_WEEKLY","usage_pct":70.5,"is_unified_billing_user":true,"period_end_display":"Dec 3, 14:30","on_demand_used_cents":89}"#.utf8)
        let report = try CursorQuotaReport.sharedJSON(valid, now: instant)
        XCTAssertEqual(report.windows.first?.id, "x-weekly")
        XCTAssertEqual(report.windows.first?.remainingPercent, 29.5)
        XCTAssertEqual(report.windows.first?.resetDescription, "Dec 3, 14:30")
        for invalid in [#"{"period_type":"monthly","usage_pct":23}"#, #"{"period_type":"weekly","usage_pct":false}"#,
                        #"{"period_type":"weekly","usage_pct":23,"is_unified_billing_user":false}"#, #"{"total_tokens":98,"usd":3}"#] {
            XCTAssertThrowsError(try CursorQuotaReport.sharedJSON(Data(invalid.utf8), now: instant))
        }
        let screen = "Context usage   Usage limit   Session info\nWeekly limit (X Premium)\n\n████░░░░  43%\nResets: Dec 2, 11:32\nCredits: $4"
        let usage = try XCTUnwrap(CursorQuotaReport.sharedScreen(screen, now: instant))
        XCTAssertEqual(usage.windows.first?.remainingPercent, 57)
        XCTAssertNil(CursorQuotaReport.sharedScreen(screen.replacingOccurrences(of:"Weekly limit",with:"Monthly limit"), now: instant))
        XCTAssertNil(CursorQuotaReport.sharedScreen(screen.replacingOccurrences(of:"X Premium",with:"SuperGrok"), now: instant))
        XCTAssertNil(CursorQuotaReport.sharedScreen(screen.replacingOccurrences(of:"43%",with:"43% remaining"), now: instant))
    }

    private func temporaryDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func program(_ name: String, content: String, directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + content).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath:file.path)
        return file
    }

    func testCursorNativePTYUsesCompletionAndReadsRenderedScreen() async throws {
        let directory = try temporaryDirectory()
        let executable = try program("cursor-agent", content: #"""
        case "$1" in
          --version) echo 2026.11.22-e9042b2; exit;;
          --help) echo 'Start the Cursor Agent'; exit;;
          status) echo '{"isAuthenticated":true}'; exit;;
        esac
        test -t 0 && test -t 1 && test "$1" = --trust || exit 3
        stty raw -echo
        printf 'Cursor Agent type / for commands'
        prefix=$(dd bs=1 count=5 2>/dev/null)
        test "$prefix" = '/usag' || exit 4
        printf '\r\n/usag\r\n/usage   Show plan and on-demand usage'
        readback=$(dd bs=1 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')
        test "$readback" = 13 || exit 5
        printf '\033[2J\033[HUsage · Pro    Resets Dec 3\033[2;1HMonthly plan and on-demand usage\033[3;1HIncluded: 70%% used\033[4;1HAuto: 30%% used\033[5;1HAPI: 90%% used\r\nOn-Demand: Disabled\r\n'
        sleep 10
        """#, directory: directory)
        let result = try await AIQuotaCursor.read(source:.cursorCLI, executable:executable,timeout:4)
        XCTAssertEqual(result.windows.map(\.remainingPercent), [30,70,10])
    }

    func testWrongProductAndSignedOutCLIStopBeforeTerminal() async throws {
        let folder = try temporaryDirectory()
        let wrong = try program("agent", content:"echo 'grok 1.0.92'", directory:folder)
        let link = folder.appendingPathComponent("cursor-agent")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:wrong)
        do { _ = try await AIQuotaCursor.read(source:.cursorCLI,executable:link); XCTFail() }
        catch { XCTAssertEqual(error as? AIQuotaError,.cursorOutdated) }
        try FileManager.default.removeItem(at:link)
        let cursor = try program("cursor-agent",content:#"""
        case "$1" in
          --version) echo 2026.11.22-e9042b2;;
          --help) echo 'Start the Cursor Agent';;
          status) echo '{"isAuthenticated":false}';;
          *) exit 10;;
        esac
        """#,directory:folder)
        do { _ = try await AIQuotaCursor.read(source:.cursorCLI,executable:cursor); XCTFail() }
        catch { XCTAssertEqual(error as? AIQuotaError,.signIn) }
    }

    func testGrokUsagePanelFallbackSelectsOnlyShow() async throws {
        let dir = try temporaryDirectory()
        let cli = try program("grok",content:#"""
        case "$*" in
          --version) echo 'grok 1.0.92 (fixture)'; exit;;
          'usage --help') echo "Print your plan's usage limit --json"; exit;;
          'usage --json') echo "Run /usage inside grok instead." >&2; exit 1;;
        esac
        stty raw -echo
        printf 'Grok · type / for commands'
        [ "$(dd bs=1 count=5 2>/dev/null)" = '/usag' ] || exit 1
        printf '\r\n/usag\r\n/usage    View usage'
        get_cr() { [ "$(dd bs=1 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')" = 13 ]; }
        get_cr || exit 2
        printf '\033[H\033[2J/usage  \r\nshow    View usage\r\nmanage    Manage billing'
        [ "$(dd bs=1 count=4 2>/dev/null)" = 'show' ] || exit 3
        printf '\033[H/usage show'
        get_cr || exit 4
        printf '\033[2J\033[HContext usage   Usage limit   Session info\r\nWeekly limit (X Plus)\r\n████░░░░  24%%\r\nResets: Dec 2, 12:00\r\n'
        sleep 10
        """#,directory:dir)
        let value = try await AIQuotaCursor.read(source:.xSubscription,executable:cli,timeout:5)
        XCTAssertEqual(value.windows.first?.remainingPercent,76)
        XCTAssertEqual(value.windows.first?.resetDescription,"Dec 2, 12:00")
    }

    func testUnrecognizedCommandMenuNeverSendsReturn() async throws {
        let dir = try temporaryDirectory()
        let log = dir.appendingPathComponent("submitted")
        let cli = try program("cursor-agent",content:"""
        stty raw -echo
        printf 'Cursor Agent type / for commands'
        dd bs=1 count=5 of=/dev/null 2>/dev/null
        printf ' ordinary prompt /usag (unknown command)'
        dd bs=1 count=1 2>/dev/null > /dev/null && touch '\(log.path)'
        """,directory:dir)
        do {
            _ = try await Task.detached {
                try CursorQuotaTerminal.read(source:.cursorCLI, binary:cli, arguments:[], environment:["PATH":"/bin:/usr/bin"],
                    workspace:dir,deadline:ProcessInfo.processInfo.systemUptime + 0.8)
            }.value
            XCTFail("Should time out without an exact native command completion")
        } catch { XCTAssertEqual(error as? AIQuotaError,.timeout) }
        XCTAssertFalse(FileManager.default.fileExists(atPath:log.path))
    }

    func testGrokSuccessfulNonSharedReportNeverStartsTerminal() async throws {
        let dir = try temporaryDirectory()
        let unexpected = dir.appendingPathComponent("unexpected")
        let grok = try program("grok",content:"""
        case "$*" in
          --version) echo 'grok 1.0.92 (fixture)';;
          'usage --help') echo 'Print plan limit --json';;
          'usage --json') echo '{"period_type":"weekly","usage_pct":85,"is_unified_billing_user":false}';;
          *) touch '\(unexpected.path)'; exit 8;;
        esac
        """,directory:dir)
        do { _ = try await AIQuotaCursor.read(source:.xSubscription,executable:grok); XCTFail() }
        catch { XCTAssertEqual(error as? AIQuotaError,.unavailable) }
        XCTAssertFalse(FileManager.default.fileExists(atPath:unexpected.path))
    }

    func testXInvokesReadOnlyCommandWithNoSessionID() async throws {
        let folder = try temporaryDirectory()
        let grok = try program("grok",content:#"""
        case "$*" in
          --version) echo 'grok 1.0.92 (fixture)';;
          'usage --help') echo "Print your plan's usage limit --json";;
          'usage --json') echo '{"period_type":"weekly","usage_pct":15,"is_unified_billing_user":true,"period_end_display":"Dec 2, 12:20"}';;
          *) exit 8;;
        esac
        """#,directory:folder)
        let value=try await AIQuotaCursor.read(source:.xSubscription,executable:grok)
        XCTAssertEqual(value.windows.first?.remainingPercent,85)
    }
}
