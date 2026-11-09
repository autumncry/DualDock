import XCTest
@testable import DualDockCore

final class PreviewStripLayoutTests: XCTestCase {
    func testSinglePreviewIsCenteredInPanel() throws {
        let layout = try XCTUnwrap(PreviewStripLayout(itemCount: 1, maxWidth: 1200))
        let center = layout.padding + layout.cardOrigins[0] + layout.cardWidth / 2
        XCTAssertEqual(center, layout.panelWidth / 2, accuracy: 0.01)
    }

    func testTwoPreviewsHaveEqualOuterMargins() throws {
        let layout = try XCTUnwrap(PreviewStripLayout(itemCount: 2, maxWidth: 1200))
        let left = layout.cardOrigins[0]
        let right = layout.documentWidth - layout.cardOrigins[1] - layout.cardWidth
        XCTAssertEqual(left, right, accuracy: 0.01)
    }

    func testOverflowPreservesEveryCardInScrollableDocument() throws {
        let layout = try XCTUnwrap(PreviewStripLayout(itemCount: 6, maxWidth: 700))
        XCTAssertEqual(layout.panelWidth, 700)
        XCTAssertGreaterThan(layout.documentWidth, layout.viewportWidth)
        XCTAssertEqual(layout.cardOrigins.count, 6)
        XCTAssertLessThanOrEqual(layout.cardOrigins.last! + layout.cardWidth, layout.documentWidth)
    }

    func testNoWindowDoesNotProducePreviewLayout() {
        XCTAssertNil(PreviewStripLayout(itemCount: 0, maxWidth: 1200))
        XCTAssertNil(PreviewStripLayout(itemCount: 1, maxWidth: .nan))
    }
}
