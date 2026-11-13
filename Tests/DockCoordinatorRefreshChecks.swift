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
        let store = AppStore(directory: directory)
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
        // NSWindow rounds fractional content height to integral points after
        // placement. That may add one frame notification for the same width.
        check((1...2).contains(frameChanges), "40-sample burst produced \(frameChanges) strip frame changes")
        check(Set(frameTrace.map(\.width)).count == 1, "burst rendered an intermediate slider width")
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
            check(abs(actual.minX - expected.minX) < 1 && abs(actual.minY - expected.minY) < 1
                  && abs(actual.width - expected.width) < 1 && abs(actual.height - expected.height) < 1,
                  "\(edge) panel differs from geometry beyond NSWindow integral-point rounding")
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
        check(coordinator.docks.values.allSatisfy { !$0.panel.isVisible }, "fixture presented a panel")
        print("Coordinator refresh: \(checks) checks, \(failures.count) failures")
        failures.prefix(12).forEach { print("FAIL: \($0)") }
        if !failures.isEmpty { exit(1) }
    }
}
