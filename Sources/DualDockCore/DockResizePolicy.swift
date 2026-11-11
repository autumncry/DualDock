import Foundation
import CoreGraphics

public struct DockResizeBounds: Equatable, Sendable {
    public let minLength: Double
    public let maxLength: Double
    public let minThickness: Double
    public let maxThickness: Double

    public init(minLength: Double, maxLength: Double, minThickness: Double, maxThickness: Double) {
        self.maxLength = maxLength.isFinite ? max(1, maxLength) : 1000
        self.maxThickness = maxThickness.isFinite ? max(1, maxThickness) : 100
        self.minLength = min(self.maxLength, minLength.isFinite ? max(1, minLength) : 1)
        self.minThickness = min(self.maxThickness, minThickness.isFinite ? max(1, minThickness) : 1)
    }

    public func clamp(_ sizing: DockManualSizing) -> DockManualSizing {
        var result = sizing
        result.normalize()
        result.length = min(maxLength, max(minLength, result.length))
        result.thickness = min(maxThickness, max(minThickness, result.thickness))
        return result
    }
}

public enum DockResizeHandle: String, CaseIterable, Sendable {
    case inward, leading, trailing, leadingCorner, trailingCorner
}

public enum DockResizePolicy {
    public static func handle(at point: CGPoint, backdrop: CGRect, edge: DockEdge,
                              edgeBand: CGFloat = 6, cornerBand: CGFloat = 10) -> DockResizeHandle? {
        guard backdrop.width > 0, backdrop.height > 0 else { return nil }
        let transform = DockAxisTransform(edge: edge,
            length: edge.isHorizontal ? backdrop.width : backdrop.height,
            thickness: edge.isHorizontal ? backdrop.height : backdrop.width)
        let p = transform.pointToCanonical(CGPoint(x: point.x - backdrop.minX, y: point.y - backdrop.minY))
        let length = transform.length, thickness = transform.thickness
        let edgeRadius = max(1, edgeBand) / 2
        let cornerRadius = max(edgeRadius, cornerBand / 2)
        if abs(p.y - thickness) <= cornerRadius {
            if abs(p.x) <= cornerRadius { return .leadingCorner }
            if abs(p.x - length) <= cornerRadius { return .trailingCorner }
        }
        guard p.y >= -edgeRadius, p.y <= thickness + edgeRadius else { return nil }
        if abs(p.x) <= edgeRadius { return .leading }
        if abs(p.x - length) <= edgeRadius { return .trailing }
        if p.x >= 0, p.x <= length, abs(p.y - thickness) <= edgeRadius { return .inward }
        return nil
    }

    public static func propose(start: DockManualSizing, handle: DockResizeHandle, edge: DockEdge,
                               screenDelta: CGSize, bounds: DockResizeBounds) -> DockManualSizing {
        var result = start
        result.normalize()
        guard screenDelta.width.isFinite, screenDelta.height.isFinite else { return result }
        let visible = bounds.clamp(result)
        let transform = DockAxisTransform(edge: edge, length: CGFloat(visible.length), thickness: CGFloat(visible.thickness))
        let delta = transform.vectorToCanonical(CGVector(dx: screenDelta.width, dy: screenDelta.height))
        switch handle {
        case .inward:
            result.thickness = min(bounds.maxThickness, max(bounds.minThickness, visible.thickness + Double(delta.dy)))
        case .leading, .trailing:
            let sign: Double = handle == .leading ? -1 : 1
            result.length = min(bounds.maxLength, max(bounds.minLength, visible.length + sign * 2 * Double(delta.dx)))
        case .leadingCorner, .trailingCorner:
            let sign: Double = handle == .leadingCorner ? -1 : 1
            // Project in normalized dimension space so both drag directions
            // contribute continuously, with one common scale for both axes.
            let rawScale = 1 + (sign * 2 * Double(delta.dx) / visible.length
                + Double(delta.dy) / visible.thickness) / 2
            let minimum = max(bounds.minLength / visible.length, bounds.minThickness / visible.thickness)
            let maximum = min(bounds.maxLength / visible.length, bounds.maxThickness / visible.thickness)
            let scale = min(maximum, max(minimum, rawScale))
            result.length = visible.length * scale
            result.thickness = visible.thickness * scale
        }
        return result
    }
}
