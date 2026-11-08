import AppKit
import DualDockCore

struct DockDrag: Codable {
    static let pasteboardType = NSPasteboard.PasteboardType("local.ronny.DualDock.item")
    var appID: String?
    var entryID: UUID
    var groupID: UUID?

    static func read(_ info: NSDraggingInfo) -> DockDrag? {
        guard let data = info.draggingPasteboard.data(forType: pasteboardType) else { return nil }
        return try? JSONDecoder().decode(DockDrag.self, from: data)
    }
}

@MainActor
final class DockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .init(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }
}

@MainActor
final class DockTile: NSView, NSDraggingSource {
    let entry: DockEntry
    let groupID: UUID?
    let store: AppStore
    var onPress: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onDrop: ((NSDraggingInfo, Bool, Bool) -> Bool)?
    var menuProvider: (() -> NSMenu)?
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var dragStart: NSPoint?
    private var dragging = false
    private var dwell: DispatchWorkItem?
    private var mergeReady = false
    private var dragInside = false
    private var dropAfter = false
    private var centralDrop = false

    init(entry: DockEntry, groupID: UUID?, store: AppStore, size: CGFloat) {
        self.entry = entry
        self.groupID = groupID
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: size + 12, height: size + 16))
        toolTip = entry.name
        registerForDraggedTypes([DockDrag.pasteboardType, .fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(entry.isGroup ? "应用组 \(entry.name)，\(entry.apps.count) 个应用" : entry.name)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        let iconRect = bounds.insetBy(dx: hovered ? 3 : 6, dy: 8).offsetBy(dx: 0, dy: 2)
        if hovered || mergeReady {
            (mergeReady ? NSColor.controlAccentColor.withAlphaComponent(0.3) : NSColor.labelColor.withAlphaComponent(0.07)).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 13, yRadius: 13).fill()
        }
        if entry.isGroup {
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: iconRect.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10).fill()
            let side = (iconRect.width - 12) / 2
            for (index, app) in entry.apps.prefix(4).enumerated() {
                let x = iconRect.minX + 4 + CGFloat(index % 2) * (side + 4)
                let y = iconRect.minY + 4 + CGFloat(1 - index / 2) * (side + 4)
                store.icon(for: app).draw(in: NSRect(x: x, y: y, width: side, height: side))
            }
        } else if let app = entry.apps.first {
            store.icon(for: app).draw(in: iconRect)
        }
        if entry.apps.contains(where: store.isRunning) {
            NSColor.labelColor.withAlphaComponent(0.8).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 2, y: 2, width: 4, height: 4)).fill()
        }
        if dragInside && !mergeReady {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: dropAfter ? bounds.maxX - 2 : 0, y: 8, width: 2, height: bounds.height - 16), xRadius: 1, yRadius: 1).fill()
        }
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true; onHover?(false) }
    override func mouseDown(with event: NSEvent) { dragStart = convert(event.locationInWindow, from: nil); dragging = false }
    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        if !dragging && bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 5 else { return }
        dragging = true
        onHover?(false)
        let payload = DockDrag(appID: entry.isGroup ? nil : entry.apps.first?.id, entryID: entry.id, groupID: groupID)
        let item = NSPasteboardItem()
        item.setData(try! JSONEncoder().encode(payload), forType: DockDrag.pasteboardType)
        let drag = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        draw(bounds)
        image.unlockFocus()
        drag.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [drag], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { dragging = false; dragStart = nil }
    override func menu(for event: NSEvent) -> NSMenu? { onHover?(false); return menuProvider?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragInside = true
        updateDropPosition(sender)
        return DockDrag.read(sender) == nil ? .copy : .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDropPosition(sender); return DockDrag.read(sender) == nil ? .copy : .move }

    private func updateDropPosition(_ sender: NSDraggingInfo) {
        let point = convert(sender.draggingLocation, from: nil)
        dropAfter = point.x > bounds.midX
        let central = point.x > bounds.width * 0.22 && point.x < bounds.width * 0.78
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

    override func draggingExited(_ sender: NSDraggingInfo?) { clearDrop() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let result = onDrop?(sender, mergeReady, dropAfter) ?? false
        clearDrop()
        return result
    }
    private func clearDrop() { dwell?.cancel(); dwell = nil; mergeReady = false; dragInside = false; centralDrop = false; needsDisplay = true }
}

@MainActor
final class DockDocumentView: NSView {
    var onDropAtEnd: ((NSDraggingInfo) -> Bool)?
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); registerForDraggedTypes([DockDrag.pasteboardType, .fileURL]) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { DockDrag.read(sender) == nil ? .copy : .move }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { DockDrag.read(sender) == nil ? .copy : .move }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { onDropAtEnd?(sender) ?? false }
}

@MainActor
final class DockStripView: NSVisualEffectView {
    let scroll = NSScrollView()
    let document = DockDocumentView(frame: .zero)
    private(set) var tiles: [DockTile] = []
    var settingsAction: (() -> Void)?
    var modeAction: (() -> Void)?
    private var actions: [MenuAction] = []
    var desiredWidth: CGFloat = 200

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.documentView = document
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); scroll.frame = bounds.insetBy(dx: 8, dy: 2) }

    func populate(entries: [DockEntry], groupID: UUID? = nil, store: AppStore, maxWidth: CGFloat,
                  configure: (DockTile) -> Void) -> NSSize {
        document.subviews.forEach { $0.removeFromSuperview() }
        tiles = []
        actions = []
        let availablePerTile = (maxWidth - (groupID == nil ? 100 : 24)) / CGFloat(max(1, entries.count))
        let size = max(28, min(CGFloat(store.configuration.iconSize), availablePerTile - 14))
        let height = size + 18
        var x: CGFloat = 2
        for (index, entry) in entries.enumerated() {
            if groupID == nil && store.pinnedCount > 0 && index == store.pinnedCount {
                let divider = NSBox(frame: NSRect(x: x + 5, y: 12, width: 1, height: height - 24))
                divider.boxType = .separator
                document.addSubview(divider)
                x += 13
            }
            let tile = DockTile(entry: entry, groupID: groupID, store: store, size: size)
            tile.frame.origin = NSPoint(x: x, y: 1)
            configure(tile)
            document.addSubview(tile)
            tiles.append(tile)
            x += tile.frame.width + 2
        }
        if entries.isEmpty {
            let label = NSTextField(labelWithString: groupID == nil ? "拖入应用，开始整理" : "将应用拖到这里")
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 12)
            label.frame = NSRect(x: x + 12, y: height / 2 - 8, width: 144, height: 20)
            document.addSubview(label)
            x += 160
        }
        if groupID == nil {
            let controls: [(String, String, () -> Void)] = [
                (store.configuration.mode == .runningOnly ? "circle.grid.2x2" : "bolt.fill", "切换显示模式", { [weak self] in self?.modeAction?() }),
                ("slider.horizontal.3", "DualDock 设置", { [weak self] in self?.settingsAction?() })
            ]
            for (symbol, label, action) in controls {
                let callback = MenuAction(action)
                actions.append(callback)
                let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: callback, action: #selector(MenuAction.invoke))
                button.bezelStyle = .inline
                button.isBordered = false
                button.contentTintColor = .secondaryLabelColor
                button.toolTip = label
                button.frame = NSRect(x: x + 3, y: (height - 24) / 2, width: 24, height: 24)
                button.setAccessibilityLabel(label)
                document.addSubview(button)
                x += 30
            }
        }
        desiredWidth = x + 20
        document.frame = NSRect(x: 0, y: 0, width: max(x, 100), height: height)
        let result = NSSize(width: min(desiredWidth, maxWidth), height: height + 4)
        frame.size = result
        needsLayout = true
        return result
    }
}

@MainActor
final class MenuAction: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}

extension NSMenu {
    @MainActor
    func addAction(_ title: String, handler: @escaping () -> Void) {
        let action = MenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.invoke), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        addItem(item)
    }
}
