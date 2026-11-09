import AppKit
import QuartzCore
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
final class DockDocumentView: NSView {
    var onDropAtEnd: ((NSDraggingInfo) -> Bool)?
    var onInteractionChanged: ((Bool) -> Void)?
    private var dragActive = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([DockDrag.pasteboardType, .fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !dragActive { dragActive = true; onInteractionChanged?(true) }
        return DockDrag.read(sender) == nil ? .copy : .move
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { DockDrag.read(sender) == nil ? .copy : .move }
    override func draggingExited(_ sender: NSDraggingInfo?) { endDrag() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let result = onDropAtEnd?(sender) ?? false
        endDrag()
        return result
    }
    private func endDrag() {
        if dragActive { dragActive = false; onInteractionChanged?(false) }
    }
}

@MainActor
private final class DockScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onUserScroll?()
    }
}

@MainActor
private final class DockAnimationTarget: NSObject {
    weak var owner: DockStripView?
    init(_ owner: DockStripView) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) { owner?.animationTick(link) }
}

@MainActor
final class DockStripView: NSVisualEffectView {
    private let scrolling = DockScrollView()
    var scroll: NSScrollView { scrolling }
    let document = DockDocumentView(frame: .zero)
    private(set) var tiles: [DockTile] = []
    var settingsAction: (() -> Void)?
    var modeAction: (() -> Void)?
    var onGeometryChange: ((NSSize, CGFloat?) -> CGFloat)?
    private(set) var desiredWidth: CGFloat = 200

    private var actions: [MenuAction] = []
    private var controls: [NSButton] = []
    private var divider: NSBox?
    private var emptyLabel: NSTextField?
    private var tracking: NSTrackingArea?
    private var baseSide: CGFloat = 48
    private var spacing: CGFloat = 14
    private var maximumWidth: CGFloat = 1800
    private var magnificationScale: CGFloat = 1
    private var isGroup = false
    private var dividerIndex: Int?
    private var baseLayout: DockWaveLayout?
    private var currentLayout: DockWaveLayout?
    private var targetLayout: DockWaveLayout?
    private var focusIndex: CGFloat?
    private var hoveredIndex: Int?
    private var interactionDepth = 0
    private var waitingForMouseRelease = false
    private var lastMousePoint: NSPoint?
    private var displayLink: CADisplayLink?
    private var animationTarget: DockAnimationTarget?
    private var lastTimestamp: CFTimeInterval?

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        scrolling.drawsBackground = false
        scrolling.hasHorizontalScroller = true
        scrolling.scrollerStyle = .overlay
        scrolling.horizontalScrollElasticity = .allowed
        scrolling.verticalScrollElasticity = .none
        scrolling.documentView = document
        scrolling.onUserScroll = { [weak self] in self?.updatePointer(force: true) }
        document.onInteractionChanged = { [weak self] active in self?.interactionChanged(active) }
        addSubview(scrolling)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        if tracking == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
            tracking = area
            addTrackingArea(area)
        }
        super.updateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopAnimations() }
    }

    override func layout() {
        super.layout()
        guard let currentLayout else { return }
        let unit = baseSide / 48
        scrolling.frame = NSRect(x: currentLayout.horizontalInset, y: 0,
                                 width: currentLayout.viewportSize.width, height: currentLayout.viewportSize.height)
        let controlSide = 24 * unit
        let firstX = bounds.width - currentLayout.horizontalInset - currentLayout.controlsWidth
        for (index, button) in controls.enumerated() {
            button.frame = NSRect(x: firstX + CGFloat(index) * 30 * unit + 4 * unit,
                                  y: 8 * unit + (baseSide - controlSide) / 2,
                                  width: controlSide, height: controlSide)
        }
        emptyLabel?.frame = NSRect(x: 10 * unit, y: 8 * unit + baseSide / 2 - 8 * unit,
                                  width: max(100, currentLayout.contentSize.width - 20 * unit), height: 20 * unit)
    }

    func populate(entries: [DockEntry], groupID: UUID? = nil, store: AppStore, maxWidth: CGFloat,
                  configure: (DockTile) -> Void) -> NSSize {
        stopAnimations()
        document.subviews.forEach { $0.removeFromSuperview() }
        controls.forEach { $0.removeFromSuperview() }
        tiles = []; controls = []; actions = []; divider = nil; emptyLabel = nil
        interactionDepth = 0
        waitingForMouseRelease = false
        baseSide = CGFloat(store.configuration.iconSize)
        spacing = CGFloat(store.configuration.iconSpacing)
        maximumWidth = max(1, maxWidth)
        isGroup = groupID != nil
        magnificationScale = !isGroup && store.configuration.magnificationEnabled
            ? CGFloat(store.configuration.magnificationScale) : 1
        dividerIndex = groupID == nil && store.pinnedCount > 0 && store.pinnedCount < entries.count ? store.pinnedCount : nil
        let unit = baseSide / 48
        layer?.cornerRadius = 18 * unit
        for entry in entries {
            let tile = DockTile(entry: entry, groupID: groupID, store: store, size: baseSide)
            tile.onInteractionChanged = { [weak self] active in self?.interactionChanged(active) }
            configure(tile)
            document.addSubview(tile)
            tiles.append(tile)
        }
        if dividerIndex != nil {
            let line = NSBox()
            line.boxType = .separator
            document.addSubview(line)
            divider = line
        }
        if entries.isEmpty {
            let label = NSTextField(labelWithString: groupID == nil ? "拖入应用，开始整理" : "将应用拖到这里")
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 12 * unit)
            document.addSubview(label)
            emptyLabel = label
        }
        if groupID == nil {
            let items: [(String, String, () -> Void)] = [
                (store.configuration.mode == .runningOnly ? "circle.grid.2x2" : "bolt.fill", "切换显示模式", { [weak self] in self?.modeAction?() }),
                ("slider.horizontal.3", "DualDock 设置", { [weak self] in self?.settingsAction?() })
            ]
            for (symbol, title, action) in items {
                let callback = MenuAction(action)
                actions.append(callback)
                let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!, target: callback, action: #selector(MenuAction.invoke))
                button.bezelStyle = .inline
                button.isBordered = false
                button.contentTintColor = .secondaryLabelColor
                button.imageScaling = .scaleProportionallyUpOrDown
                button.toolTip = title
                button.setAccessibilityLabel(title)
                addSubview(button)
                controls.append(button)
            }
        }
        let base = makeLayout(focus: nil)
        baseLayout = base
        currentLayout = base
        targetLayout = base
        apply(base, notify: false)
        scrolling.contentView.scroll(to: .zero)
        return base.panelSize
    }

    func stopAnimations() {
        displayLink?.invalidate()
        displayLink = nil
        animationTarget = nil
        lastTimestamp = nil
        focusIndex = nil
        lastMousePoint = nil
        changeHoveredIndex(nil)
    }

    func resetMagnification() {
        stopAnimations()
        interactionDepth = 0
        waitingForMouseRelease = false
        guard let baseLayout else { return }
        currentLayout = baseLayout
        targetLayout = baseLayout
        apply(baseLayout, notify: true)
    }

    override func mouseEntered(with event: NSEvent) { updatePointer() }
    override func mouseMoved(with event: NSEvent) { updatePointer() }
    override func mouseExited(with event: NSEvent) {
        guard interactionDepth == 0 else { return }
        guard let window else { return }
        let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        if !bounds.contains(local) { updatePointer(force: true) }
    }

    private func makeLayout(focus: CGFloat?) -> DockWaveLayout {
        DockWaveLayout.make(count: tiles.count, iconSize: baseSide, spacing: spacing,
                            magnificationScale: magnificationScale, focusIndex: focus,
                            maxWidth: maximumWidth, hasControls: !isGroup, dividerIndex: dividerIndex)
    }

    private func updatePointer(force: Bool = false) {
        guard interactionDepth == 0, let window, let currentLayout else { return }
        if NSEvent.pressedMouseButtons != 0 { waitingForMouseRelease = true; startAnimation(); return }
        let global = NSEvent.mouseLocation
        if !force, let previous = lastMousePoint, hypot(global.x - previous.x, global.y - previous.y) < 0.05 { return }
        lastMousePoint = global
        let local = convert(window.convertPoint(fromScreen: global), from: nil)
        let point = document.convert(local, from: self)
        let insideViewport = scrolling.frame.contains(local)
        let index = insideViewport ? currentLayout.tileFrames.firstIndex(where: { $0.contains(point) }) : nil
        changeHoveredIndex(index)
        if let index, !isGroup, magnificationScale > 1 {
            let itemFrame = currentLayout.tileFrames[index]
            let fraction = min(1, max(0, (point.x - itemFrame.minX) / max(1, itemFrame.width)))
            focusIndex = CGFloat(index) + fraction - 0.5
        } else { focusIndex = nil }
        targetLayout = makeLayout(focus: focusIndex)
        startAnimation()
    }

    private func changeHoveredIndex(_ index: Int?) {
        guard hoveredIndex != index else { return }
        if let old = hoveredIndex, tiles.indices.contains(old) { tiles[old].setHovered(false) }
        hoveredIndex = index
        if let index, tiles.indices.contains(index) { tiles[index].setHovered(true) }
    }

    private func interactionChanged(_ active: Bool) {
        interactionDepth = max(0, interactionDepth + (active ? 1 : -1))
        if active {
            displayLink?.isPaused = true
            changeHoveredIndex(nil)
        } else if interactionDepth == 0 {
            updatePointer(force: true)
            startAnimation()
        }
    }

    private func startAnimation() {
        guard interactionDepth == 0, window != nil else { return }
        if isGroup, let targetLayout {
            currentLayout = targetLayout
            apply(targetLayout, notify: false)
            displayLink?.isPaused = true
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let targetLayout {
            currentLayout = targetLayout
            apply(targetLayout, notify: true)
            return
        }
        if displayLink == nil {
            let proxy = DockAnimationTarget(self)
            animationTarget = proxy
            let link = self.displayLink(target: proxy, selector: #selector(DockAnimationTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        lastTimestamp = nil
        displayLink?.isPaused = false
    }

    fileprivate func animationTick(_ link: CADisplayLink) {
        guard interactionDepth == 0, let currentLayout, let targetLayout else { link.isPaused = true; return }
        if NSEvent.pressedMouseButtons != 0 { waitingForMouseRelease = true; return }
        if waitingForMouseRelease {
            waitingForMouseRelease = false
            updatePointer(force: true)
            return
        }
        let now = link.timestamp
        let dt = min(0.05, max(0.001, now - (lastTimestamp ?? (now - 1.0 / 60.0))))
        lastTimestamp = now
        let fraction = CGFloat(1 - exp(-dt / 0.055))
        let remaining = currentLayout.maximumDifference(from: targetLayout)
        let next = remaining < 0.08 ? targetLayout : currentLayout.interpolated(to: targetLayout, fraction: fraction)
        self.currentLayout = next
        let centerDistance = apply(next, notify: true, settlingFraction: fraction)
        if remaining < 0.08 && centerDistance < 0.08 { link.isPaused = true; lastTimestamp = nil }
    }

    @discardableResult
    private func apply(_ value: DockWaveLayout, notify: Bool, settlingFraction: CGFloat = 1) -> CGFloat {
        let oldOffset = scrolling.contentView.bounds.origin.x
        frame.size = value.panelSize
        document.frame.size = value.contentSize
        for (tile, itemFrame) in zip(tiles, value.tileFrames) {
            let sizeChanged = tile.frame.size != itemFrame.size
            tile.frame = itemFrame
            if sizeChanged { tile.needsDisplay = true }
        }
        let unit = baseSide / 48
        if let x = value.dividerX {
            divider?.frame = NSRect(x: x, y: 10 * unit, width: max(0.5, unit), height: max(1, baseSide - 4 * unit))
        }
        desiredWidth = value.contentSize.width + value.controlsWidth + 2 * value.horizontalInset
        needsLayout = true
        layoutSubtreeIfNeeded()
        let maxOffset = max(0, value.contentSize.width - value.viewportSize.width)
        var offset = min(max(0, oldOffset), maxOffset)
        scrolling.contentView.scroll(to: NSPoint(x: offset, y: 0))
        var centerDistance: CGFloat = 0
        if notify {
            let focus: CGFloat?
            if let focusIndex, let contentX = value.position(for: focusIndex) {
                focus = value.horizontalInset + contentX - offset
            } else if onGeometryChange != nil, let window, let screen = window.screen, settlingFraction < 1 {
                let centeredX = (screen.frame.midX - value.panelSize.width / 2).rounded(.down)
                let nextX = DockWaveLayout.nextPanelOrigin(current: window.frame.minX, target: centeredX, fraction: settlingFraction)
                centerDistance = abs(centeredX - nextX)
                // A virtual anchor lets the same coordinator callback smoothly
                // return the panel to center after the pointer has left it.
                focus = NSEvent.mouseLocation.x - nextX
            } else { focus = nil }
            let correction = onGeometryChange?(value.panelSize, focus) ?? 0
            if focusIndex != nil && abs(correction) > 0.01 {
                offset = min(max(0, offset + correction), maxOffset)
                scrolling.contentView.scroll(to: NSPoint(x: offset, y: 0))
            }
        }
        scrolling.reflectScrolledClipView(scrolling.contentView)
        return centerDistance
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
