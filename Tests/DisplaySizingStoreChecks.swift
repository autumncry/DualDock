import AppKit
import Combine
import DualDockCore

/// Actual AppStore integration checks using a temporary configuration directory.
/// No windows are shown, no input is posted, and no system preferences are changed.
/// Background readers are stopped immediately; screen snapshots are supplied via
/// the production updateDisplays API rather than modifying the source under test.
@main
struct DisplaySizingStoreChecks {
  @MainActor
  static func main() throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let a = DockDisplayInfo(
      id: "A", runtimeID: 1, name: "A", frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
      visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1129), isPrimary: true)
    let b = DockDisplayInfo(
      id: "B", runtimeID: 2, name: "B", frame: CGRect(x: -3008, y: 800, width: 3008, height: 1692),
      visibleFrame: CGRect(x: -3008, y: 800, width: 3008, height: 1692))
    let mirror = DockDisplayInfo(
      id: "M", runtimeID: 3, name: "M", frame: CGRect(x: 0, y: 0, width: 320, height: 200),
      visibleFrame: CGRect(x: 0, y: 0, width: 320, height: 200), isMirrored: true)
    var checks = 0
    var failures: [String] = []
    func check(_ condition: Bool, _ text: String) {
      checks += 1
      if !condition { failures.append(text) }
    }
    func same(_ x: Double, _ y: Double) -> Bool { abs(x - y) < 0.000001 }
    var config = DockConfiguration()
    config.showBadges = false
    config.showPreviews = false
    config.dockWidth = 1000
    config.displaySettings["C"] = DockDisplaySettings(
      edge: .top, manualSizing: DockManualSizing(length: 700, thickness: 50))
    let dir = root.appendingPathComponent("profiles")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("configuration.json")
    try JSONEncoder().encode(config).write(to: file)
    let store = AppStore(directory: dir)
    store.stopBackgroundServices()
    store.updateDisplays([a, b])
    check(store.displays == [a, b], "supplied display snapshots missing")
    check(same(store.sizingBounds(for: "A").maxLength, 1800), "shared horizontal limit")
    check(
      same(store.sizingBounds(for: "A").maxThickness, 135.48),
      "shared safe-short-edge thickness limit")
    check(store.presentation(for: "A").canResize, "manual resize unavailable")
    store.setEdge(.left, for: "B")
    check(store.edge(for: "B") == .left && store.edge(for: "A") == .bottom, "positions coupled")
    check(same(store.sizingBounds(for: "A").maxLength, 1692), "oriented shared limit")
    store.setSizeSynchronization(false, sourceDisplayID: "B")
    check(
      store.effectiveManualSizing(for: "A") == store.effectiveManualSizing(for: "B"),
      "unlock jumped profiles")
    store.updateManualSizing(for: "B") {
      $0.length = 1500
      $0.thickness = 80
      $0.iconScale = 0.7
      $0.iconSpacing = 8
    }
    check(same(store.effectiveManualSizing(for: "A").length, 1000), "independent edit changed A")
    check(same(store.effectiveManualSizing(for: "B").length, 1500), "independent B edit missing")
    check(same(store.presentation(for: "B").style.barThickness, 80), "B thickness")
    check(store.presentation(for: "B").edge == .left, "B presentation edge")
    let group = store.presentation(for: "B", group: true)
    check(
      group.edge == .bottom && group.fixedLength == nil && !group.canResize,
      "group must remain natural horizontal popup")
    check(same(Double(group.style.barThickness), store.iconSize(for: "B") + 12), "group thickness")
    check(same(Double(group.maximumLength), 2984), "group own screen width")
    store.setSizeSynchronization(true, sourceDisplayID: "B")
    check(store.configuration.synchronizeSizes, "sync enable")
    check(same(store.configuration.dockWidth!, 1500), "sync did not adopt selected B")
    check(
      store.effectiveManualSizing(for: "A") == store.effectiveManualSizing(for: "B"),
      "sync results differ")
    for key in ["A", "B", "C"] {
      check(
        same(store.configuration.displaySettings[key]!.manualSizing!.length, 1500),
        "known profile not mirrored")
    }
    check(store.edge(for: "B") == .left && store.edge(for: "C") == .top, "sync changed positions")
    store.updateManualSizing(for: "A") {
      $0.length = 1200
      $0.thickness = 75
    }
    for key in ["A", "B", "C"] {
      check(
        same(store.configuration.displaySettings[key]!.manualSizing!.thickness, 75),
        "shared edits not mirrored")
    }
    store.setSizeSynchronization(false, sourceDisplayID: "A")
    store.updateManualSizing(for: "B") {
      $0.length = 900
      $0.thickness = 100
    }
    store.updateDisplays([a])
    store.updateDisplays([a, b])
    check(
      same(store.effectiveManualSizing(for: "B").length, 900), "reconnect lost independent profile")
    let beforeStale = store.configuration
    store.updateManualSizing(for: "gone") { $0.length = 77 }
    store.setEdge(.right, for: "gone")
    store.setSizeSynchronization(true, sourceDisplayID: "gone")
    store.setResizePreview(DockManualSizing(length: 77, thickness: 77), for: "gone")
    check(store.configuration == beforeStale, "stale target mutated configuration")
    let beforeDraft = try Data(contentsOf: file)
    var draft = store.requestedManualSizing(for: "B")
    draft.length = 1000
    draft.thickness = 110
    let revision = store.resizeRevision
    store.setResizePreview(draft, for: "B")
    check(store.resizeRevision == revision + 1, "draft did not publish")
    check(try Data(contentsOf: file) == beforeDraft, "draft wrote disk")
    check(same(store.effectiveManualSizing(for: "B").length, 1000), "draft not visible")
    check(same(store.effectiveManualSizing(for: "A").length, 1200), "independent draft affected A")
    store.updateDisplays([a, b])
    check(
      same(store.effectiveManualSizing(for: "B").length, 1000),
      "identical display snapshot canceled drag")
    store.setResizePreview(nil, for: "gone")
    store.commitManualResize(DockManualSizing(length: 77, thickness: 77), for: "gone")
    check(
      same(store.effectiveManualSizing(for: "B").length, 1000), "stale end canceled another drag")
    var configUpdates = 0
    let subscription = store.$configuration.dropFirst().sink { _ in configUpdates += 1 }
    store.commitManualResize(draft, for: "B")
    check(configUpdates == 1, "resize commit was not one configuration change")
    check(try Data(contentsOf: file) != beforeDraft, "commit did not save")
    check(
      same(store.configuration.displaySettings["B"]!.manualSizing!.length, 1000),
      "commit profile missing")
    store.setResizePreview(DockManualSizing(length: 1100, thickness: 120), for: "B")
    store.updateDisplays([a])
    check(
      same(store.requestedManualSizing(for: "A").length, 1200),
      "display removal leaked draft to primary")
    store.commitManualResize(DockManualSizing(length: 1777, thickness: 80), for: "B")
    check(
      same(store.configuration.displaySettings["B"]!.manualSizing!.length, 1000),
      "stale removed-display commit")
    store.updateDisplays([a, b, mirror])
    store.setSizeSynchronization(true, sourceDisplayID: "B")
    check(
      same(store.sizingBounds(for: "A").maxLength, 1692), "mirror follower restricted live Dock")
    let beforeMirror = store.configuration
    store.setEdge(.right, for: "M")
    store.updateManualSizing(for: "M") { $0.length = 99 }
    check(store.configuration == beforeMirror, "mirror target mutated configuration")
    store.update {
      $0.magnificationScale = 2.2
      $0.magnificationRadius = 1.4
    }
    check(
      same(Double(store.presentation(for: "A").style.magnificationScale), 2.2)
        && same(Double(store.presentation(for: "A").style.magnificationRadius), 1.4),
      "manual curve controls not applied independently")
    check(
      same(Double(store.presentation(for: "B").style.magnificationRadius), 1.4),
      "manual curve range not shared across displays")
    store.update { $0.magnificationEnabled = false }
    check(
      store.presentation(for: "A").style.magnificationScale == 1
        && same(store.configuration.magnificationRadius, 1.4),
      "disabling magnification changed saved curve range")
    store.update { $0.magnificationEnabled = true }
    store.setResizePreview(DockManualSizing(length: 1300, thickness: 100), for: "A")
    check(same(store.effectiveManualSizing(for: "B").length, 1300), "synced draft not visible on B")
    let measured = store.nativeDockMetrics
    store.setAdaptiveSizing(true)
    let nativeA = store.presentation(for: "A")
    let nativeB = store.presentation(for: "B")
    check(!nativeA.canResize && nativeA.fixedLength == nil, "adaptive still manually sized")
    check(
      nativeA.style.iconSize == measured.iconSize
        && nativeA.style.barThickness == measured.barThickness, "native size not used")
    check(
      nativeA.style.magnificationScale == measured.magnificationScale,
      "native magnification was not used")
    check(nativeA.style.magnificationRadius == 2.5,
          "manual curve range leaked into native adaptive mode")
    check(
      nativeA.maximumLength == 1800 && nativeB.maximumLength == 1692,
      "adaptive limits should follow own edge")
    let beforeAdaptive = store.configuration
    store.updateManualSizing(for: "A") { $0.length = 77 }
    store.setResizePreview(DockManualSizing(length: 77, thickness: 77), for: "A")
    store.setSizeSynchronization(false, sourceDisplayID: "A")
    check(store.configuration == beforeAdaptive, "adaptive allowed manual size mutation")
    store.setAdaptiveSizing(false)
    check(
      same(Double(store.presentation(for: "A").style.magnificationRadius), 1.4)
        && same(Double(store.presentation(for: "A").style.magnificationScale), 2.2),
      "adaptive mode overwrote saved manual curve")
    check(
      same(store.effectiveManualSizing(for: "A").length, 1000),
      "adaptive overwrote saved manual size")
    let request = store.configuration
    let bytes = try Data(contentsOf: file)
    let small = DockDisplayInfo(
      id: "A", runtimeID: 1, name: "A", frame: CGRect(x: 0, y: 0, width: 800, height: 600),
      visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 560), isPrimary: true)
    store.updateDisplays([small])
    check(same(store.effectiveManualSizing(for: "A").length, 800), "small screen length clamp")
    let afterHotplug = try Data(contentsOf: file)
    check(store.configuration == request && afterHotplug == bytes, "hotplug overwrote preferences")
    store.updateDisplays([a, b])
    check(
      same(store.effectiveManualSizing(for: "A").length, 1000),
      "reconnect did not restore desired size")
    subscription.cancel()
    store.stopBackgroundServices()
    let saved = store.configuration
    let reopened = AppStore(directory: dir)
    reopened.stopBackgroundServices()
    reopened.updateDisplays([a, b])
    check(reopened.configuration == saved, "restart changed saved display profiles")
    check(reopened.edge(for: "B") == .left, "restart lost per-display position")

    // Schema migration keeps explicit sizing and backs up the original bytes.
    let migrationDirectory = root.appendingPathComponent("migration")
    try FileManager.default.createDirectory(
      at: migrationDirectory, withIntermediateDirectories: true)
    let original = Data(
      "{\"version\":6,\"entries\":[],\"dockWidth\":700,\"iconSize\":48,\"showBadges\":false,\"showPreviews\":false}"
        .utf8)
    try original.write(to: migrationDirectory.appendingPathComponent("configuration.json"))
    let migrated = AppStore(directory: migrationDirectory)
    migrated.stopBackgroundServices()
    migrated.updateDisplays([a, b])
    check(migrated.configuration.version == DockConfiguration.currentVersion, "schema not migrated")
    check(migrated.configuration.dockWidth == 700, "migration changed explicit width")
    let backup = migrationDirectory.appendingPathComponent(
      "configuration-before-v\(DockConfiguration.currentVersion).json")
    check(try Data(contentsOf: backup) == original, "migration backup differs from original")
    check(
      migrated.configuration.synchronizeSizes,
      "legacy configuration did not default to synchronized sizes")
    check(
      migrated.edge(for: "A") == .bottom && migrated.edge(for: "B") == .bottom,
      "legacy position is not bottom")

    print("Display sizing store checks: \(checks), failures: \(failures.count)")
    for failure in failures { print("FAIL: \(failure)") }
    if !failures.isEmpty { exit(1) }
  }
}
