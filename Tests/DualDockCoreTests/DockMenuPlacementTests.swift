import XCTest
@testable import DualDockCore

final class DockMenuPlacementTests: XCTestCase {
    func testMenuStartsSlightlyRightOfIconCenter() {
        let icon = CGRect(x: 400, y: 10, width: 48, height: 48)
        let size = CGSize(width: 180, height: 230)
        let origin = DockMenuPlacement.origin(icon: icon, menuSize: size, visibleScreen: CGRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(origin.x, icon.midX + 8)
        XCTAssertEqual(origin.y - size.height, icon.maxY + 8)
    }

    func testRightEdgeClampsTheMenuInsideItsDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 240, height: 230)
        let origin = DockMenuPlacement.origin(icon: CGRect(x: 1380, y: 10, width: 48, height: 48), menuSize: size, visibleScreen: screen)
        XCTAssertLessThanOrEqual(origin.x + size.width, screen.maxX - 8)
        XCTAssertGreaterThanOrEqual(origin.x, screen.minX + 8)
    }

    func testNegativeDisplayCoordinatesAndTopBoundary() {
        let screen = CGRect(x: -2560, y: 1000, width: 2560, height: 1440)
        let origin = DockMenuPlacement.origin(icon: CGRect(x: -2000, y: 2220, width: 72, height: 72), menuSize: CGSize(width: 220, height: 300), visibleScreen: screen)
        XCTAssertLessThan(origin.x, 0)
        XCTAssertEqual(origin.y, screen.maxY - 8)
    }
}
