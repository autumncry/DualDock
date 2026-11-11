import Foundation
import CoreGraphics

/// A compact bell curve: the peak and influence radius can vary independently.
/// Zero slope at both ends avoids a discontinuity when a neighbor joins/leaves.
public struct DockMagnificationCurve: Equatable, Sendable {
    public let radius: CGFloat

    public init(radius: CGFloat = 2.5) {
        self.radius = radius.isFinite ? min(4, max(1, radius)) : 2.5
    }

    public func weight(atDistance distance: CGFloat) -> CGFloat {
        guard distance.isFinite else { return 0 }
        let distance = abs(distance)
        return distance >= radius ? 0 : (1 + cos(.pi * distance / radius)) / 2
    }

    public func scale(atDistance distance: CGFloat, peak: CGFloat) -> CGFloat {
        let peak = peak.isFinite ? max(1, peak) : 1
        return 1 + (peak - 1) * weight(atDistance: distance)
    }

    /// Transparent canvas only; changing the curve never enlarges the backdrop.
    public func reserveFactor(itemCount: Int) -> CGFloat {
        if itemCount <= 0 { return 0 }
        if itemCount == 1 { return 0.5 }
        if itemCount == 2 { return max(1.25, 0.5 + weight(atDistance: 1)) }
        return max(1.5, radius / 2 + 0.25)
    }
}
