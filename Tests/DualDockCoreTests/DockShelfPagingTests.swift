import XCTest
@testable import DualDockCore

final class DockShelfPagingTests: XCTestCase {
    func testDirectionalDragAndMomentum() {
        var swipe = DockShelfGesture()
        func feed(_ phase: DockShelfGesture.Phase, _ along: CGFloat = 0, _ across: CGFloat = 0,
                  _ page: DockShelfPage = .apps, enabled: Bool = true) -> DockShelfGesture.Result {
            swipe.update(phase: phase, along: along, across: across, travel: 60, page: page, enabled: enabled)
        }
        XCTAssertEqual(feed(.began), .pass)
        XCTAssertEqual(feed(.changed, 2, 30), .preview(0.5))
        XCTAssertEqual(feed(.ended), .settle(.tools))
        XCTAssertEqual(feed(.momentum, 3, 90, .tools), .consume)
        XCTAssertEqual(feed(.momentum, 3, -90, .tools), .consume)
        XCTAssertEqual(feed(.wheel, 0, 100, .tools), .pass)
        XCTAssertEqual(feed(.began, 0, -22, .tools), .preview(1 - 22 / 60.0))
        XCTAssertEqual(feed(.ended, 0, -5, .tools), .settle(.apps))
    }

    func testContentAxisAndCancelledPagingDoNotFlip() {
        var swipe = DockShelfGesture()
        func feed(_ phase: DockShelfGesture.Phase, _ along: CGFloat, _ across: CGFloat) -> DockShelfGesture.Result {
            swipe.update(phase: phase, along: along, across: across, travel: 60, page: .apps, enabled: true)
        }
        XCTAssertEqual(feed(.began, 0, 0), .pass)
        XCTAssertEqual(feed(.changed, 20, 1), .pass)
        XCTAssertEqual(feed(.changed, 0, 100), .pass)
        XCTAssertEqual(feed(.ended, 0, 0), .pass)
        XCTAssertEqual(feed(.momentum, 0, 100), .pass)
        XCTAssertEqual(feed(.began, 0, 9), .preview(0.15))
        XCTAssertEqual(feed(.ended, 0, 0), .settle(.apps))
        XCTAssertEqual(feed(.began, 0, 120), .preview(1))
        XCTAssertEqual(feed(.cancelled, 0, 0), .settle(.apps))
    }

    func testBlockedBeginningCannotAcquireMidGesture() {
        var swipe = DockShelfGesture()
        XCTAssertEqual(swipe.update(phase: .began, along: 0, across: 12, travel: 60, page: .apps, enabled: false), .pass)
        XCTAssertEqual(swipe.update(phase: .changed, along: 0, across: 60, travel: 60, page: .apps, enabled: true), .pass)
        XCTAssertEqual(swipe.update(phase: .ended, along: 0, across: 0, travel: 60, page: .apps, enabled: true), .pass)
    }
}
