import AppKit

/// The App icon's overlapping screens and Dock tiles, simplified for the menu bar.
enum StatusItemIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            drawScreen(NSRect(x: 5.25, y: 6, width: 13, height: 10), alpha: 0.6)
            drawScreen(NSRect(x: 1.25, y: 1.75, width: 14.5, height: 10.5), alpha: 1)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "DualDock"
        return image
    }

    private static func drawScreen(_ rect: NSRect, alpha: CGFloat) {
        NSColor.black.withAlphaComponent(alpha).setStroke()
        let outline = NSBezierPath(roundedRect: rect, xRadius: 1.7, yRadius: 1.7)
        outline.lineWidth = 1.25
        outline.stroke()

        NSColor.black.withAlphaComponent(alpha).setFill()
        let tileSize: CGFloat = 1.4
        let step: CGFloat = 1.75
        let start = rect.midX - (3 * step + tileSize) / 2
        for index in 0..<4 {
            NSBezierPath(roundedRect: NSRect(x: start + CGFloat(index) * step,
                                            y: rect.minY + 1.8, width: tileSize, height: tileSize),
                         xRadius: 0.3, yRadius: 0.3).fill()
        }
    }
}
