import AppKit
import DualDockCore

/// Replays the production pointer/animation path without showing any windows,
/// posting mouse events, reading user configuration, or changing system settings.
@main
struct DockTerminalHoverChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        for edge in DockEdge.allCases {
            for (name, count, length) in [("fit", 7, 800.0), ("single", 1, 400.0), ("overflow", 30, 320.0)] {
                let directory = root.appendingPathComponent("\(edge.rawValue)-\(name)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var config = DockConfiguration()
                config.showBadges = false
                config.showPreviews = false
                config.hideSystemDock = false
                config.entries = (0..<count).map {
                    DockEntry(name: "Fixture", apps: [.init(id: "terminal.\($0)", name: "Fixture",
                        path: "/System/Applications/Notes.app")])
                }
                try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("configuration.json"))
                let store = AppStore(directory: directory)
                store.stopBackgroundServices()
                let presentation = DockPresentation(displayID: nil, edge: edge,
                    style: .init(iconSize: 48, barThickness: 66, gap: 8, leadingPadding: 6, trailingPadding: 6,
                                 magnificationScale: 2, magnificationRadius: 2.5),
                    maximumLength: 1600, fixedLength: length, resizeMargin: 0,
                    resizeBounds: .init(minLength: 120, maxLength: 1600, minThickness: 33, maxThickness: 140),
                    requestedManualSizing: .init(length: length, thickness: 66), canResize: false)
                let strip = DockStripView()
                let size = strip.populate(entries: config.entries, store: store, maxWidth: 1600,
                                          presentation: presentation) { _ in }
                let panel = DockPanel()
                panel.contentView = strip
                panel.setFrame(CGRect(x: -8000, y: -8000, width: size.width, height: size.height), display: false)
                strip.layoutSubtreeIfNeeded()
                let rest = strip.layoutGeometry!
                let windowFrame = panel.frame, backdrop = strip.backdropFrame
                let identities = strip.tiles.map(ObjectIdentifier.init)
                let clip = strip.scroll.contentView
                let maxOffset = max(0, edge.isHorizontal ? strip.document.frame.width - clip.bounds.width
                                                         : strip.document.frame.height - clip.bounds.height)
                check(name == "overflow" ? maxOffset > 1 : maxOffset == 0, "\(edge) \(name): unexpected scroll range")
                var clock: Double = 1
                func pointer(_ canonical: CGPoint) -> CGPoint {
                    let physical = rest.documentTransform.pointToPhysical(canonical)
                    return panel.convertPoint(toScreen: strip.document.convert(physical, to: nil))
                }
                func settle(at point: CGPoint) {
                    strip.updatePointer(at: point, buttonsPressed: false, force: true)
                    for _ in 0..<240 {
                        clock += 1.0 / 120
                        strip.advanceAnimation(at: clock, pointer: point, buttonsPressed: false)
                    }
                }
                for end in [0, 1] {
                    strip.resetMagnification()
                    let offset = end == 0 ? CGFloat(0) : maxOffset
                    clip.scroll(to: rest.scrollOrigin(forCanonicalOffset: offset,
                        actualDocumentSize: strip.document.frame.size, actualViewportSize: clip.bounds.size))
                    strip.scroll.reflectScrolledClipView(clip)
                    let retainedOffset = strip.scrollOffset
                    let index = end == 0 ? 0 : count - 1
                    let direction: CGFloat = end == 0 ? -1 : 1
                    let anchor = rest.canonicalIconFrames[index].midX
                    settle(at: pointer(CGPoint(x: anchor, y: rest.barThickness / 2)))
                    let atCenter = strip.layoutGeometry!
                    check(atCenter.canonicalIconFrames[index].width > 90,
                          "\(edge) \(name) end\(end): terminal hover never magnified")
                    let steps: [CGFloat] = name == "overflow" ? [4, 8, 16] : [8, 16, 32]
                    for distance in steps {
                        settle(at: pointer(CGPoint(x: anchor + direction * distance, y: rest.barThickness / 2)))
                        let current = strip.layoutGeometry!
                        let drift = current.canonicalIconFrames[0].minX - atCenter.canonicalIconFrames[0].minX
                        check(abs(drift) < 0.1,
                              "\(edge.rawValue) \(name) end\(end) outward\(distance): entire row drifted \(drift)pt")
                        check(abs(current.canonicalIconFrames[index].width - atCenter.canonicalIconFrames[index].width) < 0.1,
                              "\(edge) \(name) end\(end): peak changed inside the fixed enlarged icon")
                        check(abs(strip.scrollOffset - retainedOffset) < 0.001,
                              "\(edge) \(name): hover changed manual scroll offset")
                        check(panel.frame == windowFrame && strip.backdropFrame == backdrop,
                              "\(edge) \(name): hover moved container/backdrop")
                    }
                    if name != "overflow" {
                        // This point is outside the correctly anchored enlarged
                        // end tile. The old chasing lens extends its own hit area
                        // far enough to incorrectly keep the entire row moving.
                        settle(at: pointer(CGPoint(x: anchor + direction * 80, y: rest.barThickness / 2)))
                        check(strip.layoutGeometry!.canonicalIconFrames.allSatisfy { abs($0.width - 48) < 0.1 },
                              "\(edge) \(name) end\(end): leaving terminal icon did not release magnification")
                    }
                    settle(at: panel.convertPoint(toScreen: CGPoint(x: -1000, y: -1000)))
                    check(strip.layoutGeometry!.canonicalIconFrames.allSatisfy { abs($0.width - 48) < 0.1 },
                          "\(edge) \(name): leaving the strip did not restore base sizes")
                }
                check(!panel.isVisible && strip.tiles.map(ObjectIdentifier.init) == identities,
                      "\(edge) \(name): fixture showed window or rebuilt tiles")
                check(!strip.scroll.hasHorizontalScroller && !strip.scroll.hasVerticalScroller,
                      "\(edge) \(name): visible scrollbar appeared")
                strip.stopAnimations()
                panel.close()
                store.stopBackgroundServices()
            }
        }
        // A wave at one end displaces the opposite endpoint. A quick jump
        // must keep that currently drawn icon under the pointer while the wave
        // reverses, without allowing subsequent outward motion to drag the row.
        for edge in DockEdge.allCases {
            for radius in [CGFloat(2.5), 4] {
                for scale in [CGFloat(2), 3.2] {
                    let name = "jump-\(edge.rawValue)-\(radius)-\(scale)"
                    let directory = root.appendingPathComponent(name)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    var config = DockConfiguration()
                    config.showBadges = false
                    config.showPreviews = false
                    config.hideSystemDock = false
                    config.entries = (0..<9).map {
                        DockEntry(name: "Fixture", apps: [.init(id: "jump.\($0)", name: "Fixture",
                            path: "/System/Applications/Notes.app")])
                    }
                    try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("configuration.json"))
                    let store = AppStore(directory: directory)
                    store.stopBackgroundServices()
                    let presentation = DockPresentation(displayID: nil, edge: edge,
                        style: .init(iconSize: 48, barThickness: 66, gap: 8, leadingPadding: 6, trailingPadding: 6,
                                     magnificationScale: scale, magnificationRadius: radius),
                        maximumLength: 1600, fixedLength: 1000, resizeMargin: 0,
                        resizeBounds: .init(minLength: 120, maxLength: 1600, minThickness: 33, maxThickness: 140),
                        requestedManualSizing: .init(length: 1000, thickness: 66), canResize: false)
                    let strip = DockStripView()
                    let size = strip.populate(entries: config.entries, store: store, maxWidth: 1600,
                                              presentation: presentation) { _ in }
                    let panel = DockPanel()
                    panel.contentView = strip
                    panel.setFrame(CGRect(x: -8000, y: -8000, width: size.width, height: size.height), display: false)
                    strip.layoutSubtreeIfNeeded()
                    let rest = strip.layoutGeometry!
                    let initialFrame = panel.frame, backdrop = strip.backdropFrame
                    var clock: Double = 1
                    func pointer(_ canonical: CGPoint) -> CGPoint {
                        let physical = rest.documentTransform.pointToPhysical(canonical)
                        return panel.convertPoint(toScreen: strip.document.convert(physical, to: nil))
                    }
                    func settle(_ point: CGPoint, expectedHit: DockTile? = nil) {
                        strip.updatePointer(at: point, buttonsPressed: false, force: true)
                        for frame in 0..<180 {
                            clock += 1.0 / 120
                            strip.advanceAnimation(at: clock, pointer: point, buttonsPressed: false)
                            if let expectedHit {
                                let local = strip.convert(panel.convertPoint(fromScreen: point), from: nil)
                                check(strip.hitTest(local) === expectedHit,
                                      "\(name) frame\(frame): endpoint became unclickable during opposite-end transition")
                            }
                        }
                    }
                    for destination in [0, 8] {
                        strip.resetMagnification()
                        let source = destination == 0 ? 8 : 0
                        let direction: CGFloat = destination == 0 ? -1 : 1
                        settle(pointer(CGPoint(x: rest.canonicalIconFrames[source].midX, y: 33)))
                        let tile = strip.tiles[destination]
                        // Only choose a point in the visible part of the icon;
                        // high magnification can clip its offscreen center.
                        let drawn = strip.document.convert(tile.visualIconBounds, from: tile)
                        let viewport = strip.document.convert(strip.scroll.contentView.bounds, from: strip.scroll.contentView)
                        let visible = drawn.intersection(viewport)
                        check(!visible.isEmpty && !visible.isNull, "\(name): endpoint fixture is not visible")
                        let drawnPoint = CGPoint(x: visible.midX, y: visible.midY)
                        let canonical = rest.documentPointToCanonical(drawnPoint)
                        let targetPoint = panel.convertPoint(toScreen: strip.document.convert(drawnPoint, to: nil))
                        let displaced = direction * (strip.layoutGeometry!.canonicalIconFrames[destination].midX
                                                    - rest.canonicalIconFrames[destination].midX)
                        check(displaced > 10, "\(name): fixture did not create a displaced endpoint")
                        settle(targetPoint, expectedHit: tile)
                        let anchored = strip.layoutGeometry!.canonicalIconFrames[0].minX
                        let outward = pointer(CGPoint(x: canonical.x + direction * 12, y: canonical.y))
                        settle(outward, expectedHit: tile)
                        check(abs(strip.layoutGeometry!.canonicalIconFrames[0].minX - anchored) < 0.1,
                              "\(name): outward motion dragged a captured endpoint")

                        let inward = pointer(CGPoint(x: canonical.x - direction * 8, y: canonical.y))
                        settle(inward, expectedHit: tile)
                        let reduced = strip.layoutGeometry!.canonicalIconFrames[0].minX
                        settle(outward, expectedHit: tile)
                        check(abs(strip.layoutGeometry!.canonicalIconFrames[0].minX - reduced) < 0.1,
                              "\(name): captured displacement regrew after inward/outward motion")
                        check(!panel.isVisible && panel.frame == initialFrame && strip.backdropFrame == backdrop,
                              "\(name): opposite-end jump changed container geometry")
                    }
                    strip.stopAnimations()
                    panel.close()
                    store.stopBackgroundServices()
                }
            }
        }
        failures.forEach { print("FAIL: \($0)") }
        print("\(checks) terminal hover checks, \(failures.count) failures; hidden windows and local pointer replay only")
        exit(failures.isEmpty ? 0 : 1)
    }
}
