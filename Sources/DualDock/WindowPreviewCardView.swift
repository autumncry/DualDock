import AppKit

/// Separate sibling buttons keep the close target independent of thumbnail activation.
@MainActor
final class WindowPreviewCardView: NSView {
    let thumbnailButton = NSButton()
    let closeButton = PreviewCloseButton()
    let titleLabel: NSTextField
    var onActivate: (() -> Void)?
    var onClose: (() -> Void)?

    init(title: String, image: NSImage) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: 192, height: 140))
        thumbnailButton.image = image
        thumbnailButton.imageScaling = .scaleProportionallyUpOrDown
        thumbnailButton.imagePosition = .imageOnly
        thumbnailButton.isBordered = false
        thumbnailButton.target = self
        thumbnailButton.action = #selector(activatePreview)
        thumbnailButton.toolTip = title
        thumbnailButton.setAccessibilityLabel("切换到 \(title)")
        addSubview(thumbnailButton)

        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .center
        addSubview(titleLabel)

        closeButton.target = self
        closeButton.action = #selector(closePreview)
        closeButton.toolTip = "关闭窗口"
        closeButton.setAccessibilityLabel("关闭窗口：\(title)")
        addSubview(closeButton)
        layout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var thumbnailContentFrame: NSRect {
        let box = thumbnailButton.frame
        guard let image = thumbnailButton.image, image.size.width > 0, image.size.height > 0 else { return box }
        let scale = min(box.width / image.size.width, box.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        thumbnailButton.frame = NSRect(x: 0, y: 26, width: bounds.width, height: 108)
        titleLabel.frame = NSRect(x: 0, y: 5, width: bounds.width, height: 18)
        let image = thumbnailContentFrame
        let side: CGFloat = 22
        closeButton.frame = NSRect(x: max(0, image.maxX - side - 3),
                                   y: min(bounds.height - side, image.maxY - side - 3),
                                   width: side, height: side)
    }

    @objc private func activatePreview() { onActivate?() }
    @objc private func closePreview() { onClose?() }
}

@MainActor
final class PreviewCloseButton: NSButton {
    private var mouseInside = false
    private var hoverTracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        setButtonType(.momentaryChange)
        isBordered = false
        title = ""
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        hoverTracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { mouseInside = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { mouseInside = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 1, dy: 1)
        let outline = NSBezierPath(ovalIn: circle)
        (mouseInside || isHighlighted ? NSColor.systemRed : NSColor.black.withAlphaComponent(0.68)).setFill()
        outline.fill()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        outline.lineWidth = 0.5
        outline.stroke()
        let cross = NSBezierPath()
        let radius: CGFloat = 3.2
        cross.move(to: NSPoint(x: bounds.midX - radius, y: bounds.midY - radius))
        cross.line(to: NSPoint(x: bounds.midX + radius, y: bounds.midY + radius))
        cross.move(to: NSPoint(x: bounds.midX - radius, y: bounds.midY + radius))
        cross.line(to: NSPoint(x: bounds.midX + radius, y: bounds.midY - radius))
        cross.lineWidth = 1.5
        cross.lineCapStyle = .round
        NSColor.white.setStroke()
        cross.stroke()
    }
}
