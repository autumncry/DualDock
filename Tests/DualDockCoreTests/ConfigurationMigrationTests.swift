import XCTest
@testable import DualDockCore

final class ConfigurationMigrationTests: XCTestCase {
    func testLegacyConfigurationKeepsUserGroupsAndSettings() throws {
        var saved = DockConfiguration()
        let app = AppReference(id: "com.example.A", name: "A", path: "/Applications/A.app")
        saved.entries = [DockEntry(name: "Work", apps: [app], isGroup: true)]
        saved.mode = .runningOnly
        saved.iconSize = 62.75
        saved.showPreviews = false
        saved.hideSystemDock = true
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        legacy["version"] = 1
        for key in ["iconSpacing", "magnificationEnabled", "magnificationScale"] { legacy.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(DockConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.version, DockConfiguration.currentVersion)
        XCTAssertEqual(decoded.entries, saved.entries)
        XCTAssertEqual(decoded.mode, .runningOnly)
        XCTAssertEqual(decoded.iconSize, 62.75)
        XCTAssertFalse(decoded.showPreviews)
        XCTAssertTrue(decoded.hideSystemDock)
        XCTAssertEqual(decoded.iconSpacing, 14)
        XCTAssertTrue(decoded.magnificationEnabled)
        XCTAssertEqual(decoded.magnificationScale, 5.0 / 3.0, accuracy: 0.001)
    }

    func testContinuousValuesSurviveRoundTripWithoutRounding() throws {
        var config = DockConfiguration()
        config.iconSize = 57.625
        config.iconSpacing = 6.375
        config.magnificationScale = 1.7345
        let decoded = try JSONDecoder().decode(DockConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
    }

    func testFutureVersionStaysIdentifiableAsUnsupported() throws {
        let decoded = try JSONDecoder().decode(DockConfiguration.self, from: Data("{\"version\":99,\"entries\":[]}".utf8))
        XCTAssertEqual(decoded.version, 99)
    }

    func testInvalidAppearanceValuesAreBounded() {
        var config = DockConfiguration()
        config.iconSize = .nan
        config.iconSpacing = -100
        config.magnificationScale = 100
        config.normalizeAppearance()
        XCTAssertEqual(config.iconSize, 48)
        XCTAssertEqual(config.iconSpacing, 0)
        XCTAssertEqual(config.magnificationScale, 2.5)
    }
}
