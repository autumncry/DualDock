import XCTest
@testable import DualDockCore

final class RunningIndicatorTests: XCTestCase {
    private func layout(edge: DockEdge, height: CGFloat, iconSize: CGFloat = 48,
                        focus: CGFloat? = nil, count: Int = 5) -> DockGeometry {
        .make(count: count, edge: edge,
              style: .init(iconSize: iconSize, barThickness: height, gap: 6,
                           leadingPadding: 6, trailingPadding: 6, magnificationScale: 2),
              maximumLength: 1200, focusIndex: focus)
    }

    func testIndicatorsStayNearIconsWhenBarHeightIncreasesOnEveryEdge() {
        for edge in DockEdge.allCases {
            for height: CGFloat in [66, 90, 120, 160] {
                let value = layout(edge: edge, height: height)
                for (icon, dot) in zip(value.iconFrames, value.dotFrames) {
                    let gap: CGFloat
                    switch edge {
                    case .bottom: gap = icon.minY - dot.maxY
                    case .top: gap = dot.minY - icon.maxY
                    case .left: gap = icon.minX - dot.maxX
                    case .right: gap = dot.minX - icon.maxX
                    }
                    XCTAssertEqual(gap, 3, accuracy: 0.000001, "\(edge), height \(height)")
                    XCTAssertEqual(edge.isHorizontal ? icon.midX : icon.midY,
                                   edge.isHorizontal ? dot.midX : dot.midY, accuracy: 0.000001)
                }
            }
        }
    }

    func testIndicatorStaysAttachedThroughoutMagnificationInterpolation() {
        for edge in DockEdge.allCases {
            let base = layout(edge: edge, height: 160)
            var current = base
            for frame in 0..<120 {
                let target = layout(edge: edge, height: 160, focus: CGFloat(frame % 60) / 59 * 4)
                current = current.interpolated(to: target, fraction: 0.12)
                XCTAssertEqual(current.backdropRect, base.backdropRect)
                for (icon, dot) in zip(current.canonicalIconFrames, current.canonicalDotFrames) {
                    XCTAssertEqual(icon.minY - dot.maxY, 3, accuracy: 0.000001)
                    XCTAssertEqual(icon.midX, dot.midX, accuracy: 0.000001)
                }
            }
        }
    }

    func testCompactIndicatorsStayInsideTileWithoutOverlappingIcons() {
        for edge in DockEdge.allCases {
            for padding: CGFloat in [0, 0.5, 1, 2, 3, 4, 5, 6, 7, 9] {
                let value = layout(edge: edge, height: 48 + padding * 2, focus: 2)
                for index in value.canonicalDotFrames.indices {
                    let dot = value.canonicalDotFrames[index]
                    let icon = value.canonicalIconFrames[index]
                    XCTAssertGreaterThanOrEqual(dot.minY, 0)
                    XCTAssertLessThanOrEqual(dot.maxY, icon.minY)
                    XCTAssertLessThanOrEqual(icon.minY - dot.maxY, 3)
                    XCTAssertTrue(dot.width.isFinite && dot.height.isFinite)
                }
            }
        }
    }
}
