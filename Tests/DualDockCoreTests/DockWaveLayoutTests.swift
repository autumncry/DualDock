import XCTest
@testable import DualDockCore

final class DockWaveLayoutTests: XCTestCase {
    private func layout(width: CGFloat = 1800, focus: CGFloat? = nil, scale: CGFloat = 2) -> DockWaveLayout {
        .make(count: 9, iconSize: 48, spacing: 14, magnificationScale: scale,
              focusIndex: focus, maxWidth: width, hasControls: false)
    }

    func testOnlyPointedIconMagnifiesAndAllOtherSlotsStayFixed() {
        let base = layout()
        for index in 0..<9 {
            let value = layout(focus: CGFloat(index))
            XCTAssertEqual(value.tileFrames[index].height, 112, accuracy: 0.001)
            XCTAssertEqual(value.tileFrames[index].midX, base.tileFrames[index].midX, accuracy: 0.001)
            for other in 0..<9 where other != index {
                XCTAssertEqual(value.tileFrames[other], base.tileFrames[other])
            }
        }
    }

    func testBackdropAndEntireCanvasStayFixedAtEveryHoverPosition() {
        for width: CGFloat in [320, 1800] {
            let base = layout(width: width)
            XCTAssertEqual(base.backdropSize.height, 66)
            XCTAssertEqual(base.panelSize.height, 114)
            for focus in stride(from: CGFloat(0), through: 8, by: 0.125) {
                let value = layout(width: width, focus: focus)
                XCTAssertEqual(value.backdropSize, base.backdropSize)
                XCTAssertEqual(value.panelSize, base.panelSize)
                XCTAssertEqual(value.contentSize, base.contentSize)
                XCTAssertEqual(value.viewportSize, base.viewportSize)
                XCTAssertEqual(value.initialScrollOffset, base.initialScrollOffset)
            }
        }
    }

    func testDifferentScreenWidthsKeepSameBaseIconSizesAndOnlyOverflowScrolls() {
        let narrow = layout(width: 320)
        let wide = layout(width: 3008)
        XCTAssertEqual(narrow.tileFrames.map(\.size), wide.tileFrames.map(\.size))
        XCTAssertEqual(narrow.panelSize.width, 320)
        XCTAssertGreaterThan(narrow.contentSize.width, narrow.viewportSize.width)
        XCTAssertEqual(wide.contentSize.width, wide.viewportSize.width)
    }

    func testNoFocusOrUnitScaleHasBaseIconGeometry() {
        XCTAssertEqual(layout(focus: nil).tileFrames.map(\.size), layout(focus: 4, scale: 1).tileFrames.map(\.size))
        XCTAssertEqual(layout(focus: 4, scale: 1).panelSize, layout(focus: 4, scale: 1).backdropSize)
    }

    func testAnimationOnlyChangesSelectedIconWithinReservedCanvas() {
        let start = layout()
        let target = layout(focus: 3)
        for fraction in stride(from: CGFloat(0), through: 1, by: 0.1) {
            let value = start.interpolated(to: target, fraction: fraction)
            XCTAssertEqual(value.backdropSize, start.backdropSize)
            XCTAssertEqual(value.panelSize, start.panelSize)
            for index in 0..<9 {
                XCTAssertEqual(value.tileFrames[index].midX, start.tileFrames[index].midX, accuracy: 0.001)
                XCTAssertLessThanOrEqual(value.tileFrames[index].maxY, value.viewportSize.height)
                if index != 3 { XCTAssertEqual(value.tileFrames[index], start.tileFrames[index]) }
            }
        }
    }

    func testSpacingChangesGapWithoutChangingIconDimension() {
        let compact = DockWaveLayout.make(count: 3, iconSize: 72, spacing: 0, magnificationScale: 1,
                                           focusIndex: nil, maxWidth: 1800, hasControls: false)
        let roomy = DockWaveLayout.make(count: 3, iconSize: 72, spacing: 20, magnificationScale: 1,
                                         focusIndex: nil, maxWidth: 1800, hasControls: false)
        XCTAssertEqual(compact.tileFrames[0].height, roomy.tileFrames[0].height)
        XCTAssertEqual(roomy.tileFrames[0].width - compact.tileFrames[0].width, 30)
        XCTAssertEqual(compact.controlsWidth, 0)
    }

    func testDividerRemainsInItsBasePosition() {
        let base = DockWaveLayout.make(count: 4, iconSize: 48, spacing: 14, magnificationScale: 2,
                                      focusIndex: nil, maxWidth: 400, hasControls: false, dividerIndex: 2)
        let value = DockWaveLayout.make(count: 4, iconSize: 48, spacing: 14, magnificationScale: 2,
                                       focusIndex: 1, maxWidth: 400, hasControls: false, dividerIndex: 2)
        XCTAssertNotNil(value.dividerX)
        XCTAssertEqual(value.dividerX, base.dividerX)
    }

    func testEmptyStateNeedsNoTransparentMagnificationSpace() {
        let empty = DockWaveLayout.make(count: 0, iconSize: 48, spacing: 14, magnificationScale: 2,
                                        focusIndex: nil, maxWidth: 300, hasControls: false)
        XCTAssertNil(empty.position(for: 0))
        XCTAssertNil(empty.focusIndex(at: 10))
        XCTAssertEqual(empty.panelSize, empty.backdropSize)
        XCTAssertLessThanOrEqual(empty.panelSize.width, 300)
    }

    func testMagnificationReserveDoesNotCreateEmptyScrollableSpace() {
        let base = layout(width: 700)
        XCTAssertEqual(base.contentSize.width, base.viewportSize.width)
        XCTAssertEqual(base.initialScrollOffset, 0)
        for focus: CGFloat in [0, 2, 4, 6, 8] {
            let value = layout(width: 700, focus: focus)
            XCTAssertEqual(value.contentSize.width, value.viewportSize.width)
            XCTAssertEqual(value.panelSize, base.panelSize)
        }
    }

    func testLensAnchorUsesFixedBaseCoordinateSpace() {
        let base = layout()
        for focus in stride(from: CGFloat(0), through: 8, by: 0.125) {
            XCTAssertEqual(base.focusIndex(at: base.position(for: focus)!)!, focus, accuracy: 0.001)
        }
    }

    func testManualScrollOffsetStaysFixedAndEdgeIconRemainsVisible() {
        let base = DockWaveLayout.make(count: 40, iconSize: 48, spacing: 14, magnificationScale: 2,
                                       focusIndex: nil, maxWidth: 700, hasControls: false)
        let maximumOffset = base.contentSize.width - base.viewportSize.width
        for offset: CGFloat in [0, maximumOffset / 2, maximumOffset] {
            for pointer in [offset + 1, offset + base.viewportSize.width - 1] {
                let focus = base.focusIndex(at: pointer)!
                let value = DockWaveLayout.make(count: 40, iconSize: 48, spacing: 14, magnificationScale: 2,
                                                focusIndex: focus, maxWidth: 700, hasControls: false, scrollOffset: offset)
                let index = min(39, max(0, Int(focus.rounded())))
                let frame = value.tileFrames[index]
                XCTAssertGreaterThanOrEqual(frame.minX + 7, offset - 0.001)
                XCTAssertLessThanOrEqual(frame.maxX - 7, offset + value.viewportSize.width + 0.001)
                XCTAssertEqual(value.contentSize, base.contentSize)
                XCTAssertEqual(value.viewportSize, base.viewportSize)
                for other in 0..<40 where other != index { XCTAssertEqual(value.tileFrames[other], base.tileFrames[other]) }
            }
        }
    }

    func testPhysicallyNarrowViewportLimitsOnlyThePeak() {
        let base = DockWaveLayout.make(count: 3, iconSize: 96, spacing: 0, magnificationScale: 2.5,
                                       focusIndex: nil, maxWidth: 200, hasControls: false)
        let value = DockWaveLayout.make(count: 3, iconSize: 96, spacing: 0, magnificationScale: 2.5,
                                        focusIndex: 1, maxWidth: 200, hasControls: false)
        XCTAssertEqual(base.tileFrames[1].height - 32, 96)
        XCTAssertEqual(value.tileFrames[1].height - 32, value.viewportSize.width)
        XCTAssertEqual(base.panelSize, value.panelSize)
        XCTAssertEqual(base.backdropSize, value.backdropSize)
    }
}
