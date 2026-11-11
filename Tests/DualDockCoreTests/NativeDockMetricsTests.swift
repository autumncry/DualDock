import XCTest
@testable import DualDockCore

final class NativeDockMetricsTests: XCTestCase {
    private let preferences = NativeDockPreferences(iconSize: 40, magnifiedIconSize: 89,
                                                     magnificationEnabled: true, axis: .vertical)

    private func verticalSnapshot(side: CGFloat = 28.62155, extra: CGFloat = 12,
                                  leading: CGFloat = 5.62155, trailing: CGFloat = 6.62155,
                                  gap: CGFloat = 0, complete: Bool = true) -> NativeDockAXSnapshot {
        var items: [NativeDockAXItem] = []
        var y: CGFloat = 100 + leading
        for _ in 0..<5 {
            items.append(.init(kind: .application, frame: CGRect(x: -45, y: y, width: side + extra, height: side)))
            y += side + gap
        }
        y -= gap
        let separator: CGFloat = 12.8797
        items.append(.init(kind: .separator, frame: CGRect(x: -45, y: y, width: side + extra, height: separator)))
        y += separator
        items.append(.init(kind: .other, frame: CGRect(x: -45, y: y, width: side + extra, height: side)))
        y += side
        return .init(frame: CGRect(x: -41, y: 100, width: ceil(side + extra), height: y + trailing - 100),
                     items: items, isComplete: complete)
    }

    func testObservedHiddenNativeDockUsesRenderedSizeRatherThanPreference() throws {
        let metrics = try XCTUnwrap(NativeDockMetricsParser.measured(preferences: preferences, snapshot: verticalSnapshot()))
        XCTAssertEqual(metrics.iconSize, 28.625)
        XCTAssertEqual(metrics.barThickness, 41)
        XCTAssertEqual(metrics.leadingPadding, 6.125)
        XCTAssertEqual(metrics.trailingPadding, 6.125)
        XCTAssertEqual(metrics.itemSpacing, 0)
        XCTAssertEqual(metrics.separatorLength, 12.875)
        XCTAssertEqual(metrics.magnifiedIconSize, 89)
        XCTAssertGreaterThan(metrics.magnificationScale, 2.5)
    }

    func testHorizontalAndVerticalSnapshotsHaveEquivalentMetrics() throws {
        let vertical = verticalSnapshot()
        func rotated(_ rect: CGRect) -> CGRect { CGRect(x: rect.minY, y: rect.minX, width: rect.height, height: rect.width) }
        let horizontal = NativeDockAXSnapshot(frame: rotated(vertical.frame),
            items: vertical.items.map { .init(kind: $0.kind, frame: rotated($0.frame)) })
        let horizontalPreferences = NativeDockPreferences(iconSize: 40, magnifiedIconSize: 89,
                                                          magnificationEnabled: true, axis: .horizontal)
        XCTAssertEqual(NativeDockMetricsParser.measured(preferences: preferences, snapshot: vertical),
                       NativeDockMetricsParser.measured(preferences: horizontalPreferences, snapshot: horizontal))
    }

    func testMagnifiedNeighboursAndWideHitAreasDoNotInflateBaseThickness() throws {
        let base = verticalSnapshot()
        var items = base.items
        // During native magnification the cross-axis hit area may widen for
        // every icon. Only plausible cross-minus-length measurements are used.
        items[0] = .init(kind: .application, frame: CGRect(x: -101, y: 0, width: 101, height: 89))
        items[1] = .init(kind: .application, frame: CGRect(x: -101, y: 89, width: 101, height: 65))
        items[2] = .init(kind: .application, frame: CGRect(x: -101, y: 154, width: 101, height: 28.62155))
        let metrics = try XCTUnwrap(NativeDockMetricsParser.measured(preferences: preferences,
            snapshot: .init(frame: CGRect(x: -101, y: 0, width: 101, height: 350), items: items)))
        XCTAssertEqual(metrics.iconSize, 28.625)
        XCTAssertEqual(metrics.barThickness, 41)
    }

    func testAllMagnifiedItemsAreCappedByKnownNativePreference() throws {
        let metrics = try XCTUnwrap(NativeDockMetricsParser.measured(preferences: preferences,
            snapshot: verticalSnapshot(side: 70)))
        XCTAssertEqual(metrics.iconSize, 40)
        XCTAssertEqual(metrics.barThickness, 52)
    }

    func testSingleSmallInsertionItemDoesNotShrinkTheWholeDock() throws {
        let snapshot = verticalSnapshot()
        var items = snapshot.items
        items[2] = .init(kind: .application, frame: CGRect(x: -45, y: items[2].frame.minY, width: 28, height: 16))
        let metrics = try XCTUnwrap(NativeDockMetricsParser.measured(preferences: preferences,
            snapshot: .init(frame: snapshot.frame, items: items)))
        XCTAssertEqual(metrics.iconSize, 28.625)
        XCTAssertEqual(metrics.barThickness, 41)
    }

    func testMixedMagnificationWithoutAMajorityKeepsTheLowerBase() throws {
        let lengths: [CGFloat] = [28.62155, 45, 45, 89, 89]
        var y: CGFloat = 6
        let items = lengths.map { side -> NativeDockAXItem in
            defer { y += side }
            return .init(kind: .application, frame: CGRect(x: 0, y: y, width: side + 12, height: side))
        }
        let metrics = try XCTUnwrap(NativeDockMetricsParser.measured(preferences: preferences,
            snapshot: .init(frame: CGRect(x: 0, y: 0, width: 101, height: y + 6), items: items)))
        XCTAssertEqual(metrics.iconSize, 28.625)
        XCTAssertEqual(metrics.barThickness, 41)
    }

    func testIncompleteOrUnbalancedAXBoundsDoNotInventLargeEndWhitespace() throws {
        for snapshot in [verticalSnapshot(leading: 80, trailing: 90),
                         verticalSnapshot(leading: 1, trailing: 15),
                         verticalSnapshot(leading: 10, trailing: 10, complete: false)] {
            let metrics = try XCTUnwrap(NativeDockMetricsParser.measured(preferences: preferences, snapshot: snapshot))
            XCTAssertEqual(metrics.leadingPadding, 6)
            XCTAssertEqual(metrics.trailingPadding, 6)
        }
    }

    func testMeasuredGapAndSmallFloatNoiseAreStable() throws {
        let a = try XCTUnwrap(NativeDockMetricsParser.measured(preferences: preferences,
            snapshot: verticalSnapshot(side: 28.62152, gap: 2)))
        let b = try XCTUnwrap(NativeDockMetricsParser.measured(preferences: preferences,
            snapshot: verticalSnapshot(side: 28.62158, gap: 2.00003)))
        XCTAssertEqual(a.itemSpacing, 2)
        XCTAssertEqual(a, b)
    }

    func testInvalidSnapshotFallsBackInsteadOfProducingNaNGeometry() {
        XCTAssertNil(NativeDockMetricsParser.measured(preferences: preferences, snapshot: .init(frame: .zero, items: [])))
        let bad = NativeDockAXItem(kind: .application, frame: CGRect(x: 0, y: 0, width: 20, height: CGFloat.nan))
        XCTAssertNil(NativeDockMetricsParser.measured(preferences: preferences,
            snapshot: .init(frame: CGRect(x: 0, y: 0, width: 40, height: 100), items: [bad])))
        let validButNoApps = NativeDockAXItem(kind: .other, frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        XCTAssertNil(NativeDockMetricsParser.measured(preferences: preferences,
            snapshot: .init(frame: CGRect(x: 0, y: 0, width: 40, height: 100), items: [validButNoApps])))
    }

    func testPreferenceFallbackHasCompactPaddingAndBoundedValues() {
        let prefs = NativeDockPreferences(iconSize: 1000, magnifiedIconSize: -5, magnificationEnabled: true, axis: nil)
        XCTAssertEqual(prefs.iconSize, 128)
        XCTAssertEqual(prefs.magnifiedIconSize, 16)
        let fallback = prefs.fallbackMetrics
        XCTAssertEqual(fallback.barThickness, 140)
        XCTAssertEqual(fallback.leadingPadding + fallback.trailingPadding, 12)
        XCTAssertEqual(fallback.magnificationScale, 1)
        XCTAssertNil(NativeDockPreferences(iconSize: .nan, magnifiedIconSize: .infinity,
                                           magnificationEnabled: nil, axis: nil).iconSize)
    }

    func testMagnificationCanBeDisabledWithoutLosingNativePeak() {
        let metrics = NativeDockMetrics(iconSize: 28, barThickness: 40, leadingPadding: 6,
            trailingPadding: 6, itemSpacing: 0, separatorLength: 12,
            magnifiedIconSize: 89, magnificationEnabled: true)
        let disabled = metrics.applyingMagnification(.init(iconSize: nil, magnifiedIconSize: nil,
                                                          magnificationEnabled: false, axis: nil))
        XCTAssertEqual(disabled.iconSize, metrics.iconSize)
        XCTAssertEqual(disabled.magnifiedIconSize, 89)
        XCTAssertEqual(disabled.magnificationScale, 1)
    }
}
