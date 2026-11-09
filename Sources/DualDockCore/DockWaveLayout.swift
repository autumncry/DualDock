import Foundation

/// Geometry in logical points. Screen width clips the viewport, never the icon size.
public struct DockWaveLayout: Equatable, Sendable {
    public var tileFrames: [CGRect]
    public var contentSize: CGSize
    public var viewportSize: CGSize
    public var panelSize: CGSize
    public var horizontalInset: CGFloat
    public var controlsWidth: CGFloat
    public var dividerX: CGFloat?

    public static func make(count: Int, iconSize: CGFloat, spacing: CGFloat,
                            magnificationScale: CGFloat, focusIndex: CGFloat?,
                            maxWidth: CGFloat, hasControls: Bool,
                            dividerIndex: Int? = nil) -> DockWaveLayout {
        let side = max(1, iconSize)
        let unit = side / 48
        let gap = max(0, spacing) * unit
        let inset = 10 * unit
        let controls = hasControls ? 62 * unit : 0
        let peak = max(1, magnificationScale)
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var highest = side
        var divider: CGFloat?
        for index in 0..<max(0, count) {
            if index == dividerIndex && index > 0 {
                divider = x + 6 * unit
                x += 13 * unit
            }
            let distance = focusIndex.map { abs(CGFloat(index) - $0) } ?? 2.5
            let weight = distance >= 2.5 ? 0 : 0.5 * (1 + cos(.pi * distance / 2.5))
            let size = side * (1 + (peak - 1) * weight)
            frames.append(CGRect(x: x, y: 0, width: size + gap, height: size + 16 * unit))
            highest = max(highest, size)
            x += size + gap
        }
        if count == 0 { x = 160 * unit }
        let height = highest + 18 * unit
        let panelWidth = min(max(1, maxWidth), x + controls + 2 * inset)
        let viewportWidth = max(1, panelWidth - controls - 2 * inset)
        return DockWaveLayout(tileFrames: frames,
                              contentSize: CGSize(width: max(x, viewportWidth), height: height),
                              viewportSize: CGSize(width: viewportWidth, height: height),
                              panelSize: CGSize(width: panelWidth, height: height),
                              horizontalInset: inset, controlsWidth: controls, dividerX: divider)
    }

    public func position(for index: CGFloat) -> CGFloat? {
        guard !tileFrames.isEmpty else { return nil }
        let bounded = min(max(index, -0.5), CGFloat(tileFrames.count) - 0.5)
        let tileIndex = min(max(Int(floor(bounded + 0.5)), 0), tileFrames.count - 1)
        let fraction = bounded - CGFloat(tileIndex) + 0.5
        return tileFrames[tileIndex].minX + fraction * tileFrames[tileIndex].width
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
                              controlsWidth: mix(controlsWidth, target.controlsWidth), dividerX: divider)
    }

    public func maximumDifference(from other: DockWaveLayout) -> CGFloat {
        guard tileFrames.count == other.tileFrames.count else { return .greatestFiniteMagnitude }
        var difference = max(abs(panelSize.width - other.panelSize.width), abs(panelSize.height - other.panelSize.height))
        for (a, b) in zip(tileFrames, other.tileFrames) {
            difference = max(difference, abs(a.minX - b.minX), abs(a.width - b.width), abs(a.height - b.height))
        }
        return difference
    }

    public static func nextPanelOrigin(current: CGFloat, target: CGFloat, fraction: CGFloat) -> CGFloat {
        guard current.isFinite, target.isFinite, fraction > 0 else { return current }
        let destination = target.rounded(.down)
        let distance = destination - current
        // NSPanel rounds origins down to whole points. A sub-point positive
        // step would otherwise never move the window or finish its display link.
        let step = min(abs(distance), max(1, abs(distance) * min(1, fraction)))
        return current + (distance < 0 ? -step : step)
    }
}
