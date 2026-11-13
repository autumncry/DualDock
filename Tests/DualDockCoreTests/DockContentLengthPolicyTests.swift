import XCTest
@testable import DualDockCore

final class DockContentLengthPolicyTests: XCTestCase {
    func testRowCountsDividerAndRetainsExactMargins() {
        let span = DockContentLengthPolicy.contentSpan(count: 7, iconSize: 48, gap: 14,
            separatorLength: 13, dividerIndex: 4)
        XCTAssertEqual(span, 433)
        let padding = DockContentLengthPolicy.capturedPadding(length: 493, contentSpan: span)
        XCTAssertEqual(padding, 30)
        let next = DockContentLengthPolicy.contentSpan(count: 8, iconSize: 48, gap: 14,
            separatorLength: 13, dividerIndex: 4)
        XCTAssertEqual(DockContentLengthPolicy.desiredLength(contentSpan: next, padding: padding), 555)
    }

    func testEmptyRowAndInvalidDividerMatchGeometry() {
        for count in [0, 1, 8] {
            for divider in [nil, 0, 4, 8, 99] as [Int?] {
                let style = DockGeometryStyle(iconSize: 48, barThickness: 66, gap: 14,
                    leadingPadding: 6, trailingPadding: 6)
                let geometry = DockGeometry.make(count: count, edge: .bottom, style: style,
                    maximumLength: 10000, dividerIndex: divider)
                let span = DockContentLengthPolicy.contentSpan(count: count, iconSize: 48,
                    gap: 14, separatorLength: 13, dividerIndex: divider)
                XCTAssertEqual(Double(geometry.bodyLength), span + 12)
            }
        }
    }

    func testOverflowUsesScrollableContentAndCenteredBar() {
        let style = DockGeometryStyle(iconSize: 48, barThickness: 66, gap: 14,
            leadingPadding: 25, trailingPadding: 25)
        for edge in DockEdge.allCases {
            let geometry = DockGeometry.make(count: 60, edge: edge, style: style,
                maximumLength: 800)
            XCTAssertEqual(geometry.bodyLength, 800)
            XCTAssertGreaterThan(geometry.scrollRange, 0)
            let screen = CGRect(x: 100, y: 200, width: 800, height: 800)
            let frame = geometry.panelFrame(in: screen)
            let body = geometry.backdropRect.offsetBy(dx: frame.minX, dy: frame.minY)
            XCTAssertEqual(edge.isHorizontal ? body.midX : body.midY,
                edge.isHorizontal ? screen.midX : screen.midY)
        }
    }

    func testSchemaDefaultsOffAndPreservesIndependentPadding() throws {
        let old = try JSONDecoder().decode(DockConfiguration.self,
            from: Data("{\"version\":8,\"autoAdjustWidth\":true,\"dockWidth\":850}".utf8))
        XCTAssertFalse(old.manualAutoLength)
        XCTAssertNil(old.manualContentPadding)
        XCTAssertTrue(old.adaptiveSizing)
        XCTAssertEqual(old.dockWidth, 850)
        XCTAssertEqual(old.version, 9)
        var new = old
        new.manualAutoLength = true
        new.manualContentPadding = 42
        new.displaySettings["second"] = DockDisplaySettings(edge: .left,
            manualSizing: DockManualSizing(length: 600, thickness: 66, contentPadding: 21))
        let roundTrip = try JSONDecoder().decode(DockConfiguration.self, from: JSONEncoder().encode(new))
        XCTAssertEqual(roundTrip, new)
    }

    func testInvalidAndOverflowingBaselinePaddingIsSafe() {
        XCTAssertEqual(DockContentLengthPolicy.capturedPadding(length: 100, contentSpan: 200), 6)
        XCTAssertEqual(DockContentLengthPolicy.capturedPadding(length: .infinity, contentSpan: 200), 6)
        XCTAssertEqual(DockManualSizing(length: 500, thickness: 66, contentPadding: -7).contentPadding, 6)
        XCTAssertNil(DockManualSizing(length: 500, thickness: 66, contentPadding: .nan).contentPadding)
    }
}
