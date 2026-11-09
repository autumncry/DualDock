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
        for key in ["iconSpacing", "magnificationEnabled", "magnificationScale", "showBadges"] { legacy.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(DockConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.version, DockConfiguration.currentVersion)
        XCTAssertEqual(decoded.entries, saved.entries)
        XCTAssertEqual(decoded.mode, .runningOnly)
        XCTAssertEqual(decoded.iconSize, 62.75)
        XCTAssertFalse(decoded.showPreviews)
        XCTAssertTrue(decoded.hideSystemDock)
        XCTAssertEqual(decoded.iconSpacing, 14)
        XCTAssertTrue(decoded.magnificationEnabled)
        XCTAssertTrue(decoded.showBadges)
        XCTAssertEqual(decoded.magnificationScale, 5.0 / 3.0, accuracy: 0.001)
    }

    func testContinuousValuesSurviveRoundTripWithoutRounding() throws {
        var config = DockConfiguration()
        config.iconSize = 57.625
        config.iconSpacing = 6.375
        config.magnificationScale = 1.7345
        config.showBadges = false
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

    func testVersionTwoMigrationPreservesAppearanceAndAddsBadgeSwitch() throws {
        var config = DockConfiguration()
        config.iconSize = 47.69
        config.iconSpacing = 6.48
        config.magnificationScale = 1.47
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        data["version"] = 2
        data.removeValue(forKey: "showBadges")
        let restored = try JSONDecoder().decode(DockConfiguration.self, from: JSONSerialization.data(withJSONObject: data))
        XCTAssertEqual(restored.version, DockConfiguration.currentVersion)
        XCTAssertEqual(restored.iconSize, config.iconSize)
        XCTAssertEqual(restored.iconSpacing, config.iconSpacing)
        XCTAssertEqual(restored.magnificationScale, config.magnificationScale)
        XCTAssertTrue(restored.showBadges)
    }
}
