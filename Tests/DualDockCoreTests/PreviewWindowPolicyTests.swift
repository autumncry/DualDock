import XCTest
@testable import DualDockCore

final class PreviewWindowPolicyTests: XCTestCase {
    func testRejectsObservedInvisibleUntitledUnmatchedSurface() {
        // TextEdit exposed a 500 × 500 layer-zero helper window whose capture
        // was fully transparent. It had no title or matching AX window.
        XCTAssertFalse(PreviewWindowPolicy.shouldInclude(
            isOnScreen: false, title: "", hasAccessibleWindow: false
        ))
        XCTAssertFalse(PreviewWindowPolicy.shouldInclude(
            isOnScreen: false, title: nil, hasAccessibleWindow: false
        ))
    }

    func testWhitespaceDoesNotMakeAnInvisibleHelperAUserWindow() {
        XCTAssertFalse(PreviewWindowPolicy.shouldInclude(
            isOnScreen: false, title: " \n\t", hasAccessibleWindow: false
        ))
    }

    func testKeepsTitledWindowOnAnotherSpaceWithoutAccessibility() {
        XCTAssertTrue(PreviewWindowPolicy.shouldInclude(
            isOnScreen: false, title: "DualDock-window-B.txt", hasAccessibleWindow: false
        ))
    }

    func testKeepsVisibleUntitledWindowWithoutAccessibility() {
        XCTAssertTrue(PreviewWindowPolicy.shouldInclude(
            isOnScreen: true, title: nil, hasAccessibleWindow: false
        ))
    }

    func testKeepsUntitledMinimizedWindowConfirmedByAccessibility() {
        XCTAssertTrue(PreviewWindowPolicy.shouldInclude(
            isOnScreen: false, title: "", hasAccessibleWindow: true
        ))
    }
    func testKeepsUntitledOffscreenWindowWhenAccessibilityIsUnavailable() {
        XCTAssertTrue(PreviewWindowPolicy.shouldInclude(
            isOnScreen: false, title: nil, hasAccessibleWindow: nil
        ))
    }

    func testKeepsUntitledWindowWhenWindowIDMappingIsIncomplete() {
        // Missing permission, AX timeouts and unavailable private symbols all
        // arrive as unknown coverage, preserving the previous fallback entry.
        XCTAssertTrue(PreviewWindowPolicy.shouldInclude(
            isOnScreen: false, title: " ", hasAccessibleWindow: nil
        ))
    }

    func testOmitsFailedCaptureInsteadOfKeepingAnIconOnlyCard() {
        XCTAssertEqual(PreviewWindowPolicy.availablePreviewIDs(
            orderedCandidates: [11, 12], validSnapshotIDs: [11], currentWindowIDs: [11, 12]
        ), [11])
    }

    func testOmitsWindowClosedWhileItsScreenshotWasCaptured() {
        XCTAssertEqual(PreviewWindowPolicy.availablePreviewIDs(
            orderedCandidates: [11, 12], validSnapshotIDs: [11, 12], currentWindowIDs: [12]
        ), [12])
    }

    func testDeduplicatesOnlyWindowIdentityAndPreservesOrder() {
        XCTAssertEqual(PreviewWindowPolicy.availablePreviewIDs(
            orderedCandidates: [22, 11, 22], validSnapshotIDs: [11, 22], currentWindowIDs: [11, 22]
        ), [22, 11])
    }

    func testKeepsTwoRealWindowsEvenWhenTheirTitlesWouldMatch() {
        // Matching titles are deliberately absent from the identity decision.
        XCTAssertEqual(PreviewWindowPolicy.availablePreviewIDs(
            orderedCandidates: [11, 12], validSnapshotIDs: [11, 12], currentWindowIDs: [11, 12]
        ), [11, 12])
    }

    func testNoSuccessfulCapturesMeansNoPreviewCards() {
        XCTAssertEqual(PreviewWindowPolicy.availablePreviewIDs(
            orderedCandidates: [11, 12], validSnapshotIDs: [], currentWindowIDs: [11, 12]
        ), [])
    }

}
