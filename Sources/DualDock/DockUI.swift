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
    var tileHitTest: ((NSPoint) -> NSView?)?
    private var dragActive = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([DockDrag.pasteboardType, .fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return tileHitTest?(local) ?? (bounds.contains(local) ? self : nil)
    }
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
    var allowsHorizontalScrolling = false
    private var handlingWheel = false
    override func scrollWheel(with event: NSEvent) {
        // A non-scrollable row must not move by a fractional backing pixel.
        // An unhandled edge event can also return here through the responder
        // chain (the strip forwards wheel input to this view); handle it once.
        guard allowsHorizontalScrolling, !handlingWheel else { return }
        handlingWheel = true
        defer { handlingWheel = false }
        let previous = contentView.bounds.origin
        super.scrollWheel(with: event)
        if contentView.bounds.origin != previous { onUserScroll?() }
    }
}

@MainActor
private final class DockAnimationTarget: NSObject {
    weak var owner: DockStripView?
    init(_ owner: DockStripView) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) { owner?.animationTick(link) }
}

@MainActor
final class DockStripView: NSView {
    private let backdrop = NSVisualEffectView()
    var backdropFrame: NSRect { backdrop.frame }
    private let scrolling = DockScrollView()
    var scroll: NSScrollView { scrolling }
    let document = DockDocumentView(frame: .zero)
    private(set) var tiles: [DockTile] = []
    var settingsAction: (() -> Void)?
    /// Higher-level popups own pointer input over their entire visible panel,
    /// including padding that overlaps this strip's transparent canvas.
    var pointerIsOccluded: ((NSPoint) -> Bool)?
    private(set) var desiredWidth: CGFloat = 200

    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var divider: NSBox?
    private var emptyLabel: NSTextField?
    private var tracking: NSTrackingArea?
    private var baseSide: CGFloat = 48
    private var spacing: CGFloat = 14
    private var widthReferenceSpacing: CGFloat?
    private var fixedPanelWidth: CGFloat?
    private var maximumWidth: CGFloat = 1800
    private var magnificationScale: CGFloat = 1
    private var isGroup = false
    private var dividerIndex: Int?
    private var baseLayout: DockWaveLayout?
    private var currentLayout: DockWaveLayout?
    private var targetLayout: DockWaveLayout?
    private var focusIndex: CGFloat?
    private var lensAnchorX: CGFloat?
    private var hoveredIndex: Int?
    private var interactionDepth = 0
    private var waitingForMouseRelease = false
    private var lastMousePoint: NSPoint?
    private var displayLink: CADisplayLink?
    private var animationTarget: DockAnimationTarget?
    private var animationTiming = DockAnimationTiming()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([DockDrag.pasteboardType, .fileURL])
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 0.5
        backdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        addSubview(backdrop)
        scrolling.drawsBackground = false
        scrolling.hasHorizontalScroller = false
        scrolling.hasVerticalScroller = false
        scrolling.scrollerStyle = .overlay
        scrolling.horizontalScrollElasticity = .none
        scrolling.verticalScrollElasticity = .none
        scrolling.documentView = document
        scrolling.onUserScroll = { [weak self] in self?.updatePointer(force: true) }
        document.onInteractionChanged = { [weak self] active in self?.interactionChanged(active) }
        document.tileHitTest = { [weak self] point in
            guard let self else { return nil }
            let local = self.convert(point, from: self.document)
            return self.interactionTileIndex(at: local).map { self.tiles[$0] }
        }
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
        removeMouseMonitors()
        if window == nil { stopAnimations(); return }
        needsLayout = true
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.updatePointer()
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.updatePointer()
        }
        updateMousePassthrough()
    }

    override func layout() {
        super.layout()
        guard let currentLayout else { return }
        let unit = baseSide / 48
        let viewport = NSRect(x: currentLayout.horizontalInset, y: 0,
                              width: currentLayout.viewportSize.width, height: currentLayout.viewportSize.height)
        scrolling.frame = backingAlignedRect(viewport, options: [.alignAllEdgesOutward])
        scrolling.layoutSubtreeIfNeeded()
        let clipSize = scrolling.contentView.bounds.size
        let overflows = currentLayout.contentSize.width > currentLayout.viewportSize.width + 0.001
        scrolling.allowsHorizontalScrolling = overflows
        document.frame.size = NSSize(width: overflows ? max(currentLayout.contentSize.width, clipSize.width) : clipSize.width,
                                     height: clipSize.height)
        if !overflows, scrolling.contentView.bounds.origin != .zero {
            scrolling.contentView.scroll(to: .zero)
        }
        emptyLabel?.frame = NSRect(x: 10 * unit, y: 8 * unit + baseSide / 2 - 8 * unit,
                                  width: max(100, currentLayout.contentSize.width - 20 * unit), height: 20 * unit)
    }

    func populate(entries: [DockEntry], groupID: UUID? = nil, store: AppStore, maxWidth: CGFloat,
                  configure: (DockTile) -> Void) -> NSSize {
        stopAnimations()
        document.subviews.forEach { $0.removeFromSuperview() }
        tiles = []; divider = nil; emptyLabel = nil
        interactionDepth = 0
        waitingForMouseRelease = false
        baseSide = CGFloat(store.effectiveIconSize)
        spacing = CGFloat(store.configuration.iconSpacing)
        maximumWidth = max(1, maxWidth)
        isGroup = groupID != nil
        widthReferenceSpacing = isGroup ? nil : CGFloat(store.configuration.dockWidthReferenceSpacing)
        fixedPanelWidth = isGroup ? nil : CGFloat(store.effectiveDockWidth)
        magnificationScale = !isGroup && store.configuration.magnificationEnabled
            ? CGFloat(store.configuration.magnificationScale) : 1
        dividerIndex = groupID == nil && store.pinnedCount > 0 && store.pinnedCount < entries.count ? store.pinnedCount : nil
        let unit = baseSide / 48
        backdrop.layer?.cornerRadius = 18 * unit
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
        let base = makeLayout(focus: nil)
        baseLayout = base
        currentLayout = base
        targetLayout = base
        apply(base)
        scrolling.contentView.scroll(to: NSPoint(x: base.initialScrollOffset, y: 0))
        return base.panelSize
    }

    func stopAnimations() {
        displayLink?.invalidate()
        displayLink = nil
        animationTarget = nil
        animationTiming.pause()
        focusIndex = nil
        lensAnchorX = nil
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
        apply(baseLayout)
    }

    override func mouseEntered(with event: NSEvent) { updatePointer() }
    override func mouseMoved(with event: NSEvent) { updatePointer() }
    override func mouseExited(with event: NSEvent) {
        guard interactionDepth == 0 else { return }
        guard let window else { return }
        let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        if !bounds.contains(local) { updatePointer(force: true) }
    }

    /// Only the opaque Dock strip and the visible magnified icon capture mouse input.
    /// The reserved transparent band above the strip must pass clicks to other apps.
    func containsInteractivePoint(_ point: NSPoint) -> Bool {
        backdropFrame.contains(point) || interactionTileIndex(at: point) != nil
    }

    private func tileIndex(at local: NSPoint) -> Int? {
        guard scrolling.frame.contains(local), let currentLayout else { return nil }
        let point = document.convert(local, from: self)
        // Actual frames own hover/preview targets. Their widths never overlap,
        // while the lens itself uses a separate immutable coordinate mapping.
        return currentLayout.tileFrames.firstIndex { $0.contains(point) }
    }

    private func interactionTileIndex(at local: NSPoint) -> Int? {
        guard let index = tileIndex(at: local) else { return nil }
        // Keep the row's small inter-icon padding clickable as part of its
        // tile. Above the backdrop only the visible icon captures input.
        if backdropFrame.contains(local) { return index }
        let tile = tiles[index]
        let point = tile.convert(local, from: self)
        if tile.visualIconBounds.contains(point) { return index }
        let unit = baseSide / 48
        let runningIndicator = NSRect(x: tile.bounds.midX - 4 * unit, y: 0,
                                      width: 8 * unit, height: 6 * unit)
        return runningIndicator.contains(point) ? index : nil
    }

    func updateMousePassthrough() {
        updateMousePassthrough(at: NSEvent.mouseLocation)
    }

    func updateMousePassthrough(at global: NSPoint) {
        guard interactionDepth == 0, let window else { return }
        guard pointerIsOccluded?(global) != true else {
            window.ignoresMouseEvents = true
            return
        }
        let local = convert(window.convertPoint(fromScreen: global), from: nil)
        window.ignoresMouseEvents = !containsInteractivePoint(local)
    }

    private func removeMouseMonitors() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
    }

    deinit {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard containsInteractivePoint(local) else { return nil }
        if let index = interactionTileIndex(at: local) { return tiles[index] }
        // Blank regions route here so context menus and scrolling remain available.
        return self
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { document.draggingEntered(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { document.draggingUpdated(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { document.draggingExited(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { document.prepareForDragOperation(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { document.performDragOperation(sender) }

    override func scrollWheel(with event: NSEvent) { scrolling.scrollWheel(with: event) }

    override func rightMouseDown(with event: NSEvent) { showBlankAreaMenu(event) }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { showBlankAreaMenu(event) }
    }

    private func showBlankAreaMenu(_ event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard backdropFrame.contains(local), interactionTileIndex(at: local) == nil, settingsAction != nil else { return }
        interactionChanged(true)
        defer { interactionChanged(false) }
        let menu = NSMenu()
        menu.addAction("DualDock 设置…") { [weak self] in self?.settingsAction?() }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func makeLayout(focus: CGFloat?) -> DockWaveLayout {
        DockWaveLayout.make(count: tiles.count, iconSize: baseSide, spacing: spacing,
                            magnificationScale: magnificationScale, focusIndex: focus,
                            maxWidth: maximumWidth, hasControls: false, dividerIndex: dividerIndex,
                            scrollOffset: scrolling.contentView.bounds.origin.x, lensAnchorX: lensAnchorX,
                            widthReferenceSpacing: widthReferenceSpacing, fixedPanelWidth: fixedPanelWidth)
    }

    private func updatePointer(force: Bool = false) {
        guard window?.isVisible == true else { return }
        updatePointer(at: NSEvent.mouseLocation, buttonsPressed: NSEvent.pressedMouseButtons != 0, force: force)
    }

    /// Process one pointer snapshot independently from the OS event source.
    func updatePointer(at global: NSPoint, buttonsPressed: Bool, force: Bool = false) {
        guard interactionDepth == 0, let window, let currentLayout else { return }
        updateMousePassthrough(at: global)
        if pointerIsOccluded?(global) == true {
            pauseForPointerOcclusion()
            return
        }
        if buttonsPressed {
            // Desktop drags unrelated to this Dock must not wake an idle display link.
            if focusIndex != nil || baseLayout.map({ currentLayout.maximumDifference(from: $0) > 0.08 }) == true {
                waitingForMouseRelease = true
                startAnimation()
            }
            return
        }
        if !force, let previous = lastMousePoint, hypot(global.x - previous.x, global.y - previous.y) < 0.05 { return }
        lastMousePoint = global
        let local = convert(window.convertPoint(fromScreen: global), from: nil)
        let index = tileIndex(at: local)
        changeHoveredIndex(index)
        if !isGroup, magnificationScale > 1, scrolling.frame.contains(local), let baseLayout {
            let point = document.convert(local, from: self)
            focusIndex = currentLayout.magnificationFocus(at: point, basedOn: baseLayout)
            lensAnchorX = focusIndex == nil ? nil : point.x
        } else { focusIndex = nil; lensAnchorX = nil }
        let next = makeLayout(focus: focusIndex)
        guard targetLayout != next || currentLayout.maximumDifference(from: next) > 0.08 else { return }
        targetLayout = next
        startAnimation()
    }

    private func changeHoveredIndex(_ index: Int?) {
        guard hoveredIndex != index else { return }
        if let old = hoveredIndex, tiles.indices.contains(old) { tiles[old].setHovered(false) }
        hoveredIndex = index
        if let index, tiles.indices.contains(index) {
            let tile = tiles[index]
            document.addSubview(tile, positioned: .above, relativeTo: nil)
            tile.setHovered(true)
        }
    }

    private func interactionChanged(_ active: Bool) {
        interactionDepth = max(0, interactionDepth + (active ? 1 : -1))
        if active {
            displayLink?.isPaused = true
            animationTiming.pause()
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
            apply(targetLayout)
            displayLink?.isPaused = true
            animationTiming.pause()
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let targetLayout {
            currentLayout = targetLayout
            apply(targetLayout)
            displayLink?.isPaused = true
            animationTiming.pause()
            return
        }
        if displayLink == nil {
            let proxy = DockAnimationTarget(self)
            animationTarget = proxy
            let link = self.displayLink(target: proxy, selector: #selector(DockAnimationTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        animationTiming.resume()
        displayLink?.isPaused = false
    }

    fileprivate func animationTick(_ link: CADisplayLink) {
        guard interactionDepth == 0, let currentLayout, let targetLayout else {
            link.isPaused = true
            animationTiming.pause()
            return
        }
        if pointerIsOccluded?(NSEvent.mouseLocation) == true {
            link.isPaused = true
            pauseForPointerOcclusion()
            updateMousePassthrough()
            return
        }
        if NSEvent.pressedMouseButtons != 0 {
            waitingForMouseRelease = true
            animationTiming.pause()
            return
        }
        if waitingForMouseRelease {
            waitingForMouseRelease = false
            updatePointer(force: true)
            return
        }
        let fraction = animationTiming.fraction(at: link.timestamp, returningToRest: focusIndex == nil)
        let remaining = currentLayout.maximumDifference(from: targetLayout)
        let next = remaining < 0.08 ? targetLayout : currentLayout.interpolated(to: targetLayout, fraction: fraction)
        self.currentLayout = next
        apply(next)
        if remaining < 0.08 {
            link.isPaused = true
            animationTiming.pause()
            refreshHoveredIndex()
        }
    }

    private func refreshHoveredIndex() {
        guard interactionDepth == 0, let window else { return }
        let global = NSEvent.mouseLocation
        guard pointerIsOccluded?(global) != true else {
            pauseForPointerOcclusion()
            updateMousePassthrough()
            return
        }
        let local = convert(window.convertPoint(fromScreen: global), from: nil)
        changeHoveredIndex(tileIndex(at: local))
        updateMousePassthrough()
    }

    private func pauseForPointerOcclusion() {
        // Keep the geometry/focus frozen, but end hover ownership once. The
        // coordinator scopes leaves to their source; a later return to the same
        // icon must deliver a fresh enter after its preview has been dismissed.
        displayLink?.isPaused = true
        animationTiming.pause()
        lastMousePoint = nil
        changeHoveredIndex(nil)
    }

    private func apply(_ value: DockWaveLayout) {
        frame.size = value.panelSize
        backdrop.frame = NSRect(origin: .zero, size: value.backdropSize)
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
        // Horizontal extents are constant across hover frames. Only explicit
        // wheel/trackpad input (or a new configuration) changes the scroll offset.
        updateMousePassthrough()
        scrolling.reflectScrolledClipView(scrolling.contentView)
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
