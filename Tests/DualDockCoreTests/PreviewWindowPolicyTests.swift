import XCTest
@testable import DualDockCore

final class PreviewWindowPolicyTests: XCTestCase {
    func testHiddenGenericShellRequiresConfirmedAccessibilityAbsence() {
        XCTAssertTrue(PreviewWindowPolicy.isBackgroundShellCandidate(
            isOnScreen: false, isActive: false, title: " 微信 ",
            applicationNames: ["WeChat", "微信"], hasAccessibleWindow: false))
        for matched: Bool? in [true, nil] {
            XCTAssertFalse(PreviewWindowPolicy.isBackgroundShellCandidate(
                isOnScreen: false, isActive: false, title: "微信",
                applicationNames: ["WeChat", "微信"], hasAccessibleWindow: matched))
        }
    }

    func testVisibleOrActiveGenericWindowsAreNotBlankShellCandidates() {
        for state in [(true, false), (false, true), (true, true)] {
            XCTAssertFalse(PreviewWindowPolicy.isBackgroundShellCandidate(
                isOnScreen: state.0, isActive: state.1, title: "Example",
                applicationNames: ["Example"], hasAccessibleWindow: false))
        }
    }

    func testNamedDocumentsAndUnknownTitlesAreNotBlankShellCandidates() {
        for title: String? in ["Untitled", "Article — Example", "Report.pdf", "", nil] {
            XCTAssertFalse(PreviewWindowPolicy.isBackgroundShellCandidate(
                isOnScreen: false, isActive: false, title: title,
                applicationNames: ["Example"], hasAccessibleWindow: false))
        }
    }

    func testShellAliasesAreRuntimeNamesRatherThanApplicationSpecificRules() {
        XCTAssertTrue(PreviewWindowPolicy.isBackgroundShellCandidate(
            isOnScreen: false, isActive: false, title: "EXAMPLE",
            applicationNames: ["Example"], hasAccessibleWindow: false))
        XCTAssertFalse(PreviewWindowPolicy.isBackgroundShellCandidate(
            isOnScreen: false, isActive: false, title: "微信",
            applicationNames: ["Example"], hasAccessibleWindow: false))
    }

    private func window(_ id: UInt32, frame: CGRect? = CGRect(x: 350, y: 130, width: 1153, height: 821),
                        role: String? = "AXWindow", subrole: String? = "AXUnknown",
                        main: Bool? = false, focused: Bool? = false, modal: Bool? = false,
                        minimized: Bool? = false, controls: Bool? = false) -> PreviewWindowPolicy.AccessibilityWindow {
        .init(windowID: id, frame: frame, role: role, subrole: subrole, isMain: main,
              isFocused: focused, isModal: modal, isMinimized: minimized, hasWindowControls: controls)
    }

    func testRejectsConfirmedCompanionOverlayAlongsideRealWindow() {
        // Observed Feishu pair: different window IDs, same frame, standard main
        // window plus a noninteractive AXUnknown watermark. Both were on-screen.
        let main = window(11, subrole: "AXStandardWindow", main: true, controls: true)
        let overlay = window(12)
        XCTAssertEqual(PreviewWindowPolicy.companionOverlayIDs(in: [main, overlay]), [12])
    }

    func testKeepsDistinctStandardWindowsEvenAtIdenticalFrames() {
        let first = window(11, subrole: "AXStandardWindow", main: true, controls: true)
        let second = window(12, subrole: "AXStandardWindow", controls: false)
        XCTAssertTrue(PreviewWindowPolicy.companionOverlayIDs(in: [first, second]).isEmpty)
    }

    func testKeepsCustomUnknownWindowWithoutCoincidentStandardSibling() {
        let main = window(11, subrole: "AXStandardWindow", main: true, controls: true)
        let otherPosition = window(12, frame: CGRect(x: 352, y: 130, width: 1153, height: 821))
        XCTAssertTrue(PreviewWindowPolicy.companionOverlayIDs(in: [window(12)]).isEmpty)
        XCTAssertTrue(PreviewWindowPolicy.companionOverlayIDs(in: [main, otherPosition]).isEmpty)
        // These arrays represent two processes; a sibling in another app is irrelevant.
        XCTAssertTrue(PreviewWindowPolicy.possibleCompanionOverlayIDs(in: [main]).isEmpty)
        XCTAssertTrue(PreviewWindowPolicy.possibleCompanionOverlayIDs(in: [window(12)]).isEmpty)
    }

    func testKeepsDialogFloatingAndUnknownRoleWindows() {
        let main = window(11, subrole: "AXStandardWindow", main: true, controls: true)
        for subrole: String? in ["AXDialog", "AXFloatingWindow", "AXSystemDialog", nil] {
            XCTAssertTrue(PreviewWindowPolicy.companionOverlayIDs(in: [main, window(12, subrole: subrole)]).isEmpty)
        }
        for role: String? in ["AXGroup", nil] {
            XCTAssertTrue(PreviewWindowPolicy.companionOverlayIDs(in: [main, window(12, role: role)]).isEmpty)
        }
    }

    func testKeepsUnknownWindowWithAnyIndependentWindowCapability() {
        let main = window(11, subrole: "AXStandardWindow", main: true, controls: true)
        let candidates = [window(12, main: true), window(12, focused: true), window(12, modal: true),
                          window(12, minimized: true), window(12, controls: true)]
        for candidate in candidates {
            XCTAssertTrue(PreviewWindowPolicy.companionOverlayIDs(in: [main, candidate]).isEmpty)
        }
    }

    func testFailedCapabilityQueriesDoNotProveHelperWindow() {
        let main = window(11, subrole: "AXStandardWindow", main: true, controls: true)
        let candidates = [window(12, main: nil), window(12, focused: nil), window(12, modal: nil),
                          window(12, minimized: nil), window(12, controls: nil)]
        for candidate in candidates {
            XCTAssertEqual(PreviewWindowPolicy.possibleCompanionOverlayIDs(in: [main, candidate]), [12])
            XCTAssertTrue(PreviewWindowPolicy.companionOverlayIDs(in: [main, candidate]).isEmpty)
        }
    }

    func testInvalidOrMissingFramesNeverCauseOverlayExclusion() {
        let main = window(11, subrole: "AXStandardWindow", main: true, controls: true)
        let frames: [CGRect?] = [nil, .zero, CGRect(x: CGFloat.nan, y: 130, width: 1153, height: 821),
                                 CGRect(x: 350, y: 130, width: CGFloat.infinity, height: 821)]
        for frame in frames {
            XCTAssertTrue(PreviewWindowPolicy.companionOverlayIDs(in: [main, window(12, frame: frame)]).isEmpty)
        }
    }

    func testOnlyAllowsOnePointOfAccessibilityGeometryRounding() {
        let main = window(11, subrole: "AXStandardWindow", main: true, controls: true)
        let rounded = window(12, frame: CGRect(x: 350.5, y: 129.5, width: 1153.5, height: 820.5))
        let differentSize = window(13, frame: CGRect(x: 350, y: 130, width: 1155, height: 821))
        XCTAssertEqual(PreviewWindowPolicy.companionOverlayIDs(in: [main, rounded, differentSize]), [12])
    }

    func testStandardWindowMustHaveConfirmedRoleAndValidFrame() {
        for main in [window(11, frame: nil, subrole: "AXStandardWindow"),
                     window(11, role: nil, subrole: "AXStandardWindow"),
                     window(11, role: "AXGroup", subrole: "AXStandardWindow")] {
            XCTAssertTrue(PreviewWindowPolicy.companionOverlayIDs(in: [main, window(12)]).isEmpty)
        }
    }

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
