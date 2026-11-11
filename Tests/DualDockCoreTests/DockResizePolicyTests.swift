import XCTest
@testable import DualDockCore

final class DockResizePolicyTests: XCTestCase {
    private let bounds = DockResizeBounds(minLength: 240, maxLength: 1800, minThickness: 33, maxThickness: 200)
    private let start = DockManualSizing(length: 1000, thickness: 100, iconScale: 0.8, iconSpacing: 8)

    func testHandlesRotateWithTheDockAndCornersWin() {
        for edge in DockEdge.allCases {
            let transform = DockAxisTransform(edge: edge, length: 1000, thickness: 100)
            let body = CGRect(origin: CGPoint(x: 10, y: 20), size: transform.physicalSize)
            func point(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
                let p = transform.pointToPhysical(CGPoint(x: u, y: v))
                return CGPoint(x: p.x + body.minX, y: p.y + body.minY)
            }
            XCTAssertEqual(DockResizePolicy.handle(at: point(0, 100), backdrop: body, edge: edge), .leadingCorner)
            XCTAssertEqual(DockResizePolicy.handle(at: point(1000, 100), backdrop: body, edge: edge), .trailingCorner)
            XCTAssertEqual(DockResizePolicy.handle(at: point(0, 50), backdrop: body, edge: edge), .leading)
            XCTAssertEqual(DockResizePolicy.handle(at: point(1000, 50), backdrop: body, edge: edge), .trailing)
            XCTAssertEqual(DockResizePolicy.handle(at: point(500, 100), backdrop: body, edge: edge), .inward)
            XCTAssertNil(DockResizePolicy.handle(at: point(500, 0), backdrop: body, edge: edge))
            XCTAssertNil(DockResizePolicy.handle(at: point(500, 50), backdrop: body, edge: edge))
        }
    }

    func testCenteredLengthResizeUsesBothEndsAndDoesNotTouchThickness() {
        let left = DockResizePolicy.propose(start: start, handle: .leading, edge: .bottom,
                                            screenDelta: CGSize(width: -20, height: 80), bounds: bounds)
        XCTAssertEqual(left.length, 1040)
        XCTAssertEqual(left.thickness, 100)
        let vertical = DockResizePolicy.propose(start: start, handle: .trailing, edge: .left,
                                                screenDelta: CGSize(width: 80, height: -20), bounds: bounds)
        XCTAssertEqual(vertical, left)
    }

    func testInwardThicknessResizeHasCorrectSignOnEveryEdge() {
        let deltas: [DockEdge: CGSize] = [.bottom: .init(width: 0, height: 20), .top: .init(width: 0, height: -20),
                                          .left: .init(width: 20, height: 0), .right: .init(width: -20, height: 0)]
        for edge in DockEdge.allCases {
            let value = DockResizePolicy.propose(start: start, handle: .inward, edge: edge,
                                                 screenDelta: deltas[edge]!, bounds: bounds)
            XCTAssertEqual(value.thickness, 120)
            XCTAssertEqual(value.length, 1000)
            XCTAssertEqual(value.iconScale, start.iconScale)
        }
    }

    func testCornersUseOneUniformScaleAndJointLimit() {
        let value = DockResizePolicy.propose(start: start, handle: .trailingCorner, edge: .bottom,
                                             screenDelta: CGSize(width: 100, height: 20), bounds: bounds)
        XCTAssertEqual(value.length, 1200, accuracy: 0.0001)
        XCTAssertEqual(value.thickness, 120, accuracy: 0.0001)
        let capped = DockResizePolicy.propose(start: start, handle: .trailingCorner, edge: .bottom,
                                              screenDelta: CGSize(width: 1000, height: 1000), bounds: bounds)
        XCTAssertEqual(capped.length, 1800)
        XCTAssertEqual(capped.thickness, 180)
        XCTAssertEqual(capped.length / capped.thickness, start.length / start.thickness)
    }

    func testUntouchedRequestedAxisSurvivesTemporaryClamping() {
        let oversized = DockManualSizing(length: 3000, thickness: 500)
        let heightOnly = DockResizePolicy.propose(start: oversized, handle: .inward, edge: .bottom,
                                                  screenDelta: CGSize(width: 0, height: -20), bounds: bounds)
        XCTAssertEqual(heightOnly.length, 3000)
        XCTAssertEqual(heightOnly.thickness, 180)
        let lengthOnly = DockResizePolicy.propose(start: oversized, handle: .trailing, edge: .bottom,
                                                  screenDelta: CGSize(width: -10, height: 0), bounds: bounds)
        XCTAssertEqual(lengthOnly.length, 1780)
        XCTAssertEqual(lengthOnly.thickness, 500)
    }
}
