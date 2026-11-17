import XCTest
@testable import DualDockCore

final class SettingsPreviewLayoutTests: XCTestCase {
    func testFixedZoomShowsIconSizeChangesAcrossCountsAndPreviewWidths() {
        for count in [8, 24] {
            for width in [260.0, 470.0] {
                for zoom in [0.5, 0.75, 1.0] {
                    let small = layout(iconSize: 32, count: count, width: width, zoom: zoom)
                    let large = layout(iconSize: 64, count: count, width: width, zoom: zoom)
                    XCTAssertEqual(small.iconFrames[0].width, 32 * zoom, accuracy: 0.001)
                    XCTAssertEqual(large.iconFrames[0].width, small.iconFrames[0].width * 2, accuracy: 0.001)
                    XCTAssertEqual(large.scale, small.scale)
                    XCTAssertEqual(large.iconFrames.count, count)
                }
            }
        }
    }

    func testNarrowStageAddsScrollingWithoutChangingGeometryScale() {
        let narrow = layout(iconSize: 64, count: 24, width: 260, zoom: 0.75)
        let wide = layout(iconSize: 64, count: 24, width: 470, zoom: 0.75)
        XCTAssertGreaterThan(narrow.maximumScrollOffset.x, wide.maximumScrollOffset.x)
        XCTAssertEqual(narrow.canvasFrame.size, wide.canvasFrame.size)
        XCTAssertEqual(narrow.iconFrames[0].size, wide.iconFrames[0].size)
    }

    func testScrollingReachesLastEntryForEveryEdgeIncludingPhysicalOverflow() {
        for edge in DockEdge.allCases {
            let g = geometry(iconSize: 64, count: 24, edge: edge, maximumLength: 420)
            let start = SettingsPreviewLayout(geometry: g, zoom: 0.75, viewportSize: CGSize(width: 260, height: 148))
            let end = SettingsPreviewLayout(geometry: g, zoom: 0.75, viewportSize: CGSize(width: 260, height: 148),
                                            scrollOffset: start.maximumScrollOffset)
            XCTAssertEqual(start.iconFrames.count, 24)
            XCTAssertGreaterThan(g.scrollRange, 0)
            XCTAssertTrue(start.visibleDockFrame.intersects(start.iconFrames[0]), "First entry: \(edge)")
            XCTAssertTrue(end.visibleDockFrame.contains(end.iconFrames.last!), "Last entry: \(edge)")
            XCTAssertTrue(CGRect(x: 0, y: 0, width: 260, height: 148).contains(end.iconFrames.last!), "Stage: \(edge)")
            XCTAssertEqual(end.iconFrames.last!.width, 48, accuracy: 0.001)
        }
    }

    func testPhysicalScreenClampIsPreservedInsteadOfReplacedByRequestedSize() {
        var request = DockCustomSizing()
        request.iconSize = 64
        let resolved = DockCustomSizingResolver.resolve(request, count: 24, dividerIndex: nil,
                                                        maximumLength: 500, maximumHeight: 200)
        XCTAssertLessThan(resolved.iconSize, request.iconSize)
        let g = DockGeometry.make(count: 24, edge: .bottom,
            style: DockGeometryStyle(iconSize: resolved.iconSize, barThickness: resolved.thickness,
                                     gap: resolved.gap, leadingPadding: resolved.padding, trailingPadding: resolved.padding),
            maximumLength: 500, fixedLength: resolved.length)
        let preview = SettingsPreviewLayout(geometry: g, zoom: 0.75, viewportSize: CGSize(width: 470, height: 148))
        XCTAssertEqual(preview.iconFrames[0].width, resolved.iconSize * 0.75, accuracy: 0.001)
        XCTAssertNotEqual(preview.iconFrames[0].width, request.iconSize * 0.75)
    }

    func testFittingDockAnchorsToItsSelectedEdge() {
        for edge in DockEdge.allCases {
            let g = geometry(iconSize: 32, count: 2, edge: edge)
            let preview = SettingsPreviewLayout(geometry: g, zoom: 0.75,
                                                 viewportSize: CGSize(width: 470, height: 148))
            switch edge {
            case .bottom: XCTAssertEqual(preview.backdropFrame.maxY, 134, accuracy: 0.001)
            case .top: XCTAssertEqual(preview.backdropFrame.minY, 14, accuracy: 0.001)
            case .left: XCTAssertEqual(preview.backdropFrame.minX, 14, accuracy: 0.001)
            case .right: XCTAssertEqual(preview.backdropFrame.maxX, 456, accuracy: 0.001)
            }
            XCTAssertEqual(preview.maximumScrollOffset, .zero)
        }
    }

    func testAllEdgesPreserveProductionContentAlignmentAndDivider() {
        for edge in DockEdge.allCases {
            for alignment in DockContentAlignment.allCases {
                let style = DockGeometryStyle(iconSize: 32, barThickness: 56, gap: 8,
                    leadingPadding: 12, trailingPadding: 12, contentAlignment: alignment)
                let g = DockGeometry.make(count: 4, edge: edge, style: style, maximumLength: 900,
                                          fixedLength: 350, dividerIndex: 2)
                let preview = SettingsPreviewLayout(geometry: g, zoom: 0.75,
                                                     viewportSize: CGSize(width: 470, height: 350))
                let a = preview.iconFrames[0], b = preview.iconFrames[1]
                let actualDistance = edge.isHorizontal ? b.minX - a.minX : b.minY - a.minY
                XCTAssertEqual(actualDistance, (g.canonicalIconFrames[1].minX - g.canonicalIconFrames[0].minX) * 0.75,
                               accuracy: 0.001)
                XCTAssertNotNil(preview.dividerFrame)
                XCTAssertTrue(preview.visibleDockFrame.contains(a))
            }
        }
    }

    private func layout(iconSize: CGFloat, count: Int, width: CGFloat, zoom: CGFloat) -> SettingsPreviewLayout {
        SettingsPreviewLayout(geometry: geometry(iconSize: iconSize, count: count), zoom: zoom,
                              viewportSize: CGSize(width: width, height: 148))
    }

    private func geometry(iconSize: CGFloat, count: Int, edge: DockEdge = .bottom,
                          maximumLength: CGFloat = 2560) -> DockGeometry {
        DockGeometry.make(count: count, edge: edge,
            style: DockGeometryStyle(iconSize: iconSize, barThickness: iconSize + 20,
                                     gap: 8, leadingPadding: 10, trailingPadding: 10),
            maximumLength: maximumLength)
    }
}
