import XCTest
@testable import DualDockCore

final class BadgeDisplayPolicyTests: XCTestCase {
    private let wechat = AppReference(id: "com.tencent.xinWeChat", name: "WeChat", path: "/Applications/WeChat.app")
    private let lark = AppReference(id: "com.electron.lark", name: "Lark", path: "/Applications/Lark.app")

    func testScaleDecodesLegacyDefaultsAndPersistsContinuousValuesWhileHidden() throws {
        var config = try JSONDecoder().decode(DockConfiguration.self, from: Data(#"{"version":11,"showBadges":false}"#.utf8))
        XCTAssertEqual(config.badgeScale, 1)
        XCTAssertFalse(config.showBadges)
        config.badgeScale = 1.58375
        let restored = try JSONDecoder().decode(DockConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored, config)
    }

    func testScaleNormalizesNonfiniteAndOutOfRangeValues() {
        for (stored, expected): (Double, Double) in [(-1, 0.75), (4, 2), (.nan, 1), (.infinity, 1)] {
            var config = DockConfiguration()
            config.badgeScale = stored
            config.normalizeAppearance()
            XCTAssertEqual(config.badgeScale, expected)
        }
    }

    func testNativeCountsAndSpecialLabelsArePreserved() {
        XCTAssertEqual(BadgeDisplayPolicy.normalizedLabel(" 4\n"), "4")
        XCTAssertEqual(BadgeDisplayPolicy.normalizedLabel("99+"), "99+")
        XCTAssertEqual(BadgeDisplayPolicy.normalizedLabel("!"), "!")
    }

    func testEmptyUnavailableAndZeroLabelsHaveNoBadge() {
        for value in [nil, "", " \n", "0", "00"] {
            XCTAssertNil(BadgeDisplayPolicy.normalizedLabel(value))
        }
    }

    func testSingleApplicationUsesExactBundleIdentity() {
        let entry = DockEntry(name: "WeChat", apps: [wechat])
        let labels = [wechat.id: "3", "com.tencent.flue.WeChatAppEx": "9"]
        XCTAssertEqual(BadgeDisplayPolicy.label(for: entry, labels: labels, enabled: true), "3")
    }

    func testGroupShowsAnExclamationInsteadOfSummingCounts() {
        let entry = DockEntry(name: "Messages", apps: [wechat, lark], isGroup: true)
        XCTAssertEqual(BadgeDisplayPolicy.label(for: entry, labels: [wechat.id: "3", lark.id: "4"], enabled: true), "!")
        XCTAssertEqual(BadgeDisplayPolicy.label(for: entry, labels: [lark.id: "1"], enabled: true), "!")
        XCTAssertNil(BadgeDisplayPolicy.label(for: entry, labels: [wechat.id: ""], enabled: true))
    }

    func testDisabledBadgesHideBothIndividualAndGroupIndicators() {
        for entry in [DockEntry(name: "WeChat", apps: [wechat]), DockEntry(name: "Messages", apps: [wechat, lark], isGroup: true)] {
            XCTAssertNil(BadgeDisplayPolicy.label(for: entry, labels: [wechat.id: "3"], enabled: false))
        }
    }
}
