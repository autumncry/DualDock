import AppKit
import DualDockCore

/// Injected native boundary: no real window enumeration/actions or input.
@main
struct WindowInteractionChecks {
    @MainActor static func main() async {
        let app = AppReference(id: "test.windows", name: "Fixture", path: "/Applications/Fixture.app")
        let date = Date(timeIntervalSince1970: 100)
        func item(_ number: UInt32, minimized: Bool = false, front: Bool = true, fullscreen: Bool = false,
                  maximized: Bool = false, launchDate: Date? = nil) -> DockWindowItem {
            .init(id: .init(pid: 123, processLaunchDate: launchDate ?? date, applicationPath: app.path, windowID: number),
                  title: "Window \(number)", frame: CGRect(x: 100, y: 100, width: 700, height: 500),
                  isMinimized: minimized, isFullscreen: fullscreen, isMaximized: maximized,
                  isFrontmost: front, isFocused: front, isMain: number == 1)
        }
        var failures: [String] = []
        var count = 0
        func check(_ value: Bool, _ message: String) { count += 1; if !value { failures.append(message) } }
        func handled(_ value: WindowInteractionResult) -> Bool { value == .handled }
        var windows = [item(1)]
        var calls: [(UInt32, DockWindowAction)] = []
        var nextOutcome = DockWindowActionOutcome.performed
        var readDelay: UInt64 = 0
        var actionDelay: UInt64 = 0
        var reads = 0
        var readIssue: DockWindowInventory?
        let environment = WindowInteractionService.Environment(read: { _ in
            reads += 1
            if readDelay > 0 { try? await Task.sleep(nanoseconds: readDelay) }
            return readIssue ?? .available(windows)
        }, perform: { selected, action, _ in
            calls.append((selected.id.windowID, action))
            if actionDelay > 0 { try? await Task.sleep(nanoseconds: actionDelay) }
            guard nextOutcome == .performed else { return nextOutcome }
            windows = windows.map { current in
                let target = current.id == selected.id
                return .init(id: current.id, title: current.title, frame: current.frame,
                    isMinimized: target ? action == .minimize : current.isMinimized,
                    isFullscreen: current.isFullscreen, isMaximized: current.isMaximized,
                    isFrontmost: target && action != .minimize,
                    isFocused: target && action != .minimize, isMain: current.isMain)
            }
            return .performed
        })
        var service = WindowInteractionService(environment: environment)

        for expected in [DockWindowAction.minimize, .restore, .minimize, .restore] {
            check(handled(await service.toggle(for: app)), "ordinary toggle failed")
            check(calls.last?.1 == expected, "repeat click did not alternate \(expected)")
            check(windows[0].isMinimized == (expected == .minimize), "native minimized state mismatch")
        }
        windows = [item(1, front: false)]
        check(handled(await service.toggle(for: app)), "background activation failed")
        check(calls.last?.1 == .activate, "background window was minimized")
        check(handled(await service.toggle(for: app)) && calls.last?.1 == .minimize, "second frontmost click did not minimize")

        windows = [item(1), item(2, front: false)]
        check(handled(await service.select(windows[1], for: app)), "window B selection failed")
        let listed = await service.list(for: app)
        check(listed.selectedID?.windowID == 2 && listed.items.count == 2, "menu checkmark did not remember window B")
        let retainedWindows = windows
        readIssue = .unavailable
        check((await service.list(for: app)).items.isEmpty, "unavailable snapshot was not empty")
        readIssue = nil
        windows = retainedWindows
        check((await service.list(for: app)).selectedID?.windowID == 2, "temporary AX unavailability lost selected B")
        check(handled(await service.toggle(for: app)) && calls.last?.0 == 2 && calls.last?.1 == .minimize,
              "icon click did not minimize selected B")
        // Minimizing B can make A focused, but the next icon click must restore B.
        windows = [item(1), item(2, minimized: true, front: false)]
        check(handled(await service.toggle(for: app)) && calls.last?.0 == 2 && calls.last?.1 == .restore,
              "focused A replaced remembered minimized B")
        let staleB = windows[1]
        windows = [item(1)]
        let beforeStale = calls.count
        check(await service.select(staleB, for: app) == .targetUnavailable,
              "explicit stale selection was not quietly rejected")
        check(calls.count == beforeStale, "stale window dispatched action")
        check(handled(await service.toggle(for: app)) && calls.last?.0 == 1, "closed target did not use fresh focused window")

        let old = item(1)
        windows = [item(1, launchDate: Date(timeIntervalSince1970: 200))]
        let beforeReuse = calls.count
        check(await service.select(old, for: app) == .targetUnavailable,
              "PID/window ID reuse was not quietly rejected")
        check(calls.count == beforeReuse, "reused PID dispatched action")

        for (fullscreen, maximized) in [(true, false), (false, true), (true, true)] {
            service = WindowInteractionService(environment: environment)
            windows = [item(1, fullscreen: fullscreen, maximized: maximized)]
            check(handled(await service.toggle(for: app)), "protected window activation failed")
            check(calls.last?.1 == .activate, "fullscreen/maximized window was minimized")
            check(handled(await service.toggle(for: app)) && calls.last?.1 == .activate, "repeated protected click minimized")
        }

        service = WindowInteractionService(environment: environment)
        windows = [item(1)]
        nextOutcome = .unsupported
        if case .failure = await service.toggle(for: app) { check(true, "unsupported minimize") }
        else { check(false, "unsupported minimize was silently reported successful") }
        nextOutcome = .missing
        check(await service.toggle(for: app) == .targetUnavailable,
              "missing action target produced a global warning or application fallback")
        nextOutcome = .superseded
        check(handled(await service.toggle(for: app)), "superseded action became user error")
        nextOutcome = .performed
        windows = []
        check(await service.toggle(for: app) == .fallbackToApplication, "no-window application did not use native reopen fallback")

        // A second click arriving before the first native state change finishes
        // must read after it, rather than deciding against the same stale state.
        windows = [item(1)]
        calls = []
        actionDelay = 5_000_000
        service = WindowInteractionService(environment: environment)
        let current = service
        let clicks = (0..<6).map { _ in Task { @MainActor in await current.toggle(for: app) } }
        for click in clicks { check(handled(await click.value), "queued toggle failed") }
        check(calls.map(\.1) == [.minimize, .restore, .minimize, .restore, .minimize, .restore], "rapid clicks consumed stale state")
        check(windows[0].isMinimized == false, "even queued click count left window minimized")
        actionDelay = 0

        // Stop/preview selection must invalidate a delayed click before it can
        // apply a window mutation after the user chose a different target.
        readDelay = 20_000_000
        calls = []
        let readsBefore = reads
        let cancelled = Task { @MainActor in await current.toggle(for: app) }
        while reads == readsBefore { await Task.yield() }
        current.cancel()
        check(handled(await cancelled.value), "cancel result")
        check(calls.isEmpty, "cancelled read still mutated a window")
        readDelay = 0

        windows = [item(1), item(2, front: false)]
        service = WindowInteractionService(environment: environment)
        service.remember(WindowPreview(windowID: 2, pid: 123, title: "B", image: nil, frame: windows[1].frame,
            processLaunchDate: date, applicationPath: app.path), for: app)
        check((await service.list(for: app)).selectedID == windows[1].id, "preview choice not reflected in menu")
        check(handled(await service.toggle(for: app)) && calls.last?.0 == 2 && calls.last?.1 == .activate,
              "preview-selected background B not activated")
        // Partial AX reads are unavailable inventories, not evidence of closure.
        // B must remain the target while A is still readable and focused.
        windows = [item(1), item(2, minimized: true, front: false)]
        let completeWindows = windows
        windows = [item(1)]
        readIssue = .unavailable
        let beforeIncomplete = calls.count
        check((await service.list(for: app)).items.isEmpty, "partial snapshot exposed incomplete menu")
        check(await service.toggle(for: app) == .targetUnavailable,
              "incomplete selected-window snapshot was not quietly rejected")
        check(calls.count == beforeIncomplete, "incomplete snapshot mutated another window")
        windows = completeWindows
        readIssue = nil
        check((await service.list(for: app)).selectedID?.windowID == 2, "incomplete snapshot lost remembered B")
        check(handled(await service.toggle(for: app)) && calls.last?.0 == 2 && calls.last?.1 == .restore,
              "complete snapshot did not restore remembered B")
        readIssue = .permissionDenied
        check(await service.toggle(for: app) == .fallbackToApplication, "no-permission path lost native open fallback")
        readIssue = nil
        windows = []
        check((await service.list(for: app)).selectedID == nil, "complete empty inventory retained closed target")
        windows = [item(1), item(2, front: false)]
        check((await service.list(for: app)).selectedID?.windowID == 1,
              "complete empty inventory did not invalidate closed selection")
        print("Window interaction: \(count) checks, \(failures.count) failures; injected native boundary only")
        failures.forEach { print("FAIL: \($0)") }
        if !failures.isEmpty { exit(1) }
    }
}
