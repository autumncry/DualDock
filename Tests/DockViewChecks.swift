import AppKit
import DualDockCore

/// Hidden component checks: no windows are shown and no system input is posted.
@main
struct DockViewChecks {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
            checks += 1
        }
        for count in [5, 20] {
            for grouped in [false, true] {
                var configuration = DockConfiguration()
                configuration.iconSize = 47.69190871369294
                configuration.iconSpacing = 6.479771784232365
                configuration.showBadges = false
                configuration.showPreviews = false
                configuration.entries = (0..<count).map { index in
                    DockEntry(name: "Fixture", apps: [.init(id: "test.\(index)", name: "Fixture", path: "/System/Applications/Notes.app")])
                }
                let directory = root.appendingPathComponent("\(count)-\(grouped)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("configuration.json"))
                let store = AppStore(directory: directory)
                let strip = DockStripView()
                let size = strip.populate(entries: configuration.entries, groupID: grouped ? UUID() : nil,
                                          store: store, maxWidth: count == 5 ? 1800 : 320) { _ in }
                let panel = DockPanel()
                panel.contentView = strip
                panel.setFrame(NSRect(x: -5000, y: -5000, width: size.width, height: size.height), display: false)
                strip.layoutSubtreeIfNeeded()
                let clip = strip.scroll.contentView
                let right = clip.constrainBoundsRect(NSRect(x: 100_000, y: 0, width: clip.bounds.width, height: clip.bounds.height))
                check(!panel.isVisible, "Checks must not show windows")
                check(!strip.scroll.hasHorizontalScroller && !strip.scroll.hasVerticalScroller, "Unexpected scrollbars")
                if count == 5 {
                    check(strip.document.frame.width == clip.bounds.width, "Fractional pixel creates phantom scrolling")
                    check(right.minX == 0, "A fitting row must not scroll")
                    // Locally delivered test event, never posted to the desktop.
                    let event = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                                        wheelCount: 2, wheel1: 0, wheel2: 120, wheel3: 0)!)!
                    for _ in 0..<40 { strip.scrollWheel(with: event) }
                    check(clip.bounds.origin == .zero, "Wheel input moved a fitting row")
                } else {
                    check(right.minX > 1, "Genuine overflow must remain scrollable")
                    let panelFrame = panel.frame
                    let backdrop = strip.backdropFrame
                    clip.scroll(to: right.origin)
                    strip.scroll.reflectScrolledClipView(clip)
                    check(clip.bounds.minX > 1, "Scroll position cannot advance")
                    check(panel.frame == panelFrame && strip.backdropFrame == backdrop, "Scrolling moved the Dock")
                }
                if !grouped {
                    let fixedWidth = panel.frame.width
                    let backdropWidth = strip.backdropFrame.width
                    for gap in [0.0, 32.0, configuration.iconSpacing] {
                        store.update { $0.iconSpacing = gap }
                        let updated = strip.populate(entries: configuration.entries, store: store,
                                                     maxWidth: count == 5 ? 1800 : 320) { _ in }
                        panel.setFrame(NSRect(origin: panel.frame.origin, size: updated), display: false)
                        strip.layoutSubtreeIfNeeded()
                        check(panel.frame.width == fixedWidth && strip.backdropFrame.width == backdropWidth,
                              "Spacing slider resized the main Dock")
                        check(abs((strip.tiles.first?.visualIconBounds.width ?? 0) - configuration.iconSize) < 0.001,
                              "Spacing slider resized application icons")
                    }
                }
                // A higher popup owns hover even when its screen coordinates
                // overlap a lower strip's transparent canvas.
                strip.scroll.contentView.scroll(to: .zero)
                strip.scroll.reflectScrolledClipView(strip.scroll.contentView)
                let tile = strip.tiles[0]
                var enters = 0
                var leaves = 0
                var covered = false
                tile.onHover = { if $0 { enters += 1 } else { leaves += 1 } }
                strip.pointerIsOccluded = { _ in covered }
                let icon = tile.visualIconBounds
                let local = tile.convert(NSPoint(x: icon.midX, y: icon.midY), to: nil)
                let pointer = panel.convertToScreen(NSRect(origin: local, size: .zero)).origin
                strip.updatePointer(at: pointer, buttonsPressed: false, force: true)
                check(enters == 1, "Initial icon hover missing")
                covered = true
                strip.updatePointer(at: pointer, buttonsPressed: false, force: true)
                check(enters == 1 && leaves == 1, "Covered strip must end hover once without another enter")
                check(panel.ignoresMouseEvents, "Covered strip must not intercept the popup")
                strip.updatePointer(at: pointer, buttonsPressed: false, force: true)
                check(enters == 1 && leaves == 1, "Covered pointer repeatedly changed hover ownership")
                covered = false
                strip.updatePointer(at: pointer, buttonsPressed: false)
                check(enters == 2, "Returning to the same icon must reopen hover")
                check(!panel.ignoresMouseEvents, "Uncovered icon must be clickable again")
                strip.stopAnimations()
                panel.close()
                store.stopBackgroundServices()
            }
        }
        // Keep the running-app universe inside one collapsed fixture group so
        // add/remove checks do not depend on the host's application count.
        do {
            var configuration = DockConfiguration()
            configuration.dockWidth = 1000
            configuration.magnificationScale = 1.5
            configuration.showBadges = false
            configuration.showPreviews = false
            let directory = root.appendingPathComponent("automatic-width")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("configuration.json"))
            let store = AppStore(directory: directory)
            store.updateDisplayLimits(screenSizes: [CGSize(width: 1600, height: 1000)])
            let apps = (0..<4).map { index in
                AppReference(id: "test.auto.\(index)", name: "Fixture", path: "/System/Applications/Notes.app")
            }
            let members = store.runningApps.isEmpty ? [apps[0]] : store.runningApps
            store.update {
                $0.entries = [DockEntry(name: "Group", apps: members, isGroup: true)]
                    + apps[1...2].map { DockEntry(name: $0.name, apps: [$0]) }
                $0.autoAdjustWidth = true
            }
            check(store.displayedEntries.count == 3, "Collapsed running-app group must count as one item")
            let height = store.effectiveDockHeight
            let width = store.effectiveDockWidth
            store.update { $0.insert([apps[3]]) }
            check(store.effectiveDockWidth > width, "Adding an app did not expand automatic width")
            check(store.effectiveDockHeight == height, "Automatic width changed the height")
            store.update { $0.removeApp(id: apps[3].id) }
            check(store.effectiveDockWidth == width, "Removing an app did not restore automatic width")
            let saved = store.configuration
            store.updateManualSizing(for: nil) {
                $0.iconSpacing = 32; $0.length = 1400; $0.thickness = 100; $0.iconScale = 0.5
            }
            check(store.configuration == saved, "Complete adaptive mode must reject manual size changes")
            check(store.effectiveDockWidth == width, "Manual settings changed native adaptive width")
            check(store.effectiveDockHeight == height, "Manual settings changed native adaptive height")
            check(store.configuration.dockWidth == 1000, "Automatic width overwrote the saved manual width")
            let strip = DockStripView()
            let size = strip.populate(entries: store.displayedEntries, store: store, maxWidth: 1600) { _ in }
            check(abs(Double(strip.layoutGeometry?.bodyLength ?? 0) - width) < 0.001
                    && abs(Double(strip.backdropFrame.height) - height) < 0.001,
                  "Rendered native adaptive dimensions differ")
            check(size.width >= strip.backdropFrame.width, "Magnification canvas cannot crop the backdrop")
            check(!store.presentation(for: nil).canResize, "Adaptive mode must disable edge resizing")
            store.setAdaptiveSizing(false)
            check(store.effectiveDockWidth == 1000, "Disabling automatic width must restore the manual choice")
            check(store.effectiveDockHeight == 66, "Disabling adaptive sizing must restore manual thickness")
            store.updateManualSizing(for: nil) { $0.thickness = 82.5 }
            check(store.effectiveDockHeight == 82.5, "Manual thickness control must remain available")
            store.update { $0.iconSpacing = 32 }
            check(store.effectiveDockWidth == 1000, "Spacing must not change the restored manual width")
            strip.stopAnimations()
            store.stopBackgroundServices()
        }
        for size in [NSSize(width: 480, height: 320), NSSize(width: 180, height: 600),
                     NSSize(width: 3000, height: 50), NSSize(width: 80, height: 3000)] {
            let image = NSImage(size: size)
            let card = WindowPreviewCardView(title: "Fixture", image: image)
            var activated = 0
            var closed = 0
            card.onActivate = { activated += 1 }
            card.onClose = { closed += 1 }
            let point = NSPoint(x: card.closeButton.frame.midX, y: card.closeButton.frame.midY)
            check(card.bounds.contains(card.closeButton.frame), "Close control must stay inside the preview card")
            check(card.hitTest(point) === card.closeButton, "Thumbnail intercepted the close control")
            card.closeButton.performClick(nil)
            check(closed == 1 && activated == 0, "Close must not activate the thumbnail")
            card.thumbnailButton.performClick(nil)
            check(closed == 1 && activated == 1, "Thumbnail must not close the window")
            check(card.closeButton.accessibilityLabel()?.contains("关闭窗口") == true, "Close accessibility label missing")
        }
        print("\(checks) hidden AppKit scroll/preview checks passed; no desktop input posted")
    }
}
