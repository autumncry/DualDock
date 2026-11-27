import XCTest
@testable import DualDock

final class UpdateChannelIsolationTests: XCTestCase {
    @MainActor func testReleaseManifestUsesTheSeparateSystemIdentity() throws {
        let source = URL(fileURLWithPath: #filePath)
        let root = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bytes = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        let id = try XCTUnwrap(info["CFBundleIdentifier"] as? String)
        XCTAssertEqual(id, LocalPreviewConfiguration.releaseBundleID)
        XCTAssertNotEqual(id, LocalPreviewConfiguration.bundleID)
        XCTAssertEqual(info["CFBundleName"] as? String, "DualDock 3")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "DualDock3")
        XCTAssertNotNil(SoftwareUpdateService.configuredFeed(bundleID: id, info: info))
    }

    @MainActor func testOnlyOptedInReleaseBundlesUseTheMajorThreeFeed() {
        let expected = "https://raw.githubusercontent.com/autumncry/DualDock/main/updates/3/appcast.xml"
        var info = ["CFBundleShortVersionString": "3.0.0"]
        let releaseID = "local.ronny.DualDock3"
        XCTAssertNil(SoftwareUpdateService.configuredFeed(bundleID: releaseID, info: info))
        info["SUFeedURL"] = "https://raw.githubusercontent.com/autumncry/DualDock/main/updates/appcast.xml"
        XCTAssertNil(SoftwareUpdateService.configuredFeed(bundleID: releaseID, info: info))
        info["SUFeedURL"] = expected
        XCTAssertEqual(SoftwareUpdateService.configuredFeed(bundleID: releaseID, info: info), expected)
        for identifier in ["local.ronny.DualDock3Preview", "local.ronny.DualDock"] {
            XCTAssertNil(SoftwareUpdateService.configuredFeed(bundleID: identifier, info: info))
        }
        info["CFBundleShortVersionString"] = "2.10.0"
        XCTAssertNil(SoftwareUpdateService.configuredFeed(bundleID: releaseID, info: info))
    }
}
