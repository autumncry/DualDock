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
        for key in ["iconSpacing", "dockWidthReferenceSpacing", "magnificationEnabled", "magnificationScale", "showBadges"] { legacy.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(DockConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.version, DockConfiguration.currentVersion)
        XCTAssertEqual(decoded.entries, saved.entries)
        XCTAssertEqual(decoded.mode, .runningOnly)
        XCTAssertEqual(decoded.iconSize, 62.75)
        XCTAssertFalse(decoded.showPreviews)
        XCTAssertTrue(decoded.hideSystemDock)
        XCTAssertEqual(decoded.iconSpacing, 14)
        XCTAssertEqual(decoded.dockWidthReferenceSpacing, 14)
        XCTAssertTrue(decoded.magnificationEnabled)
        XCTAssertTrue(decoded.showBadges)
        XCTAssertEqual(decoded.magnificationScale, 5.0 / 3.0, accuracy: 0.001)
    }

    func testContinuousValuesSurviveRoundTripWithoutRounding() throws {
        var config = DockConfiguration()
        config.iconSize = 57.625
        config.iconSpacing = 6.375
        config.dockWidthReferenceSpacing = 12.125
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
        config.dockWidthReferenceSpacing = .infinity
        config.normalizeAppearance()
        XCTAssertEqual(config.iconSize, 48)
        XCTAssertEqual(config.iconSpacing, 0)
        XCTAssertEqual(config.magnificationScale, 2.5)
        XCTAssertEqual(config.dockWidthReferenceSpacing, 14)
    }

    func testVersionTwoMigrationPreservesAppearanceAndAddsBadgeSwitch() throws {
        var config = DockConfiguration()
        config.iconSize = 47.69
        config.iconSpacing = 6.48
        config.magnificationScale = 1.47
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        data["version"] = 2
        data.removeValue(forKey: "showBadges")
        data.removeValue(forKey: "dockWidthReferenceSpacing")
        let restored = try JSONDecoder().decode(DockConfiguration.self, from: JSONSerialization.data(withJSONObject: data))
        XCTAssertEqual(restored.version, DockConfiguration.currentVersion)
        XCTAssertEqual(restored.iconSize, config.iconSize)
        XCTAssertEqual(restored.iconSpacing, config.iconSpacing)
        XCTAssertEqual(restored.magnificationScale, config.magnificationScale)
        XCTAssertTrue(restored.showBadges)
        XCTAssertEqual(restored.dockWidthReferenceSpacing, config.iconSpacing)
    }

    func testVersionThreeMigrationPreservesExistingDockWidthAndSettings() throws {
        var existing = DockConfiguration()
        existing.iconSize = 47.69190871369294
        existing.iconSpacing = 6.479771784232365
        existing.magnificationScale = 1.4713622709197787
        existing.mode = .runningOnly
        existing.showBadges = false
        existing.entries = [DockEntry(name: "Work", apps: [.init(id: "app", name: "App", path: "/Applications/App.app")], isGroup: true)]
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(existing)) as? [String: Any])
        encoded["version"] = 3
        encoded.removeValue(forKey: "dockWidthReferenceSpacing")
        var migrated = try JSONDecoder().decode(DockConfiguration.self, from: JSONSerialization.data(withJSONObject: encoded))
        XCTAssertEqual(migrated.version, DockConfiguration.currentVersion)
        XCTAssertEqual(migrated.dockWidthReferenceSpacing, existing.iconSpacing)
        XCTAssertEqual(migrated.entries, existing.entries)
        XCTAssertEqual(migrated.mode, existing.mode)
        XCTAssertFalse(migrated.showBadges)
        for width: CGFloat in [320, 1768, 2976] {
            let old = DockWaveLayout.make(count: 24, iconSize: existing.iconSize, spacing: existing.iconSpacing,
                magnificationScale: existing.magnificationScale, focusIndex: nil, maxWidth: width,
                hasControls: false, dividerIndex: 21)
            let new = DockWaveLayout.make(count: 24, iconSize: migrated.iconSize, spacing: migrated.iconSpacing,
                magnificationScale: migrated.magnificationScale, focusIndex: nil, maxWidth: width,
                hasControls: false, dividerIndex: 21, widthReferenceSpacing: migrated.dockWidthReferenceSpacing)
            XCTAssertEqual(new, old)
        }
        migrated.iconSpacing = 32
        let restarted = try JSONDecoder().decode(DockConfiguration.self, from: JSONEncoder().encode(migrated))
        XCTAssertEqual(restarted.iconSpacing, 32)
        XCTAssertEqual(restarted.dockWidthReferenceSpacing, existing.iconSpacing)
        XCTAssertEqual(restarted.entries, existing.entries)
    }

    func testLegacyInvalidSpacingIsNormalizedTogetherWithItsWidthBaseline() throws {
        for (stored, expected) in [(-100.0, 0.0), (100.0, 32.0)] {
            let data = try JSONSerialization.data(withJSONObject: ["version": 3, "iconSpacing": stored])
            let decoded = try JSONDecoder().decode(DockConfiguration.self, from: data)
            XCTAssertEqual(decoded.iconSpacing, expected)
            XCTAssertEqual(decoded.dockWidthReferenceSpacing, expected)
        }
    }
}
