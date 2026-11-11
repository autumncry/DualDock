import XCTest
@testable import DualDockCore

final class DisplaySizingMigrationTests: XCTestCase {
    func testVersionSixPreservesLayoutAndUsesSharedBottomDefaults() throws {
        let data = Data("{\"version\":6,\"autoAdjustWidth\":true,\"dockWidth\":1234.5,\"iconSize\":52,\"iconSpacing\":7}".utf8)
        let value = try JSONDecoder().decode(DockConfiguration.self, from: data)
        XCTAssertEqual(value.version, DockConfiguration.currentVersion)
        XCTAssertTrue(value.adaptiveSizing)
        XCTAssertTrue(value.synchronizeSizes)
        XCTAssertEqual(value.manualIconScale, 1)
        XCTAssertEqual(value.dockWidth, 1234.5)
        XCTAssertEqual(value.iconSize, 52)
        XCTAssertTrue(value.displaySettings.isEmpty)
    }

    func testPerDisplayProfilesAndPositionsSurviveRoundTrip() throws {
        var value = DockConfiguration()
        value.synchronizeSizes = false
        value.manualIconScale = 0.75
        value.displaySettings = ["display-A": .init(edge: .left, manualSizing: .init(length: 600, thickness: 80, iconScale: 0.6, iconSpacing: 7)),
                                 "display-B": .init(edge: .top)]
        value.adaptiveSizing = true
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(DockConfiguration.self, from: data), value)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["autoAdjustWidth"] as? Bool, true)
        XCTAssertNil(json["adaptiveSizing"])
    }

    func testManualIconRatioAndProfileSanityAreNormalized() {
        var value = DockConfiguration()
        value.manualIconScale = .infinity
        value.displaySettings["screen"] = .init(edge: .right, manualSizing: .init(length: 600, thickness: 80))
        value.displaySettings["screen"]?.manualSizing?.iconScale = 5
        value.normalizeAppearance()
        XCTAssertEqual(value.manualIconScale, 1)
        XCTAssertEqual(value.displaySettings["screen"]?.manualSizing?.iconScale, 1.25)
        let small = DockManualSizing(length: 500, thickness: 100, iconScale: 0.5)
        let large = DockManualSizing(length: 1000, thickness: 200, iconScale: 0.5)
        XCTAssertEqual(large.resolvedIconSize, small.resolvedIconSize * 2)
        XCTAssertLessThanOrEqual(DockManualSizing(length: 500, thickness: 33, iconScale: 1.25).resolvedIconSize, 25)
    }
}
