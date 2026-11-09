import XCTest
@testable import DualDockCore

final class DockWaveLayoutTests: XCTestCase {
    private func layout(width: CGFloat = 1800, focus: CGFloat? = nil, scale: CGFloat = 2) -> DockWaveLayout {
        .make(count: 9, iconSize: 48, spacing: 14, magnificationScale: scale,
              focusIndex: focus, maxWidth: width, hasControls: true)
    }

    func testPeakAndNeighborsFollowSymmetricWave() {
        let value = layout(focus: 4)
        XCTAssertEqual(value.tileFrames[4].height, 112, accuracy: 0.001)
        XCTAssertEqual(value.tileFrames[3].height, value.tileFrames[5].height, accuracy: 0.001)
        XCTAssertGreaterThan(value.tileFrames[3].height, value.tileFrames[2].height)
        XCTAssertEqual(value.tileFrames[0].height, 64, accuracy: 0.001)
    }

    func testDifferentScreenWidthsKeepSameIconSizesAndOverflowScrolls() {
        let narrow = layout(width: 320)
        let wide = layout(width: 3008)
        XCTAssertEqual(narrow.tileFrames, wide.tileFrames)
        XCTAssertEqual(narrow.panelSize.width, 320)
        XCTAssertGreaterThan(narrow.contentSize.width, narrow.viewportSize.width)
        XCTAssertEqual(wide.contentSize.width, wide.viewportSize.width)
    }

    func testNoFocusOrUnitScaleHasBaseGeometry() {
        XCTAssertEqual(layout(focus: nil).tileFrames, layout(focus: 4, scale: 1).tileFrames)
        XCTAssertEqual(layout(focus: nil).panelSize.height, 66)
    }

    func testFramesRemainOrderedAndFitAtIntermediateAnimationFractions() {
        let start = layout()
        let target = layout(focus: 3.2)
        for fraction in stride(from: CGFloat(0), through: 1, by: 0.1) {
            let value = start.interpolated(to: target, fraction: fraction)
            for pair in zip(value.tileFrames, value.tileFrames.dropFirst()) {
                XCTAssertLessThanOrEqual(pair.0.maxX, pair.1.minX + 0.001)
            }
            for frame in value.tileFrames {
                XCTAssertEqual(frame.minY, 0)
                XCTAssertLessThanOrEqual(frame.maxY, value.viewportSize.height)
            }
        }
    }

    func testSpacingChangesTheGapWithoutChangingIconDimension() {
        let compact = DockWaveLayout.make(count: 3, iconSize: 72, spacing: 0, magnificationScale: 1,
                                           focusIndex: nil, maxWidth: 1800, hasControls: true)
        let roomy = DockWaveLayout.make(count: 3, iconSize: 72, spacing: 20, magnificationScale: 1,
                                         focusIndex: nil, maxWidth: 1800, hasControls: true)
        XCTAssertEqual(compact.tileFrames[0].height, roomy.tileFrames[0].height)
        XCTAssertEqual(roomy.tileFrames[0].width - compact.tileFrames[0].width, 30)
        XCTAssertEqual(compact.controlsWidth, 93)
    }

    func testFocusMappingUsesActualAnimatedFrames() {
        let value = layout(focus: 4)
        XCTAssertEqual(value.position(for: 4)!, value.tileFrames[4].midX, accuracy: 0.001)
        XCTAssertEqual(value.position(for: 3.5)!, value.tileFrames[4].minX, accuracy: 0.001)
    }

    func testDividerAndEmptyStateRemainBounded() {
        let value = DockWaveLayout.make(count: 4, iconSize: 48, spacing: 14, magnificationScale: 2,
                                         focusIndex: 1, maxWidth: 300, hasControls: true, dividerIndex: 2)
        XCTAssertNotNil(value.dividerX)
        XCTAssertGreaterThan(value.tileFrames[2].minX - value.tileFrames[1].maxX, 0)
        let empty = DockWaveLayout.make(count: 0, iconSize: 48, spacing: 14, magnificationScale: 2,
                                         focusIndex: nil, maxWidth: 300, hasControls: true)
        XCTAssertNil(empty.position(for: 0))
        XCTAssertLessThanOrEqual(empty.panelSize.width, 300)
    }

    func testPanelSettlesWhenAppKitRoundsOriginsDownToWholePoints() {
        for start: CGFloat in [97, 104] {
            var actual = start
            for _ in 0..<12 {
                actual = DockWaveLayout.nextPanelOrigin(current: actual, target: 100.5, fraction: 0.12).rounded(.down)
            }
            XCTAssertEqual(actual, 100)
        }
    }
}
