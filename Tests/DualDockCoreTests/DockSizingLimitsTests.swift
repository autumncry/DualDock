import XCTest
@testable import DualDockCore

final class DockSizingLimitsTests: XCTestCase {
    func testUsesSmallestLogicalWidthAndHeightAcrossAllDisplays() throws {
        let limits = try XCTUnwrap(DockSizingLimits(screenSizes: [
            CGSize(width: 1800, height: 1169), CGSize(width: 3008, height: 1692)
        ]))
        XCTAssertEqual(limits.maxWidth, 1800)
        XCTAssertEqual(limits.maxHeight, 140.28, accuracy: 0.000001)
        XCTAssertEqual(limits.minWidth, 240)
        XCTAssertEqual(limits.minHeight, 33)
        let mixed = try XCTUnwrap(DockSizingLimits(screenSizes: [
            CGSize(width: 1200, height: 1920), CGSize(width: 3008, height: 1692)
        ]))
        XCTAssertEqual(mixed.maxWidth, 1200)
        XCTAssertEqual(mixed.maxHeight, 1692 * 0.12, accuracy: 0.000001)
    }

    func testClampingDoesNotChangeRequestedPreferences() throws {
        var requested = DockConfiguration()
        requested.dockWidth = 1600
        requested.iconSize = 120
        requested.normalizeAppearance()
        let small = try XCTUnwrap(DockSizingLimits(screenSizes: [CGSize(width: 800, height: 600)]))
        let large = try XCTUnwrap(DockSizingLimits(screenSizes: [CGSize(width: 3008, height: 1692)]))
        XCTAssertEqual(small.clampWidth(requested.dockWidth!), 800)
        XCTAssertEqual(small.height(forIconSize: requested.iconSize), 72, accuracy: 0.000001)
        XCTAssertEqual(requested.dockWidth, 1600)
        XCTAssertEqual(requested.iconSize, 120)
        XCTAssertEqual(large.clampWidth(requested.dockWidth!), 1600)
        XCTAssertEqual(large.clampIconSize(requested.iconSize), 120)
    }

    func testInvalidScreenListsDoNotProduceSliderRanges() throws {
        XCTAssertNil(DockSizingLimits(screenSizes: []))
        XCTAssertNil(DockSizingLimits(screenSizes: [.zero, CGSize(width: -1, height: 800),
                                                   CGSize(width: CGFloat.nan, height: 800)]))
        let filtered = try XCTUnwrap(DockSizingLimits(screenSizes: [.zero, CGSize(width: 1024, height: 768)]))
        XCTAssertEqual(filtered, .fallback)
        XCTAssertEqual(DockSizingLimits.fallback.maxWidth, 1024)
    }

    func testExtremeRequestedSizesAreClampedBeforeScaling() throws {
        let limits = try XCTUnwrap(DockSizingLimits(screenSizes: [CGSize(width: 1800, height: 1169)]))
        XCTAssertEqual(limits.clampWidth(.greatestFiniteMagnitude), limits.maxWidth)
        XCTAssertEqual(limits.height(forIconSize: .greatestFiniteMagnitude), limits.maxHeight, accuracy: 0.000001)
        for value in [Double.nan, .infinity, -.infinity, -100, .greatestFiniteMagnitude] {
            XCTAssertTrue(limits.clampWidth(value).isFinite)
            XCTAssertTrue(limits.clampIconSize(value).isFinite)
            XCTAssertLessThanOrEqual(limits.height(forIconSize: value), limits.maxHeight)
        }
        let tiny = try XCTUnwrap(DockSizingLimits(screenSizes: [CGSize(width: 100, height: 100)]))
        XCTAssertEqual(tiny.minWidth, tiny.maxWidth)
        XCTAssertEqual(tiny.minHeight, tiny.maxHeight)
    }

    func testMinimumWidthIsIndependentOfCurrentlySelectedHeight() throws {
        let limits = try XCTUnwrap(DockSizingLimits(screenSizes: [CGSize(width: 4000, height: 4000)]))
        let width = limits.clampWidth(1)
        for size in [24.0, 96, 200, Double.greatestFiniteMagnitude] {
            _ = limits.clampIconSize(size)
            XCTAssertEqual(limits.clampWidth(1), width)
        }
        let largestIcon = limits.clampIconSize(.greatestFiniteMagnitude)
        XCTAssertGreaterThanOrEqual(width, largestIcon * (1 + 20.0 / 48.0))
    }
}
