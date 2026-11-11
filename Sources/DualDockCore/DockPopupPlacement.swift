import Foundation
import CoreGraphics

public enum DockPopupPlacement {
    /// The caller lays out its content inside the returned, screen-bounded frame.
    public static func frame(size: CGSize, anchor: CGRect, edge: DockEdge,
                             visibleScreen: CGRect, gap: CGFloat = 10, margin: CGFloat = 12) -> CGRect {
        let inset = min(max(0, margin), max(0, min(visibleScreen.width, visibleScreen.height) / 2 - 1))
        let usable = visibleScreen.insetBy(dx: inset, dy: inset)
        let width = min(max(1, size.width), max(1, usable.width))
        let height = min(max(1, size.height), max(1, usable.height))
        let origin: CGPoint
        switch edge {
        case .bottom: origin = CGPoint(x: anchor.midX - width / 2, y: anchor.maxY + gap)
        case .top: origin = CGPoint(x: anchor.midX - width / 2, y: anchor.minY - gap - height)
        case .left: origin = CGPoint(x: anchor.maxX + gap, y: anchor.midY - height / 2)
        case .right: origin = CGPoint(x: anchor.minX - gap - width, y: anchor.midY - height / 2)
        }
        return CGRect(x: min(max(origin.x, usable.minX), usable.maxX - width),
                      y: min(max(origin.y, usable.minY), usable.maxY - height), width: width, height: height)
    }

    /// Only the short inward gap is protected, not unrelated main-row icons.
    public static func bridge(source: CGRect, popup: CGRect, edge: DockEdge) -> CGRect? {
        let left = min(source.minX, popup.minX), right = max(source.maxX, popup.maxX)
        let bottom = min(source.minY, popup.minY), top = max(source.maxY, popup.maxY)
        switch edge {
        case .bottom:
            guard popup.minY > source.maxY else { return nil }
            return CGRect(x: left, y: source.maxY, width: right - left, height: popup.minY - source.maxY)
        case .top:
            guard popup.maxY < source.minY else { return nil }
            return CGRect(x: left, y: popup.maxY, width: right - left, height: source.minY - popup.maxY)
        case .left:
            guard popup.minX > source.maxX else { return nil }
            return CGRect(x: source.maxX, y: bottom, width: popup.minX - source.maxX, height: top - bottom)
        case .right:
            guard popup.maxX < source.minX else { return nil }
            return CGRect(x: popup.maxX, y: bottom, width: source.minX - popup.maxX, height: top - bottom)
        }
    }
}
