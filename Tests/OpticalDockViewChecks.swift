import AppKit
import DualDockCore

/// Production Store/Strip/Tile checks with isolated preferences and application
/// inventory. Windows stay hidden; no input is posted to the desktop.
@main
struct OpticalDockViewChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.00001) -> Bool { abs(a - b) <= tolerance }
        func sameRect(_ a: CGRect, _ b: CGRect) -> Bool {
            near(a.minX, b.minX) && near(a.minY, b.minY) && near(a.width, b.width) && near(a.height, b.height)
        }
        func checkDropZones(_ tile: DockTile, edge: DockEdge, tag: String,
                            region: CGRect? = nil, requiresContainment: Bool = true) {
            let body = region ?? tile.visibleContentBounds
            func point(_ fraction: CGFloat) -> CGPoint {
                edge.isHorizontal ? CGPoint(x: body.minX + body.width * fraction, y: body.midY)
                    : CGPoint(x: body.midX, y: body.maxY - body.height * fraction)
            }
            let leading = tile.dropPosition(at: point(0.1))
            let center = tile.dropPosition(at: point(0.5))
            let trailing = tile.dropPosition(at: point(0.9))
            check(!leading.after && !leading.central, "\(tag) visible leading edge entered merge/after zone")
            check(center.central, "\(tag) visible body center did not enter merge zone")
            check(trailing.after && !trailing.central, "\(tag) visible trailing edge entered merge/before zone")
            if requiresContainment {
                let outside = edge.isHorizontal ? CGPoint(x: body.midX, y: body.maxY + 0.1)
                    : CGPoint(x: body.maxX + 0.1, y: body.midY)
                check(!tile.dropPosition(at: outside).central, "\(tag) transparent cross-axis margin entered merge zone")
            }
        }
        func drawing(_ body: CGRect?, alpha: CGFloat = 1, shadow: Bool = false) -> NSImage {
            NSImage(size: NSSize(width: 256, height: 256), flipped: false) { _ in
                if shadow {
                    NSColor.black.withAlphaComponent(0.1).setFill()
                    NSRect(x: 32, y: 16, width: 192, height: 128).fill()
                }
                if let body {
                    NSColor.red.withAlphaComponent(alpha).setFill()
                    body.fill()
                }
                return true
            }
        }
        let asymmetric = CGRect(x: 64, y: 32, width: 128, height: 64)
        let normalized = CGRect(x: 0.25, y: 0.125, width: 0.5, height: 0.25)
        check(sameRect(IconArtworkBounds.measure(drawing(asymmetric)), normalized),
              "Artwork measurement flipped asymmetric unflipped coordinates")
        check(sameRect(IconArtworkBounds.measure(drawing(asymmetric, shadow: true)), normalized),
              "Soft shadow displaced the measured visible body")
        check(sameRect(IconArtworkBounds.measure(drawing(asymmetric, alpha: 0.3)), normalized),
              "Translucent artwork did not use the nonempty fallback threshold")
        check(IconArtworkBounds.measure(drawing(nil)) == IconArtworkBounds.full,
              "Empty artwork did not fall back to the full canvas")
        for name in ["Notes", "Calendar", "Calculator"] {
            let path = "/System/Applications/\(name).app"
            check(FileManager.default.fileExists(atPath: path), "Missing built-in icon fixture: \(name)")
            let bounds = IconArtworkBounds.measure(NSWorkspace.shared.icon(forFile: path))
            check(bounds.width > 0.5 && bounds.height > 0.5 && bounds.width < 1 && bounds.height < 1,
                  "Built-in icon body was not measured inside its transparent canvas: \(name) \(bounds)")
        }

        let display = DockDisplayInfo(id: "fixture", runtimeID: 987, name: "Fixture",
            frame: CGRect(x: 0, y: 0, width: 700, height: 1000),
            visibleFrame: CGRect(x: 0, y: 0, width: 700, height: 972), isPrimary: true)
        let names = ["Notes", "Calendar", "Calculator"]
        let groupApps = [AppReference(id: "fixture.group.text", name: "TextEdit", path: "/System/Applications/TextEdit.app"),
                         AppReference(id: "fixture.group.preview", name: "Preview", path: "/System/Applications/Preview.app")]
        var entries = (0..<6).map { index -> DockEntry in
            let name = names[index % names.count]
            let app = AppReference(id: "fixture.app.\(index)", name: name, path: "/System/Applications/\(name).app")
            return DockEntry(name: name, apps: [app])
        }
        entries.insert(DockEntry(name: "Fixture group", apps: groupApps, isGroup: true), at: 3)
        let extra = AppReference(id: "fixture.unpinned", name: "Music", path: "/System/Applications/Music.app")
        let running = entries.flatMap(\.apps) + [extra]
        func fixture(_ name: String, edge: DockEdge, percent: Double?, fixed: Bool) throws -> AppStore {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var config = DockConfiguration()
            config.entries = entries
            config.hideSystemDock = false; config.showBadges = false; config.showPreviews = false
            config.synchronizeSizes = false
            config.magnificationScale = 1.6
            config.displaySettings[display.id] = .init(edge: edge)
            var sizing = DockCustomSizing()
            sizing.iconSize = 48; sizing.spacingPercent = percent
            sizing.gapOverride = percent == nil ? 0 : nil
            sizing.paddingOverride = 14; sizing.minimumHeightOverride = 72
            sizing.lengthMode = fixed ? .fixed : .fit; sizing.fixedLengthPercent = 20
            sizing.shrinkBeforeScroll = false
            config.customSizing = sizing
            try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("configuration.json"))
            let store = AppStore(directory: directory, runningAppsProvider: { running },
                                 permissionsProvider: { (accessibility: true, capture: true) })
            store.stopBackgroundServices()
            store.updateDisplays([display])
            return store
        }
        func checkFrames(_ strip: DockStripView, edge: DockEdge, percent: Double,
                         divider: Int?, separator: CGFloat, tag: String, exactGap: Bool = true) {
            guard let geometry = strip.layoutGeometry else { check(false, "\(tag) missing geometry"); return }
            let content = strip.tiles.map { strip.document.convert($0.visibleContentBounds, from: $0) }
            let canonical = content.map(geometry.documentTransform.rectToCanonical)
            for index in strip.tiles.indices {
                let tile = strip.tiles[index]
                let drawn = strip.document.convert(tile.visualIconBounds, from: tile)
                let hit = strip.document.convert(tile.interactionBounds, from: tile)
                check(sameRect(content[index], geometry.contentFrames[index]), "\(tag) tile content coordinates diverged")
                check(sameRect(hit, geometry.hitFrames[index]), "\(tag) tile hit coordinates diverged")
                check(sameRect(drawn, geometry.iconFrames[index]) && near(drawn.width, drawn.height),
                      "\(tag) original drawing canvas was cropped or stretched")
                let dot = geometry.documentTransform.rectToCanonical(strip.document.convert(tile.runningIndicatorBounds, from: tile))
                check(near(dot.midX, canonical[index].midX), "\(tag) running dot not centered on visible body")
                check(canonical[index].minY - dot.maxY >= -0.00001 && canonical[index].minY - dot.maxY <= 3.00001,
                      "\(tag) running dot detached from visible body")
                let body = tile.visibleContentBounds
                checkDropZones(tile, edge: edge, tag: tag + "-drop-\(index)")
                let points = edge.isHorizontal
                    ? [CGPoint(x: body.minX + 0.1, y: body.midY), CGPoint(x: body.midX, y: body.midY), CGPoint(x: body.maxX - 0.1, y: body.midY)]
                    : [CGPoint(x: body.midX, y: body.minY + 0.1), CGPoint(x: body.midX, y: body.midY), CGPoint(x: body.midX, y: body.maxY - 0.1)]
                for point in points {
                    let local = strip.convert(point, from: tile)
                    if strip.scroll.frame.contains(local) {
                        check(strip.hitTest(local) === tile, "\(tag) visible body edge targeted a neighboring canvas (\(index))")
                    }
                }
            }
            for index in 1..<canonical.count {
                let left = canonical[index - 1], right = canonical[index]
                let actual = right.minX - left.maxX
                let expected = (left.width + right.width) / 2 * CGFloat(percent / 100)
                    + (divider == index ? separator : 0)
                check(actual >= -0.00001, "\(tag) visible bodies overlap")
                if exactGap { check(near(actual, expected), "\(tag) gap is \(actual), expected \(expected)") }
                let a = geometry.canonicalHitFrames[index - 1], b = geometry.canonicalHitFrames[index]
                check(a.maxX <= b.minX + 0.00001, "\(tag) hit ownership regions overlap")
            }
        }

        for edge in DockEdge.allCases {
            for percent in [0.0, 50, 100] {
                for fixed in [false, true] {
                    let tag = "\(edge.rawValue)-\(Int(percent))-\(fixed ? "overflow" : "fit")"
                    let store = try fixture(tag, edge: edge, percent: percent, fixed: fixed)
                    defer { store.stopBackgroundServices() }
                    let presentedEntries = store.displayedEntries
                    let divider = store.pinnedCount
                    check(presentedEntries.count == 8 && divider == 7, "\(tag) app inventory escaped fixture")
                    let presentation = store.presentation(for: display.id)
                    check(presentation.style.spacingPercent == CGFloat(percent), "\(tag) percentage missing from presentation")
                    check(near(presentation.style.iconSize, 48), "\(tag) spacing resized original artwork")
                    let strip = DockStripView()
                    let size = strip.populate(entries: presentedEntries, store: store,
                                              maxWidth: presentation.maximumLength, presentation: presentation) { _ in }
                    let panel = DockPanel()
                    panel.contentView = strip
                    panel.setFrame(CGRect(x: -8000, y: -8000, width: size.width, height: size.height), display: false)
                    strip.layoutSubtreeIfNeeded()
                    let identities = strip.tiles.map(ObjectIdentifier.init)
                    let geometry = strip.layoutGeometry!
                    check(strip.tiles.allSatisfy { near($0.visualIconBounds.width, 48) },
                          "\(tag) optical spacing changed the original drawing size")
                    if percent == 0 {
                        check(zip(geometry.canonicalIconFrames, geometry.canonicalIconFrames.dropFirst())
                            .contains { $0.maxX > $1.minX + 0.1 },
                            "\(tag) fixture did not exercise overlapping transparent canvases")
                    }
                    check(!panel.isVisible, "\(tag) test window became visible")
                    check(!strip.scroll.hasHorizontalScroller && !strip.scroll.hasVerticalScroller, "\(tag) visible scrollbar added")
                    check(fixed ? geometry.scrollRange > 0 : geometry.scrollRange == 0, "\(tag) wrong fit/overflow state")
                    checkFrames(strip, edge: edge, percent: percent, divider: divider,
                                separator: presentation.style.separatorLength, tag: tag)
                    for fraction: CGFloat in [0, 0.5, 1] {
                        let clip = strip.scroll.contentView
                        let offset = geometry.scrollRange * fraction
                        clip.scroll(to: geometry.scrollOrigin(forCanonicalOffset: offset,
                            actualDocumentSize: strip.document.frame.size, actualViewportSize: clip.bounds.size))
                        strip.scroll.reflectScrolledClipView(clip)
                        let retained = strip.scrollOffset
                        check(near(retained, offset, 1), "\(tag) requested scroll did not actually move to the target")
                        _ = strip.updatePresentation(store.presentation(for: display.id))
                        check(near(strip.scrollOffset, retained, 1), "\(tag) refresh changed scroll offset")
                        check(strip.tiles.map(ObjectIdentifier.init) == identities, "\(tag) refresh rebuilt tiles")
                        checkFrames(strip, edge: edge, percent: percent, divider: divider,
                                    separator: presentation.style.separatorLength, tag: tag + "-scroll")
                    }
                    if !fixed {
                        let body = strip.tiles[2].visibleContentBounds
                        let local = strip.tiles[2].convert(CGPoint(x: body.midX, y: body.midY), to: nil)
                        let pointer = panel.convertPoint(toScreen: local)
                        strip.updatePointer(at: pointer, buttonsPressed: false, force: true)
                        for frame in 0..<30 {
                            strip.advanceAnimation(at: 100 + Double(frame) / 120, pointer: pointer, buttonsPressed: false)
                            checkFrames(strip, edge: edge, percent: percent, divider: divider,
                                separator: presentation.style.separatorLength, tag: tag + "-hover", exactGap: false)
                        }
                        check(strip.tiles.map { $0.visualIconBounds.width }.max()! > 49,
                              "\(tag) hover fixture never magnified")
                        strip.resetMagnification()
                    }
                    var draft = presentation.requestedManualSizing
                    draft.thickness *= 1.1
                    store.setResizePreview(draft, for: display.id)
                    _ = strip.updatePresentation(store.presentation(for: display.id))
                    check(strip.tiles.map(ObjectIdentifier.init) == identities, "\(tag) resize draft rebuilt tiles")
                    check(strip.tiles[0].visualIconBounds.width > 48
                        && strip.layoutGeometry!.barThickness > geometry.barThickness,
                        "\(tag) resize draft did not actually grow the icon and backdrop")
                    check(store.customSizing(for: display.id).spacingPercent == percent, "\(tag) resize changed saved percentage")
                    checkFrames(strip, edge: edge, percent: percent, divider: divider,
                        separator: store.presentation(for: display.id).style.separatorLength, tag: tag + "-resize")
                    store.setResizePreview(nil, for: display.id)
                    strip.stopAnimations(); panel.close()

                    let groupStrip = DockStripView()
                    let groupEntries = groupApps.map { DockEntry(name: $0.name, apps: [$0]) }
                    let groupPresentation = store.presentation(for: display.id, group: true)
                    let groupSize = groupStrip.populate(entries: groupEntries, groupID: UUID(), store: store,
                        maxWidth: groupPresentation.maximumLength, presentation: groupPresentation) { _ in }
                    let groupPanel = DockPanel(); groupPanel.contentView = groupStrip
                    groupPanel.setFrame(CGRect(x: -8000, y: -8000, width: groupSize.width, height: groupSize.height), display: false)
                    groupStrip.layoutSubtreeIfNeeded()
                    check(groupStrip.layoutGeometry!.edge == .bottom && !groupPresentation.canResize, "\(tag) group lost horizontal layout")
                    checkFrames(groupStrip, edge: .bottom, percent: percent, divider: nil, separator: 0, tag: tag + "-group")
                    let ownMetrics = store.contentBounds(for: groupEntries)
                    for index in groupEntries.indices {
                        let icon = groupStrip.tiles[index].visualIconBounds
                        let body = groupStrip.tiles[index].visibleContentBounds
                        check(near(body.width / icon.width, ownMetrics[index].width)
                            && near(body.height / icon.height, ownMetrics[index].height), "\(tag) group inherited parent artwork bounds")
                    }
                    groupStrip.stopAnimations(); groupPanel.close()
                }
            }
        }

        // Shared resizing captures one preference from the source screen, then
        // resolves that same preference for each destination orientation. Include
        // deliberately nonsquare artwork: the square folder tray alone cannot
        // catch a length jump caused by using the destination's axis for padding.
        let wideFile = root.appendingPathComponent("wide-artwork")
        try Data().write(to: wideFile)
        check(NSWorkspace.shared.setIcon(drawing(asymmetric), forFile: wideFile.path, options: []),
              "Could not install the isolated nonsquare icon fixture")
        let wideApp = AppReference(id: "fixture.wide-artwork", name: "Wide", path: wideFile.path)
        let wideBounds = IconArtworkBounds.measure(NSWorkspace.shared.icon(forFile: wideFile.path))
        check(wideBounds.width > 1.5 * wideBounds.height, "Fixture artwork must differ between axes")
        for source in ["A", "B"] {
            for percent in [0.0, 50, 100] {
                for gesture in ["length", "height", "corner"] {
                    let directory = root.appendingPathComponent("sync-\(source)-\(Int(percent))-\(gesture)")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    var config = DockConfiguration()
                    config.hideSystemDock = false; config.showBadges = false; config.showPreviews = false
                    config.synchronizeSizes = true
                    config.entries = [DockEntry(name: "Group", apps: groupApps, isGroup: true),
                                      DockEntry(name: wideApp.name, apps: [wideApp])]
                    var sizing = DockCustomSizing.visualDefault
                    sizing.spacingPercent = percent; sizing.paddingOverride = 14
                    sizing.minimumHeightOverride = 72; sizing.shrinkBeforeScroll = false
                    config.customSizing = sizing
                    config.displaySettings["A"] = .init(edge: .bottom)
                    config.displaySettings["B"] = .init(edge: .left)
                    try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("configuration.json"))
                    let store = AppStore(directory: directory, runningAppsProvider: { [] },
                        permissionsProvider: { (accessibility: true, capture: true) })
                    store.stopBackgroundServices()
                    store.updateDisplays([
                        .init(id: "A", runtimeID: 991, name: "A", frame: CGRect(x: 0, y: 0, width: 1800, height: 1200),
                              visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1160), isPrimary: true),
                        .init(id: "B", runtimeID: 992, name: "B", frame: CGRect(x: 1800, y: 0, width: 1800, height: 1200),
                              visibleFrame: CGRect(x: 1800, y: 0, width: 1800, height: 1160))])
                    let original = store.presentation(for: source)
                    var draft = original.requestedManualSizing
                    if gesture != "height" { draft.length += 100 }
                    if gesture != "length" { draft.thickness *= 1.1 }
                    store.setResizePreview(draft, for: source)
                    let previews = ["A", "B"].map { store.presentation(for: $0) }
                    if gesture != "height" {
                        check(near(store.presentation(for: source).fixedLength!, draft.length),
                              "Synced \(gesture) preview did not apply the source length")
                    }
                    if gesture != "length" {
                        check(store.presentation(for: source).style.iconSize > original.style.iconSize,
                              "Synced \(gesture) preview did not grow the source icon")
                    }
                    store.commitManualResize(draft, for: source)
                    for (index, destination) in ["A", "B"].enumerated() {
                        let committed = store.presentation(for: destination)
                        check(near(previews[index].fixedLength!, committed.fixedLength!),
                              "Shared \(source) \(gesture) at \(percent)% jumped length on \(destination) when committed")
                        check(previews[index].style == committed.style,
                              "Shared \(source) \(gesture) at \(percent)% changed geometry on \(destination) when committed")
                        check(store.customSizing(for: destination) == store.customSizing(for: source),
                              "Shared gesture persisted different preferences for the destination")
                    }
                    store.stopBackgroundServices()
                }
            }
        }

        let legacy = try fixture("legacy", edge: .bottom, percent: nil, fixed: false)
        defer { legacy.stopBackgroundServices() }
        // Verify that the fourth thumbnail is visible and the grid does not
        // shift or change when further members are added to the same group.
        let members = entries.filter { !$0.isGroup }.compactMap { $0.apps.first }
        func renderFolder(_ count: Int) -> NSImage {
            let group = DockEntry(name: "Grid", apps: Array(members.prefix(count)), isGroup: true)
            let tile = DockTile(entry: group, groupID: nil, store: legacy, size: 128)
            let canvas = NSRect(x: 0, y: 0, width: 128, height: 128)
            tile.applyGeometry(frame: canvas, iconFrame: canvas, dotFrame: .zero,
                               baseIconSize: 128, edge: .bottom)
            return NSImage(size: canvas.size, flipped: false) { _ in
                tile.draw(canvas)
                return true
            }
        }
        let three = renderFolder(3), four = renderFolder(4), five = renderFolder(5)
        for group in [three, four, five] {
            let artwork = IconArtworkBounds.measure(group)
            check(abs(artwork.minX - IconArtworkBounds.folder.minX) < 0.01
                  && abs(artwork.minY - IconArtworkBounds.folder.minY) < 0.01
                  && abs(artwork.maxX - IconArtworkBounds.folder.maxX) < 0.01
                  && abs(artwork.maxY - IconArtworkBounds.folder.maxY) < 0.01,
                  "Group pixels drifted from the optical spacing and badge anchor")
        }
        check(three.tiffRepresentation != four.tiffRepresentation, "Fourth member did not change the group icon")
        check(four.tiffRepresentation == five.tiffRepresentation, "Fifth member displaced a visible thumbnail")
        // Deliberately asymmetric, offset artwork inside a much larger draw
        // canvas catches a regression back to using the whole tile as its drop zone.
        for edge in DockEdge.allCases {
            let tile = DockTile(entry: entries[0], groupID: nil, store: legacy, size: 48)
            let frame = CGRect(x: 0, y: 0, width: 200, height: 180)
            let icon = CGRect(x: 70, y: 60, width: 48, height: 48)
            let content = CGRect(x: icon.minX + 0.6 * 48, y: icon.minY + 0.1 * 48,
                                 width: 0.3 * 48, height: 0.25 * 48)
            for optical in [true, false] {
                tile.applyGeometry(frame: frame, iconFrame: icon, dotFrame: .zero,
                    baseIconSize: 48, edge: edge, contentFrame: content, hitFrame: frame, optical: optical)
                checkDropZones(tile, edge: edge, tag: "asymmetric-\(edge)-\(optical)",
                    region: optical ? content : frame, requiresContainment: optical)
            }
        }
        legacy.flushPendingSave()
        let oldConfig = legacy.configuration, oldStyle = legacy.presentation(for: display.id).style
        let saved = try Data(contentsOf: legacy.directory.appendingPathComponent("configuration.json"))
        let read = legacy.spacingPercent(for: display.id)
        check(read.isFinite && (0...100).contains(read), "Legacy display percentage was invalid")
        check(legacy.configuration == oldConfig && legacy.presentation(for: display.id).style == oldStyle,
              "Reading the new slider reinterpreted legacy geometry")
        check(try Data(contentsOf: legacy.directory.appendingPathComponent("configuration.json")) == saved,
              "Reading the new slider rewrote stored preferences")
        legacy.updateCustomSizing(for: display.id) { $0.alignment = .distribute }
        legacy.setSpacingPercent(0, for: display.id)
        check(legacy.customSizing(for: display.id).spacingPercent == 0
            && legacy.customSizing(for: display.id).gapOverride == nil
            && legacy.customSizing(for: display.id).alignment == .center,
              "First spacing edit did not activate optical spacing or remove conflicting overrides")
        let beforeNative = legacy.configuration
        legacy.setAdaptiveSizing(true)
        let nativeConfig = legacy.configuration, native = legacy.presentation(for: display.id)
        check(native.style.spacingPercent == nil && native.style.contentBounds.isEmpty,
              "Native-follow mode inherited optical spacing")
        check(near(native.style.iconSize, CGFloat(legacy.nativeDockMetrics.iconSize))
            && near(native.style.gap, CGFloat(legacy.nativeDockMetrics.itemSpacing)), "Native-follow metrics changed")
        legacy.setSpacingPercent(100, for: display.id)
        check(legacy.configuration == nativeConfig, "Native-follow mode allowed a custom spacing mutation")
        legacy.setAdaptiveSizing(false)
        check(legacy.configuration == beforeNative, "Native-follow round trip changed custom settings")
        if CommandLine.arguments.count > 2, !CommandLine.arguments[2].isEmpty {
            let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: 880,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSGraphicsContext.current!.cgContext.scaleBy(x: 2, y: 2)
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 900, height: 440).fill()
            let text: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black]
            ("Production DockTile comparison · original 48 pt artwork" as NSString)
                .draw(at: CGPoint(x: 24, y: 405), withAttributes: text)
            ("Opaque fixture background; no desktop material or real pointer interaction is represented." as NSString)
                .draw(at: CGPoint(x: 24, y: 383), withAttributes: text)
            for (row, percent) in [0.0, 50, 100].enumerated() {
                let sample = try fixture("visual-\(Int(percent))", edge: .bottom, percent: percent, fixed: false)
                let presentation = sample.presentation(for: display.id, group: true)
                let strip = DockStripView()
                let sampleEntries = Array(entries.prefix(4))
                let size = strip.populate(entries: sampleEntries, groupID: UUID(), store: sample,
                    maxWidth: presentation.maximumLength, presentation: presentation) { _ in }
                let panel = DockPanel(); panel.contentView = strip
                panel.setFrame(CGRect(x: -8000, y: -8000, width: size.width, height: size.height), display: false)
                strip.layoutSubtreeIfNeeded()
                let geometry = strip.layoutGeometry!
                let origin = CGPoint(x: 190 + (650 - geometry.documentSize.width) / 2,
                                     y: 285 - CGFloat(row) * 110)
                ("\(Int(percent))% spacing" as NSString).draw(at: CGPoint(x: 24, y: origin.y + 22), withAttributes: text)
                NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
                NSBezierPath(roundedRect: geometry.backdropRect.offsetBy(dx: origin.x, dy: origin.y), xRadius: 14, yRadius: 14).fill()
                for (index, tile) in strip.tiles.enumerated() {
                    NSGraphicsContext.saveGraphicsState()
                    let frame = geometry.tileFrames[index]
                    NSGraphicsContext.current!.cgContext.translateBy(x: origin.x + frame.minX, y: origin.y + frame.minY)
                    NSGraphicsContext.current!.cgContext.clip(to: tile.bounds)
                    tile.draw(tile.bounds)
                    NSGraphicsContext.restoreGraphicsState()
                }
                check(!panel.isVisible, "Visual fixture became visible")
                strip.stopAnimations(); panel.close(); sample.stopBackgroundServices()
            }
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using: .png, properties: [:])!
                .write(to: output.appendingPathComponent("optical-spacing.png"))
        }
        failures.prefix(60).forEach { print("FAIL: \($0)") }
        if failures.count > 60 { print("Additional failures: \(failures.count - 60)") }
        print("Optical Dock AppKit checks: \(checks), failures: \(failures.count); isolated preferences, hidden windows, no desktop input")
        exit(failures.isEmpty ? 0 : 1)
    }
}
