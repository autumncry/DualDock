import AppKit
import DualDockCore

private final class WindowRecoveryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var minimized = false
    private var restorations = 0

    func perform(_ action: DockWindowAction) {
        lock.lock(); defer { lock.unlock() }
        minimized = action == .minimize
    }

    func recover(_ cancellation: ActivationRecoveryCancellation) {
        lock.lock(); defer { lock.unlock() }
        if !cancellation.isCancelled && minimized { minimized = false; restorations += 1 }
    }

    var state: (minimized: Bool, restorations: Int) {
        lock.lock(); defer { lock.unlock() }
        return (minimized, restorations)
    }
}

/// Actual menu construction and Dock callbacks with an injected native window
/// boundary. Panels remain hidden; no posted input or real app/window actions.
@main
struct WindowMenuChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = AppReference(id: "local.dualdock.fixture.window-menu", name: "Window Fixture",
                               path: directory.appendingPathComponent("NeverLaunched.app").path)
        let otherApp = AppReference(id: "local.dualdock.fixture.other-menu", name: "Other Fixture",
                                   path: directory.appendingPathComponent("NeverLaunchedOther.app").path)
        precondition(!FileManager.default.fileExists(atPath: app.path))
        var config = DockConfiguration()
        config.showBadges = false
        config.showPreviews = false
        config.hideSystemDock = false
        config.dockWidth = 700
        config.entries = [.init(name: app.name, apps: [app]), .init(name: otherApp.name, apps: [otherApp])]
        try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("configuration.json"))
        let date = Date(timeIntervalSince1970: 100)
        func item(_ id: UInt32, title: String, minimized: Bool = false, front: Bool = false) -> DockWindowItem {
            .init(id: .init(pid: 456, processLaunchDate: date, applicationPath: app.path, windowID: id),
                  title: title, frame: CGRect(x: 100, y: 100, width: 700, height: 500),
                  isMinimized: minimized, isFullscreen: false, isMaximized: false,
                  isFrontmost: front, isFocused: front, isMain: id == 1)
        }
        var windows = [item(1, title: "Window A", front: true), item(2, title: "Window B", minimized: true)]
        var calls: [(UInt32, DockWindowAction)] = []
        var reads = 0
        var blockNextRead = false
        var blockedRead: CheckedContinuation<[DockWindowItem], Never>?
        var blockAcrossTiles = false
        var menuReads: [String: CheckedContinuation<DockWindowInventory, Never>] = [:]
        let service = WindowInteractionService(environment: .init(read: { queriedApp in
            precondition(queriedApp == app || queriedApp == otherApp)
            reads += 1
            if blockAcrossTiles {
                return await withCheckedContinuation { menuReads[queriedApp.id] = $0 }
            }
            if blockNextRead {
                blockNextRead = false
                return .available(await withCheckedContinuation { blockedRead = $0 })
            }
            return .available(queriedApp == app ? windows : [])
        }, perform: { selected, action, queriedApp in
            precondition(queriedApp == app)
            guard windows.contains(where: { $0.id == selected.id }) else { return .missing }
            calls.append((selected.id.windowID, action))
            windows = windows.map { current in
                let target = current.id == selected.id
                return .init(id: current.id, title: current.title, frame: current.frame,
                    isMinimized: target ? action == .minimize : current.isMinimized,
                    isFullscreen: current.isFullscreen, isMaximized: current.isMaximized,
                    isFrontmost: target && action != .minimize,
                    isFocused: target && action != .minimize, isMain: current.isMain)
            }
            return .performed
        }))
        let store = AppStore(directory: directory)
        store.stopBackgroundServices()
        let coordinator = DisplayCoordinator(store: store, presentsPanels: false, windowInteractions: service)
        defer { coordinator.stop(); store.stopBackgroundServices() }
        var failures: [String] = []
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        func settle(until condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(2)
            while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
        guard let first = coordinator.docks.values.first,
              let tile = first.strip.tiles.first(where: { $0.entry.apps.first?.id == app.id }) else {
            fatalError("No attached display for hidden menu fixture")
        }
        guard let initial = await tile.prepareMenu?() else { fatalError("No prepared window menu") }
        check(initial.items.prefix(2).map(\.title) == ["Window A", "Window B（已最小化）"],
              "window list was not at the top or omitted minimized B")
        check(initial.items[0].state == .on && initial.items[1].state == .off,
              "initial focused window checkmark incorrect")
        check(initial.items[2].isSeparatorItem, "window list missing separator from application actions")
        check(initial.items[3].title == "打开 Window Fixture", "existing application action missing")
        check(calls.isEmpty, "reading menu mutated a window")

        let selectedB = initial.items[1]
        check(NSApp.sendAction(selectedB.action!, to: selectedB.target, from: selectedB), "menu action was not dispatched")
        await settle { calls.count == 1 }
        check(calls.last?.0 == 2 && calls.last?.1 == .restore, "selecting minimized B did not restore exact window")
        check(windows.first(where: { $0.id.windowID == 1 })?.isMinimized == false,
              "selecting B changed A minimized state")
        for dock in coordinator.docks.values {
            guard let sharedTile = dock.strip.tiles.first(where: { $0.entry.apps.first?.id == app.id }),
                  let menu = await sharedTile.prepareMenu?() else { check(false, "display missing shared menu"); continue }
            check(menu.items[1].title == "Window B" && menu.items[1].state == .on && menu.items[0].state == .off,
                  "selected window was not shared across display menus")
        }

        for expected in [DockWindowAction.minimize, .restore, .minimize, .restore] {
            let count = calls.count
            tile.onPress?()
            await settle { calls.count > count }
            check(calls.count == count + 1 && calls.last?.0 == 2 && calls.last?.1 == expected,
                  "repeat Dock icon press did not \(expected) selected B")
            check(windows.first(where: { $0.id.windowID == 1 })?.isMinimized == false,
                  "repeat B toggle changed A")
        }
        let beforeRapid = calls.count
        for _ in 0..<6 { tile.onPress?() }
        await settle { calls.count == beforeRapid + 6 }
        check(Array(calls.dropFirst(beforeRapid)).map(\.0) == Array(repeating: UInt32(2), count: 6),
              "rapid coordinator clicks changed selected target")
        check(Array(calls.dropFirst(beforeRapid)).map(\.1) == [.minimize, .restore, .minimize, .restore, .minimize, .restore],
              "rapid coordinator clicks were lost or used stale minimized state")

        windows = [item(1, title: "Window A", front: true)]
        let beforeClosed = calls.count
        tile.onPress?()
        await settle { calls.count > beforeClosed }
        check(calls.count == beforeClosed + 1 && calls.last?.0 == 1 && calls.last?.1 == .minimize,
              "closed selected B did not fall back to fresh A")
        guard let afterClose = await tile.prepareMenu?() else { fatalError("No menu after closing B") }
        check(afterClose.items[0].title == "Window A（已最小化）" && afterClose.items[0].state == .on,
              "fresh menu did not show A as selected/minimized")
        check(afterClose.items[1].isSeparatorItem && !afterClose.items.contains(where: { $0.title == "Window B" }),
              "closed B remained in window list")
        check(store.message == nil, "coordinator attempted native fallback or reported an unexpected failure")

        // Local event method invocation arms the actual deferred menu path, but
        // the hidden panel prevents any NSMenu popup even if a guard regresses.
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: first.panel.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        for attempt in 0..<2 {
            blockNextRead = true
            let beforeRead = reads
            tile.rightMouseDown(with: event)
            await settle { reads > beforeRead && blockedRead != nil }
            check(blockedRead != nil && first.strip.isInteracting, "pending menu \(attempt) did not hold interaction")
            coordinator.dismissPopups()
            check(!first.strip.isInteracting, "dismiss did not release pending-menu interaction")
            let gate = blockedRead; blockedRead = nil
            gate?.resume(returning: windows)
            try? await Task.sleep(nanoseconds: 10_000_000)
            check(!first.strip.isInteracting, "late canceled menu reacquired interaction")
            check(calls.count == beforeClosed + 1, "canceled menu executed a window action")
        }
        guard let otherTile = first.strip.tiles.first(where: { $0.entry.apps.first?.id == otherApp.id }) else {
            fatalError("No second tile for cross-menu cancellation fixture")
        }
        blockAcrossTiles = true
        tile.rightMouseDown(with: event)
        await settle { menuReads[app.id] != nil }
        check(menuReads[app.id] != nil, "first tile did not start its deferred menu read")
        otherTile.rightMouseDown(with: event)
        await settle { menuReads[otherApp.id] != nil }
        check(menuReads[otherApp.id] != nil && first.strip.isInteracting,
              "second tile did not own the pending menu interaction")
        otherTile.cancelPendingMenu()
        check(!first.strip.isInteracting, "new tile menu left the older tile's pending interaction alive")
        blockAcrossTiles = false
        let completedMenus = Array(menuReads.values)
        menuReads.removeAll()
        completedMenus.forEach { $0.resume(returning: .available([])) }
        try? await Task.sleep(nanoseconds: 10_000_000)
        check(!first.strip.isInteracting && calls.count == beforeClosed + 1,
              "late superseded menu result reacquired interaction or executed an action")
        check(coordinator.docks.values.allSatisfy { !$0.panel.isVisible }, "fixture presented a Dock panel")
        check(!FileManager.default.fileExists(atPath: app.path), "fixture application unexpectedly materialized")
        for reopenDuringRead in [false, true] {
            let target = item(1, title: "Recovery target", front: true)
            let process = ApplicationActivationService.Process(pid: target.id.pid, bundleIdentifier: app.id,
                bundlePath: URL(fileURLWithPath: app.path).standardizedFileURL.resolvingSymlinksInPath().path,
                launchDate: date, regular: true, active: true, terminated: false)
            let probe = WindowRecoveryProbe()
            var launches = 0
            let activation = ApplicationActivationService(environment: .init(processes: { [process] },
                windowOrder: { [process.pid] }, activate: { _ in true }, restoreWindow: { _ in .raised },
                fileExists: { _ in true }, openApplication: { _, done in launches += 1; done(process, nil) },
                recoverAfterOpen: { _, cancellation in probe.recover(cancellation) }))
            let actions = DisplayCoordinator.ApplicationActions(
                launch: { activation.open($0, at: URL(fileURLWithPath: $0.path)) { _ in } },
                cancelRecovery: { activation.cancelPendingRecovery() })
            var firstRead = true
            var readGate: CheckedContinuation<DockWindowInventory, Never>?
            var performed: [DockWindowAction] = []
            let recoveryService = WindowInteractionService(environment: .init(read: { _ in
                if firstRead {
                    firstRead = false
                    return await withCheckedContinuation { readGate = $0 }
                }
                return .available([target])
            }, perform: { _, action, _ in performed.append(action); probe.perform(action); return .performed }))
            let recovery = DisplayCoordinator(store: store, presentsPanels: false,
                windowInteractions: recoveryService, applicationActions: actions)
            guard let recoveryTile = recovery.docks.values.first?.strip.tiles.first else {
                fatalError("No hidden recovery fixture")
            }
            recoveryTile.onPress?()
            await settle { readGate != nil }
            if reopenDuringRead {
                // A native reopen completion can arrive after callback-entry
                // cancellation, while the current window inventory is pending.
                actions.launch(app)
            } else {
                // A newer click must suppress the older click's delayed empty
                // inventory fallback, without dropping the newer real toggle.
                recoveryTile.onPress?()
            }
            readGate?.resume(returning: .available(reopenDuringRead ? [target] : []))
            await settle { performed.count == 1 }
            try? await Task.sleep(nanoseconds: 200_000_000)
            check(performed == [.minimize], "recovery fixture lost the intended real toggle")
            check(launches == (reopenDuringRead ? 1 : 0), "obsolete click launched a native fallback")
            check(probe.state.minimized && probe.state.restorations == 0,
                  "\(reopenDuringRead ? "late reopen" : "obsolete fallback") recovery resurrected the minimized window")
            recovery.stop()
        }
        for useMenu in [false, true] {
            let stopping = DisplayCoordinator(store: store, presentsPanels: false, windowInteractions: service)
            guard let stoppingTile = stopping.docks.values.first?.strip.tiles.first,
                  let stoppingMenu = await stoppingTile.prepareMenu?() else {
                fatalError("No hidden stopping fixture")
            }
            let beforeStop = calls.count
            if useMenu {
                let action = stoppingMenu.items[0]
                _ = NSApp.sendAction(action.action!, to: action.target, from: action)
            } else { stoppingTile.onPress?() }
            stopping.stop()
            try? await Task.sleep(nanoseconds: 30_000_000)
            check(calls.count == beforeStop,
                  "queued \(useMenu ? "menu" : "icon") callback performed a window action after stop")
        }
        var explicitLaunches = 0
        let replacing = DisplayCoordinator(store: store, presentsPanels: false, windowInteractions: service,
            applicationActions: .init(launch: { _ in explicitLaunches += 1 }, cancelRecovery: {}))
        guard let replacingTile = replacing.docks.values.first?.strip.tiles.first,
              let applicationMenu = replacingTile.menuProvider?() else {
            fatalError("No hidden explicit-open fixture")
        }
        let beforeReplacement = calls.count
        replacingTile.onPress?()
        let openAction = applicationMenu.items[0]
        _ = NSApp.sendAction(openAction.action!, to: openAction.target, from: openAction)
        try? await Task.sleep(nanoseconds: 30_000_000)
        check(explicitLaunches == 1, "explicit open action did not reach its native boundary")
        check(calls.count == beforeReplacement, "explicit open did not supersede an unstarted icon callback")
        replacing.stop()
        print("Window menu integration: \(checks) checks, \(failures.count) failures; hidden panels, injected window actions only")
        failures.forEach { print("FAIL: \($0)") }
        if !failures.isEmpty { exit(1) }
    }
}
