import XCTest
@testable import DualDockCore

final class DockMagnificationCurveTests: XCTestCase {
    func testWidthChangesNeighborsWithoutChangingPeak() {
        let narrow = DockMagnificationCurve(radius: 1)
        let wide = DockMagnificationCurve(radius: 4)
        XCTAssertEqual(narrow.scale(atDistance: 0, peak: 2), 2)
        XCTAssertEqual(wide.scale(atDistance: 0, peak: 2), 2)
        XCTAssertEqual(narrow.scale(atDistance: 1, peak: 2), 1)
        XCTAssertGreaterThan(wide.scale(atDistance: 1, peak: 2), 1.8)
        XCTAssertEqual(wide.scale(atDistance: 4, peak: 2), 1)
        XCTAssertEqual(wide.weight(atDistance: -1), wide.weight(atDistance: 1))
    }

    func testInvalidInputsRemainBounded() {
        XCTAssertEqual(DockMagnificationCurve(radius: .nan).radius, 2.5)
        XCTAssertEqual(DockMagnificationCurve(radius: -1).radius, 1)
        XCTAssertEqual(DockMagnificationCurve(radius: 100).radius, 4)
        XCTAssertEqual(DockMagnificationCurve().scale(atDistance: 0, peak: .nan), 1)
        XCTAssertEqual(DockMagnificationCurve().weight(atDistance: .infinity), 0)
    }

    func testAllWidthsKeepVisibleBarCenteredAndPeakConstant() {
        let screen = CGRect(x: -1400, y: 150, width: 1400, height: 1000)
        for edge in DockEdge.allCases {
            var previousBody: CGRect?
            for radius in [CGFloat(1), 1.6, 2.5, 4] {
                let style = DockGeometryStyle(iconSize: 48, barThickness: 66, gap: 0,
                    leadingPadding: 6, trailingPadding: 6, magnificationScale: 2, magnificationRadius: radius)
                let base = DockGeometry.make(count: 12, edge: edge, style: style, maximumLength: 1000, fixedLength: 760)
                let hovered = DockGeometry.make(count: 12, edge: edge, style: style, maximumLength: 1000,
                                                fixedLength: 760, focusIndex: 5)
                XCTAssertEqual(hovered.canonicalIconFrames[5].width, 96, accuracy: 0.000001)
                XCTAssertEqual(base.canvasSize, hovered.canvasSize)
                XCTAssertEqual(base.backdropRect, hovered.backdropRect)
                let panel = hovered.panelFrame(in: screen)
                let body = hovered.backdropRect.offsetBy(dx: panel.minX, dy: panel.minY)
                if let previousBody { XCTAssertEqual(body, previousBody) }
                previousBody = body
            }
        }
    }
}
