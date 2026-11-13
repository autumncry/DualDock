import AppKit
import Combine
import QuartzCore
import DualDockCore

@MainActor
final class DisplayCoordinator {
    struct ScreenDock {
        let screen: NSScreen
        let displayID: String
        let panel: DockPanel
        let strip: DockStripView
    }
    let store: AppStore
    private let presentsPanels: Bool
    var showSettings: (() -> Void)?
    private(set) var docks: [CGDirectDisplayID: ScreenDock] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var poll: Timer?
    private var visibility: DockVisibilityController?
    private var previewTask: Task<Void, Never>?
    private weak var previewSource: DockTile?
    private var previewGeneration = 0
    private var pendingPreviewScreen: CGDirectDisplayID?
    private var previewPanel: DockPanel?
    private var groupPanel: DockPanel?
    private var popupScreen: CGDirectDisplayID?
    private var popupAnchor = NSRect.zero
    private var groupEdge: DockEdge = .bottom
    private var previewEdge: DockEdge = .bottom
    private var previewAnchor = NSRect.zero
    private var geometryRefreshScheduled = false
    private var renderedEntries: [DockEntry] = []
    private var renderedPinnedCount = 0
    private var renderedMode: DockMode?
    private var renderedShowBadges: Bool?
    private var renderedHideSystemDock: Bool?
    private var tileAppearanceNeedsRefresh = false
    private var stopped = false
    private var pointerOutsideSince: Date?
    private var contextMenuTracking = false
    private var menuTrackingObserver: MenuTrackingObserver?

    /// Hidden coordinators exercise the real update pipeline without presenting UI.
    init(store: AppStore, presentsPanels: Bool = true) {
        self.store = store
        self.presentsPanels = presentsPanels
        store.$configuration.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.scheduleGeometryRefresh()
        }.store(in: &subscriptions)
        store.$runningApps.dropFirst().sink { [weak self] _ in
            self?.tileAppearanceNeedsRefresh = true
            self?.scheduleGeometryRefresh()
        }.store(in: &subscriptions)
        store.$badgeLabels.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.redrawBadges() }
        }.store(in: &subscriptions)
        store.$nativeDockMetrics.dropFirst().sink { [weak self] _ in
            guard let self, self.store.configuration.adaptiveSizing else { return }
            self.scheduleGeometryRefresh()
        }.store(in: &subscriptions)
        store.$resizeRevision.dropFirst().sink { [weak self] _ in
            self?.scheduleGeometryRefresh()
        }.store(in: &subscriptions)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.dismissPopups(); self?.refreshDisplays() }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismissPopups() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, !self.contextMenuTracking, event.window !== self.groupPanel && event.window !== self.previewPanel && !self.docks.values.contains(where: { $0.panel === event.window }) {
                self.dismissPopups()
            }
            return event
        }
        let poll = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(poll, forMode: .common)
        self.poll = poll
        visibility = DockVisibilityController(windows: store.windows,
            targets: { [weak self] in self?.visibilityTargets() ?? [] },
            autoHide: { [weak self] in self?.store.configuration.autoHideWhenMaximized ?? false },
            apply: { [weak self] hidden in self?.applyVisibility(hidden: hidden) })
        refreshDisplays()
    }

    func refreshDisplays() {
        guard !stopped else { return }
        docks.values.forEach { $0.strip.cancelResize() }
        dismissPopups()
        let allScreens = NSScreen.screens
        let info = DockDisplayInfo.current()
        store.updateDisplays(info)
        let screens = allScreens.filter { CGDisplayMirrorsDisplay(Self.id($0)) == kCGNullDirectDisplay }
        let entries = store.displayedEntries
        let valid = Set(screens.map(Self.id))
        for id in Array(docks.keys) where !valid.contains(id) {
            if let removed = docks.removeValue(forKey: id) {
                removed.strip.stopAnimations()
                removed.panel.close()
            }
        }
        for screen in screens {
            let id = Self.id(screen)
            guard let display = info.first(where: { $0.runtimeID == id }) else { continue }
            let presentation = store.presentation(for: display.id)
            let old = docks[id]
            let panel = old?.panel ?? DockPanel()
            // A shadow on the transparent canvas also outlines magnified icons.
            // Floating group/preview panels retain their own normal shadow.
            panel.hasShadow = false
            let strip = old?.strip ?? DockStripView()
            panel.title = "DualDock · \(screen.localizedName)"
            strip.pointerIsOccluded = { [weak self] point in
                self?.pointerIsOverPopup(point, includeGroup: true) ?? false
            }
            strip.settingsAction = { [weak self] in self?.dismissPopups(); self?.showSettings?() }
            strip.resizeInteractionAllowed = { [weak self] in
                guard let self else { return false }
                return self.groupPanel == nil && self.previewPanel == nil && !self.contextMenuTracking
            }
            strip.onResizeBegan = { [weak self] in self?.dismissPopups() }
            strip.onResizeChanged = { [weak self] value in self?.store.setResizePreview(value, for: display.id) }
            strip.onResizeEnded = { [weak self] value in
                guard let self else { return }
                if let value { self.store.commitManualResize(value, for: display.id) }
                else { self.store.setResizePreview(nil, for: display.id) }
            }
            strip.document.onDropAtEnd = { [weak self] info in self?.handleDrop(info, target: nil, groupID: nil, merge: false, after: false) ?? false }
            _ = strip.populate(entries: entries, store: store, maxWidth: presentation.maximumLength,
                               presentation: presentation) { [weak self] tile in
                self?.configure(tile, on: screen, displayID: display.id, edge: presentation.edge)
            }
            panel.contentView = strip
            panel.placeDock(strip, in: display.visibleFrame, display: true)
            strip.updateMousePassthrough()
            docks[id] = ScreenDock(screen: screen, displayID: display.id, panel: panel, strip: strip)
        }
        renderedEntries = entries
        renderedPinnedCount = store.pinnedCount
        renderedMode = store.configuration.mode
        renderedShowBadges = store.configuration.showBadges
        renderedHideSystemDock = store.configuration.hideSystemDock
        tileAppearanceNeedsRefresh = false
        visibility?.invalidate()
    }

    private func scheduleGeometryRefresh() {
        guard !stopped, !geometryRefreshScheduled else { return }
        geometryRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.geometryRefreshScheduled = false
            // Configuration publishes before its assignment finishes. Read the
            // final value once on the next main-loop turn, coalescing a burst of
            // slider samples and the resize-preview/configuration handoff.
            let entries = self.store.displayedEntries
            let presentations = self.docks.mapValues { self.store.presentation(for: $0.displayID) }
            let structureChanged = self.renderedEntries != entries
                || self.renderedPinnedCount != self.store.pinnedCount
                || self.renderedMode != self.store.configuration.mode
                || self.renderedHideSystemDock != self.store.configuration.hideSystemDock
                || self.docks.contains { id, dock in
                    dock.strip.presentation?.edge != presentations[id]?.edge
                }
            if structureChanged {
                // Entry identity/order and edge changes require new callbacks;
                // real display topology changes still call refreshDisplays().
                self.refreshDisplays()
                return
            }
            let changedDocks = self.docks.filter { id, dock in dock.strip.presentation != presentations[id] }
            if !changedDocks.isEmpty { self.dismissPopups() }
            else if !self.store.configuration.showPreviews { self.dismissPreview() }
            // Place the panels and their content in one transaction. Drawing is
            // left to AppKit's next display pass, rather than synchronously
            // forcing a display for every slider or pointer sample.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for (id, dock) in changedDocks {
                    guard let display = self.store.displays.first(where: { $0.id == dock.displayID }),
                          let presentation = presentations[id] else { continue }
                    _ = dock.strip.updatePresentation(presentation)
                    dock.panel.placeDock(dock.strip, in: display.visibleFrame, display: false)
                    dock.strip.layoutSubtreeIfNeeded()
                    dock.strip.updateMousePassthrough()
                }
                CATransaction.commit()
            }
            if self.tileAppearanceNeedsRefresh || self.renderedShowBadges != self.store.configuration.showBadges {
                self.redrawBadges()
                self.tileAppearanceNeedsRefresh = false
                self.renderedShowBadges = self.store.configuration.showBadges
            }
            self.visibility?.refresh(force: true)
        }
    }

    func resetMagnification() {
        dismissPopups()
        docks.values.forEach { $0.strip.resetMagnification() }
    }

    private func redrawBadges() {
        docks.values.forEach { dock in dock.strip.tiles.forEach { $0.refreshBadge() } }
        (groupPanel?.contentView as? DockStripView)?.tiles.forEach { $0.refreshBadge() }
    }

    static func id(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    func stop() {
        stopped = true
        poll?.invalidate()
        visibility?.stop()
        visibility = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        subscriptions.removeAll()
        dismissPopups()
        docks.values.forEach { $0.strip.cancelResize(); $0.strip.stopAnimations(); $0.panel.close() }
        docks.removeAll()
    }

    private func configure(_ tile: DockTile, on screen: NSScreen, displayID: String, edge: DockEdge) {
        tile.menuEdge = edge
        tile.onPress = { [weak self, weak tile] in
            guard let self, let tile else { return }
            if tile.entry.isGroup { self.openGroup(tile, screen: screen, displayID: displayID, edge: edge) }
            else if let app = tile.entry.apps.first { self.dismissPopups(); self.store.launch(app) }
        }
        tile.onHover = { [weak self, weak tile] inside in
            guard let self, let tile else { return }
            if inside { self.hover(tile, screen: screen, edge: edge) }
            else {
                // Monitors from different strips may report enter/leave in
                // either order. A stale main-strip leave must not cancel a
                // newer request from a member of the floating group.
                guard self.previewSource == nil || self.previewSource === tile else { return }
                if self.previewSource === tile { self.cancelPreviewRequest() }
                self.pointerOutsideSince = Date()
            }
        }
        tile.menuProvider = { [weak self, weak tile] in
            guard let self, let tile else { return NSMenu() }
            self.dismissPreview()
            return self.menu(for: tile)
        }
        tile.onDrop = { [weak self, weak tile] info, merge, after in
            guard let tile else { return false }
            return self?.handleDrop(info, target: tile.entry, groupID: tile.groupID, merge: merge, after: after) ?? false
        }
    }

    private func tileRect(_ tile: DockTile) -> NSRect {
        tile.window?.convertToScreen(tile.convert(tile.visualIconBounds, to: nil)) ?? .zero
    }

    private func interactionRect(_ tile: DockTile) -> NSRect {
        tile.window?.convertToScreen(tile.convert(tile.visibleRect, to: nil)) ?? .zero
    }

    private func openGroup(_ tile: DockTile, screen: NSScreen, displayID: String, edge: DockEdge) {
        dismissPopups()
        let strip = DockStripView()
        strip.pointerIsOccluded = { [weak self] point in
            self?.pointerIsOverPopup(point, includeGroup: false) ?? false
        }
        let members = tile.entry.apps.map { DockEntry(name: $0.name, apps: [$0]) }
        let presentation = store.presentation(for: displayID, group: true)
        let size = strip.populate(entries: members, groupID: tile.entry.id, store: store,
                                  maxWidth: presentation.maximumLength, presentation: presentation) { [weak self] child in
            self?.configure(child, on: screen, displayID: displayID, edge: edge)
        }
        strip.document.onDropAtEnd = { [weak self] info in
            self?.handleDrop(info, target: nil, groupID: tile.entry.id, merge: true, after: true) ?? false
        }
        let panel = DockPanel()
        panel.title = "应用组 · \(tile.entry.name)"
        panel.level = .popUpMenu
        panel.contentView = strip
        popupAnchor = tileRect(tile)
        groupEdge = edge
        popupScreen = Self.id(screen)
        panel.setFrame(popupFrame(size: size, anchor: popupAnchor, screen: screen, edge: edge), display: true)
        strip.updateMousePassthrough()
        groupPanel = panel
        if presentsPanels { panel.orderFrontRegardless() }
        refreshMousePassthrough()
        pointerOutsideSince = nil
    }

    private func hover(_ tile: DockTile, screen: NSScreen, edge: DockEdge) {
        // A higher popup owns the pointer even if a lower transparent Dock
        // canvas also geometrically contains that screen coordinate.
        guard !pointerIsOverPopup(NSEvent.mouseLocation, includeGroup: tile.groupID == nil) else { return }
        cancelPreviewRequest()
        pointerOutsideSince = nil
        guard !tile.entry.isGroup, store.configuration.showPreviews,
              let app = tile.entry.apps.first, store.isRunning(app) else { return }
        previewSource = tile
        // The previous popup must not cancel this new hover while its capture
        // is pending. Only a member's own group remains as its interaction area.
        previewPanel?.close()
        previewPanel = nil
        refreshMousePassthrough()
        let generation = previewGeneration
        pendingPreviewScreen = Self.id(screen)
        previewTask = Task { [weak self, weak tile] in
            do { try await Task.sleep(nanoseconds: 450_000_000) } catch { return }
            guard let self, let tile, !Task.isCancelled, generation == self.previewGeneration,
                  tile.window != nil, self.docks[Self.id(screen)]?.panel.isVisible == true,
                  self.interactionRect(tile).contains(NSEvent.mouseLocation),
                  !self.pointerIsOverPopup(NSEvent.mouseLocation, includeGroup: tile.groupID == nil) else { return }
            // Crossing a neighboring main-row icon on the way to a group
            // member is not an intent to dismiss the group. Reuse the preview
            // dwell, then retire the group before asynchronous capture starts.
            if tile.groupID == nil {
                (self.groupPanel?.contentView as? DockStripView)?.stopAnimations()
                self.groupPanel?.close()
                self.groupPanel = nil
                self.popupScreen = nil
                self.pointerOutsideSince = nil
                self.refreshMousePassthrough()
            }
            let previews = await self.store.windows.previews(for: app)
            guard !Task.isCancelled, generation == self.previewGeneration,
                  tile.window != nil,
                  self.docks[Self.id(screen)]?.panel.isVisible == true,
                  self.interactionRect(tile).contains(NSEvent.mouseLocation),
                  !self.pointerIsOverPopup(NSEvent.mouseLocation, includeGroup: tile.groupID == nil) else { return }
            self.pendingPreviewScreen = nil
            self.showPreview(previews, app: app, anchor: self.tileRect(tile), sourceRect: self.interactionRect(tile), screen: screen, edge: edge)
        }
    }

    private func showPreview(_ items: [WindowPreview], app: AppReference, anchor: NSRect, sourceRect: NSRect, screen: NSScreen, edge: DockEdge) {
        previewPanel?.close()
        previewPanel = nil
        let visibleItems = items.filter { $0.image != nil }
        let available = placementBounds(for: screen)
        guard let layout = PreviewStripLayout(itemCount: visibleItems.count,
                                               maxWidth: min(screen.frame.width - 40, available.width - 24)) else {
            if groupPanel == nil { popupScreen = nil }
            return
        }
        let panel = DockPanel()
        panel.title = "窗口预览 · \(app.name)"
        panel.level = .popUpMenu
        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        let title = NSTextField(labelWithString: app.name)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.frame = NSRect(x: layout.padding, y: 150, width: layout.viewportWidth, height: 20)
        background.addSubview(title)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        let document = NSView()
        for (index, item) in visibleItems.enumerated() {
            guard let image = item.image else { continue }
            let x = layout.cardOrigins[index]
            let card = WindowPreviewCardView(title: item.title.isEmpty ? app.name : item.title, image: image)
            card.frame.origin = NSPoint(x: x, y: 0)
            card.onActivate = { [weak self] in
                guard let self else { return }
                self.dismissPopups()
                _ = self.store.windows.activate(item)
                self.store.refreshPermissions()
            }
            card.onClose = { [weak self] in self?.closePreview(item, app: app) }
            document.addSubview(card)
        }
        document.frame = NSRect(x: 0, y: 0, width: layout.documentWidth, height: 140)
        scroll.documentView = document
        scroll.frame = NSRect(x: layout.padding, y: 8, width: layout.viewportWidth, height: 140)
        background.addSubview(scroll)
        let size = NSSize(width: layout.panelWidth, height: 182)
        background.frame.size = size
        panel.contentView = background
        // The group frame already contains its members. Keep its original
        // source anchor so the short transition bridge remains stable.
        if groupPanel == nil { popupAnchor = sourceRect }
        previewAnchor = anchor
        previewEdge = edge
        popupScreen = Self.id(screen)
        panel.setFrame(popupFrame(size: size, anchor: anchor, screen: screen, edge: edge), display: true)
        previewPanel = panel
        if presentsPanels { panel.orderFrontRegardless() }
        refreshMousePassthrough()
    }

    private func closePreview(_ item: WindowPreview, app: AppReference) {
        // A successful AXPress can open a save sheet instead of closing the
        // window. Dismiss the snapshot; a later hover always reads fresh state.
        dismissPopups()
        let result = store.windows.close(item, for: app)
        store.refreshPermissions()
        guard let message = result.message else { return }
        store.message = message
        let alert = NSAlert()
        alert.messageText = "无法关闭这个窗口"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func popupFrame(size: NSSize, anchor: NSRect, screen: NSScreen, edge: DockEdge) -> NSRect {
        DockPopupPlacement.frame(size: size, anchor: anchor, edge: edge, visibleScreen: placementBounds(for: screen))
    }

    private func placementBounds(for screen: NSScreen) -> NSRect {
        store.displays.first(where: { $0.runtimeID == Self.id(screen) })?.visibleFrame ?? screen.visibleFrame
    }

    private func pointerIsOverPopup(_ point: NSPoint, includeGroup: Bool) -> Bool {
        if let previewPanel, previewPanel.isVisible {
            if previewPanel.frame.contains(point) { return true }
            if DockPopupPlacement.bridge(source: previewAnchor, popup: previewPanel.frame, edge: previewEdge)?.contains(point) == true { return true }
        }
        if includeGroup, let groupPanel, groupPanel.isVisible {
            let frame = groupPanel.frame
            if frame.contains(point) { return true }
            if DockPopupPlacement.bridge(source: popupAnchor, popup: frame, edge: groupEdge)?.contains(point) == true { return true }
        }
        return false
    }

    private func refreshMousePassthrough() {
        docks.values.forEach { $0.strip.updateMousePassthrough(); $0.strip.refreshResizeCursors() }
        (groupPanel?.contentView as? DockStripView)?.updateMousePassthrough()
    }

    private func cancelPreviewRequest() {
        previewTask?.cancel()
        previewTask = nil
        previewSource = nil
        previewGeneration += 1
        pendingPreviewScreen = nil
    }

    private func dismissPreview() {
        cancelPreviewRequest()
        previewPanel?.close()
        previewPanel = nil
        refreshMousePassthrough()
        if groupPanel == nil { popupScreen = nil; pointerOutsideSince = nil }
    }

    func dismissPopups() {
        cancelPreviewRequest()
        (groupPanel?.contentView as? DockStripView)?.stopAnimations()
        groupPanel?.close(); groupPanel = nil
        previewPanel?.close(); previewPanel = nil
        refreshMousePassthrough()
        popupScreen = nil
        pointerOutsideSince = nil
    }

    private func tick() {
        guard !contextMenuTracking, NSEvent.pressedMouseButtons == 0, groupPanel != nil || previewPanel != nil else { return }
        var safe = popupAnchor
        if let groupPanel { safe = safe.union(groupPanel.frame) }
        if let previewPanel { safe = safe.union(previewPanel.frame) }
        if safe.insetBy(dx: -14, dy: -14).contains(NSEvent.mouseLocation) { pointerOutsideSince = nil }
        else if let since = pointerOutsideSince, Date().timeIntervalSince(since) > 0.35 { dismissPopups() }
        else if pointerOutsideSince == nil { pointerOutsideSince = Date() }
    }

    private func visibilityTargets() -> [DockVisibilityController.Target] {
        let pointer = NSEvent.mouseLocation
        return docks.map { id, dock in
            let local = dock.strip.convert(dock.panel.convertPoint(fromScreen: pointer), from: nil)
            let popupOpen = popupScreen == id && (groupPanel?.isVisible == true || previewPanel?.isVisible == true)
            return .init(id: id, screen: dock.screen, visibleFrame: placementBounds(for: dock.screen),
                edge: dock.strip.layoutGeometry?.edge ?? .bottom,
                backdrop: dock.panel.convertToScreen(dock.strip.convert(dock.strip.backdropFrame, to: nil)),
                pointerInside: dock.panel.isVisible && dock.strip.containsInteractivePoint(local),
                interacting: dock.strip.isInteracting || popupOpen)
        }
    }

    private func applyVisibility(hidden: Set<CGDirectDisplayID>) {
        guard presentsPanels else { return }
        for (id, dock) in docks {
            if hidden.contains(id) {
                if dock.panel.isVisible { dock.strip.resetMagnification() }
                dock.panel.orderOut(nil)
                if popupScreen == id || pendingPreviewScreen == id { dismissPopups() }
            } else if !dock.panel.isVisible {
                dock.panel.orderFrontRegardless()
                dock.strip.updateMousePassthrough()
            }
        }
    }

    private func handleDrop(_ info: NSDraggingInfo, target: DockEntry?, groupID: UUID?, merge: Bool, after: Bool) -> Bool {
        guard store.configuration.mode == .standard else { return false }
        let payload = DockDrag.read(info)
        let external = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).compactMap(AppStore.reference)
        if let payload, payload.appID == nil {
            guard groupID == nil else { return false }
            let before = insertionID(target: target, after: after)
            store.update { $0.moveEntry(id: payload.entryID, before: before) }
            return true
        }
        let known = store.configuration.entries.flatMap(\.apps) + store.runningApps
        let apps = payload?.appID.flatMap { id in known.first { $0.id == id }.map { [$0] } } ?? external
        guard !apps.isEmpty else { return false }
        let before = insertionID(target: target, after: after)
        store.update { config in
            config.insert(apps)
            if let groupID {
                let members = config.entries.first { $0.id == groupID }?.apps ?? []
                let targetID = target?.apps.first?.id
                var memberBefore = targetID
                if after, let targetID, let index = members.firstIndex(where: { $0.id == targetID }) {
                    memberBefore = index + 1 < members.count ? members[index + 1].id : nil
                }
                for app in apps {
                    config.merge(appID: app.id, into: groupID)
                    config.moveMember(id: app.id, before: memberBefore, groupID: groupID)
                }
            } else if merge, let target {
                if !config.entries.contains(where: { $0.id == target.id }), let targetApp = target.apps.first { config.insert([targetApp]) }
                let targetID = config.entries.first { $0.id == target.id || (!target.isGroup && $0.apps.first?.id == target.apps.first?.id) }?.id
                if let targetID { for app in apps { config.merge(appID: app.id, into: targetID) } }
            } else {
                for app in apps {
                    config.moveAppOut(appID: app.id, before: before)
                    if let entry = config.entries.first(where: { !$0.isGroup && $0.apps.first?.id == app.id }) { config.moveEntry(id: entry.id, before: before) }
                }
            }
        }
        return true
    }

    private func insertionID(target: DockEntry?, after: Bool) -> UUID? {
        guard let target, let index = store.configuration.entries.firstIndex(where: { $0.id == target.id }) else { return nil }
        if !after { return target.id }
        return index + 1 < store.configuration.entries.count ? store.configuration.entries[index + 1].id : nil
    }

    private func menu(for tile: DockTile) -> NSMenu {
        let menu = NSMenu()
        let observer = MenuTrackingObserver(
            opened: { [weak self] in self?.contextMenuTracking = true },
            closed: { [weak self] in self?.contextMenuTracking = false }
        )
        menuTrackingObserver = observer
        menu.delegate = observer
        if tile.entry.isGroup {
            menu.addAction("重命名应用组…") { [weak self] in self?.rename(tile.entry) }
            menu.addAction("展开为独立应用") { [weak self] in self?.store.update { $0.ungroup(id: tile.entry.id) } }
            menu.addAction("打开组内全部应用") { [weak self] in tile.entry.apps.forEach { self?.store.launch($0) } }
            menu.addItem(.separator())
            menu.addAction("移除应用组") { [weak self] in self?.store.update { $0.removeEntry(id: tile.entry.id) } }
        } else if let app = tile.entry.apps.first {
            menu.addAction("打开 \(app.name)") { [weak self] in self?.store.launch(app) }
            if store.configuration.allAppIDs.contains(app.id) {
                if tile.groupID != nil { menu.addAction("移出应用组") { [weak self] in self?.store.update { $0.moveAppOut(appID: app.id) } } }
                menu.addAction("从 Dock 移除") { [weak self] in self?.store.update { $0.removeApp(id: app.id) } }
            } else { menu.addAction("固定到 Dock") { [weak self] in self?.store.update { $0.insert([app]) } } }
            menu.addAction("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }
            if store.isRunning(app) { menu.addItem(.separator()); menu.addAction("退出 \(app.name)") { [weak self] in self?.store.quit(app) } }
        }
        return menu
    }

    private func rename(_ entry: DockEntry) {
        dismissPopups()
        let alert = NSAlert()
        alert.messageText = "应用组名称"
        let field = NSTextField(string: entry.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { store.update { $0.renameGroup(id: entry.id, name: field.stringValue) } }
    }
}

@MainActor
private final class MenuTrackingObserver: NSObject, NSMenuDelegate {
    private let opened: () -> Void
    private let closed: () -> Void

    init(opened: @escaping () -> Void, closed: @escaping () -> Void) {
        self.opened = opened
        self.closed = closed
    }

    func menuWillOpen(_ menu: NSMenu) { opened() }
    func menuDidClose(_ menu: NSMenu) { closed() }
}
