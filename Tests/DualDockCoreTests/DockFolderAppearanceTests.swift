import XCTest
@testable import DualDockCore

final class DockFolderAppearanceTests: XCTestCase {
    func testOldConfigurationsKeepTheirEntriesAndOpenWithTheCurrentSilverTray() throws {
        let app = AppReference(id: "example", name: "Example", path: "/Applications/Example.app")
        let group = DockEntry(name: "Folder", apps: [app], isGroup: true)
        var original = DockConfiguration()
        original.entries = [group]
        original.mode = .runningOnly
        original.badgeScale = 1.7
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String:Any])
        json["version"] = 11
        json.removeValue(forKey: "folderAppearance")
        let migrated = try JSONDecoder().decode(DockConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated, original)
        XCTAssertEqual(migrated.version, DockConfiguration.currentVersion)
        XCTAssertEqual(migrated.folderAppearance.style, .silver)
        XCTAssertNil(migrated.folderAppearance.backgroundColor)
        XCTAssertEqual(migrated.folderAppearance.backgroundOpacity, 1)
    }

    func testStylesRetainCustomColorAndTransparentBackgroundAcrossRelaunch() throws {
        var config = DockConfiguration()
        config.folderAppearance.backgroundColor = DockFolderColor(red: 0.1, green: 0.64, blue: 0.92)
        config.folderAppearance.backgroundOpacity = 0
        for style in DockFolderStyle.allCases {
            config.folderAppearance.style = style
            let restored = try JSONDecoder().decode(DockConfiguration.self, from: JSONEncoder().encode(config))
            XCTAssertEqual(restored.folderAppearance, config.folderAppearance)
        }
    }

    func testAppearanceClampsColorComponentsAndOpacity() {
        XCTAssertEqual(DockFolderColor(red: -1, green: 3, blue: .nan), DockFolderColor(red: 0, green: 1, blue: 0))
        var config = DockConfiguration()
        for (input, expected): (Double,Double) in [(-2,0), (0.613,0.613), (2,1), (.infinity,1)] {
            config.folderAppearance.backgroundOpacity = input
            config.normalizeAppearance()
            XCTAssertEqual(config.folderAppearance.backgroundOpacity, expected)
        }
    }

    func testInvalidOptionalAppearanceValuesDoNotDiscardOtherSettings() throws {
        let data = Data(#"{"version":12,"badgeScale":1.4,"folderAppearance":{"style":"future","backgroundColor":{"red":"bad"},"backgroundOpacity":0.5}}"#.utf8)
        let config = try JSONDecoder().decode(DockConfiguration.self, from: data)
        XCTAssertEqual(config.badgeScale, 1.4)
        XCTAssertEqual(config.folderAppearance.style, .silver)
        XCTAssertNil(config.folderAppearance.backgroundColor)
        XCTAssertEqual(config.folderAppearance.backgroundOpacity, 0.5)
    }
}
