import Foundation
import XCTest
@testable import DualDock

final class ClaudeStatusLineHandoffTests: XCTestCase {
    func testExplicitHandoffVerifiesOldCommandAndRetainsUserCommandExactly() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("LocalData"), fresh = base.appendingPathComponent("DualDock")
        let oldExe = base.appendingPathComponent("Old's Preview.app/Contents/MacOS/Preview")
        let newExe = base.appendingPathComponent("DualDock.app/Contents/MacOS/DualDock")
        let settings = base.appendingPathComponent("settings.json")
        let original = "printf 'abc\\n'\ncat"
        let prior: [String: Any] = ["type": "command", "command": original, "padding": 9]
        try JSONSerialization.data(withJSONObject: ["statusLine": prior, "other": "unchanged"]).write(to: settings)
        let oldToken = try AIQuotaClaudeBridge.install(in: settings, executable: oldExe, directory: old)
        let before = try Data(contentsOf: settings)

        // An unverified callback must never be wrapped, overwritten, or executed.
        XCTAssertThrowsError(try AIQuotaClaudeBridge.install(in: settings, executable: newExe, directory: fresh))
        XCTAssertThrowsError(try AIQuotaClaudeBridge.install(in: settings, executable: newExe, directory: fresh,
            retired: [.init(executable: newExe, directory: old)]))
        XCTAssertEqual(try Data(contentsOf: settings), before)
        XCTAssertNil(AIQuotaClaudeBridge.connection(in: fresh))

        let token = try AIQuotaClaudeBridge.install(in: settings, executable: newExe, directory: fresh,
                                                   retired: [.init(executable: oldExe, directory: old)])
        XCTAssertNotEqual(oldToken, token)
        let adopted = try Data(contentsOf: settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: adopted) as? [String: Any])
        let line = try XCTUnwrap(object["statusLine"] as? [String: Any])
        let command = try XCTUnwrap(line["command"] as? String)
        XCTAssertTrue(command.contains(newExe.path))
        XCTAssertTrue(command.contains(original))
        XCTAssertFalse(command.contains(oldToken.uuidString))
        XCTAssertEqual(line["padding"] as? Int, 9)
        XCTAssertEqual(object["other"] as? String, "unchanged")

        try AIQuotaClaudeBridge.remove(from: settings, directory: old, token: oldToken)
        XCTAssertEqual(try Data(contentsOf: settings), adopted, "A retired helper cannot undo the new registration")
        try AIQuotaClaudeBridge.remove(from: settings, directory: fresh, token: token)
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        let restoredLine = try XCTUnwrap(restored["statusLine"] as? [String: Any])
        XCTAssertTrue((restoredLine as NSDictionary).isEqual(to: prior))
    }

    func testHandoffOfEmptyOriginalRestoresAbsenceAndRejectsTampering() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("old"), fresh = dir.appendingPathComponent("release")
        let file = dir.appendingPathComponent("settings.json"), exe = old.appendingPathComponent("old-helper")
        _ = try AIQuotaClaudeBridge.install(in: file, executable: exe, directory: old)
        let oldBytes = try Data(contentsOf: file)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: oldBytes) as? [String: Any])
        var line = try XCTUnwrap(object["statusLine"] as? [String: Any])
        line["command"] = (line["command"] as? String ?? "") + "\n# user edited"
        object["statusLine"] = line
        let edited = try JSONSerialization.data(withJSONObject: object)
        try edited.write(to: file)
        let oldBinding = AIQuotaClaudeBridge.RetiredHelper(executable: exe, directory: old)
        XCTAssertThrowsError(try AIQuotaClaudeBridge.install(in: file, executable: fresh.appendingPathComponent("helper"),
                                                             directory: fresh, retired: [oldBinding]))
        XCTAssertEqual(try Data(contentsOf: file), edited)
        try oldBytes.write(to: file)
        let token = try AIQuotaClaudeBridge.install(in: file, executable: fresh.appendingPathComponent("helper"),
                                                    directory: fresh, retired: [oldBinding])
        try AIQuotaClaudeBridge.remove(from: file, directory: fresh, token: token)
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNil(restored["statusLine"])
    }
}
