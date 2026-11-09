import XCTest
@testable import DualDockCore

final class DockWaveLayoutTests: XCTestCase {
    private func layout(width: CGFloat = 1800, focus: CGFloat? = nil, scale: CGFloat = 2) -> DockWaveLayout {
        .make(count: 9, iconSize: 48, spacing: 14, magnificationScale: scale,
              focusIndex: focus, maxWidth: width, hasControls: false)
    }

    func testMagnificationFallsOffSmoothlyAcrossTwoNeighbors() {
        let base = layout()
        let value = layout(focus: 4)
        let sizes = value.tileFrames.map { $0.height - 16 }
        XCTAssertEqual(sizes[4], 96, accuracy: 0.001)
        XCTAssertGreaterThan(sizes[3], sizes[2])
        XCTAssertGreaterThan(sizes[2], 48)
        XCTAssertEqual(sizes[3], sizes[5], accuracy: 0.001)
        XCTAssertEqual(sizes[2], sizes[6], accuracy: 0.001)
        XCTAssertEqual(sizes[1], 48)
        XCTAssertEqual(sizes[7], 48)
        XCTAssertEqual(value.position(for: 4)!, base.position(for: 4)!, accuracy: 0.001)
    }

    func testFractionalFocusIsContinuousAcrossIconBoundaries() {
        for focus in stride(from: CGFloat(0.01), through: 7.99, by: 0.1) {
            let before = layout(focus: focus - 0.001)
            let after = layout(focus: focus + 0.001)
            XCTAssertLessThan(before.maximumDifference(from: after), 0.25)
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

    func testAnimatedWaveDoesNotOverlapOrChangeFixedCanvas() {
        for focus in stride(from: CGFloat(0), through: 8, by: 0.125) {
            let start = layout()
            let target = layout(focus: focus)
            for fraction: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
                let value = start.interpolated(to: target, fraction: fraction)
                XCTAssertEqual(value.backdropSize, start.backdropSize)
                XCTAssertEqual(value.panelSize, start.panelSize)
                for pair in zip(value.tileFrames, value.tileFrames.dropFirst()) {
                    XCTAssertLessThanOrEqual(pair.0.maxX, pair.1.minX + 0.001)
                }
                for frame in value.tileFrames {
                    XCTAssertGreaterThanOrEqual(frame.minX, -0.001)
                    XCTAssertLessThanOrEqual(frame.maxX, value.contentSize.width + 0.001)
                    XCTAssertLessThanOrEqual(frame.maxY, value.viewportSize.height)
                }
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

    func testDividerStaysBetweenItsAdjacentWaveIcons() {
        let base = DockWaveLayout.make(count: 4, iconSize: 48, spacing: 14, magnificationScale: 2,
                                      focusIndex: nil, maxWidth: 400, hasControls: false, dividerIndex: 2)
        let value = DockWaveLayout.make(count: 4, iconSize: 48, spacing: 14, magnificationScale: 2,
                                       focusIndex: 1, maxWidth: 400, hasControls: false, dividerIndex: 2)
        XCTAssertNotNil(value.dividerX)
        XCTAssertNotNil(base.dividerX)
        XCTAssertGreaterThan(value.dividerX!, value.tileFrames[1].maxX)
        XCTAssertLessThan(value.dividerX!, value.tileFrames[2].minX)
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
            XCTAssertEqual(layout(focus: focus).position(for: focus)!, base.position(for: focus)!, accuracy: 0.001)
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
                                                focusIndex: focus, maxWidth: 700, hasControls: false, scrollOffset: offset,
                                                lensAnchorX: pointer)
                let index = min(39, max(0, Int(focus.rounded())))
                let frame = value.tileFrames[index]
                XCTAssertGreaterThan(frame.maxX - 7, offset)
                XCTAssertLessThan(frame.minX + 7, offset + value.viewportSize.width)
                XCTAssertTrue(value.tileFrames.contains { $0.contains(CGPoint(x: pointer, y: 24)) })
                XCTAssertEqual(value.contentSize, base.contentSize)
                XCTAssertEqual(value.viewportSize, base.viewportSize)
                for pair in zip(value.tileFrames, value.tileFrames.dropFirst()) {
                    XCTAssertLessThanOrEqual(pair.0.maxX, pair.1.minX + 0.001)
                }
            }
        }
    }

    func testShiftedTerminalIconRemainsUnderPointerAfterNewHover() {
        let base = layout()
        let previous = layout(focus: 0)
        let pointer = previous.tileFrames[8].midX
        let target = DockWaveLayout.make(count: 9, iconSize: 48, spacing: 14, magnificationScale: 2,
                                         focusIndex: base.focusIndex(at: pointer), maxWidth: 1800,
                                         hasControls: false, lensAnchorX: pointer)
        XCTAssertTrue(target.tileFrames[8].contains(CGPoint(x: pointer, y: 24)))
        XCTAssertEqual(target.panelSize, previous.panelSize)
        XCTAssertEqual(target.contentSize, previous.contentSize)
        for fraction: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
            XCTAssertTrue(previous.interpolated(to: target, fraction: fraction).tileFrames[8]
                .contains(CGPoint(x: pointer, y: 24)))
        }
    }

    func testOverflowEdgeConstraintDoesNotJumpWhenRoundedFocusChanges() {
        let base = DockWaveLayout.make(count: 40, iconSize: 48, spacing: 14, magnificationScale: 2,
                                       focusIndex: nil, maxWidth: 320, hasControls: false)
        let offset: CGFloat = 2108
        let focus: CGFloat = 33.5
        let x = base.position(for: focus)!
        let before = DockWaveLayout.make(count: 40, iconSize: 48, spacing: 14, magnificationScale: 2,
                                         focusIndex: focus - 0.0001, maxWidth: 320, hasControls: false,
                                         scrollOffset: offset, lensAnchorX: x - 0.0062)
        let after = DockWaveLayout.make(count: 40, iconSize: 48, spacing: 14, magnificationScale: 2,
                                        focusIndex: focus + 0.0001, maxWidth: 320, hasControls: false,
                                        scrollOffset: offset, lensAnchorX: x + 0.0062)
        XCTAssertLessThan(before.maximumDifference(from: after), 0.1)
        XCTAssertEqual(before.panelSize, after.panelSize)
        XCTAssertEqual(before.backdropSize, after.backdropSize)
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
