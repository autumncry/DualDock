import AppKit
import DualDockCore

/// Exercises real AppStore -> coordinator -> NSWindow placement. All windows
/// stay hidden; no desktop input or user configuration is read or modified.
@main
struct DockPlacementChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = DockConfiguration()
        config.showBadges = false
        config.showPreviews = false
        config.hideSystemDock = false
        config.dockWidth = 900.3
        config.iconSize = 39.37
        config.manualIconScale = 0.65
        config.entries = (0..<6).map {
            DockEntry(name: "Fixture", apps: [.init(id: "placement.\($0)", name: "Fixture",
                path: "/System/Applications/Notes.app")])
        }
        try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("configuration.json"))
        let store = AppStore(directory: directory)
        store.stopBackgroundServices()
        let coordinator = DisplayCoordinator(store: store, presentsPanels: false)
        defer { coordinator.stop(); store.stopBackgroundServices() }
        var failures: [String] = []
        var checks = 0
        var maximumCenterError: CGFloat = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        func drain() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        drain()
        guard let first = coordinator.docks.values.first else { fatalError("No attached screen for hidden fixture") }

        func verifyPlacement(_ context: String) {
            for dock in coordinator.docks.values {
                guard let geometry = dock.strip.layoutGeometry,
                      let display = store.displays.first(where: { $0.id == dock.displayID }) else {
                    failures.append("\(context): missing display geometry")
                    continue
                }
                // This is the same conversion used by visibility, popup anchors
                // and pointer hit-testing, rather than the ideal geometry alone.
                let actual = dock.panel.convertToScreen(dock.strip.convert(dock.strip.backdropFrame, to: nil))
                let desiredPanel = geometry.panelFrame(in: display.visibleFrame)
                let expected = geometry.backdropRect.offsetBy(dx: desiredPanel.minX, dy: desiredPanel.minY)
                check(dock.panel.frame.contains(desiredPanel), "\(context): window clipped the fractional canvas")
                check(abs(dock.strip.frame.minX + dock.panel.frame.minX - desiredPanel.minX) < 0.000001
                      && abs(dock.strip.frame.minY + dock.panel.frame.minY - desiredPanel.minY) < 0.000001,
                      "\(context): content origin lost its fractional placement")
                let centerError = geometry.edge.isHorizontal
                    ? abs(actual.midX - expected.midX) : abs(actual.midY - expected.midY)
                maximumCenterError = max(maximumCenterError, centerError)
                check(centerError < 0.000001, "\(context): bar center drifted \(centerError)pt on \(dock.displayID)")
                check(abs(actual.minX - expected.minX) < 0.000001 && abs(actual.minY - expected.minY) < 0.000001,
                      "\(context): bar lost its edge anchor")
                check(abs(actual.width - expected.width) < 0.000001 && abs(actual.height - expected.height) < 0.000001,
                      "\(context): content dimensions changed during placement")
                check(!dock.panel.isVisible, "fixture presented a window")
                check(abs(dock.strip.scrollOffset) < 0.000001,
                      "\(context): layout rounding became an unintended user scroll")
                for index in Set([0, dock.strip.tiles.count - 1]) where dock.strip.tiles.indices.contains(index) {
                    let tile = dock.strip.tiles[index]
                    let actualIcon = dock.panel.convertToScreen(tile.convert(tile.visualIconBounds, to: nil))
                    // This fixture never scrolls. NSClipView may use a matching
                    // fractional frame/bounds origin for backing alignment;
                    // those offsets cancel and are not a user scroll distance.
                    let clipOrigin = geometry.scrollOrigin(forCanonicalOffset: 0,
                        actualDocumentSize: dock.strip.document.frame.size,
                        actualViewportSize: dock.strip.scroll.contentView.bounds.size)
                    let expectedIcon = geometry.iconFrames[index].offsetBy(
                        dx: desiredPanel.minX + geometry.viewportRect.minX - clipOrigin.x,
                        dy: desiredPanel.minY + geometry.viewportRect.minY - clipOrigin.y)
                    check(abs(actualIcon.midX - expectedIcon.midX) < 0.000001
                          && abs(actualIcon.midY - expectedIcon.midY) < 0.000001,
                          "\(context): icon \(index) shifted from its continuous screen position by \(actualIcon.midX - expectedIcon.midX),\(actualIcon.midY - expectedIcon.midY)pt")
                }
                // A screen-space point still round-trips through the offset root
                // and hits the real tile; menu/preview anchors use this path too.
                if let tile = dock.strip.tiles.first {
                    let icon = tile.visualIconBounds
                    let point = NSPoint(x: icon.midX, y: icon.midY)
                    let screenPoint = dock.panel.convertPoint(toScreen: tile.convert(point, to: nil))
                    let local = dock.strip.convert(dock.panel.convertPoint(fromScreen: screenPoint), from: nil)
                    check(dock.strip.containsInteractivePoint(local), "\(context): tile lost screen-space hit testing")
                    let restored = tile.convert(dock.panel.convertPoint(fromScreen: screenPoint), from: nil)
                    check(abs(restored.x - point.x) < 0.000001 && abs(restored.y - point.y) < 0.000001,
                          "\(context): icon screen coordinate did not round-trip")
                }
            }
        }
        verifyPlacement("initial")
        for adaptiveLength in [false, true] {
            store.setManualAutoLength(adaptiveLength, sourceDisplayID: first.displayID)
            for edge in DockEdge.allCases {
                for dock in coordinator.docks.values { store.setEdge(edge, for: dock.displayID) }
                store.updateManualSizing(for: first.displayID) {
                    $0.length = 900.3; $0.thickness = 54.37; $0.iconScale = 0.65
                }
                drain()
                verifyPlacement("mode \(adaptiveLength), \(edge) initial")
                for step in 0..<18 {
                    let bounds = store.editingSizingBounds(for: first.displayID)
                    store.updateManualSizing(for: first.displayID) {
                        $0.length = min(bounds.maxLength, max(900.3, bounds.minLength) + Double(step) * 1.37)
                    }
                    drain()
                    verifyPlacement("mode \(adaptiveLength), \(edge) length \(step)")
                }
                for step in 0..<18 {
                    store.updateManualSizing(for: first.displayID) { $0.thickness = 54.37 + Double(step) * 0.137 }
                    drain()
                    verifyPlacement("mode \(adaptiveLength), \(edge) thickness \(step)")
                }
                // Crossing the screen limit changes transparent end reserve.
                // Applying/canceling a preview must not lose the fractional
                // origin correction or snap back to its previous placement.
                let limit = store.sizingBounds(for: first.displayID).maxLength
                for delta in [-1.37, -0.37, 0, 0.37, 1.37] {
                    var draft = store.requestedManualSizing(for: first.displayID)
                    draft.length = limit + delta
                    store.setResizePreview(draft, for: first.displayID)
                    drain()
                    verifyPlacement("mode \(adaptiveLength), \(edge) limit preview \(delta)")
                    store.commitManualResize(draft, for: first.displayID)
                    drain()
                    verifyPlacement("mode \(adaptiveLength), \(edge) limit commit \(delta)")
                }
                store.setResizePreview(nil, for: first.displayID)
                drain()
                verifyPlacement("mode \(adaptiveLength), \(edge) final")
            }
        }
        print("Dock placement: \(checks) checks, \(failures.count) failures; maximum center error \(maximumCenterError)pt")
        failures.prefix(12).forEach { print("FAIL: \($0)") }
        if !failures.isEmpty { exit(1) }
    }
}
