import Foundation
import CoreGraphics

/// Logical-point geometry with a fixed horizontal envelope for a configured Dock.
public struct DockWaveLayout: Equatable, Sendable {
    public var tileFrames: [CGRect]
    public var contentSize: CGSize
    public var viewportSize: CGSize
    public var panelSize: CGSize
    public var horizontalInset: CGFloat
    public var controlsWidth: CGFloat
    public var dividerX: CGFloat?
    public var initialScrollOffset: CGFloat

    public static func make(count: Int, iconSize: CGFloat, spacing: CGFloat,
                            magnificationScale: CGFloat, focusIndex: CGFloat?,
                            maxWidth: CGFloat, hasControls: Bool,
                            dividerIndex: Int? = nil,
                            scrollOffset: CGFloat? = nil) -> DockWaveLayout {
        let itemCount = max(0, count)
        let side = max(1, iconSize)
        let unit = side / 48
        let gap = max(0, spacing) * unit
        let inset = 10 * unit
        let controls = hasControls ? 62 * unit : 0
        let availableWidth = max(1, maxWidth - controls - 2 * inset)
        // Only physically narrower viewports limit the peak; base sizes stay shared.
        let peakSide = min(side * max(1, magnificationScale), max(side, availableWidth))
        let delta = peakSide - side
        let reserveFactor: CGFloat = itemCount == 1 ? 0.5 : (itemCount == 2 ? 1.25 : 1.5)
        let reserve = itemCount == 0 ? 0 : ceil(delta * reserveFactor)
        let dividerWidth: CGFloat = dividerIndex.map { $0 > 0 && $0 < itemCount ? 13 * unit : 0 } ?? 0
        let baseWidth = itemCount == 0 ? 160 * unit : CGFloat(itemCount) * (side + gap) + dividerWidth
        let panelWidth = min(max(1, maxWidth), baseWidth + reserve * 2 + controls + 2 * inset)
        let viewportWidth = max(1, panelWidth - controls - 2 * inset)
        // Reserve belongs to the visible panel, not to scrollable empty space.
        // A scroll range exists only when the base application row itself overflows.
        let contentWidth = max(baseWidth, viewportWidth)
        let leadingSpace = (contentWidth - baseWidth) / 2
        let initialOffset: CGFloat = 0
        let visibleOffset = min(max(0, scrollOffset ?? initialOffset), max(0, contentWidth - viewportWidth))
        let focus = focusIndex.map { min(max(0, $0), CGFloat(max(0, itemCount - 1))) }

        var baseFrames: [CGRect] = []
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var baseX: CGFloat = leadingSpace
        var highest = side
        var divider: CGFloat?
        for index in 0..<itemCount {
            if index == dividerIndex && index > 0 {
                divider = x + 6 * unit
                x += 13 * unit
                baseX += 13 * unit
            }
            let distance = focus.map { abs(CGFloat(index) - $0) } ?? 2.5
            let weight = distance >= 2.5 ? 0 : 0.5 * (1 + cos(.pi * distance / 2.5))
            let size = side + delta * weight
            baseFrames.append(CGRect(x: baseX, y: 0, width: side + gap, height: side + 16 * unit))
            frames.append(CGRect(x: x, y: 0, width: size + gap, height: size + 16 * unit))
            highest = max(highest, size)
            x += size + gap
            baseX += side + gap
        }
        var shift = leadingSpace
        if let focus, let baseAnchor = position(focus, in: baseFrames), let waveAnchor = position(focus, in: frames) {
            shift = baseAnchor - waveAnchor
            let activeIndex = min(itemCount - 1, max(0, Int(focus.rounded())))
            let active = frames[activeIndex]
            let iconLeft = active.minX + gap / 2 + shift
            let iconRight = active.maxX - gap / 2 + shift
            // Edge protection moves icons inside the existing viewport, never the Dock or its scroll offset.
            if iconLeft < visibleOffset { shift += visibleOffset - iconLeft }
            else if iconRight > visibleOffset + viewportWidth { shift -= iconRight - visibleOffset - viewportWidth }
        }
        frames = frames.map { $0.offsetBy(dx: shift, dy: 0) }
        if let value = divider { divider = value + shift }
        let height = highest + 18 * unit
        return DockWaveLayout(tileFrames: frames,
                              contentSize: CGSize(width: contentWidth, height: height),
                              viewportSize: CGSize(width: viewportWidth, height: height),
                              panelSize: CGSize(width: panelWidth, height: height),
                              horizontalInset: inset, controlsWidth: controls,
                              dividerX: divider, initialScrollOffset: initialOffset)
    }

    public func position(for index: CGFloat) -> CGFloat? { Self.position(index, in: tileFrames) }

    /// Pointer-to-lens mapping belongs to the fixed base layout, not moving frames.
    public func focusIndex(at x: CGFloat) -> CGFloat? {
        guard let first = tileFrames.first, let last = tileFrames.last else { return nil }
        if x <= first.midX { return 0 }
        if x >= last.midX { return CGFloat(tileFrames.count - 1) }
        for index in 0..<(tileFrames.count - 1) {
            let left = tileFrames[index].midX
            let right = tileFrames[index + 1].midX
            if x >= left && x <= right {
                return CGFloat(index) + (x - left) / max(1, right - left)
            }
        }
        return nil
    }

    private static func position(_ index: CGFloat, in frames: [CGRect]) -> CGFloat? {
        guard !frames.isEmpty else { return nil }
        let bounded = min(max(index, 0), CGFloat(frames.count - 1))
        let lower = Int(floor(bounded))
        let upper = min(lower + 1, frames.count - 1)
        let fraction = bounded - CGFloat(lower)
        return frames[lower].midX + (frames[upper].midX - frames[lower].midX) * fraction
    }

    public func interpolated(to target: DockWaveLayout, fraction: CGFloat) -> DockWaveLayout {
        guard tileFrames.count == target.tileFrames.count else { return target }
        let t = min(1, max(0, fraction))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        func size(_ a: CGSize, _ b: CGSize) -> CGSize { CGSize(width: mix(a.width, b.width), height: mix(a.height, b.height)) }
        let frames = zip(tileFrames, target.tileFrames).map { a, b in
            CGRect(x: mix(a.minX, b.minX), y: mix(a.minY, b.minY),
                   width: mix(a.width, b.width), height: mix(a.height, b.height))
        }
        let divider: CGFloat?
        if let a = dividerX, let b = target.dividerX { divider = mix(a, b) } else { divider = target.dividerX }
        return DockWaveLayout(tileFrames: frames, contentSize: size(contentSize, target.contentSize),
                              viewportSize: size(viewportSize, target.viewportSize), panelSize: size(panelSize, target.panelSize),
                              horizontalInset: mix(horizontalInset, target.horizontalInset),
                              controlsWidth: mix(controlsWidth, target.controlsWidth), dividerX: divider,
                              initialScrollOffset: initialScrollOffset)
    }

    public func maximumDifference(from other: DockWaveLayout) -> CGFloat {
        guard tileFrames.count == other.tileFrames.count else { return .greatestFiniteMagnitude }
        var difference = max(abs(panelSize.width - other.panelSize.width), abs(panelSize.height - other.panelSize.height))
        for (a, b) in zip(tileFrames, other.tileFrames) {
            difference = max(difference, abs(a.minX - b.minX), abs(a.width - b.width), abs(a.height - b.height))
        }
        return difference
    }
}
