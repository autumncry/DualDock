import AppKit
import DualDockCore

/// Production AppStore tests with isolated configuration and no displayed UI.
@main
struct ManualContentSizingChecks {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("configuration.json")
        var config = DockConfiguration()
        config.showBadges = false
        config.showPreviews = false
        config.dockWidth = 1000
        config.insert((0..<10).map {
            AppReference(id: "test.dualdock.seed.\($0)", name: "Seed \($0)", path: "/not-an-app/\($0)")
        })
        try JSONEncoder().encode(config).write(to: file)
        let store = AppStore(directory: directory)
        store.stopBackgroundServices()
        store.updateDisplayLimits(screenSizes: [CGSize(width: 1800, height: 1200)])
        var checks = 0, failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        func inode() throws -> UInt64 {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            return (attributes[.systemFileNumber] as! NSNumber).uint64Value
        }
        var previous = try inode(), replacements = 0
        for index in 0..<120 {
            store.updateManualSizing(for: nil) { $0.length = 900 + Double(index) }
            let current = try inode()
            if current != previous { replacements += 1 }
            previous = current
        }
        print("Slider burst: 120 values, \(replacements) synchronous atomic file replacements")
        check(replacements == 0, "slider burst performed synchronous configuration writes")
        store.flushPendingSave()
        var saved = try JSONDecoder().decode(DockConfiguration.self, from: Data(contentsOf: file))
        check(saved.dockWidth == 1019, "edit-end flush lost latest slider value")
        let afterFlush = try inode()
        store.flushPendingSave()
        check(try inode() == afterFlush, "second flush rewrote unchanged configuration")
        store.updateManualSizing(for: nil) { $0.length = 1111 }
        try await Task.sleep(nanoseconds: 250_000_000)
        saved = try JSONDecoder().decode(DockConfiguration.self, from: Data(contentsOf: file))
        check(saved.dockWidth == 1111, "idle debounce did not persist final geometry")
        store.updateManualSizing(for: nil) { $0.length = 1222 }
        store.update { $0.mode = .runningOnly }
        saved = try JSONDecoder().decode(DockConfiguration.self, from: Data(contentsOf: file))
        check(saved.mode == .runningOnly && saved.dockWidth == 1222,
              "structural save did not include latest pending geometry")
        let structuralInode = try inode()
        try await Task.sleep(nanoseconds: 200_000_000)
        check(try inode() == structuralInode, "stale delayed save rewrote structural snapshot")
        store.update { $0.mode = .standard }

        let screenA = DockDisplayInfo(id: "A", runtimeID: 1, name: "A",
            frame: CGRect(x: 0, y: 0, width: 20000, height: 1600),
            visibleFrame: CGRect(x: 0, y: 0, width: 20000, height: 1560), isPrimary: true)
        let screenB = DockDisplayInfo(id: "B", runtimeID: 2, name: "B",
            frame: CGRect(x: 20000, y: 0, width: 16000, height: 1400),
            visibleFrame: CGRect(x: 20000, y: 0, width: 16000, height: 1360))
        store.updateDisplays([screenA, screenB])
        func span(_ id: String) -> Double {
            let presentation = store.presentation(for: id)
            let count = store.displayedEntries.count
            return DockContentLengthPolicy.contentSpan(count: count,
                iconSize: Double(presentation.style.iconSize), gap: Double(presentation.style.gap),
                separatorLength: Double(presentation.style.separatorLength),
                dividerIndex: store.pinnedCount > 0 && store.pinnedCount < count ? store.pinnedCount : nil)
        }
        func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }
        let fixed = span("A") + 80
        store.updateManualSizing(for: "A") { $0.length = fixed }
        store.setManualAutoLength(true, sourceDisplayID: "A")
        check(store.configuration.manualAutoLength, "manual content mode not enabled")
        check(same(store.configuration.manualContentPadding ?? -1, 40), "current end padding not captured")
        check(same(store.effectiveManualSizing(for: "A").length, fixed), "enabling changed visible length")
        check(store.presentation(for: "A").style.leadingPadding == 40, "captured padding missing from geometry")
        let fake = AppReference(id: "test.dualdock.added", name: "Added App", path: "/not-an-app")
        store.update { $0.insert([fake]) }
        check(same(store.effectiveManualSizing(for: "A").length, span("A") + 80), "new icon did not grow row")
        check(store.effectiveManualSizing(for: "A").length > fixed, "new icon remained clipped at fixed length")
        check(store.configuration.dockWidth == fixed, "content growth overwrote fixed-width backup")
        store.update { $0.removeApp(id: fake.id) }
        check(same(store.effectiveManualSizing(for: "A").length, fixed), "removal did not restore row length")
        let extra = AppReference(id: "test.dualdock.member", name: "Group Member", path: "/not-a-member")
        let group = DockEntry(name: "Group", apps: [fake, extra], isGroup: true)
        store.update { $0.entries.append(group) }
        let groupedCount = store.displayedEntries.count
        let groupedWidth = store.effectiveManualSizing(for: "A").length
        check(same(groupedWidth, span("A") + 80), "collapsed group did not occupy one tile")
        store.update { $0.entries[$0.entries.count - 1].apps.append(
            AppReference(id: "test.dualdock.member2", name: "Second Member", path: "/not-a-member2")) }
        check(store.displayedEntries.count == groupedCount
            && same(store.effectiveManualSizing(for: "A").length, groupedWidth),
            "adding a member to a collapsed group enlarged the main Dock")
        check(store.presentation(for: "A", group: true).style.leadingPadding == 6,
              "main Dock end padding leaked into group popup")
        store.update { $0.removeEntry(id: group.id) }
        if let running = store.runningApps.first {
            let count = store.displayedEntries.count
            store.update { $0.insert([running]) }
            check(store.displayedEntries.count == count, "pinning a running app duplicated its content width")
            store.update { $0.removeApp(id: running.id) }
        }
        store.update { $0.mode = .runningOnly }
        check(same(store.effectiveManualSizing(for: "A").length, span("A") + 80),
              "running-only mode did not size to its actual visible entries")
        store.update { $0.mode = .standard }
        check(same(store.effectiveManualSizing(for: "A").length, fixed),
              "returning to standard mode lost preserved padding")
        check(same(store.editingSizingBounds(for: "A").minLength, span("A") + 12),
              "length-control minimum did not follow actual row")
        store.updateManualSizing(for: "A") { $0.iconSpacing = 3 }
        check(same(store.effectiveManualSizing(for: "A").length, span("A") + 80), "spacing did not fit actual content")
        check(same(store.configuration.manualContentPadding ?? -1, 40), "spacing changed end padding")
        store.updateManualSizing(for: "A") { $0.thickness = 80; $0.iconScale = 0.8 }
        check(same(store.effectiveManualSizing(for: "A").length, span("A") + 80), "manual icon scaling did not grow content length")
        check(same(store.configuration.manualContentPadding ?? -1, 40), "thickness changed end padding")
        store.updateManualSizing(for: "A") { $0.length = span("A") + 120 }
        check(same(store.configuration.manualContentPadding ?? -1, 60), "length edit did not rebase padding")
        check(store.configuration.dockWidth == fixed, "length edit overwrote fixed-width backup")

        var draft = store.requestedManualSizing(for: "A")
        draft.thickness += 10
        store.setResizePreview(draft, for: "A")
        check(same(store.effectiveManualSizing(for: "A").contentPadding ?? -1, 60), "height-only preview rebased padding")
        store.commitManualResize(draft, for: "A")
        saved = try JSONDecoder().decode(DockConfiguration.self, from: Data(contentsOf: file))
        check(same(saved.manualContentPadding ?? -1, 60) && same(saved.iconSize * 1.375, draft.thickness),
              "height resize commit was not durable or lost retained padding")
        draft = store.requestedManualSizing(for: "A")
        draft.length += 40
        store.setResizePreview(draft, for: "A")
        store.commitManualResize(draft, for: "A")
        check(same(store.configuration.manualContentPadding ?? -1, 80), "length drag did not persist rebased padding")

        store.setSizeSynchronization(false, sourceDisplayID: "A")
        store.updateManualSizing(for: "B") { $0.length += 60 }
        check(same(store.effectiveManualSizing(for: "A").contentPadding ?? -1, 80), "independent B edit changed A padding")
        check(same(store.effectiveManualSizing(for: "B").contentPadding ?? -1, 110), "independent B padding missing")
        store.setSizeSynchronization(true, sourceDisplayID: "B")
        check(same(store.effectiveManualSizing(for: "A").contentPadding ?? -1, 110), "sync did not adopt selected screen padding")
        check(store.configuration.dockWidth == fixed, "sync overwrote fixed-width backup")

        let tiny = DockDisplayInfo(id: "A", runtimeID: 1, name: "A",
            frame: CGRect(x: 0, y: 0, width: 600, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 600, height: 860), isPrimary: true)
        store.updateDisplays([tiny, screenB])
        let p = store.presentation(for: "A")
        let g = DockGeometry.make(count: store.displayedEntries.count, edge: p.edge, style: p.style,
            maximumLength: p.maximumLength, fixedLength: p.fixedLength,
            dividerIndex: store.pinnedCount > 0 ? store.pinnedCount : nil)
        check(p.fixedLength == 600, "content length did not cap at narrowest synchronized screen")
        check(g.scrollRange > 0, "screen-filling content did not allow manual overflow scrolling")
        check(same(store.configuration.manualContentPadding ?? -1, 110), "small screen destroyed requested padding")
        let blockedResize = DockResizePolicy.propose(start: p.requestedManualSizing,
            handle: .trailing, edge: p.edge, screenDelta: CGSize(width: 40, height: 0),
            bounds: p.lengthResizeBounds!)
        store.setResizePreview(blockedResize, for: "A")
        store.commitManualResize(blockedResize, for: "A")
        check(same(store.configuration.manualContentPadding ?? -1, 110),
              "a width drag blocked by the screen cap discarded retained padding")
        store.updateDisplays([screenA, screenB])
        check(same(store.effectiveManualSizing(for: "A").length, span("A") + 220), "reconnect did not restore content length")
        let nativeMetrics = store.nativeDockMetrics
        store.setAdaptiveSizing(true)
        check(store.presentation(for: "A").fixedLength == nil && !store.presentation(for: "A").canResize,
              "manual fitting replaced native adaptive behavior")
        check(store.presentation(for: "A").style.iconSize == nativeMetrics.iconSize,
              "manual fitting changed native icon size")
        store.setAdaptiveSizing(false)
        check(store.configuration.manualAutoLength && same(store.configuration.manualContentPadding ?? -1, 110),
              "native mode overwrote manual fitting choice")
        store.setManualAutoLength(false, sourceDisplayID: "A")
        check(same(store.effectiveManualSizing(for: "A").length, fixed), "disabling did not restore saved fixed width")

        store.setManualAutoLength(true, sourceDisplayID: "A")
        store.stopBackgroundServices()
        let expected = store.configuration
        let reopened = AppStore(directory: directory)
        reopened.stopBackgroundServices()
        reopened.updateDisplays([screenA, screenB])
        check(reopened.configuration == expected, "restart lost manual content sizing preferences")
        store.updateManualSizing(for: "A") { $0.iconSpacing = 17 }
        store.stopBackgroundServices()
        saved = try JSONDecoder().decode(DockConfiguration.self, from: Data(contentsOf: file))
        check(saved.iconSpacing == 17, "stop discarded a pending final slider value")
        store.setManualAutoLength(false, sourceDisplayID: "A")
        store.setSizeSynchronization(false, sourceDisplayID: "A")
        store.update {
            $0.displaySettings["C"] = DockDisplaySettings(edge: .top,
                manualSizing: DockManualSizing(length: 5000, thickness: 70, iconSpacing: 11, contentPadding: 55))
        }
        store.setManualAutoLength(true, sourceDisplayID: "A")
        check(store.configuration.displaySettings["C"]?.manualSizing?.contentPadding == nil,
              "offline screen was rebased using another screen's bounds")
        let screenC = DockDisplayInfo(id: "C", runtimeID: 3, name: "C",
            frame: CGRect(x: 0, y: 1600, width: 8000, height: 1800),
            visibleFrame: CGRect(x: 0, y: 1600, width: 8000, height: 1760))
        store.updateDisplays([screenA, screenB, screenC])
        check(same(store.effectiveManualSizing(for: "C").length, 5000),
              "reconnected screen did not capture its own saved manual whitespace")
        check(store.configuration.displaySettings["C"]?.manualSizing?.contentPadding != nil,
              "reconnected screen capture was not persisted")
        check(store.edge(for: "C") == .top, "content fitting changed a saved screen edge")
        store.setEdge(.left, for: "B")
        check(store.editingSizingBounds(for: "B").maxLength == screenB.visibleFrame.height,
              "vertical content fitting did not use its own screen height")
        store.update {
            $0.mode = .standard
            $0.entries = [DockEntry(name: "All apps", apps: store.runningApps + [fake], isGroup: true)]
        }
        store.updateManualSizing(for: "A") { $0.thickness = 33; $0.iconScale = 0.8 }
        store.updateManualSizing(for: "A") { $0.length = span("A") + 12 }
        let compact = store.presentation(for: "A")
        check(compact.fixedLength! < 120, "single collapsed group retained unrelated manual minimum width")
        let unchangedCorner = DockResizePolicy.propose(start: compact.requestedManualSizing,
            handle: .trailingCorner, edge: compact.edge, screenDelta: .zero, bounds: compact.resizeBounds)
        check(same(unchangedCorner.length, compact.requestedManualSizing.length),
              "zero-motion corner resize jumped a compact content-fit Dock")
        check(same(compact.lengthResizeBounds?.minLength ?? -1, span("A") + 12),
              "width edge did not receive its distinct content-based minimum")
        store.updateDisplays([])
        store.setResizePreview(store.requestedManualSizing(for: nil), for: nil)
        check(store.resizeRevision > 0, "display-transition preview failed")
        store.setResizePreview(nil, for: nil)
        store.stopBackgroundServices()
        print("Manual content sizing checks: \(checks), failures: \(failures.count)")
        failures.forEach { print("FAIL: \($0)") }
        if !failures.isEmpty { exit(1) }
    }
}
