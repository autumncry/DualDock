import XCTest
@testable import DualDockCore

final class DockOpticalSpacingTests: XCTestCase {
    private let symmetric = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    private let mixed = [CGRect(x: 0.06, y: 0.08, width: 0.83, height: 0.85),
                         CGRect(x: 0.04, y: 0.10, width: 0.92, height: 0.73),
                         CGRect(x: 0.20, y: 0.10, width: 0.54, height: 0.80),
                         CGRect(x: 0.10, y: 0.23, width: 0.76, height: 0.67)]
    private func geometry(edge: DockEdge, percent: CGFloat?, bounds: [CGRect],
                          focus: CGFloat? = nil, fixedLength: CGFloat? = nil,
                          divider: Int? = nil, icon: CGFloat = 48) -> DockGeometry {
        .make(count: bounds.count, edge: edge,
              style: .init(iconSize: icon, barThickness: 100, gap: 0,
                           leadingPadding: 6, trailingPadding: 6, magnificationScale: 2,
                           contentBounds: bounds, spacingPercent: percent),
              maximumLength: 1800, fixedLength: fixedLength, focusIndex: focus, dividerIndex: divider)
    }

    func testZeroHalfAndFullSpacingUseVisibleWidthOnEveryEdge() {
        for edge in DockEdge.allCases {
            for percent: CGFloat in [0, 50, 100] {
                let value = geometry(edge: edge, percent: percent, bounds: Array(repeating: symmetric, count: 5))
                for index in 0..<4 {
                    let a = value.canonicalContentFrames[index], b = value.canonicalContentFrames[index + 1]
                    XCTAssertEqual(b.minX - a.maxX, (a.width + b.width) / 2 * percent / 100, accuracy: 0.000001)
                    XCTAssertEqual(a.width, 48 * 0.8, accuracy: 0.000001)
                }
                for frame in value.iconFrames { XCTAssertEqual(frame.size, CGSize(width: 48, height: 48)) }
            }
        }
    }

    func testMissingPercentRetainsLegacyGeometryEvenWhenMetricsExist() {
        for edge in DockEdge.allCases {
            let old = geometry(edge: edge, percent: nil, bounds: Array(repeating: CGRect(x: 0, y: 0, width: 1, height: 1), count: 4))
            let measured = geometry(edge: edge, percent: nil, bounds: mixed)
            XCTAssertEqual(old, measured)
            XCTAssertEqual(old.canonicalContentFrames, old.canonicalIconFrames)
            XCTAssertEqual(old.canonicalHitFrames, old.canonicalTileFrames)
        }
    }

    func testScreenLimitDoesNotSilentlyDiscardVisualSpacingRatio() {
        var preferences = DockCustomSizing.visualDefault
        preferences.spacingPercent = 100
        preferences.iconSize = 48
        let bounds = Array(repeating: symmetric, count: 20)
        let value = DockCustomSizingResolver.resolve(preferences, count: 20, dividerIndex: nil,
            maximumLength: 400, maximumHeight: 160, contentBounds: bounds, edge: .bottom)
        XCTAssertEqual(value.iconSize, 24, accuracy: 0.000001)
        XCTAssertEqual(value.gap, 24 * 0.8, accuracy: 0.000001)
        XCTAssertTrue(value.isScrollable)
    }
    func testAsymmetricArtworkGroupsAndDividerKeepExactGapAndUniqueHitOwnership() {
        for edge in DockEdge.allCases {
            for percent: CGFloat in [0, 50, 100] {
                let value = geometry(edge: edge, percent: percent, bounds: mixed, divider: 2)
                for index in value.canonicalContentFrames.indices {
                    let content = value.canonicalContentFrames[index]
                    let center = CGPoint(x: content.midX, y: content.midY)
                    let owners = value.canonicalHitFrames.indices.filter { value.canonicalHitFrames[$0].contains(center) }
                    XCTAssertEqual(owners, [index])
                    XCTAssertTrue(value.canonicalTileFrames[index].contains(value.canonicalIconFrames[index]))
                    XCTAssertEqual(value.canonicalDotFrames[index].midX, content.midX, accuracy: 0.000001)
                    if index > 0 {
                        let previous = value.canonicalContentFrames[index - 1]
                        let expected = (previous.width + content.width) / 2 * percent / 100 + (index == 2 ? 13 : 0)
                        XCTAssertEqual(content.minX - previous.maxX, expected, accuracy: 0.000001)
                        XCTAssertLessThanOrEqual(value.canonicalHitFrames[index - 1].maxX,
                                                value.canonicalHitFrames[index].minX + 0.000001)
                    }
                }
            }
        }
    }

    func testContinuousMagnificationPreservesOpticalGapsWithoutOverlappingArtwork() {
        let bounds = mixed + mixed
        for edge in DockEdge.allCases {
            for percent: CGFloat in [0, 50, 100] {
                let base = geometry(edge: edge, percent: percent, bounds: bounds)
                var current = base
                for step in 0..<120 {
                    let target = geometry(edge: edge, percent: percent, bounds: bounds,
                        focus: CGFloat(step % 60) / 59 * CGFloat(bounds.count - 1))
                    current = current.interpolated(to: target, fraction: 0.12)
                    XCTAssertEqual(current.backdropRect, base.backdropRect)
                    XCTAssertEqual(current.viewportRect, base.viewportRect)
                    XCTAssertEqual(current.documentSize, base.documentSize)
                    for index in 1..<bounds.count {
                        let a = current.canonicalContentFrames[index - 1], b = current.canonicalContentFrames[index]
                        XCTAssertEqual(b.minX - a.maxX, (a.width + b.width) / 2 * percent / 100, accuracy: 0.000001)
                        XCTAssertLessThanOrEqual(a.maxX, b.minX + 0.000001)
                        XCTAssertLessThanOrEqual(current.canonicalHitFrames[index - 1].maxX,
                                                current.canonicalHitFrames[index].minX + 0.000001)
                    }
                }
            }
        }
    }

    func testWideMagnificationCurveReservesSpaceForGrowingOpticalGaps() {
        for edge in DockEdge.allCases {
            for bounds in [Array(repeating: symmetric, count: 8), Array(repeating: CGRect(x: 0, y: 0, width: 1, height: 1), count: 8), mixed + mixed + mixed + mixed] {
                let style = DockGeometryStyle(iconSize: 48, barThickness: 100, gap: 0,
                    leadingPadding: 6, trailingPadding: 6, magnificationScale: 2.5,
                    magnificationRadius: 4, contentBounds: bounds, spacingPercent: 100)
                let base = DockGeometry.make(count: bounds.count, edge: edge, style: style, maximumLength: 4000)
                for step in 0...(bounds.count - 1) * 4 {
                    let value = DockGeometry.make(count: bounds.count, edge: edge, style: style,
                        maximumLength: 4000, focusIndex: CGFloat(step) / 4)
                    XCTAssertEqual(value.canvasSize, base.canvasSize)
                    let canvas = CGRect(origin: .zero, size: value.canonicalCanvasSize)
                    for rect in value.canonicalContentFrames {
                        XCTAssertTrue(canvas.insetBy(dx: -0.00001, dy: -0.00001).contains(rect),
                                      "Clipped optical artwork at \(edge), focus \(step)/4: \(rect) in \(canvas)")
                    }
                }
            }
        }
    }

    func testVisualResizeUsesTheSameSpanAsResolverAndKeepsSavedPercent() {
        for edge in DockEdge.allCases {
            var p = DockCustomSizing.visualDefault
            p.spacingPercent = 75
            p.shrinkBeforeScroll = false
            let original = DockCustomSizingResolver.resolve(p, count: 4, dividerIndex: 2,
                maximumLength: 1800, maximumHeight: 160, contentBounds: mixed, edge: edge)
            var draft = original.manualSizing
            draft.length += 100
            let resized = p.resized(from: original.manualSizing, to: draft,
                maximumLength: 1800, count: 4, dividerIndex: 2, contentBounds: mixed, edge: edge)
            let result = DockCustomSizingResolver.resolve(resized, count: 4, dividerIndex: 2,
                maximumLength: 1800, maximumHeight: 160, contentBounds: mixed, edge: edge)
            XCTAssertEqual(result.length, draft.length, accuracy: 0.000001)
            XCTAssertEqual(resized.paddingOverride!, original.padding + 50, accuracy: 0.000001)
            XCTAssertEqual(resized.spacingPercent, 75)
            XCTAssertEqual(result.iconSize, original.iconSize)
        }
    }

    func testOldConfigurationAndInvalidArtworkBoundsRemainUsable() throws {
        let legacy = DockCustomSizing()
        let encoded = try JSONEncoder().encode(legacy)
        XCTAssertNil((try JSONSerialization.jsonObject(with: encoded) as? [String: Any])?["spacingPercent"])
        XCTAssertEqual(try JSONDecoder().decode(DockCustomSizing.self, from: encoded), legacy)
        var visual = DockCustomSizing.visualDefault
        visual.spacingPercent = 250
        visual.normalize()
        XCTAssertEqual(visual.spacingPercent, 100)
        XCTAssertEqual(try JSONDecoder().decode(DockCustomSizing.self, from: JSONEncoder().encode(visual)), visual)
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        for invalid in [CGRect.null, CGRect.zero, CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1),
                        CGRect(x: 5, y: 5, width: 1, height: 1)] {
            XCTAssertEqual(DockOpticalSpacingPolicy.normalizedBounds(invalid), unit)
        }
        let clipped = DockOpticalSpacingPolicy.normalizedBounds(CGRect(x: -0.2, y: 0.2, width: 0.8, height: 2))
        XCTAssertEqual(clipped.minX, 0)
        XCTAssertEqual(clipped.maxX, 0.6, accuracy: 0.000001)
        XCTAssertEqual(clipped.maxY, 1)
        let configuration = DockConfiguration()
        XCTAssertEqual(configuration.version, DockConfiguration.currentVersion)
    }

    func testDividerKeepsItsOwnNonAppHitRegionAndThinArtworkFocusIsContinuous() {
        let value = geometry(edge: .bottom, percent: 0, bounds: mixed, divider: 2)
        let divider = value.canonicalDividerFrame!
        let point = CGPoint(x: divider.midX, y: 20)
        XCTAssertFalse(value.canonicalHitFrames.contains(where: { $0.contains(point) }))
        let thin = CGRect(x: 0.49, y: 0.1, width: 0.02, height: 0.8)
        let compact = geometry(edge: .bottom, percent: 0, bounds: [thin, thin], icon: 16)
        let midpoint = (compact.canonicalContentFrames[0].midX + compact.canonicalContentFrames[1].midX) / 2
        XCTAssertEqual(compact.focusIndex(at: midpoint)!, 0.5, accuracy: 0.000001)
    }

    func testExtremeAsymmetricBoundsFitDrawingCanvasesAndKeepContentOrdered() {
        let bounds = [CGRect(x: 0.01, y: 0.1, width: 0.05, height: 0.8),
                      CGRect(x: 0.9, y: 0.1, width: 0.05, height: 0.8),
                      CGRect(x: 0.1, y: 0.9, width: 0.8, height: 0.05),
                      CGRect(x: 0.1, y: 0.01, width: 0.8, height: 0.05)]
        for edge in DockEdge.allCases {
            let value = geometry(edge: edge, percent: 0, bounds: bounds)
            let rowHull = value.canonicalIconFrames.reduce(CGRect.null) { $0.union($1) }
            XCTAssertGreaterThanOrEqual(rowHull.minX, value.canonicalBackdropRect.minX)
            XCTAssertLessThanOrEqual(rowHull.maxX, value.canonicalBackdropRect.maxX)
            for index in 1..<bounds.count {
                XCTAssertEqual(value.canonicalContentFrames[index].minX,
                               value.canonicalContentFrames[index - 1].maxX, accuracy: 0.000001)
            }
        }
    }

}
