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
        // Join normal desktops without opting into another app's fullscreen
        // Space. Visibility polling then handles restoration, not the first
        // frame of a fullscreen transition.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
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
    var pointerIsOccluded: ((NSPoint) -> Bool)?
    var resizeInteractionAllowed: (() -> Bool)?
    var onResizeBegan: (() -> Void)?
    var onResizeChanged: ((DockManualSizing) -> Void)?
    var onResizeEnded: ((DockManualSizing?) -> Void)?
    private(set) var desiredWidth: CGFloat = 200
    var layoutGeometry: DockGeometry? { currentGeometry }
    var isResizing: Bool { resizeSession?.started == true }
    var isInteracting: Bool { interactionDepth > 0 || resizeSession != nil }
    var scrollOffset: CGFloat {
        currentGeometry?.canonicalScrollOffset(clipBounds: scrolling.contentView.bounds,
                                               actualDocumentSize: document.frame.size) ?? 0
    }

    private struct ResizeSession {
        let point: NSPoint
        let handle: DockResizeHandle
        let edge: DockEdge
        let sizing: DockManualSizing
        let bounds: DockResizeBounds
        let clickTile: DockTile?
        var started = false
        var proposed: DockManualSizing
    }
    private var resizeSession: ResizeSession?
    private var presentation: DockPresentation?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var divider: NSBox?
    private var emptyLabel: NSTextField?
    private var tracking: NSTrackingArea?
    private var isGroup = false
    private var dividerIndex: Int?
    private var baseGeometry: DockGeometry?
    private var currentGeometry: DockGeometry?
    private var targetGeometry: DockGeometry?
    private var focusIndex: CGFloat?
    private var lensAnchor: CGFloat?
    private var hoveredIndex: Int?
    private var interactionDepth = 0
    private var waitingForMouseRelease = false
    private var lastMousePoint: NSPoint?
    private var displayLink: CADisplayLink?
    private var animationTarget: DockAnimationTarget?
    private var animationTiming = DockAnimationTiming()
    private struct CursorLayout: Equatable {
        let frame: NSRect
        let edge: DockEdge
        let enabled: Bool
    }
    private var cursorLayout: CursorLayout?
    private var ownsResizeCursor = false
    private struct ContainerLayout: Equatable {
        let canvasSize: CGSize
        let documentSize: CGSize
        let viewport: CGRect
        let backdrop: CGRect
        let thickness: CGFloat
    }
    private var containerLayout: ContainerLayout?

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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        cursorLayout = nil
        if window == nil { cancelResize(); stopAnimations(); return }
        needsLayout = true
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.updatePointer()
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in self?.updatePointer() }
        updateMousePassthrough()
    }

    override func layout() {
        super.layout()
        guard let geometry = currentGeometry else { return }
        scrolling.frame = backingAlignedRect(geometry.viewportRect, options: [.alignAllEdgesOutward])
        scrolling.layoutSubtreeIfNeeded()
        let clip = scrolling.contentView.bounds.size
        let proposed = geometry.documentSize
        let overflow = geometry.scrollRange > 0.001
        scrolling.allowsHorizontalScrolling = overflow
        if geometry.edge.isHorizontal {
            document.frame.size = NSSize(width: overflow ? max(proposed.width, clip.width) : clip.width, height: clip.height)
        } else {
            document.frame.size = NSSize(width: clip.width, height: overflow ? max(proposed.height, clip.height) : clip.height)
        }
        if !overflow, scrolling.contentView.bounds.origin != .zero { scrolling.contentView.scroll(to: .zero) }
        let bodyInDocument = document.convert(backdropFrame, from: self)
        emptyLabel?.frame = NSRect(x: bodyInDocument.minX + 6, y: bodyInDocument.midY - 9,
                                  width: max(20, bodyInDocument.width - 12), height: 18)
        refreshResizeCursors()
    }

    func populate(entries: [DockEntry], groupID: UUID? = nil, store: AppStore, maxWidth: CGFloat,
                  presentation supplied: DockPresentation? = nil, configure: (DockTile) -> Void) -> NSSize {
        cancelResize()
        stopAnimations()
        document.subviews.forEach { $0.removeFromSuperview() }
        tiles = []; divider = nil; emptyLabel = nil
        containerLayout = nil
        interactionDepth = 0
        waitingForMouseRelease = false
        isGroup = groupID != nil
        var resolved = supplied ?? store.presentation(for: nil, group: isGroup)
        resolved.maximumLength = min(resolved.maximumLength, max(1, maxWidth))
        presentation = resolved
        dividerIndex = !isGroup && store.pinnedCount > 0 && store.pinnedCount < entries.count ? store.pinnedCount : nil
        for entry in entries {
            let tile = DockTile(entry: entry, groupID: groupID, store: store, size: resolved.style.iconSize)
            tile.onInteractionChanged = { [weak self] active in self?.interactionChanged(active) }
            configure(tile)
            document.addSubview(tile)
            tiles.append(tile)
        }
        if dividerIndex != nil {
            let line = NSBox(); line.boxType = .separator
            document.addSubview(line); divider = line
        }
        if entries.isEmpty {
            let label = NSTextField(labelWithString: isGroup ? "将应用拖到这里" : "拖入应用，开始整理")
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 11)
            label.alignment = .center
            document.addSubview(label); emptyLabel = label
        }
        return installBaseGeometry(preservingOffset: 0)
    }

    /// Geometry-only update: keep existing tiles and the active resize gesture alive.
    @discardableResult
    func updatePresentation(_ value: DockPresentation) -> NSSize {
        let offset = scrollOffset
        if value.edge != presentation?.edge || !value.canResize { cancelResize() }
        stopAnimations()
        presentation = value
        return installBaseGeometry(preservingOffset: offset)
    }

    private func installBaseGeometry(preservingOffset offset: CGFloat) -> NSSize {
        let base = makeGeometry(focus: nil, offset: offset)
        baseGeometry = base; currentGeometry = base; targetGeometry = base
        apply(base)
        let point = base.scrollOrigin(forCanonicalOffset: offset, actualDocumentSize: document.frame.size,
                                      actualViewportSize: scrolling.contentView.bounds.size)
        scrolling.contentView.scroll(to: point)
        scrolling.reflectScrolledClipView(scrolling.contentView)
        return base.canvasSize
    }

    func stopAnimations() {
        displayLink?.invalidate(); displayLink = nil; animationTarget = nil
        animationTiming.pause(); focusIndex = nil; lensAnchor = nil; lastMousePoint = nil
        changeHoveredIndex(nil)
    }

    func resetMagnification() {
        if resizeSession != nil { cancelResize() }
        stopAnimations(); interactionDepth = 0; waitingForMouseRelease = false
        guard let baseGeometry else { return }
        currentGeometry = baseGeometry; targetGeometry = baseGeometry; apply(baseGeometry)
    }

    override func mouseEntered(with event: NSEvent) { updatePointer(); updateResizeCursor() }
    override func mouseMoved(with event: NSEvent) { updatePointer(); updateResizeCursor() }
    override func cursorUpdate(with event: NSEvent) { updateResizeCursor() }

    private func updateResizeCursor() {
        guard let window else { return }
        if pointerIsOccluded?(NSEvent.mouseLocation) == true {
            if ownsResizeCursor { NSCursor.arrow.set(); ownsResizeCursor = false }
            return
        }
        let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        if let handle = resizeSession?.handle ?? resizeHandle(at: local), let edge = presentation?.edge {
            DockResizeCursor.cursor(for: handle, edge: edge).set()
            ownsResizeCursor = true
        } else if ownsResizeCursor {
            NSCursor.arrow.set()
            ownsResizeCursor = false
        }
    }
    override func mouseExited(with event: NSEvent) {
        guard interactionDepth == 0, resizeSession == nil, let window else { return }
        updateResizeCursor()
        let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        if !bounds.contains(local) { updatePointer(force: true) }
    }

    func containsInteractivePoint(_ point: NSPoint) -> Bool {
        backdropFrame.contains(point) || interactionTileIndex(at: point) != nil || resizeHandle(at: point) != nil
    }

    private func tileIndex(at local: NSPoint) -> Int? {
        guard scrolling.frame.contains(local), let geometry = currentGeometry else { return nil }
        let point = document.convert(local, from: self)
        return geometry.tileFrames.firstIndex { $0.contains(point) }
    }

    private func interactionTileIndex(at local: NSPoint) -> Int? {
        guard let index = tileIndex(at: local) else { return nil }
        if backdropFrame.contains(local) { return index }
        let tile = tiles[index]
        return tile.visualIconBounds.contains(tile.convert(local, from: self)) ? index : nil
    }

    func updateMousePassthrough() { updateMousePassthrough(at: NSEvent.mouseLocation) }
    func updateMousePassthrough(at global: NSPoint) {
        guard resizeSession == nil, interactionDepth == 0, let window else { return }
        if pointerIsOccluded?(global) == true { window.ignoresMouseEvents = true; return }
        let local = convert(window.convertPoint(fromScreen: global), from: nil)
        window.ignoresMouseEvents = !containsInteractivePoint(local)
    }
    private func removeMouseMonitors() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil; globalMouseMonitor = nil
    }
    deinit {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard containsInteractivePoint(local) else { return nil }
        if resizeHandle(at: local) != nil { return self }
        if let index = interactionTileIndex(at: local) { return tiles[index] }
        return self
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { document.draggingEntered(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { document.draggingUpdated(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { document.draggingExited(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { document.prepareForDragOperation(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { document.performDragOperation(sender) }
    override func scrollWheel(with event: NSEvent) { if resizeSession == nil { scrolling.scrollWheel(with: event) } }
    override func rightMouseDown(with event: NSEvent) { showContextMenu(event) }

    private func resizeHandle(at local: NSPoint) -> DockResizeHandle? {
        guard !isGroup, let p = presentation, p.canResize, onResizeEnded != nil,
              resizeInteractionAllowed?() != false else { return nil }
        return DockResizePolicy.handle(at: local, backdrop: backdropFrame, edge: p.edge,
                                       edgeBand: 6, cornerBand: max(16, min(32, p.style.barThickness * 0.56)))
    }

    func refreshResizeCursors() {
        guard let p = presentation else { return }
        let state = CursorLayout(frame: backdropFrame, edge: p.edge,
            enabled: !isGroup && p.canResize && onResizeEnded != nil && resizeInteractionAllowed?() != false)
        guard state != cursorLayout else { return }
        cursorLayout = state
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !isGroup, let p = presentation, p.canResize, onResizeEnded != nil,
              resizeInteractionAllowed?() != false else { return }
        let body = backdropFrame
        let length = p.edge.isHorizontal ? body.width : body.height
        let depth = p.edge.isHorizontal ? body.height : body.width
        let transform = DockAxisTransform(edge: p.edge, length: length, thickness: depth)
        let corner: CGFloat = max(8, min(16, depth * 0.28))
        let regions: [(DockResizeHandle, CGRect)] = [
            (.leading, CGRect(x: -3, y: 0, width: 6, height: depth)),
            (.trailing, CGRect(x: length - 3, y: 0, width: 6, height: depth)),
            (.inward, CGRect(x: 0, y: depth - 3, width: length, height: 6)),
            (.leadingCorner, CGRect(x: -corner, y: depth - corner, width: corner * 2, height: corner * 2)),
            (.trailingCorner, CGRect(x: length - corner, y: depth - corner, width: corner * 2, height: corner * 2))
        ]
        for (handle, canonical) in regions {
            let rect = transform.rectToPhysical(canonical).offsetBy(dx: body.minX, dy: body.minY).intersection(bounds)
            if !rect.isEmpty { addCursorRect(rect, cursor: DockResizeCursor.cursor(for: handle, edge: p.edge)) }
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { showContextMenu(event); return }
        guard let window, let p = presentation else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let local = convert(event.locationInWindow, from: nil)
        guard let handle = resizeHandle(at: local) else { return }
        let clickTile = interactionTileIndex(at: local).map { tiles[$0] }.flatMap { tile in
            tile.visualIconBounds.contains(tile.convert(local, from: self)) ? tile : nil
        }
        resizeSession = ResizeSession(point: point, handle: handle, edge: p.edge,
            sizing: p.requestedManualSizing, bounds: p.resizeBounds, clickTile: clickTile,
            proposed: p.requestedManualSizing)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var session = resizeSession else { return }
        let point = NSEvent.mouseLocation
        let delta = CGSize(width: point.x - session.point.x, height: point.y - session.point.y)
        guard session.started || hypot(delta.width, delta.height) >= 2 else { return }
        if !session.started {
            session.started = true; resizeSession = session
            interactionChanged(true)
            onResizeBegan?()
        }
        guard resizeSession != nil else { return }
        session.proposed = DockResizePolicy.propose(start: session.sizing, handle: session.handle,
                                                   edge: session.edge, screenDelta: delta, bounds: session.bounds)
        resizeSession = session
        DockResizeCursor.cursor(for: session.handle, edge: session.edge).set()
        ownsResizeCursor = true
        onResizeChanged?(session.proposed)
    }

    override func mouseUp(with event: NSEvent) {
        guard let session = resizeSession else { return }
        resizeSession = nil
        if session.started {
            onResizeEnded?(session.proposed)
            interactionChanged(false)
            updateResizeCursor()
            window?.invalidateCursorRects(for: self)
        } else if let tile = session.clickTile, let window {
            let local = tile.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            if tile.visualIconBounds.contains(local) { tile.onPress?() }
        }
    }

    func cancelResize() {
        guard let session = resizeSession else { return }
        resizeSession = nil
        if session.started {
            onResizeEnded?(nil)
            interactionDepth = max(0, interactionDepth - 1)
            NSCursor.arrow.set()
            ownsResizeCursor = false
            window?.invalidateCursorRects(for: self)
        }
    }

    private func showContextMenu(_ event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        // Resize handles take hit-testing priority, but secondary clicks on
        // an icon crossing that edge still belong to the application menu.
        if let index = interactionTileIndex(at: local) {
            tiles[index].rightMouseDown(with: event)
            return
        }
        guard backdropFrame.contains(local), settingsAction != nil else { return }
        interactionChanged(true); defer { interactionChanged(false) }
        let menu = NSMenu()
        menu.addAction("DualDock 设置…") { [weak self] in self?.settingsAction?() }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func makeGeometry(focus: CGFloat?, offset: CGFloat? = nil) -> DockGeometry {
        guard let p = presentation else {
            return .make(count: 0, edge: .bottom,
                         style: .init(iconSize: 48, barThickness: 66, gap: 14, leadingPadding: 6, trailingPadding: 6), maximumLength: 240)
        }
        return .make(count: tiles.count, edge: p.edge, style: p.style, maximumLength: p.maximumLength,
                     fixedLength: p.fixedLength, focusIndex: focus, dividerIndex: dividerIndex,
                     scrollOffset: offset ?? scrollOffset, lensAnchor: lensAnchor, resizeMargin: p.resizeMargin)
    }

    private func updatePointer(force: Bool = false) {
        guard window?.isVisible == true else { return }
        updatePointer(at: NSEvent.mouseLocation, buttonsPressed: NSEvent.pressedMouseButtons != 0, force: force)
    }
    func updatePointer(at global: NSPoint, buttonsPressed: Bool, force: Bool = false) {
        guard resizeSession == nil, interactionDepth == 0, let window, let geometry = currentGeometry else { return }
        updateMousePassthrough(at: global)
        if pointerIsOccluded?(global) == true { pauseForPointerOcclusion(); return }
        if buttonsPressed {
            if focusIndex != nil || baseGeometry.map({ geometry.maximumDifference(from: $0) > 0.08 }) == true {
                waitingForMouseRelease = true; startAnimation()
            }
            return
        }
        if !force, let previous = lastMousePoint, hypot(global.x - previous.x, global.y - previous.y) < 0.05 { return }
        lastMousePoint = global
        let local = convert(window.convertPoint(fromScreen: global), from: nil)
        if resizeHandle(at: local) != nil {
            // Cursor feedback only; do not collapse or grow icons while the
            // pointer is aiming at a resize edge.
            changeHoveredIndex(nil); displayLink?.isPaused = true; animationTiming.pause()
            return
        }
        changeHoveredIndex(tileIndex(at: local))
        if !isGroup, (presentation?.style.magnificationScale ?? 1) > 1,
           scrolling.frame.contains(local), let baseGeometry {
            let point = document.convert(local, from: self)
            focusIndex = geometry.magnificationFocus(at: point, basedOn: baseGeometry)
            lensAnchor = focusIndex == nil ? nil : geometry.documentPointToCanonical(point).x
        } else { focusIndex = nil; lensAnchor = nil }
        let next = makeGeometry(focus: focusIndex)
        guard targetGeometry != next || geometry.maximumDifference(from: next) > 0.08 else { return }
        targetGeometry = next; startAnimation()
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
        if active { displayLink?.isPaused = true; animationTiming.pause(); changeHoveredIndex(nil) }
        else if interactionDepth == 0 { updatePointer(force: true); startAnimation() }
    }
    private func startAnimation() {
        guard interactionDepth == 0, window != nil else { return }
        if isGroup || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            if let targetGeometry { currentGeometry = targetGeometry; apply(targetGeometry) }
            displayLink?.isPaused = true; animationTiming.pause(); return
        }
        if displayLink == nil {
            let proxy = DockAnimationTarget(self); animationTarget = proxy
            let link = self.displayLink(target: proxy, selector: #selector(DockAnimationTarget.tick(_:)))
            link.add(to: .main, forMode: .common); displayLink = link
        }
        animationTiming.resume(); displayLink?.isPaused = false
    }
    fileprivate func animationTick(_ link: CADisplayLink) {
        advanceAnimation(at: link.timestamp, pointer: NSEvent.mouseLocation,
                         buttonsPressed: NSEvent.pressedMouseButtons != 0)
    }

    /// The display-link callback supplies time and input explicitly so animation
    /// frames can also be replayed without sending events to the desktop.
    func advanceAnimation(at timestamp: TimeInterval, pointer: NSPoint, buttonsPressed: Bool) {
        guard resizeSession == nil, interactionDepth == 0, let geometry = currentGeometry, let targetGeometry else {
            displayLink?.isPaused = true; animationTiming.pause(); return
        }
        if pointerIsOccluded?(pointer) == true { pauseForPointerOcclusion(); updateMousePassthrough(at: pointer); return }
        if buttonsPressed { waitingForMouseRelease = true; animationTiming.pause(); return }
        if waitingForMouseRelease {
            waitingForMouseRelease = false
            updatePointer(at: pointer, buttonsPressed: false, force: true)
            return
        }
        let fraction = animationTiming.fraction(at: timestamp, returningToRest: focusIndex == nil)
        let remaining = geometry.maximumDifference(from: targetGeometry)
        let next = remaining < 0.08 ? targetGeometry : geometry.interpolated(to: targetGeometry, fraction: fraction)
        currentGeometry = next; apply(next, pointer: pointer)
        if remaining < 0.08 { displayLink?.isPaused = true; animationTiming.pause(); refreshHoveredIndex(at: pointer) }
    }
    private func refreshHoveredIndex(at global: NSPoint = NSEvent.mouseLocation) {
        guard resizeSession == nil, interactionDepth == 0, let window else { return }
        if pointerIsOccluded?(global) == true { pauseForPointerOcclusion(); updateMousePassthrough(); return }
        let local = convert(window.convertPoint(fromScreen: global), from: nil)
        changeHoveredIndex(resizeHandle(at: local) == nil ? tileIndex(at: local) : nil)
        updateMousePassthrough()
    }
    private func pauseForPointerOcclusion() {
        displayLink?.isPaused = true; animationTiming.pause(); lastMousePoint = nil; changeHoveredIndex(nil)
    }
    private func apply(_ value: DockGeometry, pointer: NSPoint? = nil) {
        let container = ContainerLayout(canvasSize: value.canvasSize, documentSize: value.documentSize,
            viewport: value.viewportRect, backdrop: value.backdropRect, thickness: value.barThickness)
        let containerChanged = containerLayout != container
        if containerChanged {
            containerLayout = container
            frame.size = value.canvasSize
            backdrop.frame = value.backdropRect
            backdrop.layer?.cornerRadius = min(18, value.barThickness * 0.28)
        }
        let frames = value.tileFrames, icons = value.iconFrames, dots = value.dotFrames
        for index in tiles.indices {
            tiles[index].applyGeometry(frame: frames[index], iconFrame: icons[index], dotFrame: dots[index],
                                       baseIconSize: presentation?.style.iconSize ?? 48, edge: value.edge)
        }
        divider?.frame = value.dividerFrame ?? .zero
        desiredWidth = value.bodyLength
        if containerChanged {
            needsLayout = true
            layoutSubtreeIfNeeded()
            scrolling.reflectScrolledClipView(scrolling.contentView)
        }
        updateMousePassthrough(at: pointer ?? NSEvent.mouseLocation)
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
