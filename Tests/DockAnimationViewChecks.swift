import AppKit
import QuartzCore
import DualDockCore

/// Counts production drawRect calls during a continuous pointer replay through
/// the actual strip/scroll/document hierarchy. A plain NSView parent is not an
/// equivalent seam: explicit display there repaints all of its children.
@main
struct DockAnimationViewChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = DockConfiguration()
        configuration.customSizing = .visualDefault
        configuration.showBadges = false
        configuration.showPreviews = false
        configuration.magnificationScale = 2
        configuration.dockWidth = 1500
        configuration.iconSize = 48
        configuration.iconSpacing = 3
        configuration.entries = (0..<28).map { index in
            DockEntry(name: "Fixture", apps: [.init(id: "fixture.\(index)", name: "Fixture",
                                                   path: "/System/Applications/Notes.app")])
        }
        try JSONEncoder().encode(configuration).write(to: directory.appendingPathComponent("configuration.json"))
        let store = AppStore(directory: directory, runningAppsProvider: { [] })
        store.stopBackgroundServices()
        let display = DockDisplayInfo(id: "fixture", runtimeID: 99, name: "Fixture",
            frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
            visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1129), isPrimary: true)
        store.updateDisplays([display])
        let strip = DockStripView()
        let presentation = store.presentation(for: display.id)
        let size = strip.populate(entries: configuration.entries, store: store, maxWidth: 1800,
                                  presentation: presentation) { _ in }
        let panel = DockPanel()
        panel.appearance = NSAppearance(named: .aqua)
        panel.contentView = strip
        panel.setFrame(CGRect(x: -8000, y: -8000, width: size.width, height: size.height), display: false)
        strip.layoutSubtreeIfNeeded()
        let body = strip.backdropFrame, originalWindow = panel.frame

        var draws = 0
        let selector = #selector(NSView.draw(_:))
        let method = class_getInstanceMethod(DockTile.self, selector)!
        let originalIMP = method_getImplementation(method)
        typealias Draw = @convention(c) (AnyObject, Selector, NSRect) -> Void
        let original = unsafeBitCast(originalIMP, to: Draw.self)
        let replacement: @convention(block) (NSView, NSRect) -> Void = { view, rect in
            original(view, selector, rect)
            draws += 1
        }
        let instrumented = imp_implementationWithBlock(replacement)
        method_setImplementation(method, instrumented)
        defer { method_setImplementation(method, originalIMP); imp_removeBlock(instrumented) }
        func check(_ condition: Bool, _ message: String) {
            if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        func paint() { strip.displayIfNeeded(); CATransaction.flush() }
        paint()
        check(draws > 0, "Hidden backing window did not execute the production draw path")
        draws = 0
        var peak: CGFloat = 0
        let frames = 360
        // CPU work on the main thread including synchronous hidden-view painting.
        // A synthetic display clock is not a measurement of hardware presentation.
        func timing(_ name: String, samples: [Double], hz: Int) {
            let sorted = samples.sorted()
            let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
            let over = sorted.filter { $0 > 1000 / Double(hz) }.count
            print(String(format: "%@ @%d Hz: mean %.3f ms, P95 %.3f ms, over budget %d/%d",
                         name, hz, sorted.reduce(0, +) / Double(sorted.count), p95, over, sorted.count))
        }
        func threadMilliseconds() -> Double {
            Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000
        }
        for hz in [60, 120] {
            strip.resetMagnification()
            var samples: [Double] = [], cpu: [Double] = []
            draws = 0
            for frame in 0..<frames {
                let began = CACurrentMediaTime(), threadBegan = threadMilliseconds()
                let phase = CGFloat(frame % 180) / 179
                let local = CGPoint(x: body.minX + 70 + (body.width - 140) * (frame < 180 ? phase : 1 - phase),
                                    y: body.midY)
                let pointer = panel.convertPoint(toScreen: strip.convert(local, to: nil))
                strip.updatePointer(at: pointer, buttonsPressed: false, force: true)
                strip.advanceAnimation(at: Double(frame) / Double(hz), pointer: pointer, buttonsPressed: false)
                paint()
                samples.append((CACurrentMediaTime() - began) * 1000)
                cpu.append(threadMilliseconds() - threadBegan)
                peak = max(peak, strip.tiles.map { $0.visualIconBounds.width }.max() ?? 0)
                check(!panel.isVisible && panel.frame == originalWindow && strip.backdropFrame == body,
                      "Hover displayed or moved the Dock window/backdrop")
            }
            timing("hover", samples: samples, hz: hz)
            timing("hover CPU", samples: cpu, hz: hz)
        }
        check(peak > 60, "The replay failed to magnify real tile frames")
        for tile in strip.tiles {
            guard let artwork = tile.layer?.sublayers?.first(where: { $0.name == "dock.icon" }) else {
                check(false, "Missing unbadged icon compositor plane"); break
            }
            let artworkBox = artwork.frame
            let target = tile.visualIconBounds
            let error = [abs(artworkBox.minX - target.minX), abs(artworkBox.minY - target.minY),
                         abs(artworkBox.width - target.width), abs(artworkBox.height - target.height)].max()!
            check(artwork.contents != nil && error < 0.0001 && !artwork.isHidden,
                  "Displayed artwork \(artworkBox) did not match \(target), hidden=\(artwork.isHidden)")
        }
        let maximumDraws = frames * strip.tiles.count * 3 / 4
        check(draws < maximumDraws, "Continuous hover repainted too much of the strip: \(draws), limit \(maximumDraws)")
        let afterWave = draws
        strip.tiles.forEach { $0.refreshBadge() }
        paint()
        check(draws >= afterWave + strip.tiles.count, "Badge invalidation lost drawing updates")
        print("PASS continuous 28-icon wave: \(afterWave) draws / \(frames) frames (limit \(maximumDraws))")
        print("PASS stationary containers, real magnification, and badge repaint behavior")
        strip.resetMagnification()
        for resizeEdge in [false, true] {
            var samples: [Double] = [], cpu: [Double] = []
            let start = store.requestedManualSizing(for: display.id)
            for tick in 0..<100 {
                let wave = sin(Double(tick) * 0.12)
                let began = CACurrentMediaTime(), threadBegan = threadMilliseconds()
                if resizeEdge {
                    let proposal = DockResizePolicy.propose(start: start, handle: .inward, edge: .bottom,
                        screenDelta: CGSize(width: 0, height: wave * 9), bounds: presentation.resizeBounds)
                    store.setResizePreview(proposal, for: display.id)
                } else {
                    store.updateCustomSizing(for: display.id) { $0.iconSize = 48 + wave * 8 }
                }
                _ = strip.updatePresentation(store.presentation(for: display.id))
                panel.placeDock(strip, in: display.visibleFrame, display: false)
                paint()
                samples.append((CACurrentMediaTime() - began) * 1000)
                cpu.append(threadMilliseconds() - threadBegan)
            }
            let name = resizeEdge ? "edge resize" : "size slider"
            timing(name, samples: samples, hz: 120)
            timing(name + " CPU", samples: cpu, hz: 120)
        }
        store.setResizePreview(nil, for: display.id)
        strip.stopAnimations()
        panel.close()
        store.stopBackgroundServices()
        print("Dock animation drawing checks passed; no windows shown or input posted")
    }
}
