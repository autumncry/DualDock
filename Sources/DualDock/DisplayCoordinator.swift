import AppKit
import Combine
import QuartzCore
import DualDockCore

@MainActor
protocol DockShelfToolsProviding: AnyObject {
    func makeSurface(on displayID: String, presentation: DockPresentation) -> DockShelfSurface
    func setShelfVisible(_ visible: Bool, on displayID: String)
    func keepsShelfOpen(on displayID: String) -> Bool
}

@MainActor
final class DisplayCoordinator {
    struct ApplicationActions {
        var launch: (AppReference) -> Void
        var cancelRecovery: () -> Void
    }

    struct ScreenDock {
        let screen: NSScreen
        let displayID: String
        let panel: DockPanel
        let strip: DockStripView
    }
    let store: AppStore
    private let windowInteractions: WindowInteractionService
    private let applicationActions: ApplicationActions
    private let presentsPanels: Bool
    private let tools: DockShelfToolsProviding?
    private let pageStateURL: URL?
    private var pages: [String: DockShelfPage]
    private var visibleToolDisplays: Set<String> = []
    var showSettings: (() -> Void)?
    private(set) var docks: [CGDirectDisplayID: ScreenDock] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var poll: Timer?
    private var visibility: DockVisibilityController?
    private var visibilitySnapshot = DockVisibilityController.Snapshot(hidden: [], fullscreen: [])
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
    private enum OrganizationChange {
        case pin(String)
        case group(UUID, AppReference, CGPoint)
    }

    private struct OrganizationMotion {
        let screenID: CGDirectDisplayID
        let previousCenters: [String: CGPoint]
        let change: OrganizationChange
    }
    private var pendingOrganizationMotion: OrganizationMotion?
    private var geometryRefreshScheduled = false
    private var badgeRedrawScheduled = false
    private var pendingBadgeLabelChange = false
    private var renderedEntries: [DockEntry] = []
    private var renderedPinnedCount = 0
    private var renderedMode: DockMode?
    private var renderedShowBadges: Bool?
    private var renderedHideSystemDock: Bool?
    private var renderedRunningIDs = Set<String>()
    private var folderRedrawScheduled = false
    private var tileAppearanceNeedsRefresh = false
    private var stopped = false
    private var latestWindowIntent: UInt64 = 0
    private var previewActivation: Task<Void, Never>?
    private var replacingWindowIntent: UInt64 = 0
    private var pointerOutsideSince: Date?
    private var contextMenuScreen: CGDirectDisplayID?
    private var contextMenuTracking: Bool { contextMenuScreen != nil }
    private var menuTrackingObserver: MenuTrackingObserver?

    /// Hidden coordinators exercise the real update pipeline without presenting UI.
    init(store: AppStore, presentsPanels: Bool = true, windowInteractions: WindowInteractionService? = nil,
         applicationActions: ApplicationActions? = nil, tools: DockShelfToolsProviding? = nil,
         pageStateDirectory: URL? = nil) {
        self.tools = tools
        self.pageStateURL = pageStateDirectory?.appendingPathComponent("dock-pages.json")
        if let url = self.pageStateURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([String: DockShelfPage].self, from: data) {
            self.pages = saved
        } else { self.pages = [:] }
        self.store = store
        self.windowInteractions = windowInteractions ?? WindowInteractionService()
        self.applicationActions = applicationActions ?? ApplicationActions(
            launch: { store.launch($0) }, cancelRecovery: { store.cancelPendingActivationRecovery() })
        self.presentsPanels = presentsPanels
        store.$configuration.removeDuplicates().dropFirst().sink { [weak self] next in
            guard let self else { return }
            // @Published emits the incoming value while the store still holds the old one.
            let previous = self.store.configuration
            if next.badgeScale != previous.badgeScale, next.showBadges { self.scheduleBadgeRedraw(labelsChanged: false) }
            if next.folderAppearance != previous.folderAppearance { self.scheduleFolderRedraw() }
            if !next.matchesExceptTileArtwork(previous) { self.scheduleGeometryRefresh() }
        }.store(in: &subscriptions)
        store.$runningApps.dropFirst().sink { [weak self] _ in
            self?.tileAppearanceNeedsRefresh = true
            self?.scheduleGeometryRefresh()
        }.store(in: &subscriptions)
        store.$badgeLabels.dropFirst().sink { [weak self] _ in
            self?.scheduleBadgeRedraw(labelsChanged: true)
        }.store(in: &subscriptions)
        store.$nativeDockMetrics.dropFirst().sink { [weak self] _ in
            guard let self, self.store.configuration.adaptiveSizing else { return }
            self.scheduleGeometryRefresh()
        }.store(in: &subscriptions)
        store.$resizeRevision.dropFirst().sink { [weak self] _ in
            self?.scheduleGeometryRefresh()
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .dualDockLanguageDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.stopped else { return }
                self.dismissPopups()
                self.docks.values.forEach { $0.strip.refreshLanguage() }
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
            autoHideWhenMaximized: { [weak self] in self?.store.configuration.autoHideWhenMaximized ?? false },
            autoHideDock: { [weak self] in self?.store.configuration.autoHideDock ?? false },
            apply: { [weak self] snapshot in self?.applyVisibility(snapshot) })
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
            panel.title = "DualDock 3 · \(screen.localizedName)"
            strip.pointerIsOccluded = { [weak self] point in
                self?.pointerIsOverPopup(point, includeGroup: true) ?? false
            }
            strip.settingsAction = { [weak self] in self?.dismissPopups(); self?.showSettings?() }
            if let tools, !strip.hasTools {
                strip.installTools(tools.makeSurface(on: display.id, presentation: presentation),
                                   initialPage: pages[display.id] ?? .apps)
                strip.canStartPaging = { [weak self] in self?.contextMenuTracking == false }
                strip.onPageMotionBegan = { [weak self] in
                    guard let self else { return }
                    if self.popupScreen == id || self.pendingPreviewScreen == id { self.dismissPopups() }
                    for case let exit as DockDeparturePanel in self.docks[id]?.panel.childWindows ?? [] {
                        exit.dismiss()
                    }
                }
                strip.onPageChanged = { [weak self] page in self?.setPage(page, for: display.id) }
            }
            strip.resizeInteractionAllowed = { [weak self] in
                guard let self else { return false }
                // Popups own only their covered region. Exposed edges must
                // remain reachable so the next resize can dismiss the popup.
                return !self.contextMenuTracking
            }
            strip.onResizeBegan = { [weak self] in self?.dismissPopups() }
            strip.onResizeChanged = { [weak self] value in self?.store.setResizePreview(value, for: display.id) }
            strip.onResizeEnded = { [weak self] value in
                guard let self else { return }
                if let value { self.store.commitManualResize(value, for: display.id) }
                else { self.store.setResizePreview(nil, for: display.id) }
            }
            strip.document.onDropAtEnd = { [weak self] info in self?.handleDrop(info, target: nil, groupID: nil, merge: false, after: false) ?? false }
            let offset = strip.presentation?.edge == presentation.edge ? strip.scrollOffset : 0
            _ = strip.populate(entries: entries, store: store, maxWidth: presentation.maximumLength,
                               presentation: presentation, preservingOffset: offset) { [weak self] tile in
                self?.configure(tile, on: screen, displayID: display.id, edge: presentation.edge)
            }
            panel.contentView = strip
            panel.placeDock(strip, in: placementBounds(for: screen), display: true)
            strip.updateMousePassthrough()
            docks[id] = ScreenDock(screen: screen, displayID: display.id, panel: panel, strip: strip)
        }
        renderedEntries = entries
        renderedRunningIDs = Set(store.runningApps.map(\.id))
        renderedPinnedCount = store.pinnedCount
        renderedMode = store.configuration.mode
        renderedShowBadges = store.configuration.showBadges
        renderedHideSystemDock = store.configuration.hideSystemDock
        tileAppearanceNeedsRefresh = false
        visibility?.invalidate()
        refreshToolVisibility()
    }

    func togglePageForPointerDisplay() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        guard let screen, let strip = docks[Self.id(screen)]?.strip, strip.hasTools,
              !strip.isResizing else { return }
        strip.setShelfPage(strip.page.other)
    }

    private func setPage(_ page: DockShelfPage, for displayID: String) {
        pages[displayID] = page
        if let url = pageStateURL {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try JSONEncoder().encode(pages).write(to: url, options: .atomic)
            } catch {
                store.notice = .init("未能保存此屏的工具页选择。", "Could not save the Dock page for this display.")
            }
        }
        refreshToolVisibility()
        visibility?.refresh(force: true)
    }

    private func refreshToolVisibility() {
        guard let tools else { return }
        let visible = Set(docks.values.compactMap { dock in
            dock.panel.isVisible && dock.strip.page == .tools ? dock.displayID : nil
        })
        for id in visibleToolDisplays.subtracting(visible) { tools.setShelfVisible(false, on: id) }
        for id in visible.subtracting(visibleToolDisplays) { tools.setShelfVisible(true, on: id) }
        visibleToolDisplays = visible
    }

    private func scheduleGeometryRefresh() {
        guard !stopped, !geometryRefreshScheduled else { return }
        geometryRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.geometryRefreshScheduled = false
            defer { self.finishOrganizationMotion() }
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
            // Capture before a rebuild so a departing transient app keeps its
            // previous screen position even if the content-sized Dock shrinks.
            let lifecycle = self.tileAppearanceNeedsRefresh
                ? self.captureLifecycle(runningIDs: Set(self.store.runningApps.map(\.id)),
                                        nextEntries: entries, structureChanged: structureChanged) : nil
            defer { if let lifecycle { self.finishLifecycle(lifecycle) } }
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
                    guard self.store.displays.contains(where: { $0.id == dock.displayID }),
                          let presentation = presentations[id] else { continue }
                    _ = dock.strip.updatePresentation(presentation)
                    dock.panel.placeDock(dock.strip, in: self.placementBounds(for: dock.screen), display: false)
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

    private struct LifecycleChange {
        let started: Set<String>
        let stopped: Set<String>
        var centers: [CGDirectDisplayID: [String: CGPoint]] = [:]
        var departures: [CGDirectDisplayID: [DockDepartureImage]] = [:]
    }

    private func captureLifecycle(runningIDs ids: Set<String>, nextEntries: [DockEntry], structureChanged: Bool) -> LifecycleChange? {
        let started = ids.subtracting(renderedRunningIDs)
        let ended = renderedRunningIDs.subtracting(ids)
        renderedRunningIDs = ids
        guard !started.isEmpty || !ended.isEmpty,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              renderedMode == store.configuration.mode else { return nil }
        var change = LifecycleChange(started: started, stopped: ended)
        guard structureChanged else { return change }
        let remaining = Set(nextEntries.flatMap { $0.apps.map(\.id) })
        for (id, dock) in docks where dock.strip.page == .apps && dock.panel.isVisible && !dock.panel.isMiniaturized {
            change.centers[id] = [:]
            for tile in dock.strip.tiles {
                guard let center = tile.presentedIconCenterOnScreen else { continue }
                change.centers[id, default: [:]][tile.organizationMotionID] = center
                guard !tile.entry.isGroup, let app = tile.entry.apps.first, ended.contains(app.id),
                      !remaining.contains(app.id), let image = DockDepartureImage(tile: tile, app: app) else { continue }
                change.departures[id, default: []].append(image)
            }
        }
        return change
    }

    private func finishLifecycle(_ change: LifecycleChange) {
        for (id, dock) in docks where dock.strip.page == .apps && dock.panel.isVisible {
            // A quick relaunch replaces its fading image immediately.
            for case let exit as DockDeparturePanel in dock.panel.childWindows ?? [] where change.started.contains(exit.appID) {
                exit.dismiss()
            }
            for departure in change.departures[id] ?? [] {
                DockDeparturePanel(departure).present(above: dock.panel)
            }
            for tile in dock.strip.tiles {
                let previous = change.centers[id]?[tile.organizationMotionID]
                if let previous, tile.layer?.animation(forKey: "dock.reflow") == nil {
                    tile.animateReflow(from: previous, duration: 0.36)
                }
                animateRunningState(of: tile, change: change, edge: dock.strip.presentation?.edge ?? .bottom,
                                    inserted: change.centers[id] != nil && previous == nil)
            }
        }
        if let groupPanel, groupPanel.isVisible, let group = groupPanel.contentView as? DockStripView {
            for tile in group.tiles { animateRunningState(of: tile, change: change, edge: groupEdge, inserted: false) }
        }
    }

    private func animateRunningState(of tile: DockTile, change: LifecycleChange, edge: DockEdge, inserted: Bool) {
        guard let layer = tile.layer, tile.visibleRect.intersects(tile.visualIconBounds) else { return }
        if tile.entry.apps.contains(where: { change.started.contains($0.id) }) {
            // A gentle inward lift reads as a launch on every screen edge.
            let lift = min(8, tile.visualIconBounds.width * 0.14)
            let vector: CGPoint
            switch edge {
            case .bottom: vector = CGPoint(x: 0, y: lift)
            case .top: vector = CGPoint(x: 0, y: -lift)
            case .left: vector = CGPoint(x: lift, y: 0)
            case .right: vector = CGPoint(x: -lift, y: 0)
            }
            let movement = CAKeyframeAnimation(keyPath: "position")
            movement.isAdditive = true
            movement.values = [NSValue(point: .zero), NSValue(point: vector), NSValue(point: .zero)]
            movement.keyTimes = [0, 0.42, 1]
            movement.timingFunctions = [.init(name: .easeOut), .init(name: .easeInEaseOut)]
            let arrival = CAAnimationGroup()
            var animations: [CAAnimation] = [movement]
            movement.duration = 0.46
            if inserted {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.25
                fade.toValue = 1
                fade.duration = 0.32
                animations.append(fade)
            }
            arrival.animations = animations
            arrival.duration = movement.duration
            layer.add(arrival, forKey: "dock.runningState")
        } else if tile.entry.apps.contains(where: { change.stopped.contains($0.id) }) {
            // Pinned tiles stay present on quit. The running dot already reflects
            // the new state; lower the contrast briefly to mark that change.
            let settle = CAKeyframeAnimation(keyPath: "opacity")
            settle.values = [1, 0.63, 1]
            settle.keyTimes = [0, 0.36, 1]
            settle.timingFunctions = [.init(name: .easeInEaseOut), .init(name: .easeOut)]
            settle.duration = 0.34
            layer.add(settle, forKey: "dock.runningState")
        }
    }

    func resetMagnification() {
        dismissPopups()
        docks.values.forEach { $0.strip.resetMagnification() }
    }

    private func scheduleFolderRedraw() {
        guard !stopped, !folderRedrawScheduled else { return }
        folderRedrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.folderRedrawScheduled = false
            let bounds = DockFolderArtwork.contentBounds(for: self.store.configuration.folderAppearance.style)
            for (id, dock) in self.docks where dock.strip.refreshFolderArtwork(contentBounds: bounds) {
                let presentation = self.store.presentation(for: dock.displayID)
                _ = dock.strip.updatePresentation(presentation)
                dock.panel.placeDock(dock.strip, in: self.placementBounds(for: dock.screen), display: false)
                if self.popupScreen == id { self.reanchorPopups(on: dock) }
            }
        }
    }

    private func reanchorPopups(on dock: ScreenDock) {
        if let groupPanel, let members = groupPanel.contentView as? DockStripView,
           let id = members.tiles.first?.groupID,
           let source = dock.strip.tiles.first(where: { $0.entry.id == id }) {
            popupAnchor = tileRect(source)
            groupPanel.setFrame(popupFrame(size: groupPanel.frame.size, anchor: popupAnchor,
                                           screen: dock.screen, edge: groupEdge), display: false)
        }
        if let previewPanel, let previewSource {
            if groupPanel == nil { popupAnchor = interactionRect(previewSource) }
            previewAnchor = tileRect(previewSource)
            previewPanel.setFrame(popupFrame(size: previewPanel.frame.size, anchor: previewAnchor,
                                             screen: dock.screen, edge: previewEdge), display: false)
        }
    }

    private func scheduleBadgeRedraw(labelsChanged: Bool) {
        guard !stopped else { return }
        pendingBadgeLabelChange = pendingBadgeLabelChange || labelsChanged
        guard !badgeRedrawScheduled else { return }
        badgeRedrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.badgeRedrawScheduled = false
            self.redrawBadges(scaleOnly: !self.pendingBadgeLabelChange)
            self.pendingBadgeLabelChange = false
        }
    }

    private func redrawBadges(scaleOnly: Bool = false) {
        func refresh(_ tile: DockTile) {
            if scaleOnly { tile.refreshBadgeScale() }
            else { tile.refreshBadge() }
        }
        docks.values.forEach { dock in dock.strip.tiles.forEach(refresh) }
        (groupPanel?.contentView as? DockStripView)?.tiles.forEach(refresh)
    }

    static func id(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        previewActivation?.cancel()
        windowInteractions.cancel()
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
        refreshToolVisibility()
    }

    private func configure(_ tile: DockTile, on screen: NSScreen, displayID: String, edge: DockEdge) {
        tile.menuEdge = edge
        tile.onContextMenuRequest = { [weak self] in self?.cancelPendingMenus() }
        tile.menuPlacementBounds = { [weak self] screen in self?.placementBounds(for: screen) ?? screen.visibleFrame }
        tile.onPress = { [weak self, weak tile] in
            guard let self, let tile else { return }
            if tile.entry.isGroup { self.openGroup(tile, screen: screen, displayID: displayID, edge: edge) }
            else if let app = tile.entry.apps.first {
                self.dismissPopups()
                let intent = self.beginWindowIntent()
                Task { [weak self] in
                    guard let self, !self.stopped, intent >= self.replacingWindowIntent else { return }
                    let result = await self.windowInteractions.toggle(for: app,
                        beforePerform: self.applicationActions.cancelRecovery)
                    guard !self.stopped else { return }
                    self.handleWindowResult(result, app: app, intent: intent)
                }
            }
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
            return self.menu(for: tile, on: Self.id(screen))
        }
        if !tile.entry.isGroup, let app = tile.entry.apps.first {
            tile.prepareMenu = { [weak self, weak tile] in
                guard let self, let tile, !self.stopped else { return nil }
                self.dismissPreview()
                let snapshot = await self.windowInteractions.list(for: app)
                guard !Task.isCancelled, !self.stopped else { return nil }
                return self.menu(for: tile, on: Self.id(screen), windows: snapshot)
            }
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
        panel.title = L("应用组 · \(tile.entry.name)", "App Group · \(tile.entry.name)")
        panel.setFullscreenOverlay(visibilitySnapshot.fullscreen.contains(Self.id(screen)))
        panel.level = .popUpMenu
        panel.contentView = strip
        popupAnchor = tileRect(tile)
        groupEdge = edge
        popupScreen = Self.id(screen)
        panel.setFrame(popupFrame(size: size, anchor: popupAnchor, screen: screen, edge: edge), display: true)
        strip.updateMousePassthrough()
        groupPanel = panel
        if presentsPanels {
            let fadeIn = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if fadeIn { panel.alphaValue = 0.35 }
            panel.orderFrontRegardless()
            if fadeIn {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.17
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1
                }
            }
        }
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
        panel.title = L("窗口预览 · \(app.name)", "Window Previews · \(app.name)")
        panel.setFullscreenOverlay(visibilitySnapshot.fullscreen.contains(Self.id(screen)))
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
            let card = WindowPreviewCardView(title: item.title.isEmpty ? app.name : item.title,
                                             image: image, canClose: item.canClose)
            card.frame.origin = NSPoint(x: x, y: 0)
            card.onActivate = { [weak self, weak card] in
                guard let self else { return }
                let intent = self.beginWindowIntent(replacingQueuedActions: true)
                self.previewActivation = Task { [weak self, weak card] in
                    guard let self, !self.stopped, !Task.isCancelled else { return }
                    let activated = await self.store.windows.activate(item, for: app)
                    guard !Task.isCancelled, intent == self.latestWindowIntent, !self.stopped else { return }
                    if activated {
                        self.windowInteractions.remember(item, for: app)
                        if let card, let panel = self.previewPanel, card.window === panel { self.dismissPopups() }
                    } else {
                        card?.showIssue(L("请重新选择窗口", "Select the window again"),
                            detail: L("请重新悬停以刷新窗口预览。", "Hover over the app to refresh its windows."))
                    }
                    self.store.refreshPermissions()
                    self.previewActivation = nil
                }
            }
            card.onClose = { [weak self, weak card] in
                guard let self, let card else { return }
                self.closePreview(item, app: app, card: card)
            }
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

    private func closePreview(_ item: WindowPreview, app: AppReference, card: WindowPreviewCardView) {
        beginWindowIntent(replacingQueuedActions: true)
        let result = store.windows.close(item, for: app)
        store.refreshPermissions()
        guard let notice = result.notice else {
            dismissPopups()
            return
        }
        let summary = result == .permissionRequired
            ? L("需要辅助功能权限", "Accessibility access required")
            : L("无法关闭此窗口", "Can't close this window")
        card.showIssue(summary, detail: notice.text, disableClose: result != .failed)
    }

    private func popupFrame(size: NSSize, anchor: NSRect, screen: NSScreen, edge: DockEdge) -> NSRect {
        DockPopupPlacement.frame(size: size, anchor: anchor, edge: edge, visibleScreen: placementBounds(for: screen))
    }

    private func placementBounds(for screen: NSScreen) -> NSRect {
        if visibilitySnapshot.fullscreen.contains(Self.id(screen)) {
            return DockVisibilityController.fullscreenBounds(for: screen)
        }
        return store.displays.first(where: { $0.runtimeID == Self.id(screen) })?.visibleFrame ?? screen.visibleFrame
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

    private func cancelPendingMenus() {
        docks.values.forEach { $0.strip.tiles.forEach { $0.cancelPendingMenu() } }
        (groupPanel?.contentView as? DockStripView)?.tiles.forEach { $0.cancelPendingMenu() }
    }

    func dismissPopups() {
        cancelPendingMenus()
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
            let workArea = store.displays.first { $0.runtimeID == id }?.visibleFrame ?? dock.screen.visibleFrame
            return .init(id: id, screen: dock.screen, visibleFrame: workArea,
                edge: dock.strip.layoutGeometry?.edge ?? .bottom,
                backdrop: dock.panel.convertToScreen(dock.strip.convert(dock.strip.backdropFrame, to: nil)),
                pointerInside: dock.panel.isVisible && dock.strip.containsInteractivePoint(local),
                interacting: dock.strip.isInteracting || popupOpen || contextMenuScreen == id
                    || tools?.keepsShelfOpen(on: dock.displayID) == true)
        }
    }

    private func applyVisibility(_ snapshot: DockVisibilityController.Snapshot) {
        let previous = visibilitySnapshot
        visibilitySnapshot = snapshot
        if let popupScreen, previous.fullscreen.contains(popupScreen) != snapshot.fullscreen.contains(popupScreen) {
            dismissPopups()
        }
        for (id, dock) in docks {
            let fullscreen = snapshot.fullscreen.contains(id)
            if snapshot.hidden.contains(id) {
                for case let exit as DockDeparturePanel in dock.panel.childWindows ?? [] { exit.dismiss() }
                if dock.panel.isVisible { dock.strip.resetMagnification() }
                dock.strip.cancelPageMotion()
                dock.panel.orderOut(nil)
                dock.panel.setFullscreenOverlay(false)
                if popupScreen == id || pendingPreviewScreen == id { dismissPopups() }
            } else {
                dock.panel.setFullscreenOverlay(fullscreen)
                if previous.fullscreen.contains(id) != fullscreen || previous.hidden.contains(id) {
                    dock.panel.placeDock(dock.strip, in: placementBounds(for: dock.screen), display: false)
                }
                if presentsPanels && !dock.panel.isVisible { dock.panel.orderFrontRegardless() }
                dock.strip.updateMousePassthrough()
            }
        }
        refreshToolVisibility()
    }

    private func organizationSource(window: NSWindow?) -> (CGDirectDisplayID, [String: CGPoint])? {
        guard let window, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return nil }
        let screenID = window === groupPanel ? popupScreen : docks.first(where: { $0.value.panel === window })?.key
        guard let screenID, let dock = docks[screenID] else { return nil }
        var centers: [String: CGPoint] = [:]
        for tile in dock.strip.tiles {
            centers[tile.organizationMotionID] = tile.presentedIconCenterOnScreen
        }
        return (screenID, centers)
    }

    private func finishOrganizationMotion() {
        guard let motion = pendingOrganizationMotion else { return }
        pendingOrganizationMotion = nil
        guard let strip = docks[motion.screenID]?.strip else { return }
        for tile in strip.tiles {
            var pin = false
            switch motion.change {
            case let .pin(appID):
                pin = !tile.entry.isGroup && tile.entry.apps.first?.id == appID
            case let .group(id, app, release) where tile.entry.id == id && tile.entry.apps.contains(where: { $0.id == app.id }):
                tile.animateDropIntoFolder(app, from: release)
            default: break
            }
            if let old = motion.previousCenters[tile.organizationMotionID] {
                tile.animateReflow(from: old, emphasizesPin: pin)
            }
        }
    }

    private func pin(_ app: AppReference, into groupID: UUID? = nil, from tile: DockTile?) {
        guard !stopped, !store.configuration.allAppIDs.contains(app.id) else { return }
        let source = organizationSource(window: tile?.window)
        let change: OrganizationChange?
        if let groupID {
            guard store.isRunning(app),
                  let index = store.configuration.entries.firstIndex(where: { $0.isGroup && $0.id == groupID })
            else { return }
            let origin = tile?.presentedIconCenterOnScreen
            store.update { $0.entries[index].apps.append(app) }
            change = origin.map { .group(groupID, app, $0) }
        } else {
            store.update { $0.insert([app]) }
            change = .pin(app.id)
        }
        if let (screenID, centers) = source, let change, store.configuration.allAppIDs.contains(app.id) {
            pendingOrganizationMotion = .init(screenID: screenID, previousCenters: centers, change: change)
        }
    }

    private func addGroupChoices(to menu: NSMenu, app: AppReference, tile: DockTile) {
        let groups = store.configuration.entries.filter(\.isGroup)
        guard !groups.isEmpty else { return }
        let title = L("加入应用组", "Add to App Group")
        let submenu = NSMenu(title: title)
        let names = Dictionary(grouping: groups, by: \.name)
        for (index, group) in groups.enumerated() {
            // Freshly created groups often share the same default name.
            let duplicateName = (names[group.name]?.count ?? 0) > 1
            let label = duplicateName ? "\(group.name) (\(index + 1))" : group.name
            let id = group.id
            submenu.addAction(label) { [weak self, weak tile] in self?.pin(app, into: id, from: tile) }
            if duplicateName { submenu.items.last?.toolTip = group.apps.map(\.name).joined(separator: ", ") }
        }
        let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
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
        let source = (groupID != nil || merge) ? organizationSource(window: info.draggingDestinationWindow) : nil
        let release = info.draggingDestinationWindow?.convertPoint(toScreen: info.draggingLocation)
        let oldEntries = store.configuration.entries
        var destinationGroup = groupID
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
                    config.merge(appID: app.id, into: groupID, defaultGroupName: L("应用组", "App Group"))
                    config.moveMember(id: app.id, before: memberBefore, groupID: groupID)
                }
            } else if merge, let target {
                if !config.entries.contains(where: { $0.id == target.id }), let targetApp = target.apps.first { config.insert([targetApp]) }
                let targetID = config.entries.first { $0.id == target.id || (!target.isGroup && $0.apps.first?.id == target.apps.first?.id) }?.id
                destinationGroup = targetID
                if let targetID { for app in apps { config.merge(appID: app.id, into: targetID, defaultGroupName: L("应用组", "App Group")) } }
            } else {
                for app in apps {
                    config.moveAppOut(appID: app.id, before: before)
                    if let entry = config.entries.first(where: { !$0.isGroup && $0.apps.first?.id == app.id }) { config.moveEntry(id: entry.id, before: before) }
                }
            }
        }
        if let (screenID, centers) = source, let release, let id = destinationGroup,
           let group = store.configuration.entries.first(where: { $0.id == id && $0.isGroup }) {
            let previousMembers = Set((oldEntries.first { $0.id == id }?.apps ?? []).map(\.id))
            let droppedIDs = Set(apps.map(\.id))
            if let incoming = group.apps.first(where: { droppedIDs.contains($0.id) && !previousMembers.contains($0.id) }) {
                pendingOrganizationMotion = .init(screenID: screenID, previousCenters: centers,
                                                  change: .group(id, incoming, release))
            }
        }
        return true
    }

    private func insertionID(target: DockEntry?, after: Bool) -> UUID? {
        guard let target, let index = store.configuration.entries.firstIndex(where: { $0.id == target.id }) else { return nil }
        if !after { return target.id }
        return index + 1 < store.configuration.entries.count ? store.configuration.entries[index + 1].id : nil
    }

    @discardableResult
    private func beginWindowIntent(replacingQueuedActions: Bool = false) -> UInt64 {
        previewActivation?.cancel()
        previewActivation = nil
        latestWindowIntent &+= 1
        if replacingQueuedActions {
            replacingWindowIntent = latestWindowIntent
            windowInteractions.cancel()
        }
        applicationActions.cancelRecovery()
        return latestWindowIntent
    }

    private func handleWindowResult(_ result: WindowInteractionResult, app: AppReference, intent: UInt64) {
        // Real queued toggles still run in order. Only the newest user intent
        // may reopen an application or present a late error after that work.
        guard intent == latestWindowIntent else { return }
        switch result {
        case .handled, .targetUnavailable: break
        case .fallbackToApplication: applicationActions.launch(app)
        case .failure(let notice): store.notice = notice
        }
    }

    private func menu(for tile: DockTile, on screen: CGDirectDisplayID, windows: DockWindowListSnapshot? = nil) -> NSMenu {
        let menu = NSMenu()
        let observer = MenuTrackingObserver(
            opened: { [weak self] in self?.contextMenuScreen = screen },
            closed: { [weak self] in self?.contextMenuScreen = nil }
        )
        menuTrackingObserver = observer
        menu.delegate = observer
        if tile.entry.isGroup {
            menu.addAction(L("重命名应用组…", "Rename Group…")) { [weak self] in self?.rename(tile.entry) }
            menu.addAction(L("展开为独立应用", "Ungroup Apps")) { [weak self] in self?.store.update { $0.ungroup(id: tile.entry.id) } }
            menu.addAction(L("打开组内全部应用", "Open All Apps in Group")) { [weak self] in
                guard let self else { return }
                self.beginWindowIntent(replacingQueuedActions: true)
                tile.entry.apps.forEach { self.applicationActions.launch($0) }
            }
            menu.addItem(.separator())
            menu.addAction(L("移除应用组", "Remove Group")) { [weak self] in self?.store.update { $0.removeEntry(id: tile.entry.id) } }
        } else if let app = tile.entry.apps.first {
            if let windows, !windows.items.isEmpty {
                if windows.isHostedChoice {
                    let label = NSMenuItem(title: L("选择此图标控制的微信窗口", "Choose the WeChat window for this icon"),
                                           action:nil, keyEquivalent:"")
                    label.isEnabled = false
                    menu.addItem(label)
                }
                for item in windows.items {
                    let title = item.title + (item.isMinimized ? L("（已最小化）", " (Minimized)") : "")
                    menu.addAction(title) { [weak self] in
                        guard let self else { return }
                        self.dismissPopups()
                        let intent = self.beginWindowIntent(replacingQueuedActions: true)
                        Task { [weak self] in
                            guard let self, !self.stopped, intent >= self.replacingWindowIntent else { return }
                            let result = await self.windowInteractions.select(item, for: app,
                                beforePerform: self.applicationActions.cancelRecovery)
                            guard !self.stopped else { return }
                            self.handleWindowResult(result, app: app, intent: intent)
                        }
                    }
                    menu.items.last?.state = item.id == windows.selectedID ? .on : .off
                }
                menu.addItem(.separator())
            }
            menu.addAction(L("打开 \(app.name)", "Open \(app.name)")) { [weak self] in
                guard let self else { return }
                self.beginWindowIntent(replacingQueuedActions: true)
                self.applicationActions.launch(app)
            }
            if store.configuration.allAppIDs.contains(app.id) {
                if tile.groupID != nil { menu.addAction(L("移出应用组", "Move Out of Group")) { [weak self] in self?.store.update { $0.moveAppOut(appID: app.id) } } }
                menu.addAction(L("从 DualDock 移除", "Remove from DualDock")) { [weak self] in self?.store.update { $0.removeApp(id: app.id) } }
            } else {
                menu.addAction(L("固定到 DualDock", "Pin to DualDock")) { [weak self, weak tile] in
                    self?.pin(app, from: tile)
                }
                addGroupChoices(to: menu, app: app, tile: tile)
            }
            menu.addAction(L("在 Finder 中显示", "Show in Finder")) { [weak self] in
                self?.beginWindowIntent(replacingQueuedActions: true)
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
            }
            if store.isRunning(app) {
                menu.addItem(.separator())
                menu.addAction(L("退出 \(app.name)", "Quit \(app.name)")) { [weak self] in
                    self?.beginWindowIntent(replacingQueuedActions: true)
                    self?.store.quit(app)
                }
            }
        }
        return menu
    }

    private func rename(_ entry: DockEntry) {
        dismissPopups()
        let alert = NSAlert()
        alert.messageText = L("应用组名称", "Group Name")
        let field = NSTextField(string: entry.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L("保存", "Save"))
        alert.addButton(withTitle: L("取消", "Cancel"))
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

/// An app can occupy just the clipped end of a scrolled Dock. Capture only
/// that part of its image, using the locally cached icon instead of a screenshot.
@MainActor
private struct DockDepartureImage {
    let appID: String
    let image: NSImage
    let screenRect: NSRect
    let imageFrame: NSRect

    init?(tile: DockTile, app: AppReference) {
        guard let window = tile.window else { return nil }
        let icon = tile.visualIconBounds
        let visible = tile.visibleRect.intersection(icon)
        guard !visible.isEmpty, !visible.isNull else { return nil }
        appID = app.id
        image = tile.store.icon(for: app)
        screenRect = window.convertToScreen(tile.convert(visible, to: nil))
        imageFrame = icon.offsetBy(dx: -visible.minX, dy: -visible.minY)
    }
}

/// Transient icons can finish outside the shortened bar. A noninteractive
/// child stays at the old icon location and inherits its parent's visibility.
@MainActor
private final class DockDeparturePanel: NSPanel {
    let appID: String
    static let duration: CFTimeInterval = 0.34

    init(_ source: DockDepartureImage) {
        appID = source.appID
        super.init(contentRect: source.screenRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        let clip = NSView(frame: NSRect(origin: .zero, size: source.screenRect.size))
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        let icon = NSImageView(frame: source.imageFrame)
        icon.image = source.image
        icon.imageScaling = .scaleAxesIndependently
        icon.setAccessibilityElement(false)
        clip.addSubview(icon)
        contentView = clip
        setAccessibilityElement(false)
    }

    func present(above dock: NSPanel) {
        guard dock.isVisible, let layer = contentView?.layer else { return }
        level = dock.level
        collectionBehavior = dock.collectionBehavior
        dock.addChildWindow(self, ordered: .above)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Self.duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in self?.dismiss() }
        }
        layer.opacity = 0
        layer.add(fade, forKey: "dock.departure")
        CATransaction.commit()
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        close()
    }
}
