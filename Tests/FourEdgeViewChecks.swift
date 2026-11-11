import AppKit
import DualDockCore

/// Integration checks against production APIs. Windows remain hidden, mouse
/// events are delivered only to owned views, and menu providers return nil.
@main
struct FourEdgeViewChecks {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        func near(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 0.001) -> Bool { abs(a - b) < tolerance }
        let display = DockDisplayInfo(id: "fixture", runtimeID: 987, name: "Fixture",
            frame: CGRect(x: -2000, y: 300, width: 1440, height: 1000),
            visibleFrame: CGRect(x: -2000, y: 300, width: 1440, height: 972), isPrimary: true)
        let variants: [(String, Int, Double, Double, Double, Double)] = [
            ("fit", 7, 700, 66, 1, 14), ("fractional", 9, 650.375, 65.57637448, 0.73, 6.47977),
            ("overflow", 30, 320, 66, 1, 14), ("large", 30, 240, 100.375, 1.25, 0)]
        for edge in DockEdge.allCases {
            for (name, count, length, thickness, ratio, gap) in variants {
                let directory = root.appendingPathComponent("\(edge.rawValue)-\(name)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let entries = (0..<count).map { DockEntry(name: "Fixture", apps: [AppReference(
                    id: "test.\($0)", name: "Fixture", path: "/System/Applications/Notes.app")]) }
                var configuration = DockConfiguration()
                configuration.showBadges = false
                configuration.showPreviews = false
                configuration.synchronizeSizes = false
                configuration.dockWidth = length
                configuration.entries = Array(entries.prefix(3))
                configuration.displaySettings[display.id] = .init(edge: edge, manualSizing:
                    .init(length: length, thickness: thickness, iconScale: ratio, iconSpacing: gap))
                try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("configuration.json"))
                let store = AppStore(directory: directory)
                store.updateDisplays([display])
                let presentation = store.presentation(for: display.id)
                let strip = DockStripView()
                let size = strip.populate(entries: entries, store: store, maxWidth: presentation.maximumLength,
                                          presentation: presentation) { _ in }
                let panel = DockPanel()
                panel.contentView = strip
                panel.setFrame(NSRect(x: -8000, y: -8000, width: size.width, height: size.height), display: false)
                strip.layoutSubtreeIfNeeded()
                let geometry = strip.layoutGeometry!
                let identities = strip.tiles.map(ObjectIdentifier.init)
                check(!panel.isVisible, "Test window became visible")
                check(!strip.scroll.hasHorizontalScroller && !strip.scroll.hasVerticalScroller, "Unexpected scrollbars")
                for (index, tile) in strip.tiles.enumerated() {
                    let icon = strip.document.convert(tile.visualIconBounds, from: tile)
                    let expected = geometry.iconFrames[index]
                    check(near(icon.minX, expected.minX) && near(icon.minY, expected.minY)
                          && near(icon.width, expected.width) && near(icon.height, expected.height), "Icon coordinate mismatch")
                    check(near(icon.width, icon.height), "Icon was stretched")
                }
                let placement = geometry.panelFrame(in: display.visibleFrame)
                panel.setFrame(placement, display: false)
                let body = panel.convertToScreen(strip.convert(strip.backdropFrame, to: nil))
                check(edge.isHorizontal ? near(body.midX, display.visibleFrame.midX, tolerance: 1.01)
                                        : near(body.midY, display.visibleFrame.midY, tolerance: 1.01), "Backdrop not centered")
                panel.setFrameOrigin(NSPoint(x: -8000, y: -8000))
                let clip = strip.scroll.contentView
                let maximum = max(0, edge.isHorizontal ? strip.document.frame.width - clip.bounds.width
                                                       : strip.document.frame.height - clip.bounds.height)
                if !edge.isHorizontal && maximum > 0 { check(clip.bounds.minY > 0, "Vertical row did not start at the top") }
                for offset in [CGFloat(0), maximum / 2, maximum] {
                    clip.scroll(to: geometry.scrollOrigin(forCanonicalOffset: offset,
                        actualDocumentSize: strip.document.frame.size, actualViewportSize: clip.bounds.size))
                    strip.scroll.reflectScrolledClipView(clip)
                    check(near(strip.scrollOffset, offset, tolerance: 1), "Canonical scroll offset mismatch")
                    let retained = strip.scrollOffset
                    _ = strip.updatePresentation(presentation)
                    check(near(strip.scrollOffset, retained, tolerance: 1), "Geometry refresh changed scroll position")
                    check(strip.tiles.map(ObjectIdentifier.init) == identities, "Geometry refresh rebuilt tiles")
                    for tile in strip.tiles {
                        let icon = strip.convert(tile.visualIconBounds, from: tile)
                        let center = NSPoint(x: icon.midX, y: icon.midY)
                        if strip.scroll.frame.contains(center) {
                            check(strip.hitTest(center) === tile, "Visible icon hit mismatch")
                        }
                    }
                }
                store.setResizePreview(.init(length: length * 0.9, thickness: thickness * 1.1,
                                             iconScale: ratio, iconSpacing: gap), for: display.id)
                _ = strip.updatePresentation(store.presentation(for: display.id))
                check(strip.tiles.map(ObjectIdentifier.init) == identities, "Live resize rebuilt tiles")
                check(near(strip.layoutGeometry!.bodyLength, CGFloat(store.effectiveManualSizing(for: display.id).length)),
                      "Resize preview dimensions not applied")
                store.setResizePreview(nil, for: display.id)
                strip.stopAnimations()
                panel.close()
                let group = store.presentation(for: display.id, group: true)
                check(group.edge == .bottom && !group.canResize, "Group must stay horizontal and nonresizable")
                store.setAdaptiveSizing(true)
                let adaptive = store.presentation(for: display.id)
                let adaptiveStrip = DockStripView()
                _ = adaptiveStrip.populate(entries: Array(entries.prefix(3)), store: store,
                                            maxWidth: adaptive.maximumLength, presentation: adaptive) { _ in }
                let adaptiveGeometry = adaptiveStrip.layoutGeometry!
                check(near(adaptiveGeometry.canonicalIconFrames.first!.minX - adaptiveGeometry.canonicalBackdropRect.minX,
                           adaptive.style.leadingPadding), "Adaptive leading padding contains magnification reserve")
                check(near(adaptiveGeometry.canonicalBackdropRect.maxX - adaptiveGeometry.canonicalIconFrames.last!.maxX,
                           adaptive.style.trailingPadding), "Adaptive trailing padding contains magnification reserve")
                check(!adaptive.canResize, "Adaptive mode permits edge resizing")
                adaptiveStrip.stopAnimations()
                store.stopBackgroundServices()
            }
        }
        // Model an icon crossing the inward resize edge. Secondary clicks must
        // still reach its menu provider, without opening a real menu.
        guard let screen = NSScreen.screens.first else { fatalError("WindowServer display required for menu coordinate checks") }
        for edge in DockEdge.allCases {
            let directory = root.appendingPathComponent("menu-\(edge.rawValue)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var configuration = DockConfiguration()
            configuration.showBadges = false
            configuration.showPreviews = false
            configuration.dockWidth = 400
            let entry = DockEntry(name: "Fixture", apps: [.init(id: "menu.fixture", name: "Fixture", path: "/System/Applications/Notes.app")])
            configuration.entries = [entry]
            try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("configuration.json"))
            let store = AppStore(directory: directory)
            let sizing = DockManualSizing(length: 400, thickness: 64)
            let presentation = DockPresentation(displayID: nil, edge: edge,
                style: .init(iconSize: 64, barThickness: 64, gap: 0, leadingPadding: 6, trailingPadding: 6),
                maximumLength: 1000, fixedLength: 400, resizeMargin: 6,
                resizeBounds: .init(minLength: 120, maxLength: 1000, minThickness: 33, maxThickness: 200),
                requestedManualSizing: sizing, canResize: true)
            let strip = DockStripView()
            strip.onResizeEnded = { _ in }
            var requests = 0
            let size = strip.populate(entries: [entry], store: store, maxWidth: 1000, presentation: presentation) {
                $0.menuProvider = { requests += 1; return nil }
            }
            let panel = DockPanel()
            panel.contentView = strip
            panel.setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2,
                                  y: screen.visibleFrame.midY - size.height / 2,
                                  width: size.width, height: size.height), display: false)
            strip.layoutSubtreeIfNeeded()
            let geometry = strip.layoutGeometry!
            let canonical = CGPoint(x: geometry.canonicalIconFrames[0].midX, y: 63)
            let documentPoint = geometry.documentTransform.pointToPhysical(canonical)
            let point = strip.convert(documentPoint, from: strip.document)
            check(strip.hitTest(point) === strip, "Fixture did not target a resize edge")
            let windowPoint = strip.convert(point, to: nil)
            func event(_ type: NSEvent.EventType, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: modifiers,
                    timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 0)!
            }
            strip.rightMouseDown(with: event(.rightMouseDown, []))
            check(requests == 1, "Resize edge swallowed the icon right-click menu")
            strip.mouseDown(with: event(.leftMouseDown, .control))
            check(requests == 2, "Resize edge swallowed the icon Control-click menu")
            check(!strip.isResizing && !panel.isVisible, "Context check started resizing or displayed a window")
            strip.stopAnimations()
            panel.close()
            store.stopBackgroundServices()
        }
        failures.forEach { print("FAIL: \($0)") }
        print("\(checks) four-edge AppKit checks, \(failures.count) failures; no windows shown or input posted")
        exit(failures.isEmpty ? 0 : 1)
    }
}
