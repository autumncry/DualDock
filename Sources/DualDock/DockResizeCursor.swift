import AppKit
import DualDockCore

/// Returns cursors without changing the global pointer. Custom diagonals keep
/// the same affordance on macOS 14, which lacks newer frame-resize cursor APIs.
@MainActor
enum DockResizeCursor {
    private static let northwestSoutheast = diagonal(descending: true)
    private static let northeastSouthwest = diagonal(descending: false)

    static func cursor(for handle: DockResizeHandle, edge: DockEdge) -> NSCursor {
        switch handle {
        case .inward:
            return edge.isHorizontal ? .resizeUpDown : .resizeLeftRight
        case .leading, .trailing:
            return edge.isHorizontal ? .resizeLeftRight : .resizeUpDown
        case .leadingCorner, .trailingCorner:
            let descending: Bool
            switch (edge, handle) {
            case (.bottom, .leadingCorner), (.top, .trailingCorner),
                 (.left, .trailingCorner), (.right, .leadingCorner): descending = true
            default: descending = false
            }
            return descending ? northwestSoutheast : northeastSouthwest
        }
    }

    private static func diagonal(descending: Bool) -> NSCursor {
        let side: CGFloat = 24
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        let start = NSPoint(x: 5, y: descending ? 19 : 5)
        let end = NSPoint(x: 19, y: descending ? 5 : 19)
        let dx = end.x - start.x, dy = end.y - start.y
        let distance = hypot(dx, dy)
        let direction = NSPoint(x: dx / distance, y: dy / distance)
        let normal = NSPoint(x: -direction.y, y: direction.x)
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        let tips: [(NSPoint, CGFloat)] = [(start, 1), (end, -1)]
        for (tip, sign) in tips {
            let inward = NSPoint(x: tip.x + sign * direction.x * 5, y: tip.y + sign * direction.y * 5)
            path.move(to: NSPoint(x: inward.x + normal.x * 3, y: inward.y + normal.y * 3))
            path.line(to: tip)
            path.line(to: NSPoint(x: inward.x - normal.x * 3, y: inward.y - normal.y * 3))
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.white.setStroke()
        path.lineWidth = 4
        path.stroke()
        NSColor.black.setStroke()
        path.lineWidth = 1.8
        path.stroke()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }
}
