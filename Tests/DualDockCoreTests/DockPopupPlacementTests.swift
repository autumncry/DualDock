import XCTest
@testable import DualDockCore

final class DockPopupPlacementTests: XCTestCase {
    func testPopupsOpenInwardOnEveryEdge() {
        let screen = CGRect(x: -1800, y: 200, width: 1800, height: 1100)
        let anchors: [DockEdge: CGRect] = [
            .bottom: .init(x: -900, y: 220, width: 48, height: 48),
            .top: .init(x: -900, y: 1200, width: 48, height: 48),
            .left: .init(x: -1780, y: 700, width: 48, height: 48),
            .right: .init(x: -68, y: 700, width: 48, height: 48)
        ]
        for edge in DockEdge.allCases {
            let source = anchors[edge]!
            let popup = DockPopupPlacement.frame(size: CGSize(width: 300, height: 180), anchor: source,
                                                 edge: edge, visibleScreen: screen)
            XCTAssertTrue(screen.contains(popup))
            switch edge {
            case .bottom: XCTAssertEqual(popup.minY, source.maxY + 10)
            case .top: XCTAssertEqual(popup.maxY, source.minY - 10)
            case .left: XCTAssertEqual(popup.minX, source.maxX + 10)
            case .right: XCTAssertEqual(popup.maxX, source.minX - 10)
            }
            let bridge = DockPopupPlacement.bridge(source: source, popup: popup, edge: edge)
            XCTAssertNotNil(bridge)
            XCTAssertFalse(bridge!.contains(CGPoint(x: source.midX, y: source.midY)))
        }
    }

    func testClampedOverlappingPopupDoesNotCreateInvalidBridge() {
        let source = CGRect(x: 100, y: 100, width: 50, height: 50)
        for edge in DockEdge.allCases {
            XCTAssertNil(DockPopupPlacement.bridge(source: source, popup: source.insetBy(dx: -10, dy: -10), edge: edge))
        }
        let frame = DockPopupPlacement.frame(size: CGSize(width: 2000, height: 2000), anchor: source,
                                             edge: .top, visibleScreen: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 800, height: 600).contains(frame))
    }

    func testMenuOriginFacesInwardAndStaysOnScreen() {
        let screen = CGRect(x: -1800, y: 200, width: 1800, height: 1100)
        let icon = CGRect(x: -1000, y: 700, width: 48, height: 48)
        let size = CGSize(width: 220, height: 240)
        for edge in DockEdge.allCases {
            let origin = DockMenuPlacement.origin(icon: icon, menuSize: size, visibleScreen: screen, edge: edge)
            let menu = CGRect(x: origin.x, y: origin.y - size.height, width: size.width, height: size.height)
            XCTAssertTrue(screen.contains(menu))
            switch edge {
            case .bottom: XCTAssertGreaterThan(menu.minY, icon.maxY)
            case .top: XCTAssertLessThan(menu.maxY, icon.minY)
            case .left: XCTAssertGreaterThan(menu.minX, icon.maxX)
            case .right: XCTAssertLessThan(menu.maxX, icon.minX)
            }
        }
    }
}
