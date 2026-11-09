import Foundation
import CoreGraphics

/// Shared logical-point limits, computed from every connected logical display.
public struct DockSizingLimits: Equatable, Sendable {
    public static let heightPerIconPoint: Double = 66.0 / 48.0
    public static let fallback = DockSizingLimits(maxWidth: 1024, maxHeight: 768 * 0.12)

    public let minWidth: Double
    public let maxWidth: Double
    public let minHeight: Double
    public let maxHeight: Double

    public init?(screenSizes: [CGSize]) {
        let valid = screenSizes.filter {
            $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0
        }
        guard let width = valid.map(\.width).min(), let height = valid.map(\.height).min() else { return nil }
        self.init(maxWidth: Double(width), maxHeight: Double(height) * 0.12)
    }

    private init(maxWidth: Double, maxHeight: Double) {
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        minHeight = min(33, maxHeight)
        // This minimum depends on the maximum allowed height, never the user's
        // current height, so adjusting height cannot push the width slider.
        let largestIcon = maxHeight / Self.heightPerIconPoint
        minWidth = min(maxWidth, max(240, largestIcon * (1 + 20.0 / 48.0)))
    }

    public func clampWidth(_ desired: Double) -> Double {
        guard desired.isFinite else { return minWidth }
        return min(maxWidth, max(minWidth, desired))
    }

    public func clampIconSize(_ desired: Double) -> Double {
        let value = desired.isFinite ? desired : 48
        return min(maxHeight / Self.heightPerIconPoint, max(minHeight / Self.heightPerIconPoint, value))
    }

    /// Clamp before multiplying, even if a stored preference is extremely large.
    public func height(forIconSize desired: Double) -> Double {
        min(maxHeight, max(minHeight, clampIconSize(desired) * Self.heightPerIconPoint))
    }
}
