import Foundation
import CoreGraphics

/// Projects the real Dock into a fixed-zoom, scrollable settings viewport.
/// The viewport can crop the drawing, but never changes its scale.
public struct SettingsPreviewLayout: Equatable, Sendable {
    public let scale: CGFloat
    public let canvasFrame: CGRect
    public let backdropFrame: CGRect
    public let visibleDockFrame: CGRect
    public let iconFrames: [CGRect]
    public let dividerFrame: CGRect?
    /// x follows the ordered row; y moves across its thickness, for every edge.
    public let scrollOffset: CGPoint
    public let maximumScrollOffset: CGPoint

    public init(geometry g: DockGeometry, zoom: CGFloat, viewportSize: CGSize,
                scrollOffset requestedOffset: CGPoint = .zero) {
        let scale = zoom.isFinite && zoom > 0 ? zoom : 0.75
        self.scale = scale
        let inset: CGFloat = 14
        let width = max(1, viewportSize.width), height = max(1, viewportSize.height)
        let canvas = CGSize(width: g.canvasSize.width * scale, height: g.canvasSize.height * scale)
        let horizontal = g.edge.isHorizontal
        let length = horizontal ? canvas.width : canvas.height
        let depth = horizontal ? canvas.height : canvas.width
        let availableLength = horizontal ? width : height
        let availableDepth = horizontal ? height : width
        let outerRange = max(0, length + 2 * inset - availableLength)
        let crossRange = max(0, depth + 2 * inset - availableDepth)
        maximumScrollOffset = CGPoint(x: outerRange + g.scrollRange * scale, y: crossRange)
        func bounded(_ value: CGFloat, maximum: CGFloat) -> CGFloat {
            min(maximum, max(0, value.isFinite ? value : 0))
        }
        let offset = CGPoint(x: bounded(requestedOffset.x, maximum: maximumScrollOffset.x),
                             y: bounded(requestedOffset.y, maximum: crossRange))
        scrollOffset = offset
        let axisOrigin = outerRange > 0 ? inset - min(offset.x, outerRange) : (availableLength - length) / 2
        let crossOrigin: CGFloat
        if crossRange > 0 {
            crossOrigin = inset - offset.y
        } else {
            crossOrigin = g.edge == .bottom || g.edge == .right ? availableDepth - depth - inset : inset
        }
        let origin = horizontal ? CGPoint(x: axisOrigin, y: crossOrigin) : CGPoint(x: crossOrigin, y: axisOrigin)
        canvasFrame = CGRect(origin: origin, size: canvas)
        func project(_ rect: CGRect) -> CGRect {
            CGRect(x: origin.x + rect.minX * scale,
                   y: origin.y + (g.canvasSize.height - rect.maxY) * scale,
                   width: rect.width * scale, height: rect.height * scale)
        }
        backdropFrame = project(g.backdropRect)
        visibleDockFrame = project(g.viewportRect).intersection(CGRect(x: 0, y: 0, width: width, height: height))
        // First pan across a Dock larger than the preview. At its far end,
        // continue through any content clipped by the physical screen limit.
        let documentOffset = max(0, offset.x - outerRange) / scale
        let scroll = g.scrollOrigin(forCanonicalOffset: documentOffset)
        func documentFrame(_ rect: CGRect) -> CGRect {
            project(rect.offsetBy(dx: g.viewportRect.minX - scroll.x, dy: g.viewportRect.minY - scroll.y))
        }
        iconFrames = g.iconFrames.map(documentFrame)
        dividerFrame = g.dividerFrame.map(documentFrame)
    }
}
