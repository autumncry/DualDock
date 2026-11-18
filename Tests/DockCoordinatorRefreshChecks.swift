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
            let expected = first.strip.layoutGeometry!.panelFrame(in: display.visibleFrame)
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
        print("Coordinator refresh: \(checks) checks, \(failures.count) failures")
        failures.prefix(12).forEach { print("FAIL: \($0)") }
        if !failures.isEmpty { exit(1) }
    }
}

// Shares a source unit with DisplayCoordinator in this isolated executable.
private extension DisplayCoordinator {
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
