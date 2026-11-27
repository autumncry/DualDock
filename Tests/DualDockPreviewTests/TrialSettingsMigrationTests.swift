import Foundation
import XCTest
import DualDockCore
@testable import DualDock

@MainActor
final class TrialSettingsMigrationTests: XCTestCase {
    private func fixture() throws -> (release: URL, trial: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let release = root.appendingPathComponent("DualDock")
        let trial = root.appendingPathComponent("LocalData")
        for folder in [release, trial] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (release, trial)
    }

    private func configuration(_ title: String) throws -> Data {
        var config = DockConfiguration()
        config.entries = [.init(name: title, apps: [.init(id: title, name: title, path: "/example.app")])]
        return try JSONEncoder().encode(config)
    }

    func testImportsTrialOnceAndBacksUpEntireFormalDirectoryBeforeSwitching() throws {
        let (release, trial) = try fixture()
        let original = try configuration("formal")
        let changed = try configuration("trial")
        try original.write(to: release.appendingPathComponent("configuration.json"))
        try changed.write(to: trial.appendingPathComponent("configuration.json"))
        try Data("keep".utf8).write(to: release.appendingPathComponent("other"))
        try Data("en".utf8).write(to: trial.appendingPathComponent("language.txt"))
        try Data("formal-journal".utf8).write(to: release.appendingPathComponent("system-dock-recovery.json"))
        try Data("fixture".utf8).write(to: trial.appendingPathComponent("claude-quota-connection"))
        let backup = try XCTUnwrap(TrialSettingsMigration.migrate(to: release, candidates: [trial]))
        func read(_ root: URL, _ path: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(path)) }
        XCTAssertEqual(try read(backup, "configuration.json"), original)
        XCTAssertEqual(try read(release, "configuration.json"), changed)
        XCTAssertEqual(try read(trial, "configuration.json"), changed)
        XCTAssertEqual(try read(backup, "other"), try read(release, "other"))
        XCTAssertEqual(try read(release, "language.txt"), Data("en".utf8))
        XCTAssertEqual(try read(release, "system-dock-recovery.json"), Data("formal-journal".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: release.appendingPathComponent("claude-quota-connection").path))
        try original.write(to: release.appendingPathComponent("configuration.json"))
        XCTAssertNil(try TrialSettingsMigration.migrate(to: release, candidates: [trial]))
        XCTAssertEqual(try read(release, "configuration.json"), original)
    }

    func testInvalidTrialNeverTouchesFormalPreferencesAndCanBeRetried() throws {
        let (release, trial) = try fixture()
        let original = try configuration("original")
        let incoming = try configuration("incoming")
        try original.write(to: release.appendingPathComponent("configuration.json"))
        try incoming.write(to: trial.appendingPathComponent("configuration.json"))
        let shelf = trial.appendingPathComponent("tool-shelf.json")
        try Data(#"{"version":100}"#.utf8).write(to: shelf)
        XCTAssertThrowsError(try TrialSettingsMigration.migrate(to: release, candidates: [trial]))
        XCTAssertEqual(try Data(contentsOf: release.appendingPathComponent("configuration.json")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: release.appendingPathComponent(TrialSettingsMigration.marker).path))
        try FileManager.default.removeItem(at: shelf)
        XCTAssertNotNil(try TrialSettingsMigration.migrate(to: release, candidates: [trial]))
    }

    private final class Preferences {
        var values: [String: Any] = ["autohide": false, "autohide-delay": 0.25]
        var writes = 0
        var reloads = 0
        var environment: SystemDockService.Environment {
            .init(read: { self.values[$0] }, write: { self.values[$0] = $1; self.writes += 1 },
                  synchronize: { true }, restart: { self.reloads += 1 })
        }
    }

    func testCrashedTrialRestoresOnlyRemainingOwnedDockValuesBeforeMigration() throws {
        let (release, trial) = try fixture()
        let prefs = Preferences()
        let desired = try configuration("incoming")
        try desired.write(to: trial.appendingPathComponent("configuration.json"))
        let service = SystemDockService(directory: trial, environment: prefs.environment)
        try service.setHidden(true)
        let writesAfterHide = prefs.writes
        let reloadsAfterHide = prefs.reloads
        prefs.values["autohide-delay"] = 0.75 // Subsequent edit by the user.
        XCTAssertNotNil(try TrialSettingsMigration.migrate(to: release, candidates: [trial],
                             dockEnvironment: prefs.environment, trialIsRunning: { false }))
        XCTAssertEqual(prefs.values["autohide"] as? Bool, false)
        XCTAssertEqual(prefs.values["autohide-delay"] as? Double, 0.75)
        XCTAssertEqual(prefs.writes, writesAfterHide + 1)
        XCTAssertEqual(prefs.reloads, reloadsAfterHide + 1)
        XCTAssertFalse(service.hasRecoveryRecord)
        XCTAssertFalse(FileManager.default.fileExists(atPath: release.appendingPathComponent("system-dock-recovery.json").path))
        XCTAssertEqual(try Data(contentsOf: release.appendingPathComponent("configuration.json")), desired)
    }

    func testJournalConflictRunningTrialAndBadJournalDoNotCommitOrWritePreferences() throws {
        let (release, trial) = try fixture()
        let original = try configuration("stable")
        try original.write(to: release.appendingPathComponent("configuration.json"))
        try configuration("trial").write(to: trial.appendingPathComponent("configuration.json"))
        let prefs = Preferences()
        let service = SystemDockService(directory: trial, environment: prefs.environment)
        try service.setHidden(true)
        let savedWrites = prefs.writes, savedReloads = prefs.reloads
        let trialJournal = trial.appendingPathComponent("system-dock-recovery.json")
        let formalJournal = release.appendingPathComponent("system-dock-recovery.json")
        let valid = try Data(contentsOf: trialJournal)
        func expectUnchanged(running: Bool, records: Int) throws {
            XCTAssertThrowsError(try TrialSettingsMigration.migrate(to: release, candidates: [trial],
                dockEnvironment: prefs.environment, trialIsRunning: { running })) {
                    XCTAssertEqual(($0 as? TrialSettingsMigration.DockRecoveryIssue)?.records.count, records)
            }
            XCTAssertEqual(prefs.writes, savedWrites)
            XCTAssertEqual(prefs.reloads, savedReloads)
            XCTAssertTrue(service.hasRecoveryRecord)
            XCTAssertFalse(FileManager.default.fileExists(atPath: release.appendingPathComponent(TrialSettingsMigration.marker).path))
            XCTAssertEqual(try Data(contentsOf: release.appendingPathComponent("configuration.json")), original)
        }
        try valid.write(to: formalJournal)
        try expectUnchanged(running: false, records: 2)
        XCTAssertEqual(try Data(contentsOf: formalJournal), valid)
        try FileManager.default.removeItem(at: formalJournal)
        try expectUnchanged(running: true, records: 1)
        try Data("corrupt".utf8).write(to: trialJournal)
        try expectUnchanged(running: false, records: 1)
        try valid.write(to: trialJournal)
        XCTAssertNotNil(try TrialSettingsMigration.migrate(to: release, candidates: [trial],
                            dockEnvironment: prefs.environment, trialIsRunning: { false }))
    }

    func testFreshInstallAndStableOnlyPaths() throws {
        let (release, trial) = try fixture()
        let original = try configuration("stable")
        try original.write(to: release.appendingPathComponent("configuration.json"))
        XCTAssertNil(try TrialSettingsMigration.migrate(to: release, candidates: []))
        XCTAssertEqual(try Data(contentsOf: release.appendingPathComponent("configuration.json")), original)
        try original.write(to: trial.appendingPathComponent("configuration.json"))
        let fresh = release.deletingLastPathComponent().appendingPathComponent("fresh")
        XCTAssertNil(try TrialSettingsMigration.migrate(to: fresh, candidates: [trial]))
        XCTAssertEqual(try Data(contentsOf: fresh.appendingPathComponent("configuration.json")), original)
    }
}
