import AppKit
import Combine
import DualDockCore

@MainActor
final class DisplayCoordinator {
    struct ScreenDock {
        let screen: NSScreen
        let panel: DockPanel
        let strip: DockStripView
    }
    let store: AppStore
    var showSettings: (() -> Void)?
    private(set) var docks: [CGDirectDisplayID: ScreenDock] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var poll: Timer?
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = 0
    private var pendingPreviewScreen: CGDirectDisplayID?
    private var previewPanel: DockPanel?
    private var groupPanel: DockPanel?
    private var popupScreen: CGDirectDisplayID?
    private var popupAnchor = NSRect.zero
    private var pointerOutsideSince: Date?
    private var previewActions: [MenuAction] = []
    private var contextMenuTracking = false
    private var menuTrackingObserver: MenuTrackingObserver?

    init(store: AppStore) {
        self.store = store
        store.$configuration.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.dismissPopups(); self?.refreshDisplays() }
        }.store(in: &subscriptions)
        store.$runningApps.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshDisplays() }
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
        poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        refreshDisplays()
    }

    func refreshDisplays() {
        dismissPopups()
        let screens = NSScreen.screens.filter { CGDisplayMirrorsDisplay(Self.id($0)) == kCGNullDirectDisplay }
        let valid = Set(screens.map(Self.id))
        for id in Array(docks.keys) where !valid.contains(id) {
            if let removed = docks.removeValue(forKey: id) {
                removed.strip.stopAnimations()
                removed.panel.close()
            }
        }
        for screen in screens {
            let id = Self.id(screen)
            let old = docks[id]
            let panel = old?.panel ?? DockPanel()
            let strip = old?.strip ?? DockStripView()
            panel.title = "DualDock · \(screen.localizedName)"
            strip.onGeometryChange = { [weak self] size, focusX in
                self?.resizeDock(id: id, size: size, focusX: focusX) ?? 0
            }
            strip.settingsAction = { [weak self] in self?.dismissPopups(); self?.showSettings?() }
            strip.modeAction = { [weak self] in self?.store.update { $0.mode = $0.mode == .standard ? .runningOnly : .standard } }
            strip.document.onDropAtEnd = { [weak self] info in self?.handleDrop(info, target: nil, groupID: nil, merge: false, after: false) ?? false }
            let size = strip.populate(entries: store.displayedEntries, store: store, maxWidth: screen.frame.width - 32) { [weak self] tile in self?.configure(tile, on: screen) }
            panel.contentView = strip
            // Respect the native Dock's reserved edge while the user keeps it visible.
            let nativeInset = max(0, screen.visibleFrame.minY - screen.frame.minY)
            let y = screen.frame.minY + (store.configuration.hideSystemDock ? 8 : max(8, nativeInset + 6))
            panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: y, width: size.width, height: size.height), display: true)
            docks[id] = ScreenDock(screen: screen, panel: panel, strip: strip)
        }
        applyFullscreenState()
    }

    private func resizeDock(id: CGDirectDisplayID, size: NSSize, focusX: CGFloat?) -> CGFloat {
        guard let dock = docks[id], size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return 0 }
        let screen = dock.screen.frame
        let desiredX = focusX.map { NSEvent.mouseLocation.x - $0 } ?? (screen.midX - size.width / 2)
        let x = min(max(desiredX, screen.minX + 16), max(screen.minX + 16, screen.maxX - size.width - 16))
        let frame = NSRect(x: x, y: dock.panel.frame.minY, width: size.width, height: size.height)
        if dock.panel.frame != frame { dock.panel.setFrame(frame, display: true) }
        return dock.panel.frame.minX - desiredX
    }

    func resetMagnification() {
        dismissPopups()
        docks.values.forEach { $0.strip.resetMagnification() }
    }

    static func id(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    func stop() {
        poll?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        subscriptions.removeAll()
        dismissPopups()
        docks.values.forEach { $0.strip.stopAnimations(); $0.panel.close() }
        docks.removeAll()
    }

    private func configure(_ tile: DockTile, on screen: NSScreen) {
        tile.onPress = { [weak self, weak tile] in
            guard let self, let tile else { return }
            if tile.entry.isGroup { self.openGroup(tile, screen: screen) }
            else if let app = tile.entry.apps.first { self.dismissPopups(); self.store.launch(app) }
        }
        tile.onHover = { [weak self, weak tile] inside in
            guard let self, let tile else { return }
            if inside { self.hover(tile, screen: screen) }
            else { self.cancelPreviewRequest(); self.pointerOutsideSince = Date() }
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

    private func openGroup(_ tile: DockTile, screen: NSScreen) {
        dismissPopups()
        let strip = DockStripView()
        let members = tile.entry.apps.map { DockEntry(name: $0.name, apps: [$0]) }
        let size = strip.populate(entries: members, groupID: tile.entry.id, store: store, maxWidth: screen.frame.width - 32) { [weak self] child in self?.configure(child, on: screen) }
        strip.document.onDropAtEnd = { [weak self] info in
            self?.handleDrop(info, target: nil, groupID: tile.entry.id, merge: true, after: true) ?? false
        }
        let panel = DockPanel()
        panel.title = "应用组 · \(tile.entry.name)"
        panel.level = .popUpMenu
        panel.contentView = strip
        popupAnchor = tileRect(tile)
        popupScreen = Self.id(screen)
        panel.setFrame(popupFrame(size: size, anchor: popupAnchor, screen: screen), display: true)
        groupPanel = panel
        panel.orderFrontRegardless()
        pointerOutsideSince = nil
    }

    private func hover(_ tile: DockTile, screen: NSScreen) {
        cancelPreviewRequest()
        pointerOutsideSince = nil
        guard !tile.entry.isGroup, store.configuration.showPreviews,
              let app = tile.entry.apps.first, store.isRunning(app) else { return }
        // The previous popup must not cancel this new hover while its capture
        // is pending. Only a member's own group remains as its interaction area.
        previewPanel?.close()
        previewPanel = nil
        previewActions = []
        if tile.groupID == nil {
            (groupPanel?.contentView as? DockStripView)?.stopAnimations()
            groupPanel?.close()
            groupPanel = nil
            popupScreen = nil
        }
        let generation = previewGeneration
        pendingPreviewScreen = Self.id(screen)
        previewTask = Task { [weak self, weak tile] in
            do { try await Task.sleep(nanoseconds: 450_000_000) } catch { return }
            guard let self, tile != nil, !Task.isCancelled, generation == self.previewGeneration else { return }
            let previews = await self.store.windows.previews(for: app)
            guard !Task.isCancelled, generation == self.previewGeneration,
                  let tile, tile.window != nil,
                  self.docks[Self.id(screen)]?.panel.isVisible == true,
                  self.interactionRect(tile).contains(NSEvent.mouseLocation) else { return }
            self.pendingPreviewScreen = nil
            if tile.groupID == nil {
                (self.groupPanel?.contentView as? DockStripView)?.stopAnimations()
                self.groupPanel?.close()
                self.groupPanel = nil
            }
            self.showPreview(previews, app: app, anchor: self.tileRect(tile), sourceRect: self.interactionRect(tile), screen: screen)
        }
    }

    private func showPreview(_ items: [WindowPreview], app: AppReference, anchor: NSRect, sourceRect: NSRect, screen: NSScreen) {
        previewPanel?.close()
        previewPanel = nil
        previewActions = []
        let visibleItems = items.filter { $0.image != nil }
        guard let layout = PreviewStripLayout(itemCount: visibleItems.count, maxWidth: screen.frame.width - 40) else {
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
            let x = layout.cardOrigins[index]
            let action = MenuAction { [weak self] in
                guard let self else { return }
                self.dismissPopups()
                _ = self.store.windows.activate(item)
                self.store.refreshPermissions()
            }
            previewActions.append(action)
            let button = NSButton(frame: NSRect(x: x, y: 26, width: 192, height: 108))
            button.image = item.image
            button.imageScaling = .scaleProportionallyUpOrDown
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.target = action
            button.action = #selector(MenuAction.invoke)
            button.toolTip = item.title
            button.setAccessibilityLabel("切换到 \(item.title)")
            document.addSubview(button)
            let label = NSTextField(labelWithString: item.title.isEmpty ? app.name : item.title)
            label.font = .systemFont(ofSize: 11)
            label.lineBreakMode = .byTruncatingTail
            label.alignment = .center
            label.frame = NSRect(x: x, y: 5, width: 192, height: 18)
            document.addSubview(label)
        }
        document.frame = NSRect(x: 0, y: 0, width: layout.documentWidth, height: 140)
        scroll.documentView = document
        scroll.frame = NSRect(x: layout.padding, y: 8, width: layout.viewportWidth, height: 140)
        background.addSubview(scroll)
        let size = NSSize(width: layout.panelWidth, height: 182)
        background.frame.size = size
        panel.contentView = background
        popupAnchor = groupPanel == nil ? sourceRect : popupAnchor.union(sourceRect)
        popupScreen = Self.id(screen)
        panel.setFrame(popupFrame(size: size, anchor: anchor, screen: screen), display: true)
        previewPanel = panel
        panel.orderFrontRegardless()
    }

    private func popupFrame(size: NSSize, anchor: NSRect, screen: NSScreen) -> NSRect {
        let usable = screen.frame.insetBy(dx: 12, dy: 12)
        let x = min(max(anchor.midX - size.width / 2, usable.minX), usable.maxX - size.width)
        let y = min(anchor.maxY + 10, usable.maxY - size.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func cancelPreviewRequest() {
        previewTask?.cancel()
        previewTask = nil
        previewGeneration += 1
        pendingPreviewScreen = nil
    }

    private func dismissPreview() {
        cancelPreviewRequest()
        previewPanel?.close()
        previewPanel = nil
        previewActions = []
        if groupPanel == nil { popupScreen = nil; pointerOutsideSince = nil }
    }

    func dismissPopups() {
        cancelPreviewRequest()
        (groupPanel?.contentView as? DockStripView)?.stopAnimations()
        groupPanel?.close(); groupPanel = nil
        previewPanel?.close(); previewPanel = nil
        previewActions = []
        popupScreen = nil
        pointerOutsideSince = nil
    }

    private var fullscreenCounter = 0
    private func tick() {
        fullscreenCounter += 1
        if fullscreenCounter % 4 == 0 { applyFullscreenState() }
        guard !contextMenuTracking, NSEvent.pressedMouseButtons == 0, groupPanel != nil || previewPanel != nil else { return }
        var safe = popupAnchor
        if let groupPanel { safe = safe.union(groupPanel.frame) }
        if let previewPanel { safe = safe.union(previewPanel.frame) }
        if safe.insetBy(dx: -14, dy: -14).contains(NSEvent.mouseLocation) { pointerOutsideSince = nil }
        else if let since = pointerOutsideSince, Date().timeIntervalSince(since) > 0.35 { dismissPopups() }
        else if pointerOutsideSince == nil { pointerOutsideSince = Date() }
    }

    private func applyFullscreenState() {
        let hidden = store.windows.fullscreenDisplayIDs(screens: docks.values.map(\.screen))
        for (id, dock) in docks {
            if hidden.contains(id) {
                if dock.panel.isVisible { dock.strip.resetMagnification() }
                dock.panel.orderOut(nil)
                if popupScreen == id || pendingPreviewScreen == id { dismissPopups() }
            } else if !dock.panel.isVisible { dock.panel.orderFrontRegardless() }
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
