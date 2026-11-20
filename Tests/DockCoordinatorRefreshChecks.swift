import AppKit
import DualDockCore

/// Real AppStore publications and DisplayCoordinator subscriptions; no visible
/// windows, posted input, user configuration, or system preference changes.
@main
struct DockCoordinatorRefreshChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = DockConfiguration()
        config.showBadges = false
        config.showPreviews = false
        config.hideSystemDock = false
        config.dockWidth = 600
        config.entries = (0..<30).map {
            DockEntry(name: "Fixture", apps: [.init(id: "refresh.\($0)", name: "Fixture",
                path: "/System/Applications/Notes.app")])
        }
        try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("configuration.json"))
        var badgeReads = 0
        let badgeService = DockBadgeService(reader: { _ in
            .init(labels: ["resize.group.one": "99+"], status: .available)
        }, inputProvider: {
            badgeReads += 1
            return .init(applications: [], dockProcessID: nil, accessibilityTrusted: true)
        })
        let store = AppStore(directory: directory, runningAppsProvider: { [] }, badgeService: badgeService)
        store.stopBackgroundServices()
        let coordinator = DisplayCoordinator(store: store, presentsPanels: false)
        defer { coordinator.stop(); store.stopBackgroundServices() }
        var failures: [String] = []
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        func drain() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.015)) }
        drain()
        guard let first = coordinator.docks.values.first else { fatalError("No attached screen for hidden fixture") }
        let retained = coordinator.docks.mapValues { $0.strip.tiles }
        var previous = retained
        var rebuilds = 0
        for dock in coordinator.docks.values {
            let geometry = dock.strip.layoutGeometry!
            dock.strip.scroll.contentView.scroll(to: geometry.scrollOrigin(forCanonicalOffset: 90,
                actualDocumentSize: dock.strip.document.frame.size,
                actualViewportSize: dock.strip.scroll.contentView.bounds.size))
        }
        let offsets = coordinator.docks.mapValues { $0.strip.scrollOffset }
        for step in 0..<24 {
            store.updateManualSizing(for: first.displayID) {
                $0.length = 620 + Double(step)
                $0.thickness = 70 + Double(step) * 0.25
                $0.iconSpacing = 8 + Double(step) * 0.1
            }
            drain()
            for (id, dock) in coordinator.docks {
                let sameTiles = zip(previous[id] ?? [], dock.strip.tiles).allSatisfy { $0 === $1 }
                if !sameTiles { rebuilds += 1 }
                previous[id] = dock.strip.tiles
                check(zip(retained[id] ?? [], dock.strip.tiles).allSatisfy { $0 === $1 },
                      "slider sample \(step) recreated tiles on display \(id)")
                check(abs(dock.strip.scrollOffset - (offsets[id] ?? -1)) < 0.001,
                      "slider sample \(step) reset manual scroll on display \(id)")
                let value = store.presentation(for: dock.displayID)
                check(abs(dock.strip.layoutGeometry!.bodyLength - value.fixedLength!) < 0.001,
                      "slider sample \(step) did not apply latest length")
                check(!dock.panel.isVisible, "fixture presented a window")
            }
        }
        print("Slider replay: 24 samples, \(coordinator.docks.count) displays, \(rebuilds) tile-row rebuilds")

        // Samples in the same main-loop turn must produce only the final geometry.
        var frameChanges = 0
        var frameTrace: [NSRect] = []
        first.strip.postsFrameChangedNotifications = true
        let frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
            object: first.strip, queue: nil) { notification in
                guard let view = notification.object as? NSView else { return }
                frameChanges += 1
                frameTrace.append(view.frame)
            }
        defer { NotificationCenter.default.removeObserver(frameObserver) }
        let beforeBurst = first.strip.layoutGeometry
        for step in 0..<40 {
            store.updateManualSizing(for: first.displayID) { $0.length = 700 + Double(step) }
        }
        check(first.strip.layoutGeometry == beforeBurst, "slider burst applied before coalescing")
        drain()
        // The content's exact geometry is followed by the enclosing integral
        // NSWindow frame. Both must belong to the final sample, not earlier
        // publications in the burst.
        check((1...2).contains(frameChanges), "40-sample burst produced \(frameChanges) strip frame changes")
        let finalCanvasWidth = first.strip.layoutGeometry!.canvasSize.width
        check(frameTrace.allSatisfy { abs($0.width - finalCanvasWidth) < 0.000001
              || abs($0.width - first.panel.frame.width) < 0.000001 }, "burst rendered an intermediate slider width")
        check(abs(first.strip.layoutGeometry!.bodyLength - 739) < 0.001, "burst did not apply final sample")
        print("Burst replay: 40 configuration publications, \(frameChanges) strip frame change(s)")

        // Exercise geometry changes with an armed resize gesture. A full
        // populate cancels this session and would drop subsequent drag input.
        let body = first.strip.backdropFrame
        let handle = CGPoint(x: body.midX, y: body.maxY - 1)
        let down = NSEvent.mouseEvent(with: .leftMouseDown,
            location: first.strip.convert(handle, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: first.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        first.strip.mouseDown(with: down)
        check(first.strip.isInteracting, "fixture did not arm a resize handle")
        let previewTiles = first.strip.tiles
        var draft = store.requestedManualSizing(for: first.displayID)
        for step in 0..<12 {
            draft.thickness = 82 + Double(step) * 0.25
            store.setResizePreview(draft, for: first.displayID)
            drain()
            check(first.strip.isInteracting, "preview sample \(step) canceled resize gesture")
            check(zip(previewTiles, first.strip.tiles).allSatisfy { $0 === $1 }, "preview rebuilt tiles")
            check(abs(first.strip.scrollOffset - offsets[DisplayCoordinator.id(first.screen)]!) < 0.001, "preview reset scroll")
        }
        first.strip.cancelResize()
        store.commitManualResize(draft, for: first.displayID)
        drain()
        check(zip(previewTiles, first.strip.tiles).allSatisfy { $0 === $1 }, "resize commit rebuilt tiles")

        // A screen edge changes callbacks as well as geometry, while subsequent
        // sizing updates on that edge must retain the new tiles and scroll.
        for edge in DockEdge.allCases {
            store.setEdge(edge, for: first.displayID)
            drain()
            let edgeTiles = first.strip.tiles
            check(first.strip.layoutGeometry!.edge == edge, "edge geometry stale")
            check(edgeTiles.allSatisfy { $0.menuEdge == edge }, "edge callbacks stale")
            let value = first.strip.layoutGeometry!
            first.strip.scroll.contentView.scroll(to: value.scrollOrigin(forCanonicalOffset: 75,
                actualDocumentSize: first.strip.document.frame.size,
                actualViewportSize: first.strip.scroll.contentView.bounds.size))
            store.updateManualSizing(for: first.displayID) { $0.length = 680 }
            drain()
            check(zip(edgeTiles, first.strip.tiles).allSatisfy { $0 === $1 }, "\(edge) geometry rebuilt tiles")
            check(abs(first.strip.scrollOffset - 75) < 0.001, "\(edge) geometry reset scroll")
            let display = store.displays.first { $0.id == first.displayID }!
            let fullscreen = coordinator.fixtureIsFullscreen(display.runtimeID)
            // Fullscreen uses the physical display's safe rectangle. An ordinary
            // desktop reserves space for the system Dock and menu bar.
            let safe = first.screen.safeAreaInsets
            let frame = first.screen.frame
            let fullscreenRect = CGRect(x: frame.minX + safe.left, y: frame.minY + safe.bottom,
                                        width: frame.width - safe.left - safe.right,
                                        height: frame.height - safe.bottom - safe.top)
            let usable = fullscreen ? fullscreenRect : display.visibleFrame
            let expected = first.strip.layoutGeometry!.panelFrame(in: usable)
            let actual = first.panel.frame
            check(actual.contains(expected)
                  && expected.minX - actual.minX < 1 && expected.minY - actual.minY < 1
                  && actual.maxX - expected.maxX < 1 && actual.maxY - expected.maxY < 1,
                  "\(edge) panel does not closely enclose the fractional geometry")
        }

        let beforeAddition = first.strip.tiles
        store.update { $0.insert([.init(id: "refresh.addition", name: "Extra", path: "/System/Applications/Notes.app")]) }
        drain()
        check(first.strip.tiles.count == beforeAddition.count + 1, "entry addition did not refresh content")
        check(first.strip.tiles.map(\.entry) == store.displayedEntries, "entry addition stale ordering")
        store.update { $0.mode = .runningOnly }
        drain()
        check(first.strip.tiles.map(\.entry) == store.displayedEntries, "running-only content stale")
        store.update { $0.mode = .standard }
        drain()
        check(first.strip.tiles.map(\.entry) == store.displayedEntries, "standard content stale")

        // Identical preview/commit geometry must not cancel the pointer's
        // current magnification or restart its animation at the base size.
        let tile = first.strip.tiles[2]
        let icon = tile.visualIconBounds
        let pointer = first.panel.convertPoint(toScreen: tile.convert(CGPoint(x: icon.midX, y: icon.midY), to: nil))
        first.strip.updatePointer(at: pointer, buttonsPressed: false, force: true)
        for tick in 1...120 {
            first.strip.advanceAnimation(at: Double(tick) / 120, pointer: pointer, buttonsPressed: false)
        }
        let magnified = first.strip.layoutGeometry!
        check(magnified.iconFrames.contains { $0.width > store.presentation(for: first.displayID).style.iconSize + 1 },
              "unchanged-presentation fixture did not magnify")
        _ = first.strip.updatePresentation(first.strip.presentation!)
        check(first.strip.layoutGeometry == magnified, "identical presentation reset pointer magnification")
        first.strip.stopAnimations()

        // A group opened after resizing must not disable exposed resize edges,
        // including edges on another display. Only the popup's covered area
        // owns the pointer; beginning another drag can dismiss the popup.
        let resizeGroup = DockEntry(name: "Resize group", apps: [
            .init(id: "resize.group.one", name: "One", path: "/System/Applications/Notes.app"),
            .init(id: "resize.group.two", name: "Two", path: "/System/Applications/Calendar.app")
        ], isGroup: true)
        store.update { $0.entries.insert(resizeGroup, at: 0) }
        drain()
        for automatic in [false, true] {
            store.setManualAutoLength(automatic, sourceDisplayID: first.displayID)
            for edge in DockEdge.allCases {
                for dock in coordinator.docks.values { store.setEdge(edge, for: dock.displayID) }
                drain()
                for dock in coordinator.docks.values {
                    for attempt in 0..<2 {
                        coordinator.dismissPopups()
                        var size = store.requestedManualSizing(for: dock.displayID)
                        size.thickness = 65 + Double(attempt) * 5
                        store.setResizePreview(size, for: dock.displayID)
                        drain()
                        store.commitManualResize(size, for: dock.displayID)
                        drain()
                        check(abs(dock.strip.layoutGeometry!.barThickness - size.thickness) < 0.001,
                              "resize preview/commit did not apply the requested height")
                        first.strip.tiles.first { $0.entry.id == resizeGroup.id }!.onPress?()
                        let strip = dock.strip
                        let body = strip.backdropFrame
                        let length = edge.isHorizontal ? body.width : body.height
                        let depth = edge.isHorizontal ? body.height : body.width
                        let axis = DockAxisTransform(edge: edge, length: length, thickness: depth)
                        let position = axis.pointToPhysical(CGPoint(x: length * 0.75, y: depth + 2))
                        let local = CGPoint(x: body.minX + position.x, y: body.minY + position.y)
                        let location = strip.convert(local, to: nil)
                        let pointer = dock.panel.convertPoint(toScreen: location)
                        strip.updatePointer(at: pointer, buttonsPressed: false, force: true)
                        let label = "\(edge), automatic=\(automatic), display=\(dock.displayID), attempt=\(attempt)"
                        check(!dock.panel.ignoresMouseEvents, "popup disabled exposed edge: \(label)")
                        check(strip.hitTest(location) === strip, "popup removed resize hit target: \(label)")
                        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                            modifierFlags: [], timestamp: 0, windowNumber: dock.panel.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                        strip.mouseDown(with: down)
                        check(strip.isInteracting, "could not rearm resize with popup: \(label)")
                        strip.cancelResize()
                        check(!strip.isInteracting, "resize stayed armed after cancellation: \(label)")

                        // Exercise the view's boundary with an occluded pointer
                        // without showing a window or moving the desktop cursor.
                        let previousOcclusion = strip.pointerIsOccluded
                        strip.pointerIsOccluded = { $0 == pointer }
                        strip.updatePointer(at: pointer, buttonsPressed: false, force: true)
                        check(dock.panel.ignoresMouseEvents, "covered edge captured popup input: \(label)")
                        strip.mouseDown(with: down)
                        check(!strip.isInteracting, "covered edge armed a resize through popup: \(label)")
                        strip.cancelResize()
                        strip.pointerIsOccluded = previousOcclusion
                    }
                }
            }
        }
        coordinator.dismissPopups()
        store.update { $0.showBadges = true }
        drain()
        try checkOrganizationMotion(in: directory.appendingPathComponent("organization"), check: check)
        let physicalRows = coordinator.docks.count
        coordinator.ensureTwoBadgeTestRows()
        let earlierWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        first.strip.tiles.first { $0.entry.id == resizeGroup.id }!.onPress?()
        let newWindows = NSApp.windows.filter { !earlierWindows.contains(ObjectIdentifier($0)) }
        guard let groupStrip = newWindows.compactMap({ $0.contentView as? DockStripView }).first(where: {
            $0.tiles.first?.groupID == resizeGroup.id
        }) else { fatalError("No expanded badge group in fixture") }

        let rows = coordinator.docks.values.map(\.strip) + [groupStrip]
        let tilesBefore = rows.map { $0.tiles.map(ObjectIdentifier.init) }
        let geometryBefore = rows.map(\.layoutGeometry)
        let scrollBefore = rows.map(\.scrollOffset)
        let badgeTiles = rows.compactMap { $0.tiles.first(where: { store.badgeLabel(for: $0.entry) != nil }) }
        check(badgeTiles.count == rows.count, "Every screen and expanded group must contain one unread fixture")
        check(store.badgeLabel(for: resizeGroup) == "!" && store.badgeLabel(for: groupStrip.tiles[0].entry) == "99+",
              "Unread fixture did not expose both the numeric badge and group alert")
        check(coordinator.docks.count >= 2 && badgeTiles.allSatisfy { $0.badgeScale == 1 },
              "Badge fixture did not start with two rows at default size")
        let configURL = directory.appendingPathComponent("configuration.json")
        let oldFile = try Data(contentsOf: configURL)
        let readsBefore = badgeReads
        for index in 0..<80 {
            store.update { $0.badgeScale = 0.75 + 1.25 * Double(index) / 79 }
        }
        check(try Data(contentsOf: configURL) == oldFile, "Slider drag wrote config synchronously")
        drain()
        check(badgeTiles.allSatisfy { $0.badgeScale == 2 },
              "Badge scale did not update on every screen and the expanded group")
        check(rows.flatMap(\.tiles).filter { store.badgeLabel(for: $0.entry) == nil }.allSatisfy { $0.badgeScale == 1 },
              "Scale drag changed rendering state on tiles without unread badges")
        check(rows.map { $0.tiles.map(ObjectIdentifier.init) } == tilesBefore, "Badge resize rebuilt a row")
        check(rows.map(\.layoutGeometry) == geometryBefore && rows.map(\.scrollOffset) == scrollBefore,
              "Badge resize changed geometry or scroll position")
        check(groupStrip.window != nil && groupStrip.window?.contentView === groupStrip,
              "Badge resize removed the expanded group")
        check(badgeReads == readsBefore, "Badge resize unnecessarily re-read system labels")
        store.flushPendingSave()
        let saved = try JSONDecoder().decode(DockConfiguration.self, from: Data(contentsOf: configURL))
        check(saved.badgeScale == 2 && saved.showBadges, "Releasing slider did not persist the final scale")
        print("Badge replay: \(coordinator.docks.count) Dock rows (\(physicalRows) physical displays) + expanded group, 80 scale updates")
        store.update { $0.showBadges = false }
        store.update { $0.showBadges = true }
        check(store.configuration.badgeScale == 2, "Hiding badges reset the chosen scale")
        coordinator.dismissPopups()
        check(coordinator.docks.values.allSatisfy { !$0.panel.isVisible }, "fixture presented a panel")
        let playback = DisplayCoordinator(store: store, presentsPanels: false)
        playback.checkLifecycleMotion(check)
        // Repeated shutdown must not remove an AppKit event monitor twice.
        playback.stop()
        try DisplayCoordinator.checkLifecycleNotifications(directory: directory.appendingPathComponent("lifecycle-notifications"), check: check)
        print("Coordinator refresh: \(checks) checks, \(failures.count) failures")
        failures.prefix(12).forEach { print("FAIL: \($0)") }
        if !failures.isEmpty { exit(1) }
    }
}

// Shares a source unit with DisplayCoordinator in this isolated executable.
private extension DisplayCoordinator {
    func fixtureIsFullscreen(_ screenID: CGDirectDisplayID) -> Bool {
        visibilitySnapshot.fullscreen.contains(screenID)
    }

    func ensureTwoBadgeTestRows() {
        guard docks.count == 1, let first = docks.values.first else { return }
        let panel = DockPanel()
        let strip = DockStripView()
        let presentation = store.presentation(for: first.displayID)
        _ = strip.populate(entries: store.displayedEntries, store: store,
                           maxWidth: presentation.maximumLength, presentation: presentation) { _ in }
        panel.contentView = strip
        let fixtureID = DisplayCoordinator.id(first.screen) ^ 0x8000_0000
        docks[fixtureID] = ScreenDock(screen: first.screen, displayID: first.displayID, panel: panel, strip: strip)
    }
}

private extension DockCoordinatorRefreshChecks {
    @MainActor static func checkOrganizationMotion(in directory: URL, check: (Bool, String) -> Void) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let apps = ["Pinned", "Active One", "Active Two", "Active Three", "Active Four", "Active Five"].map {
            AppReference(id: "motion." + $0, name: $0, path: "/System/Applications/Notes.app")
        }
        var config = DockConfiguration()
        config.showPreviews = false
        config.showBadges = false
        config.hideSystemDock = false
        config.entries = [DockEntry(name: apps[0].name, apps: [apps[0]])]
        try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("configuration.json"))
        let store = AppStore(directory: directory, runningAppsProvider: { Array(apps.dropFirst()) })
        store.stopBackgroundServices()
        let coordinator = DisplayCoordinator(store: store, presentsPanels: false)
        defer { coordinator.stop() }
        func drain(_ seconds: TimeInterval = 0.025) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        drain()
        guard let dock = coordinator.docks.values.first else { fatalError("No organization fixture dock") }
        func tile(_ app: AppReference) -> DockTile {
            dock.strip.tiles.first { $0.entry.apps.contains(app) }!
        }
        let moving = tile(apps[2])
        let initialID = moving.entry.id
        let oldCenter = moving.presentedIconCenterOnScreen!
        guard let menu = moving.menuProvider?() else { fatalError("Missing real context menu") }
        let pin = menu.indexOfItem(withTitle: L("固定到 DualDock", "Pin to DualDock"))
        guard pin >= 0 else { fatalError("Pin to DualDock is missing from the actual app menu") }
        menu.performActionForItem(at: pin)
        drain()
        let pinned = tile(apps[2])
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        check(store.configuration.allAppIDs.contains(apps[2].id) && initialID != pinned.entry.id,
              "Pin must persist a new entry identity")
        let motion = pinned.layer?.animation(forKey: "dock.reflow") as? CAKeyframeAnimation
        check(reduce ? motion == nil : motion?.duration == 0.42, "Pin feedback does not match motion preference")
        if !reduce {
            let modelCenter = dock.panel.convertPoint(toScreen: pinned.convert(
                NSPoint(x: pinned.visualIconBounds.midX, y: pinned.visualIconBounds.midY), to: nil))
            let startOffset = (motion?.values?.first as? NSValue)?.pointValue
            check(abs((startOffset?.x ?? .infinity) - (oldCenter.x - modelCenter.x)) < 0.001,
                  "Pinned icon did not start at its former running location")
            let modelFrame = pinned.frame
            CATransaction.flush()
            let early = pinned.presentedIconCenterOnScreen!
            drain(0.19)
            let middle = pinned.presentedIconCenterOnScreen!
            drain(0.30)
            let end = pinned.presentedIconCenterOnScreen!
            check(abs(early.x - end.x) > abs(middle.x - end.x) + 2 && abs(middle.x - end.x) > 1,
                  "Pinned artwork did not move smoothly across the divider")
            check(pinned.frame == modelFrame && end == modelCenter, "Pin motion shifted the settled layout")
            print("Pin position samples: \(early.x) → \(middle.x) → \(end.x)")
        }

        for (index, incoming) in [apps[1], apps[3]].enumerated() {
            let target = tile(apps[0])
            let release = target.convert(NSPoint(x: target.visualIconBounds.midX, y: target.visualIconBounds.midY), to: nil)
            let drag = try OrganizationFixtureDrag(window: dock.panel, point: release, tile: tile(incoming))
            check(target.draggingEntered(drag) == .move, "Dock tile rejected the incoming app")
            drain(target.entry.isGroup ? 0.19 : 0.66)
            check(target.performDragOperation(drag), "Dropping after the group dwell failed")
            drain()
            let folder = tile(apps[0])
            check(folder.entry.isGroup && folder.entry.apps.count == index + 2 && folder.entry.apps.contains(incoming),
                  "Creating or extending a group failed")
            let arrival = folder.layer?.sublayers?.first { $0.name == "dock.folderIncoming" }
            check(reduce ? arrival == nil : arrival?.animation(forKey: "dock.folderDrop")?.duration == 0.46,
                  "Accepted drop missing the incoming artwork or violates Reduce Motion")
            if !reduce, let arrival {
                CATransaction.flush()
                let early = arrival.presentation()?.transform.m11
                drain(0.17)
                let middle = arrival.presentation()?.transform.m11
                print("Folder shrink samples: \(early ?? -1) → \(middle ?? -1)")
                check((early ?? 0) > (middle ?? 1) + 0.05 && (middle ?? 0) > 0.31,
                      "Released artwork did not shrink between two compositor frames")
            }
            check(!dock.panel.isVisible, "Organization replay showed a test panel")
            drain(0.54)
            check(folder.layer?.sublayers?.contains { $0.name == "dock.folderIncoming" } != true,
                  "Transient artwork lingered after the drop completed")
        }
        store.update { $0.showPreviews.toggle() }
        drain()
        check(tile(apps[0]).layer?.sublayers?.contains { $0.name == "dock.folderIncoming" } != true,
              "Unrelated preferences replayed an old operation")
        tile(apps[0]).onPress?()
        guard let memberStrip = NSApp.windows.compactMap({ $0.contentView as? DockStripView })
            .first(where: { $0.tiles.first?.groupID == tile(apps[0]).entry.id }), let memberWindow = memberStrip.window
        else { fatalError("Missing expanded destination group") }
        let memberDrop = try OrganizationFixtureDrag(window: memberWindow, point: .zero, tile: tile(apps[5]))
        check(memberStrip.document.performDragOperation(memberDrop), "Drop into the open group was rejected")
        drain()
        check(tile(apps[0]).entry.apps.contains(apps[5]), "Expanded group did not keep the dropped app")
        let memberGhost = tile(apps[0]).layer?.sublayers?.first { $0.name == "dock.folderIncoming" }
        check((memberGhost != nil) == !reduce, "Closing the member panel lost the destination feedback")
        let staleMenu = tile(apps[4]).menuProvider?()
        let oldEntry = store.configuration.entries.first!
        store.update { $0.renameGroup(id: oldEntry.id, name: "Renamed group") }
        drain()
        if let staleMenu, let item = staleMenu.item(withTitle: L("固定到 DualDock", "Pin to DualDock")) {
            staleMenu.performActionForItem(at: staleMenu.index(of: item))
        }
        check(store.configuration.allAppIDs.contains(apps[4].id),
              "Refreshing the source tile while its menu is open prevented pinning the app")
        print("Verified context menu pin, stable app identity, new/existing group drops and transient cleanup")
    }
}

private final class OrganizationFixtureDrag: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint
    let draggingPasteboard = NSPasteboard.withUniqueName()
    @MainActor init(window: NSWindow, point: NSPoint, tile: DockTile) throws {
        draggingDestinationWindow = window
        draggingLocation = point
        super.init()
        let payload = DockDrag(appID: tile.entry.apps.first!.id, entryID: tile.entry.id, groupID: tile.groupID)
        draggingPasteboard.declareTypes([DockDrag.pasteboardType], owner: nil)
        draggingPasteboard.setData(try JSONEncoder().encode(payload), forType: DockDrag.pasteboardType)
    }
    deinit { draggingPasteboard.releaseGlobally() }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

private extension DisplayCoordinator {
    /// Enter through the same workspace notifications as real processes. Only
    /// the source of running app identities is replaced with an isolated fixture.
    static func checkLifecycleNotifications(directory: URL, check: (Bool, String) -> Void) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = AppReference(id: "fixture.lifecycle.publisher", name: "Pinned", path: "/System/Applications/Notes.app")
        var config = DockConfiguration()
        config.showPreviews = false
        config.showBadges = false
        config.hideSystemDock = false
        config.entries = [DockEntry(name: app.name, apps: [app])]
        try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("configuration.json"))
        var running: [AppReference] = []
        let store = AppStore(directory: directory, runningAppsProvider: { running })
        let coordinator = DisplayCoordinator(store: store, presentsPanels: false)
        defer { coordinator.stop(); store.stopBackgroundServices() }
        // This fixture owns the visibility of an offscreen panel; a genuine
        // fullscreen Space elsewhere should have no influence on that choice.
        coordinator.visibility?.stop()
        coordinator.visibility = nil
        guard let dock = coordinator.docks.values.first, let tile = dock.strip.tiles.first else {
            fatalError("Missing pinned application in lifecycle notification fixture")
        }
        let minX = NSScreen.screens.map(\.frame.minX).min() ?? 0
        dock.panel.setFrameOrigin(NSPoint(x: minX - dock.panel.frame.width - 80, y: 0))
        dock.panel.ignoresMouseEvents = true
        dock.panel.orderFrontRegardless()
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        running = [app]
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.07))
        check(store.isRunning(app) && dock.strip.tiles.first === tile, "Workspace start rebuilt or lost the pinned tile")
        check(reduce ? tile.layer?.animation(forKey: "dock.runningState") == nil :
                tile.layer?.animation(forKey: "dock.runningState")?.duration == 0.46,
              "Workspace/Combine launch did not reach the existing pinned tile")
        running = []
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.07))
        check(!store.isRunning(app) && dock.strip.tiles.first === tile, "Workspace quit removed the persistent pin")
        check(reduce ? tile.layer?.animation(forKey: "dock.runningState") == nil :
                tile.layer?.animation(forKey: "dock.runningState")?.duration == 0.34,
              "Workspace/Combine exit did not replace the in-flight launch animation")
    }

    /// Exercise the production capture and playback on an offscreen row. The
    /// system application list, user preferences and physical pointer are untouched.
    func checkLifecycleMotion(_ check: (Bool, String) -> Void) {
        guard let saved = docks.first else { fatalError("lifecycle fixture needs one display") }
        // This isolated coordinator supplies fixture screens. Detach the real Space,
        // pointer and visibility observers before taking offscreen motion samples.
        stop()
        let panel = DockPanel()
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        let strip = DockStripView()
        let pinned = AppReference(id: "fixture.lifecycle.pinned", name: "Pinned", path: "/System/Applications/Notes.app")
        let active = AppReference(id: "fixture.lifecycle.transient", name: "Transient", path: "/System/Applications/Mail.app")
        let member = AppReference(id: "fixture.lifecycle.member", name: "Member", path: pinned.path)
        let kept = [DockEntry(name: pinned.name, apps: [pinned]), DockEntry(name: "Group", apps: [member], isGroup: true)]
        let all = kept + [DockEntry(name: active.name, apps: [active])]
        func populate(_ entries: [DockEntry]) {
            let size = strip.populate(entries: entries, store: store, maxWidth: 750) { _ in }
            let minX = NSScreen.screens.map(\.frame.minX).min() ?? 0
            panel.setFrame(NSRect(x: minX - size.width - 80, y: 0, width: size.width, height: size.height), display: false)
            strip.layoutSubtreeIfNeeded()
        }
        panel.contentView = strip
        populate(all)
        panel.orderFrontRegardless()
        docks = [saved.key: ScreenDock(screen: saved.value.screen, displayID: saved.value.displayID,
                                       panel: panel, strip: strip)]
        defer {
            panel.close()
            docks.removeAll()
        }
        let popup = DockPanel()
        popup.ignoresMouseEvents = true
        let memberStrip = DockStripView()
        let memberSize = memberStrip.populate(entries: [DockEntry(name: member.name, apps: [member])],
                                              groupID: kept[1].id, store: store, maxWidth: 200) { _ in }
        popup.contentView = memberStrip
        popup.setFrame(NSRect(origin: panel.frame.origin, size: memberSize), display: false)
        popup.orderFrontRegardless()
        groupPanel = popup
        defer { popup.close(); groupPanel = nil }
        renderedRunningIDs = [pinned.id, member.id, active.id]
        let ended = captureLifecycle(runningIDs: [], nextEntries: kept, structureChanged: true)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            check(ended == nil, "Reduce Motion scheduled application lifecycle animation")
            return
        }
        guard let ended else { check(false, "Missing quit transition"); return }
        check(ended.departures[saved.key]?.map(\.appID) == [active.id], "Pinned or grouped artwork was treated as a departed tile")
        populate(kept)
        finishLifecycle(ended)
        guard let ghost = panel.childWindows?.compactMap({ $0 as? DockDeparturePanel }).first else {
            check(false, "Transient quit did not leave fading artwork"); return
        }
        check(ghost.appID == active.id && ghost.ignoresMouseEvents, "Departing image captured input or displayed the wrong app")
        check(ghost.contentView?.layer?.animation(forKey: "dock.departure")?.duration == 0.34,
              "Departing icon did not receive the exit duration")
        check(strip.tiles.allSatisfy { $0.layer?.animation(forKey: "dock.runningState")?.duration == 0.34 },
              "Pinned/group quit did not keep their slots and show feedback")
        check(memberStrip.tiles[0].layer?.animation(forKey: "dock.runningState")?.duration == 0.34,
              "Expanded group member lacked quit feedback")
        CATransaction.flush()
        let firstOpacity = ghost.contentView?.layer?.presentation()?.opacity
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.13))
        let nextOpacity = ghost.contentView?.layer?.presentation()?.opacity
        check((firstOpacity ?? 0) > (nextOpacity ?? 1) + 0.08 && (nextOpacity ?? 0) > 0.02,
              "Transient artwork did not visibly fade between compositor frames")
        print("Exit opacity samples: \(firstOpacity ?? -1) → \(nextOpacity ?? -1)")
        guard let started = captureLifecycle(runningIDs: [pinned.id, active.id, member.id], nextEntries: all,
                                             structureChanged: true) else { check(false, "Missing launch transition"); return }
        populate(all)
        finishLifecycle(started)
        check(ghost.parent == nil && !ghost.isVisible, "Rapid relaunch left departing artwork on top of a live icon")
        let arrivals = strip.tiles.map { $0.layer?.animation(forKey: "dock.runningState") as? CAAnimationGroup }
        check(memberStrip.tiles[0].layer?.animation(forKey: "dock.runningState")?.duration == 0.46,
              "Expanded group member lacked launch feedback")
        check(arrivals.count == 3 && arrivals.allSatisfy { $0?.duration == 0.46 },
              "Launch lost motion for a pinned app, group member or transient app")
        check(arrivals[0]?.animations?.count == 1 && arrivals[1]?.animations?.count == 1 &&
              arrivals[2]?.animations?.count == 2, "Only newly inserted apps should fade in")
        check(captureLifecycle(runningIDs: [pinned.id, member.id, active.id], nextEntries: all,
                               structureChanged: true) == nil, "A repeated workspace refresh replayed the animation")
        guard let lastExit = captureLifecycle(runningIDs: [member.id, pinned.id], nextEntries: kept,
                                              structureChanged: true) else { check(false, "Missing final transient exit"); return }
        populate(kept)
        finishLifecycle(lastExit)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.65))
        check(panel.childWindows?.contains { $0 is DockDeparturePanel } != true, "Finished exit retained a child panel")
        populate([])
        renderedRunningIDs = []
        guard let firstLaunch = captureLifecycle(runningIDs: [active.id], nextEntries: [all[2]], structureChanged: true) else {
            check(false, "Empty strip lost first launch"); return
        }
        populate([all[2]])
        finishLifecycle(firstLaunch)
        let arrival = strip.tiles[0].layer?.animation(forKey: "dock.runningState") as? CAAnimationGroup
        check(arrival?.animations?.count == 2, "First app entering an empty row should fade in")
        CATransaction.flush()
        let early = strip.tiles[0].layer?.presentation()?.opacity
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.14))
        let mid = strip.tiles[0].layer?.presentation()?.opacity
        check((mid ?? 0) > (early ?? 1) + 0.06, "Arrival opacity did not increase between compositor frames")
        print("Arrival opacity samples: \(early ?? -1) → \(mid ?? -1)")
        guard let quitBeforeHide = captureLifecycle(runningIDs: [], nextEntries: [], structureChanged: true) else {
            check(false, "Missing exit before Dock hide"); return
        }
        populate([])
        finishLifecycle(quitBeforeHide)
        applyVisibility(.init(hidden: [saved.key], fullscreen: []))
        check(!panel.isVisible && panel.childWindows?.contains { $0 is DockDeparturePanel } != true,
              "Hiding the Dock left a departure image")
        print("Verified app launch, quit, persistent pins, groups, relaunch, empty row and hidden Dock cleanup")

    }
}
