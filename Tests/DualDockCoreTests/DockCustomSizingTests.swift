import XCTest
@testable import DualDockCore

final class DockCustomSizingTests: XCTestCase {
    private func resolve(_ sizing: DockCustomSizing, count: Int = 8, length: Double = 1200,
                         height: Double = 120, divider: Int? = nil) -> DockResolvedSizing {
        DockCustomSizingResolver.resolve(sizing, count: count, dividerIndex: divider,
                                         maximumLength: length, maximumHeight: height)
    }

    func testDensityComputesAutomaticValuesAndOverridesRemainIndependent() {
        var preferences = DockCustomSizing()
        let standard = resolve(preferences)
        XCTAssertEqual(standard.iconSize, 48)
        XCTAssertEqual(standard.gap, 8.16, accuracy: 0.000001)
        XCTAssertEqual(standard.padding, 10.08, accuracy: 0.000001)
        XCTAssertEqual(standard.thickness, 68.16, accuracy: 0.000001)
        preferences.iconSize = 24
        preferences.density = 0
        let compact = resolve(preferences)
        XCTAssertEqual(compact.thickness, 29.76, accuracy: 0.000001)
        XCTAssertEqual(compact.manualSizing.resolvedIconSize, 24)
        preferences.gapOverride = 7
        preferences.paddingOverride = 11
        preferences.minimumHeightOverride = 90
        preferences.iconSize = 64
        preferences.density = 1
        let custom = resolve(preferences)
        XCTAssertEqual(custom.gap, 7)
        XCTAssertEqual(custom.padding, 11)
        XCTAssertEqual(custom.thickness, 90)
        preferences.iconSize = 104
        XCTAssertEqual(resolve(preferences).thickness, 108, "Height override is a minimum, not an icon cap")
    }

    func testExtremeSavedRequestsRemainFiniteAndScreenClampsNeverRewritePreferences() {
        var preferences = DockCustomSizing()
        preferences.iconSize = 1000
        preferences.paddingOverride = .greatestFiniteMagnitude
        preferences.gapOverride = .greatestFiniteMagnitude
        preferences.minimumHeightOverride = 1000
        let resolved = resolve(preferences, count: 20, length: 800, height: 72)
        XCTAssertTrue(resolved.length.isFinite && resolved.thickness.isFinite && resolved.padding.isFinite)
        XCTAssertLessThanOrEqual(resolved.thickness, 72)
        XCTAssertLessThanOrEqual(resolved.iconSize, resolved.thickness)
        let geometry = DockGeometry.make(count: 20, edge: .right,
            style: DockGeometryStyle(iconSize: resolved.iconSize, barThickness: resolved.thickness,
                gap: resolved.gap, leadingPadding: resolved.padding, trailingPadding: resolved.padding),
            maximumLength: 800, fixedLength: resolved.length)
        XCTAssertTrue(geometry.documentSize.height.isFinite)
        XCTAssertEqual(preferences.iconSize, 1000)
    }

    func testOverflowCompressesGapThenShrinksThenScrollsWithoutGrowingSmallIcons() {
        var preferences = DockCustomSizing()
        let compressed = resolve(preferences, count: 8, length: 430)
        XCTAssertEqual(compressed.iconSize, 48)
        XCTAssertLessThan(compressed.gap, 8.16)
        XCTAssertFalse(compressed.isScrollable)
        let shrunk = resolve(preferences, count: 8, length: 350)
        XCTAssertLessThan(shrunk.iconSize, 48)
        XCTAssertFalse(shrunk.isScrollable)
        XCTAssertTrue(resolve(preferences, count: 20, length: 350).isScrollable)
        preferences.shrinkBeforeScroll = false
        XCTAssertEqual(resolve(preferences, count: 8, length: 350).iconSize, 48)
        XCTAssertTrue(resolve(preferences, count: 8, length: 350).isScrollable)
        preferences.iconSize = 24
        preferences.shrinkBeforeScroll = true
        XCTAssertEqual(resolve(preferences, count: 30, length: 350).iconSize, 24)
    }

    func testLengthModesDividerAndEmptyRowsStayFinite() {
        var preferences = DockCustomSizing()
        XCTAssertEqual(resolve(preferences, count: 100).length, 1200, "Fit may use the full applicable screen")
        preferences.lengthMode = .fill
        XCTAssertEqual(resolve(preferences, count: 1).length, 1200)
        preferences.lengthMode = .fixed
        preferences.fixedLengthPercent = 60
        XCTAssertEqual(resolve(preferences).length, 720)
        for count in [0, 1, 2] {
            let resolved = resolve(preferences, count: count, divider: 1)
            XCTAssertTrue(resolved.length.isFinite && resolved.gap.isFinite)
        }
        preferences.lengthMode = .fit
        XCTAssertEqual(resolve(preferences, count: 2, divider: 1).length
            - resolve(preferences, count: 2).length, 13, accuracy: 0.000001)
    }

    func testLegacyAdoptionKeepsVisibleValuesAndNeverEnablesShrink() {
        let manual = DockManualSizing(length: 1100, thickness: 89, iconScale: 0.72,
                                      iconSpacing: 17, contentPadding: 72)
        let preferences = DockCustomSizing.preserving(manual, fitContent: false, maximumLength: 1800)
        let resolved = resolve(preferences, length: 1800)
        XCTAssertEqual(resolved.iconSize, manual.resolvedIconSize, accuracy: 0.000001)
        XCTAssertEqual(resolved.thickness, manual.thickness)
        XCTAssertEqual(resolved.gap, 17 * manual.resolvedIconSize / 48, accuracy: 0.000001)
        XCTAssertEqual(resolved.padding, 6)
        XCTAssertEqual(resolved.length, 1100)
        XCTAssertFalse(preferences.shrinkBeforeScroll)
    }

    func testHeightAndCornerDragScaleIconsAndFitEndDragRebasesPadding() {
        let preferences = DockCustomSizing()
        let original = resolve(preferences).manualSizing
        var heightDraft = original
        heightDraft.thickness *= 1.2
        let grown = preferences.resized(from: original, to: heightDraft, maximumLength: 1200,
                                       count: 8, dividerIndex: nil)
        XCTAssertEqual(grown.iconSize, 57.6, accuracy: 0.000001)
        XCTAssertEqual(grown.minimumHeightOverride!, heightDraft.thickness)
        var endDraft = original
        endDraft.length += 100
        let widened = preferences.resized(from: original, to: endDraft, maximumLength: 1200,
                                         count: 8, dividerIndex: nil)
        XCTAssertEqual(widened.paddingOverride!, 60.08, accuracy: 0.000001)
        XCTAssertEqual(widened.iconSize, 48)
        XCTAssertEqual(resolve(widened).length, endDraft.length, accuracy: 0.000001)
    }

    func testGeometryAlignmentUsesCanonicalStartAndDistributionOnEveryEdge() {
        for edge in DockEdge.allCases {
            var style = DockGeometryStyle(iconSize: 48, barThickness: 68, gap: 8,
                                         leadingPadding: 10, trailingPadding: 10)
            style.contentAlignment = .start
            let start = DockGeometry.make(count: 3, edge: edge, style: style,
                                          maximumLength: 1000, fixedLength: 600)
            XCTAssertEqual(start.canonicalIconFrames.first!.minX, 10)
            style.contentAlignment = .distribute
            let distributed = DockGeometry.make(count: 3, edge: edge, style: style,
                                                maximumLength: 1000, fixedLength: 600)
            XCTAssertEqual(distributed.canonicalIconFrames.first!.minX, 10)
            XCTAssertEqual(distributed.canonicalIconFrames.last!.maxX, 590)
        }
    }
}
