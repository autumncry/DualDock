import AppKit
import DualDockCore

@MainActor
final class DockTile: NSView, NSDraggingSource {
    let entry: DockEntry
    let groupID: UUID?
    let store: AppStore
    var onPress: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onDrop: ((NSDraggingInfo, Bool, Bool) -> Bool)?
    var menuProvider: (() -> NSMenu?)?
    /// Group rows stay horizontal, while their menus follow the parent Dock edge.
    var menuEdge: DockEdge?
    var onInteractionChanged: ((Bool) -> Void)?
    private var unitScale: CGFloat
    private var layoutEdge: DockEdge = .bottom
    private var explicitIconBounds: NSRect?
    private var explicitDotBounds: NSRect?
    private var hovered = false
    private var dragStart: NSPoint?
    private var dragging = false
    private var suppressMouseUp = false
    private var ownsInteraction = false
    private var destinationInteraction = false
    private var dwell: DispatchWorkItem?
    private var mergeReady = false
    private var dragInside = false
    private var dropAfter = false
    private var centralDrop = false
    private var backingScale: CGFloat = 0
    private var backingColorSpace: NSColorSpace?

    init(entry: DockEntry, groupID: UUID?, store: AppStore, size: CGFloat) {
        self.entry = entry
        self.groupID = groupID
        self.store = store
        unitScale = size / 48
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size + 16 * unitScale))
        wantsLayer = true
        // Geometry changes alone must not recache unchanged pixels. The local
        // icon/dot checks below explicitly invalidate all appearance changes.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .scaleAxesIndependently
        toolTip = entry.name
        registerForDraggedTypes([DockDrag.pasteboardType, .fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        refreshBadge()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 1
        let colorSpace = window?.colorSpace
        guard backingScale != scale || backingColorSpace != colorSpace else { return }
        backingScale = scale
        backingColorSpace = colorSpace
        needsDisplay = true
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    override func accessibilityPerformShowMenu() -> Bool {
        guard menuProvider != nil else { return false }
        DispatchQueue.main.async { [weak self] in self?.showContextMenu() }
        return true
    }

    var visualIconBounds: NSRect {
        if let explicitIconBounds { return explicitIconBounds }
        let side = max(1, bounds.height - 16 * unitScale)
        return NSRect(x: (bounds.width - side) / 2, y: 8 * unitScale, width: side, height: side)
    }

    /// All rectangles arrive in the document coordinate space. Only positions
    /// transform between edges; the image, folder and badge remain upright.
    func applyGeometry(frame: NSRect, iconFrame: NSRect, dotFrame: NSRect,
                       baseIconSize: CGFloat, edge: DockEdge) {
        let icon = iconFrame.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let dot = dotFrame.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let scale = (baseIconSize.isFinite ? max(1, baseIconSize) : 48) / 48
        // A translated layer keeps the same pixels. Only local drawing geometry
        // invalidates its backing image; subtracting large document coordinates
        // can introduce insignificant floating-point noise in those local rects.
        func same(_ lhs: NSRect?, _ rhs: NSRect) -> Bool {
            guard let lhs else { return false }
            return abs(lhs.minX - rhs.minX) < 0.000001 && abs(lhs.minY - rhs.minY) < 0.000001
                && abs(lhs.width - rhs.width) < 0.000001 && abs(lhs.height - rhs.height) < 0.000001
        }
        let sizeChanged = abs(self.frame.width - frame.width) >= 0.000001
            || abs(self.frame.height - frame.height) >= 0.000001
        let changed = sizeChanged || !same(explicitIconBounds, icon) || !same(explicitDotBounds, dot)
            || unitScale != scale || layoutEdge != edge
        if self.frame.origin != frame.origin { setFrameOrigin(frame.origin) }
        if sizeChanged { setFrameSize(frame.size) }
        explicitIconBounds = icon
        explicitDotBounds = dot
        unitScale = scale
        layoutEdge = edge
        if changed { needsDisplay = true }
    }

    var runningIndicatorBounds: NSRect {
        explicitDotBounds ?? NSRect(x: bounds.midX - 2 * unitScale, y: 2 * unitScale,
                                     width: 4 * unitScale, height: 4 * unitScale)
    }

    func setHovered(_ value: Bool) {
        guard hovered != value else { return }
        hovered = value
        onHover?(value)
    }

    func refreshBadge() {
        needsDisplay = true
        let base = entry.isGroup ? "应用组 \(entry.name)，\(entry.apps.count) 个应用" : entry.name
        if let badge = store.badgeLabel(for: entry) {
            setAccessibilityLabel(entry.isGroup ? "\(base)，有未读提醒" : "\(base)，消息角标 \(badge)")
        } else {
            setAccessibilityLabel(base)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        let iconRect = visualIconBounds
        if mergeReady {
            NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
            NSBezierPath(roundedRect: iconRect.insetBy(dx: -2 * unitScale, dy: -2 * unitScale), xRadius: 12 * unitScale, yRadius: 12 * unitScale).fill()
        }
        if entry.isGroup { drawFolder(in: iconRect) }
        else if let app = entry.apps.first { store.icon(for: app).draw(in: iconRect) }
        if entry.apps.contains(where: store.isRunning) {
            NSColor.labelColor.withAlphaComponent(0.8).setFill()
            NSBezierPath(ovalIn: runningIndicatorBounds).fill()
        }
        if dragInside && !mergeReady {
            NSColor.controlAccentColor.setFill()
            let width = max(1, 2 * unitScale)
            let marker: NSRect
            if layoutEdge.isHorizontal {
                marker = NSRect(x: dropAfter ? bounds.maxX - width : bounds.minX,
                                y: bounds.minY + 6 * unitScale, width: width,
                                height: max(1, bounds.height - 12 * unitScale))
            } else {
                marker = NSRect(x: bounds.minX + 6 * unitScale,
                                y: dropAfter ? bounds.minY : bounds.maxY - width,
                                width: max(1, bounds.width - 12 * unitScale), height: width)
            }
            NSBezierPath(roundedRect: marker, xRadius: width / 2, yRadius: width / 2).fill()
        }
        if let label = store.badgeLabel(for: entry) { drawBadge(label, in: iconRect) }
    }

    private func drawBadge(_ label: String, in icon: NSRect) {
        if min(icon.width, icon.height) < 18 {
            // The normal count pill has a 12 pt minimum. On a deliberately
            // tiny icon, show a bounded unread dot and keep the full label in AX.
            let available = icon.intersection(bounds)
            guard !available.isNull, available.width.isFinite, available.height.isFinite,
                  available.width > 0, available.height > 0 else { return }
            let side = min(available.width, available.height)
            let diameter = min(side, min(6, max(2, side * 0.35)))
            let dot = NSRect(x: available.maxX - diameter, y: available.maxY - diameter,
                             width: diameter, height: diameter)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return
        }
        let scale = icon.width / 48
        let maximumWidth = max(12, min(bounds.width - 2, icon.width * 0.88))
        var fontSize = max(7, icon.width * 0.22)
        var font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let text = label as NSString
        var textSize = text.size(withAttributes: [.font: font])
        while textSize.width + 6 * scale > maximumWidth && fontSize > 5 {
            fontSize -= 0.5
            font = .systemFont(ofSize: fontSize, weight: .semibold)
            textSize = text.size(withAttributes: [.font: font])
        }
        let height = max(12, textSize.height + 2 * scale)
        let width = min(maximumWidth, max(height, textSize.width + 7 * scale))
        let right = min(bounds.maxX - 1, icon.maxX)
        let top = min(bounds.maxY - 1, icon.maxY + 2 * scale)
        let badge = NSRect(x: right - width, y: top - height, width: width, height: height)
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: badge, xRadius: height / 2, yRadius: height / 2).fill()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let textRect = NSRect(x: badge.minX + 1, y: badge.midY - textSize.height / 2,
                              width: badge.width - 2, height: textSize.height)
        text.draw(in: textRect, withAttributes: [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: style])
    }

    private func drawFolder(in rect: NSRect) {
        let w = rect.width
        let body = NSRect(x: rect.minX + 0.04 * w, y: rect.minY + 0.10 * w, width: 0.92 * w, height: 0.66 * w)
        let tab = NSBezierPath(roundedRect: NSRect(x: body.minX, y: rect.minY + 0.58 * w,
                                                  width: 0.42 * w, height: 0.25 * w), xRadius: 0.08 * w, yRadius: 0.08 * w)
        NSColor.systemBlue.withAlphaComponent(0.8).setFill()
        tab.fill()
        NSBezierPath(roundedRect: body.offsetBy(dx: 0, dy: 0.04 * w), xRadius: 0.09 * w, yRadius: 0.09 * w).fill()
        let page = NSRect(x: rect.minX + 0.14 * w, y: rect.minY + 0.31 * w, width: 0.72 * w, height: 0.41 * w)
        NSColor.white.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: page, xRadius: 0.035 * w, yRadius: 0.035 * w).fill()
        let front = NSBezierPath(roundedRect: NSRect(x: body.minX, y: body.minY, width: body.width, height: 0.52 * w), xRadius: 0.08 * w, yRadius: 0.08 * w)
        NSGradient(starting: .systemCyan, ending: .systemBlue)?.draw(in: front, angle: -90)
        let apps = Array(entry.apps.prefix(3))
        let centers: [CGFloat] = apps.count == 1 ? [0.5] : (apps.count == 2 ? [0.37, 0.63] : [0.29, 0.5, 0.71])
        for (index, app) in apps.enumerated() {
            let side = 0.31 * w
            let lift: CGFloat = index % 2 == 0 ? 0 : 0.035 * w
            let icon = NSRect(x: rect.minX + centers[index] * w - side / 2,
                              y: rect.minY + 0.18 * w + lift, width: side, height: side)
            store.icon(for: app).draw(in: icon)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            suppressMouseUp = true
            showContextMenu()
            return
        }
        suppressMouseUp = false
        beginInteraction()
        dragStart = convert(event.locationInWindow, from: nil)
        dragging = false
    }

    override func mouseUp(with event: NSEvent) {
        if suppressMouseUp { suppressMouseUp = false; return }
        let shouldOpen = !dragging && bounds.contains(convert(event.locationInWindow, from: nil))
        dragStart = nil
        endInteraction()
        if shouldOpen { onPress?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 5 else { return }
        dragging = true
        suppressMouseUp = true
        onHover?(false)
        let payload = DockDrag(appID: entry.isGroup ? nil : entry.apps.first?.id, entryID: entry.id, groupID: groupID)
        let item = NSPasteboardItem()
        guard let data = try? JSONEncoder().encode(payload) else { dragging = false; endInteraction(); return }
        item.setData(data, forType: DockDrag.pasteboardType)
        let drag = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size)
        image.lockFocus(); draw(bounds); image.unlockFocus()
        drag.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [drag], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        dragStart = nil
        endInteraction()
    }

    override func rightMouseDown(with event: NSEvent) { showContextMenu() }

    private func showContextMenu() {
        guard let window else { return }
        beginInteraction()
        defer { endInteraction() }
        let icon = window.convertToScreen(convert(visualIconBounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: icon.midX, y: icon.midY)) } ?? window.screen
        guard let screen, let menu = menuProvider?() else { return }
        onHover?(false)
        menu.update()
        let origin = DockMenuPlacement.origin(icon: icon, menuSize: menu.size, visibleScreen: screen.visibleFrame,
                                              edge: menuEdge ?? layoutEdge)
        menu.popUp(positioning: nil, at: origin, in: nil)
    }

    private func beginInteraction() {
        guard !ownsInteraction else { return }
        ownsInteraction = true
        onInteractionChanged?(true)
    }
    private func endInteraction() {
        guard ownsInteraction else { return }
        ownsInteraction = false
        onInteractionChanged?(false)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragInside = true
        if !destinationInteraction { destinationInteraction = true; onInteractionChanged?(true) }
        updateDropPosition(sender)
        return DockDrag.read(sender) == nil ? .copy : .move
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDropPosition(sender); return DockDrag.read(sender) == nil ? .copy : .move }

    private func updateDropPosition(_ sender: NSDraggingInfo) {
        let point = convert(sender.draggingLocation, from: nil)
        let position = dropPosition(at: point)
        dropAfter = position.after
        let central = position.central
        let payload = DockDrag.read(sender)
        let canMerge = groupID == nil && central && (payload?.appID != nil || payload == nil)
            && payload?.appID != entry.apps.first?.id
        if canMerge && !centralDrop {
            let work = DispatchWorkItem { [weak self] in self?.mergeReady = true; self?.needsDisplay = true }
            dwell = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (entry.isGroup ? 0.15 : 0.6), execute: work)
        } else if !canMerge { dwell?.cancel(); dwell = nil; mergeReady = false }
        centralDrop = canMerge
        needsDisplay = true
    }

    /// Express order along the visible row: left-to-right or top-to-bottom.
    func dropPosition(at point: NSPoint) -> (after: Bool, central: Bool) {
        let fraction = layoutEdge.isHorizontal
            ? (point.x - bounds.minX) / max(1, bounds.width)
            : (bounds.maxY - point.y) / max(1, bounds.height)
        return (fraction > 0.5, fraction > 0.22 && fraction < 0.78)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { clearDrop() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let result = onDrop?(sender, mergeReady, dropAfter) ?? false
        clearDrop()
        return result
    }
    private func clearDrop() {
        dwell?.cancel(); dwell = nil; mergeReady = false; dragInside = false; centralDrop = false
        if destinationInteraction { destinationInteraction = false; onInteractionChanged?(false) }
        needsDisplay = true
    }
}
