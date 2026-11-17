import AppKit
import Combine
import DualDockCore

@main
struct CustomSizingStoreChecks {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("configuration.json")
        let a = DockDisplayInfo(id: "A", runtimeID: 1, name: "A",
            frame: CGRect(x: 0, y: 0, width: 1800, height: 1200),
            visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1160), isPrimary: true)
        let b = DockDisplayInfo(id: "B", runtimeID: 2, name: "B",
            frame: CGRect(x: 1800, y: 0, width: 2200, height: 1600),
            visibleFrame: CGRect(x: 1800, y: 0, width: 2200, height: 1560))
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        func same(_ x: Double, _ y: Double) -> Bool { abs(x - y) < 0.000001 }
        var legacy = DockConfiguration()
        legacy.version = 9
        legacy.showBadges = false
        legacy.showPreviews = false
        legacy.dockWidth = 1017
        legacy.iconSize = 62
        legacy.manualIconScale = 0.71
        legacy.iconSpacing = 17
        legacy.entries = [DockEntry(name: "Saved group", apps: [
            AppReference(id: "custom-sizing.test", name: "Test", path: "/Applications/Test.app")], isGroup: true)]
        legacy.displaySettings["offline"] = DockDisplaySettings(edge: .right,
            manualSizing: DockManualSizing(length: 777, thickness: 68))
        let originalBytes = try JSONEncoder().encode(legacy)
        try originalBytes.write(to: file)
        let store = AppStore(directory: directory)
        store.stopBackgroundServices()
        store.updateDisplays([a, b])
        check(store.configuration.customSizing == nil, "Migration eagerly changed legacy sizing")
        check(store.configuration.entries == legacy.entries, "Migration changed groups")
        check(try Data(contentsOf: directory.appendingPathComponent("configuration-before-v10.json")) == originalBytes,
              "Migration backup changed bytes")
        let oldPresentation = store.presentation(for: "A")
        let snapshot = store.customSizing(for: "A")
        check(snapshot.minimumHeightOverride == oldPresentation.style.barThickness, "Snapshot changed visible height")
        check(same(snapshot.iconSize, oldPresentation.style.iconSize), "Snapshot changed visible icon size")
        check(snapshot.gapOverride == oldPresentation.style.gap, "Snapshot changed gap")
        check(snapshot.paddingOverride == 6 && !snapshot.shrinkBeforeScroll, "Migration adopted shrinking or altered end padding")
        check(store.configuration.customSizing == nil, "Opening settings changed the configuration")

        store.resetCustomSizing(for: "A")
        check(store.customSizing(for: "A").shrinkBeforeScroll, "Fresh defaults did not enable shrink")
        store.flushPendingSave()
        let beforeSliders = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
        for index in 0..<120 {
            store.updateCustomSizing(for: "A") { $0.density = Double(index) / 120 }
        }
        let afterSliders = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
        check(beforeSliders == afterSliders, "Continuous custom slider rewrote configuration synchronously")
        store.flushPendingSave()
        let flushed = try JSONDecoder().decode(DockConfiguration.self, from: Data(contentsOf: file))
        check(flushed.customSizing?.density == 119.0 / 120, "Custom slider flush lost final value")
        store.resetCustomSizing(for: "A")
        store.updateCustomSizing(for: "A") { $0.lengthMode = .fill; $0.iconSize = 40 }
        let reset = store.presentation(for: "A")
        check(reset.fixedLength == 1800, "Fill did not use all applicable length")
        check(same(reset.style.barThickness, 56.8), "Automatic height is not icon plus two paddings")
        check(store.configuration.entries == legacy.entries, "Sizing edit changed groups")
        check(store.edge(for: "offline") == .right, "Sizing synchronization changed position")
        store.updateCustomSizing(for: "A") {
            $0.gapOverride = 9; $0.paddingOverride = 13; $0.minimumHeightOverride = 85
        }
        store.updateCustomSizing(for: "A") { $0.iconSize = 50; $0.density = 0.9 }
        let manual = store.customSizing(for: "A")
        check(manual.gapOverride == 9 && manual.paddingOverride == 13 && manual.minimumHeightOverride == 85,
              "Basic settings overwrote manual overrides")
        store.resetCustomSizingOverride(.gap, for: "A")
        check(store.customSizing(for: "A").gapOverride == nil
            && store.customSizing(for: "A").paddingOverride == 13, "Individual reset changed another field")
        store.updateCustomSizing(for: "A") { $0.iconSize = 100 }
        check(store.presentation(for: "A").style.barThickness == 104, "Manual height incorrectly capped icon growth")

        store.setSizeSynchronization(false, sourceDisplayID: "A")
        store.setEdge(.left, for: "B")
        let unchangedA = store.customSizing(for: "A")
        store.updateCustomSizing(for: "B") { $0.lengthMode = .fixed; $0.fixedLengthPercent = 60; $0.iconSize = 36 }
        check(store.customSizing(for: "A") == unchangedA, "Independent edit changed other screen")
        check(same(store.presentation(for: "B").fixedLength!, 936), "Vertical percent used screen width")
        check(same(store.presentation(for: "B").style.iconSize, 36), "Independent icon size did not render")
        store.updateDisplays([a])
        store.updateDisplays([a, b])
        check(store.customSizing(for: "B").iconSize == 36, "Reconnect lost independent custom profile")
        let beforeStale = store.configuration
        store.updateCustomSizing(for: "gone") { $0.iconSize = 70 }
        check(store.configuration == beforeStale, "Stale screen edited a live profile")
        store.setSizeSynchronization(true, sourceDisplayID: "B")
        check(store.customSizing(for: "A") == store.customSizing(for: "B"), "Sync did not adopt source custom settings")
        check(store.configuration.displaySettings["offline"]?.customSizing == store.configuration.customSizing,
              "Sync did not mirror offline custom profile")
        check(store.edge(for: "B") == .left, "Sync lost vertical edge")

        store.resetCustomSizing(for: "A")
        // A collapsed group counts as one tile, including every currently running app.
        store.update { $0.entries = [DockEntry(name: "Everything", apps: store.runningApps, isGroup: true)] }
        let original = store.presentation(for: "A")
        check(original.fixedLength! < 100, "Collapsed group counted its members as separate tiles")
        store.flushPendingSave()
        let beforeDraft = try Data(contentsOf: file)
        var draft = original.requestedManualSizing
        draft.thickness *= 1.2
        store.setResizePreview(draft, for: "A")
        check(same(store.presentation(for: "A").style.iconSize, 57.6), "Height drag did not scale icons")
        check(try Data(contentsOf: file) == beforeDraft, "Drag draft wrote configuration")
        check(store.presentation(for: "A").style.iconSize == store.presentation(for: "B").style.iconSize,
              "Synced drag did not update other display")
        store.commitManualResize(draft, for: "A")
        check(same(store.customSizing(for: "A").iconSize, 57.6), "Height drag was not committed")
        let beforeEnd = store.presentation(for: "A")
        var end = beforeEnd.requestedManualSizing
        end.length += 100
        store.setResizePreview(end, for: "A")
        check(same(store.presentation(for: "A").fixedLength!, end.length), "End drag preview did not change fit padding")
        store.commitManualResize(end, for: "A")
        check(store.customSizing(for: "A").paddingOverride != nil, "End drag did not persist fit padding")
        for edge in DockEdge.allCases {
            store.setEdge(edge, for: "A")
            store.resetCustomSizing(for: "A")
            store.updateCustomSizing(for: "A") { $0.iconSize = 16; $0.density = 0 }
            let compact = store.presentation(for: "A")
            for handle in DockResizeHandle.allCases {
                let unchanged = DockResizePolicy.propose(start: compact.requestedManualSizing,
                    handle: handle, edge: edge, screenDelta: .zero,
                    bounds: handle == .leading || handle == .trailing
                        ? compact.lengthResizeBounds! : compact.resizeBounds)
                store.setResizePreview(unchanged, for: "A")
                check(same(store.presentation(for: "A").fixedLength!, compact.fixedLength!)
                    && same(store.presentation(for: "A").style.barThickness, compact.style.barThickness),
                    "Zero-motion custom drag jumped compact layout at \(edge)/\(handle)")
                store.setResizePreview(nil, for: "A")
            }
            let physicalDelta: CGSize
            switch edge {
            case .bottom: physicalDelta = CGSize(width: 10, height: 5)
            case .top: physicalDelta = CGSize(width: 10, height: -5)
            case .left: physicalDelta = CGSize(width: 5, height: -10)
            case .right: physicalDelta = CGSize(width: -5, height: -10)
            }
            let corner = DockResizePolicy.propose(start: compact.requestedManualSizing,
                handle: .trailingCorner, edge: edge, screenDelta: physicalDelta, bounds: compact.resizeBounds)
            store.setResizePreview(corner, for: "A")
            let grown = store.presentation(for: "A")
            check(grown.fixedLength! > compact.fixedLength! && grown.style.barThickness > compact.style.barThickness
                && grown.style.iconSize > compact.style.iconSize, "Corner did not grow both axes at \(edge)")
            store.commitManualResize(corner, for: "A")
            check(store.presentation(for: "A").style == grown.style, "Corner commit differed from preview at \(edge)")
        }
        let preserved = store.configuration
        store.setAdaptiveSizing(true)
        check(store.presentation(for: "A").style.iconSize == store.nativeDockMetrics.iconSize,
              "Native adaptive mode ignored native metrics")
        check(!store.presentation(for: "A").canResize, "Native adaptive allowed resizing")
        store.setAdaptiveSizing(false)
        check(store.configuration == preserved, "Native adaptive mode changed saved custom preferences")
        store.stopBackgroundServices()
        let reopened = AppStore(directory: directory)
        reopened.stopBackgroundServices()
        reopened.updateDisplays([a, b])
        check(reopened.configuration == store.configuration, "Restart changed custom preferences")
        check(reopened.presentation(for: "A").style == store.presentation(for: "A").style,
              "Restart changed actual rendered custom values")
        print("Custom sizing store checks: \(checks), failures: \(failures.count)")
        failures.forEach { print("FAIL: \($0)") }
        if !failures.isEmpty { exit(1) }
    }
}
