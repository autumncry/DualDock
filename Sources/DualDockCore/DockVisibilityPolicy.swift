import Foundation
import CoreGraphics

/// Per-display visibility state. Fullscreen always wins over edge reveal.
public struct DockVisibilityPolicy: Sendable {
    public private(set) var isVisible = true
    private var edgeEnteredAt: TimeInterval?
    private var lastEngagedAt: TimeInterval?

    public init() {}

    @discardableResult
    public mutating func update(now: TimeInterval, fullscreen: Bool, autoHide: Bool,
                                maximized: Bool, pointerAtEdge: Bool,
                                pointerInsideDock: Bool, interacting: Bool) -> Bool {
        if fullscreen {
            isVisible = false
            edgeEnteredAt = nil
            lastEngagedAt = nil
            return false
        }
        guard autoHide && maximized else {
            isVisible = true
            edgeEnteredAt = nil
            lastEngagedAt = nil
            return true
        }
        if interacting || (isVisible && (pointerInsideDock || pointerAtEdge)) {
            isVisible = true
            lastEngagedAt = now
            edgeEnteredAt = nil
            return true
        }
        if isVisible, let lastEngagedAt, now - lastEngagedAt < 0.3 { return true }
        isVisible = false
        if pointerAtEdge {
            if edgeEnteredAt == nil { edgeEnteredAt = now }
            if now - (edgeEnteredAt ?? now) >= 0.12 {
                isVisible = true
                lastEngagedAt = now
                edgeEnteredAt = nil
            }
        } else {
            edgeEnteredAt = nil
        }
        return isVisible
    }

    /// Classifies a workspace-filling rectangle, not overlap with the Dock.
    /// Accept small frame rounding and symmetric native tiling margins. A
    /// full-sized window translated off an edge is still an ordinary window.
    public static func isMaximizedWindow(_ frame: CGRect, in visibleScreen: CGRect) -> Bool {
        guard valid(frame), valid(visibleScreen) else { return false }
        let left = frame.minX - visibleScreen.minX
        let right = visibleScreen.maxX - frame.maxX
        let bottom = frame.minY - visibleScreen.minY
        let top = visibleScreen.maxY - frame.maxY
        let insets = [left, right, bottom, top]
        let alignmentTolerance: CGFloat = 2
        let maximumTilingInset: CGFloat = 16
        guard insets.allSatisfy(\.isFinite) else { return false }
        if insets.allSatisfy({ abs($0) <= alignmentTolerance }) { return true }
        return insets.allSatisfy { $0 >= -alignmentTolerance && $0 <= maximumTilingInset }
            && abs(left - right) <= alignmentTolerance
            && abs(top - bottom) <= alignmentTolerance
    }

    /// Geometric diagnostic utility; auto-hide uses isMaximizedWindow instead.
    public static func isObstructed(_ backdrop: CGRect, by windows: [CGRect]) -> Bool {
        guard valid(backdrop) else { return false }
        return windows.contains { frame in
            guard valid(frame) else { return false }
            let overlap = backdrop.intersection(frame)
            return !overlap.isNull && overlap.width > 1 && overlap.height > 1 && overlap.width * overlap.height > 4
        }
    }

    /// At the top, the activation edge is below the menu bar / camera safe area.
    public static func activationRegion(backdrop: CGRect, edge: DockEdge,
                                        visibleScreen: CGRect) -> CGRect {
        guard valid(backdrop), valid(visibleScreen) else { return .null }
        let depth: CGFloat = 3
        switch edge {
        case .bottom:
            return CGRect(x: backdrop.minX, y: visibleScreen.minY, width: backdrop.width, height: depth)
                .intersection(visibleScreen)
        case .top:
            return CGRect(x: backdrop.minX, y: visibleScreen.maxY - depth, width: backdrop.width, height: depth)
                .intersection(visibleScreen)
        case .left:
            return CGRect(x: visibleScreen.minX, y: backdrop.minY, width: depth, height: backdrop.height)
                .intersection(visibleScreen)
        case .right:
            return CGRect(x: visibleScreen.maxX - depth, y: backdrop.minY, width: depth, height: backdrop.height)
                .intersection(visibleScreen)
        }
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }
}
