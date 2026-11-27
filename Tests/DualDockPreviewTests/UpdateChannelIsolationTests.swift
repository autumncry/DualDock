import XCTest
@testable import DualDock

final class UpdateChannelIsolationTests: XCTestCase {
    @MainActor func testReleaseKeepsTheInstalledProductAndStableUpdateIdentity() throws {
        let source = URL(fileURLWithPath: #filePath)
        let root = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bytes = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
        let id = try XCTUnwrap(info["CFBundleIdentifier"] as? String)
        XCTAssertEqual(id, "local.ronny.DualDock")
        XCTAssertEqual(id, LocalPreviewConfiguration.releaseBundleID)
        XCTAssertNotEqual(id, LocalPreviewConfiguration.bundleID)
        XCTAssertEqual(info["CFBundleName"] as? String, "DualDock")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "DualDock")
        XCTAssertEqual(info["SUPublicEDKey"] as? String, "LpR3PPiBqo8LaJh/80Rq81Cx3gHe957jxeKw0pLgEWU=")
        XCTAssertEqual(SoftwareUpdateService.configuredFeed(bundleID: id, info: info),
                       "https://raw.githubusercontent.com/autumncry/DualDock/main/updates/appcast.xml")
    }

    @MainActor func testDevelopmentBundlesAndOtherFeedsCannotOfferProductionUpdates() {
        let stable = "https://raw.githubusercontent.com/autumncry/DualDock/main/updates/appcast.xml"
        XCTAssertNil(SoftwareUpdateService.configuredFeed(bundleID: LocalPreviewConfiguration.releaseBundleID, info: [:]))
        XCTAssertNil(SoftwareUpdateService.configuredFeed(bundleID: LocalPreviewConfiguration.bundleID, info: ["SUFeedURL": stable]))
        XCTAssertNil(SoftwareUpdateService.configuredFeed(bundleID: LocalPreviewConfiguration.releaseBundleID,
                                                         info: ["SUFeedURL": "https://example.org/appcast.xml"]))
    }
}
