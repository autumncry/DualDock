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
        XCTAssertEqual(narrow.tileFrames.map(\.size), wide.tileFrames.map(\.size))
        XCTAssertEqual(narrow.panelSize.width, 320)
        XCTAssertGreaterThan(narrow.contentSize.width, narrow.viewportSize.width)
        XCTAssertEqual(wide.contentSize.width, wide.viewportSize.width)
    }

    func testNoFocusOrUnitScaleHasBaseGeometry() {
        XCTAssertEqual(layout(focus: nil).tileFrames.map(\.size), layout(focus: 4, scale: 1).tileFrames.map(\.size))
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
        XCTAssertEqual(value.position(for: 3.5)!, (value.tileFrames[3].midX + value.tileFrames[4].midX) / 2, accuracy: 0.001)
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

    func testHoverKeepsAllHorizontalExtentsAndOverflowRangeConstant() {
        for width: CGFloat in [700, 1800] {
            let base = layout(width: width)
            let originalRange = base.contentSize.width - base.viewportSize.width
            for focus: CGFloat in [0, 0.3, 2, 4, 6, 7.7, 8] {
                let wave = layout(width: width, focus: focus)
                XCTAssertEqual(wave.panelSize.width, base.panelSize.width)
                XCTAssertEqual(wave.viewportSize.width, base.viewportSize.width)
                XCTAssertEqual(wave.contentSize.width, base.contentSize.width)
                XCTAssertEqual(wave.contentSize.width - wave.viewportSize.width, originalRange)
                XCTAssertEqual(wave.initialScrollOffset, base.initialScrollOffset)
            }
        }
    }

    func testMagnificationReserveDoesNotCreateEmptyScrollableSpace() {
        let base = layout(width: 700)
        XCTAssertEqual(base.viewportSize.width, 618)
        XCTAssertEqual(base.contentSize.width, base.viewportSize.width)
        XCTAssertEqual(base.initialScrollOffset, 0)
        for focus: CGFloat in [0, 2, 4, 6, 8] {
            let wave = layout(width: 700, focus: focus)
            XCTAssertEqual(wave.contentSize.width, wave.viewportSize.width)
            XCTAssertEqual(wave.panelSize.width, base.panelSize.width)
        }
    }

    func testLensAnchorUsesFixedBaseCoordinateSpace() {
        let base = layout()
        for focus in stride(from: CGFloat(0), through: 8, by: 0.125) {
            let wave = layout(focus: focus)
            XCTAssertEqual(wave.position(for: focus)!, base.position(for: focus)!, accuracy: 0.001)
            XCTAssertEqual(base.focusIndex(at: base.position(for: focus)!)!, focus, accuracy: 0.001)
        }
    }

    func testManualScrollOffsetDoesNotChangeAndEdgeIconRemainsVisible() {
        let base = DockWaveLayout.make(count: 40, iconSize: 48, spacing: 14, magnificationScale: 2,
                                       focusIndex: nil, maxWidth: 700, hasControls: true)
        let maximumOffset = base.contentSize.width - base.viewportSize.width
        for offset: CGFloat in [0, base.initialScrollOffset, maximumOffset / 2, maximumOffset] {
            for pointer in [offset + 1, offset + base.viewportSize.width - 1] {
                let focus = base.focusIndex(at: pointer)!
                let wave = DockWaveLayout.make(count: 40, iconSize: 48, spacing: 14, magnificationScale: 2,
                                               focusIndex: focus, maxWidth: 700, hasControls: true, scrollOffset: offset)
                let index = min(39, max(0, Int(focus.rounded())))
                let frame = wave.tileFrames[index]
                let iconLeft = frame.minX + 7
                let iconRight = frame.maxX - 7
                XCTAssertGreaterThanOrEqual(iconLeft, offset - 0.001)
                XCTAssertLessThanOrEqual(iconRight, offset + wave.viewportSize.width + 0.001)
                XCTAssertEqual(wave.contentSize.width, base.contentSize.width)
                XCTAssertEqual(wave.viewportSize.width, base.viewportSize.width)
            }
        }
    }

    func testPhysicallyNarrowViewportLimitsOnlyThePeak() {
        let base = DockWaveLayout.make(count: 3, iconSize: 96, spacing: 0, magnificationScale: 2.5,
                                       focusIndex: nil, maxWidth: 320, hasControls: true)
        let wave = DockWaveLayout.make(count: 3, iconSize: 96, spacing: 0, magnificationScale: 2.5,
                                       focusIndex: 1, maxWidth: 320, hasControls: true)
        XCTAssertEqual(base.tileFrames[1].height - 32, 96)
        XCTAssertEqual(wave.tileFrames[1].height - 32, wave.viewportSize.width)
        XCTAssertEqual(base.panelSize.width, wave.panelSize.width)
    }
}
