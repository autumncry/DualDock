import XCTest
@testable import DualDockCore

final class DockGeometryTests: XCTestCase {
    func testMovingWaveSettlesSubpixelSizeTailsIndependently() {
        let style = DockGeometryStyle(iconSize: 48, barThickness: 66, gap: 3,
            leadingPadding: 6, trailingPadding: 6, magnificationScale: 2)
        let rest = DockGeometry.make(count: 28, edge: .bottom, style: style,
                                     maximumLength: 1800, fixedLength: 1500)
        let previousPeak = DockGeometry.make(count: 28, edge: .bottom, style: style,
            maximumLength: 1800, fixedLength: 1500, focusIndex: 2)
        let smallTail = rest.interpolated(to: previousPeak, fraction: 0.001)
        let movingTarget = DockGeometry.make(count: 28, edge: .bottom, style: style,
            maximumLength: 1800, fixedLength: 1500, focusIndex: 20.3)
        let next = smallTail.interpolated(to: movingTarget, fraction: 0.1)
        XCTAssertEqual(next.canonicalIconFrames[2].width, movingTarget.canonicalIconFrames[2].width,
                       accuracy: 0.000001, "An invisible old size tail must not keep invalidating the icon bitmap")
        XCTAssertGreaterThan(next.maximumDifference(from: movingTarget), 1,
                             "The active wave must continue; this is not a whole-strip snap")
    }

    func testContinuousZeroGapWaveDoesNotOverlapIcons() {
        let style = DockGeometryStyle(iconSize: 48, barThickness: 66, gap: 0,
            leadingPadding: 6, trailingPadding: 6, magnificationScale: 2)
        var current = DockGeometry.make(count: 28, edge: .bottom, style: style,
                                        maximumLength: 1800, fixedLength: 1500)
        for frame in 0..<360 {
            let focus = CGFloat(frame % 180) / 179 * 27
            let target = DockGeometry.make(count: 28, edge: .bottom, style: style,
                maximumLength: 1800, fixedLength: 1500, focusIndex: focus)
            current = current.interpolated(to: target, fraction: 0.09)
            for index in current.canonicalIconFrames.indices {
                let icon = current.canonicalIconFrames[index]
                let tile = current.canonicalTileFrames[index]
                let dot = current.canonicalDotFrames[index]
                XCTAssertEqual(dot.midX, icon.midX, accuracy: 0.000001)
                XCTAssertEqual(tile.width, icon.width, accuracy: 0.000001)
            }
            if let pair = zip(current.canonicalIconFrames, current.canonicalIconFrames.dropFirst())
                .first(where: { $0.maxX > $1.minX + 0.000001 }) {
                XCTFail("Icons overlap by \(pair.0.maxX - pair.1.minX) at frame \(frame)")
                return
            }
        }
    }
    private let style = DockGeometryStyle(iconSize: 48, barThickness: 66, gap: 6,
        leadingPadding: 6, trailingPadding: 8, magnificationScale: 2)

    private func geometry(_ edge: DockEdge, count: Int = 5, length: CGFloat? = nil,
                          focus: CGFloat? = nil, offset: CGFloat = 0) -> DockGeometry {
        .make(count: count, edge: edge, style: style, maximumLength: 1000,
              fixedLength: length, focusIndex: focus, scrollOffset: offset)
    }

    func testResizeCanvasStaysContinuousWhenGrowingIconsStartToOverflow() {
        for edge in DockEdge.allCases {
            for (count, length, ratio, magnification) in [(26, 1348.644, 1.0013, 1.638), (1, 120.0, 1.25, 2.5)] {
                var previous: DockGeometry?
                var observedFit = false, observedOverflow = false
                for step in 0...896 {
                    let thickness = 48 + CGFloat(step) / 8
                    let sizing = DockManualSizing(length: length, thickness: Double(thickness), iconScale: ratio, iconSpacing: 0)
                    let next = DockGeometry.make(count: count, edge: edge,
                        style: .init(iconSize: CGFloat(sizing.resolvedIconSize), barThickness: thickness,
                                     gap: 0, leadingPadding: 6, trailingPadding: 6,
                                     magnificationScale: magnification),
                        maximumLength: 1800, fixedLength: CGFloat(length), resizeMargin: 6)
                    observedFit = observedFit || next.scrollRange == 0
                    observedOverflow = observedOverflow || next.scrollRange > 0
                    if let previous {
                        // A 1/8pt input step may cross a whole-point bleed rounding
                        // boundary, but must not discard an entire magnification gutter.
                        XCTAssertLessThanOrEqual(abs(next.canonicalCanvasSize.width - previous.canonicalCanvasSize.width), 2.01)
                        XCTAssertLessThanOrEqual(abs(next.canonicalCanvasSize.height - previous.canonicalCanvasSize.height), 1)
                        XCTAssertLessThanOrEqual(abs(next.canonicalBackdropRect.minX - previous.canonicalBackdropRect.minX), 1.01)
                    }
                    previous = next
                }
                XCTAssertTrue(observedFit && observedOverflow, "The sweep must cross the fit/overflow boundary")
            }
        }
    }

    func testResizeLengthDoesNotDropCanvasReserveAtOverflowBoundary() {
        for edge in DockEdge.allCases {
            var previous: DockGeometry?
            for step in 0...160 {
                let next = DockGeometry.make(count: 5, edge: edge, style: style, maximumLength: 1000,
                    fixedLength: 260 + CGFloat(step) / 4, resizeMargin: 6)
                if let previous {
                    XCTAssertLessThanOrEqual(abs(next.canonicalCanvasSize.width - previous.canonicalCanvasSize.width), 0.251)
                    XCTAssertEqual(next.canonicalCanvasSize.height, previous.canonicalCanvasSize.height)
                }
                previous = next
            }
        }
    }

    func testFourEdgeTransformsRoundTripWithoutRotatingImageContent() {
        for edge in DockEdge.allCases {
            let transform = DockAxisTransform(edge: edge, length: 800, thickness: 140)
            let point = CGPoint(x: -20, y: 64)
            let rect = CGRect(x: 100, y: 12, width: 70, height: 92)
            XCTAssertEqual(transform.pointToCanonical(transform.pointToPhysical(point)), point)
            XCTAssertEqual(transform.rectToCanonical(transform.rectToPhysical(rect)), rect)
            XCTAssertEqual(transform.physicalSize, edge.isHorizontal ? CGSize(width: 800, height: 140) : CGSize(width: 140, height: 800))
        }
    }

    func testAutomaticEndPaddingExcludesMagnificationReserve() {
        for edge in DockEdge.allCases {
            let base = geometry(edge)
            XCTAssertEqual(base.bodyLength, 5 * 48 + 4 * 6 + 6 + 8)
            XCTAssertGreaterThan(base.canonicalCanvasSize.width, base.bodyLength)
            XCTAssertEqual(base.canonicalIconFrames.first!.minX - base.canonicalBackdropRect.minX, 6)
            XCTAssertEqual(base.canonicalBackdropRect.maxX - base.canonicalIconFrames.last!.maxX, 8)
            XCTAssertEqual(base.scrollRange, 0)
            for focus: CGFloat in [0, 0.5, 2, 4] {
                let expanded = geometry(edge, focus: focus)
                XCTAssertEqual(expanded.backdropRect, base.backdropRect)
                XCTAssertEqual(expanded.canvasSize, base.canvasSize)
                XCTAssertEqual(expanded.viewportRect, base.viewportRect)
                XCTAssertEqual(expanded.documentSize, base.documentSize)
            }
        }
    }

    func testMappedItemsStayUprightAndOrderedAlongEachEdge() {
        for edge in DockEdge.allCases {
            let value = geometry(edge, focus: 2)
            for icon in value.iconFrames { XCTAssertEqual(icon.width, icon.height) }
            for (a, b) in zip(value.iconFrames, value.iconFrames.dropFirst()) {
                if edge.isHorizontal { XCTAssertLessThanOrEqual(a.maxX, b.minX) }
                else { XCTAssertGreaterThanOrEqual(a.minY, b.maxY) }
            }
            for (tile, icon) in zip(value.tileFrames, value.iconFrames) {
                XCTAssertTrue(tile.contains(icon))
            }
        }
    }

    func testOverflowDoesNotExposeRestingIconsOutsideBackdrop() {
        for edge in DockEdge.allCases {
            let value = DockGeometry.make(count: 20, edge: edge, style: style, maximumLength: 1000,
                                           fixedLength: 300, resizeMargin: 6)
            XCTAssertEqual(value.canonicalViewportRect.width, value.bodyLength)
            XCTAssertEqual(value.canonicalViewportRect.minX, value.canonicalBackdropRect.minX)
            XCTAssertGreaterThan(value.scrollRange, 0)
            let start = value.scrollOrigin(forCanonicalOffset: 0)
            let finish = value.scrollOrigin(forCanonicalOffset: value.scrollRange)
            if edge.isHorizontal {
                XCTAssertEqual(start.x, 0)
                XCTAssertEqual(finish.x, value.scrollRange)
            } else {
                XCTAssertEqual(start.y, value.scrollRange)
                XCTAssertEqual(finish.y, 0)
            }
            for offset in [CGFloat(0), value.scrollRange / 2, value.scrollRange] {
                let origin = value.scrollOrigin(forCanonicalOffset: offset)
                let clip = CGRect(origin: origin, size: value.viewportRect.size)
                XCTAssertEqual(value.canonicalScrollOffset(clipBounds: clip), offset, accuracy: 0.00001)
            }
        }
    }

    func testVisibleBackdropIsCenteredAndAnchoredOnNegativeCoordinateScreens() {
        let screen = CGRect(x: -1920, y: 400, width: 1800, height: 1100)
        for edge in DockEdge.allCases {
            let value = geometry(edge)
            let window = value.panelFrame(in: screen, edgeInset: 8)
            let body = value.backdropRect.offsetBy(dx: window.minX, dy: window.minY)
            if edge.isHorizontal { XCTAssertEqual(body.midX, screen.midX) }
            else { XCTAssertEqual(body.midY, screen.midY) }
            switch edge {
            case .bottom: XCTAssertEqual(body.minY, screen.minY + 8)
            case .top: XCTAssertEqual(body.maxY, screen.maxY - 8)
            case .left: XCTAssertEqual(body.minX, screen.minX + 8)
            case .right: XCTAssertEqual(body.maxX, screen.maxX - 8)
            }
        }
    }

    func testHoverInterpolationKeepsAllContainersFixed() {
        for edge in DockEdge.allCases {
            let base = geometry(edge)
            let target = geometry(edge, focus: 2.3)
            for fraction: CGFloat in [0, 0.2, 0.5, 1] {
                let current = base.interpolated(to: target, fraction: fraction)
                XCTAssertEqual(current.canvasSize, base.canvasSize)
                XCTAssertEqual(current.backdropRect, base.backdropRect)
                XCTAssertEqual(current.documentSize, base.documentSize)
                for (left, right) in zip(current.canonicalIconFrames, current.canonicalIconFrames.dropFirst()) {
                    XCTAssertLessThanOrEqual(left.maxX, right.minX + 0.0001)
                }
            }
        }
    }

    func testDividerGapRemainsAnActiveMagnificationPath() {
        for edge in DockEdge.allCases {
            let base = DockGeometry.make(count: 6, edge: edge, style: style, maximumLength: 1000, dividerIndex: 3)
            let u = (base.canonicalTileFrames[2].maxX + base.canonicalTileFrames[3].minX) / 2
            let point = base.documentTransform.pointToPhysical(CGPoint(x: u, y: 20))
            XCTAssertNotNil(base.magnificationFocus(at: point, basedOn: base))
        }
    }

    func testEmptyAndSingleItemGeometryIsFinite() {
        for edge in DockEdge.allCases {
            for count in [0, 1] {
                let value = geometry(edge, count: count)
                XCTAssertTrue(value.canvasSize.width.isFinite && value.canvasSize.height.isFinite)
                XCTAssertEqual(value.tileFrames.count, count)
                if count == 0 { XCTAssertNil(value.focusIndex(at: 10)) }
            }
        }
    }
}
