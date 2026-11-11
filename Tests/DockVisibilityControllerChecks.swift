import AppKit
import DualDockCore

/// Stub state provider, deliberately compiled instead of the real WindowService.
/// These checks exercise the production controller's timer/observer lifecycle,
/// not real macOS fullscreen detection. No AX or WindowServer window reads occur.
@MainActor
final class WindowService {
    var onFullscreenStateChange: (() -> Void)?
    var fullscreen: Set<CGDirectDisplayID> = []
    private(set) var reads = 0
    private(set) var invalidations = 0
    private(set) var stops = 0

    func fullscreenDisplayIDs(screens: [NSScreen]) -> Set<CGDirectDisplayID> {
        reads += 1
        return screens.isEmpty ? [] : fullscreen
    }
    func invalidateFullscreenState() { invalidations += 1 }
    func stopFullscreenMonitoring() { stops += 1 }
}

@main
struct DockVisibilityControllerChecks {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard let screen = NSScreen.screens.first,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            fputs("A WindowServer display is required for a real NSScreen snapshot.\n", stderr)
            exit(1)
        }
        let id = number.uint32Value
        let windows = WindowService()
        var activeTarget = true
        var applied: [(TimeInterval, Set<CGDirectDisplayID>)] = []
        let controller = DockVisibilityController(windows: windows, targets: {
            guard activeTarget else { return [] }
            let frame = screen.visibleFrame
            return [.init(id: id, screen: screen, visibleFrame: frame, edge: .bottom,
                backdrop: CGRect(x: frame.midX - 200, y: frame.minY + 8, width: 400, height: 60),
                pointerInside: false, interacting: false)]
        }, autoHide: { false }, apply: { applied.append((ProcessInfo.processInfo.systemUptime, $0)) })
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        func pump(_ mode: RunLoop.Mode = .default, for duration: TimeInterval,
                  until condition: () -> Bool = { false }) -> TimeInterval {
            let start = ProcessInfo.processInfo.systemUptime
            while !condition(), ProcessInfo.processInfo.systemUptime - start < duration {
                RunLoop.main.run(mode: mode, before: Date().addingTimeInterval(0.005))
            }
            return ProcessInfo.processInfo.systemUptime - start
        }
        func expectState(_ hidden: Bool, in mode: RunLoop.Mode, _ label: String) {
            windows.fullscreen = hidden ? [id] : []
            let count = applied.count
            let latency = pump(mode, for: 0.19) {
                applied.count > count && applied.last?.1.contains(id) == hidden
            }
            check(applied.count > count && applied.last?.1.contains(id) == hidden,
                  "\(label): state did not update within 190ms")
            check(latency < 0.2, "\(label): exceeded 200ms visibility budget")
            print(String(format: "%@ %.1fms", label, latency * 1000))
        }

        controller.refresh(force: true)
        check(applied.count == 1 && applied.last?.1.isEmpty == true, "Initial forced visible state missing")
        controller.refresh()
        check(applied.count == 1, "Unchanged state needlessly reapplied")

        expectState(true, in: .default, "Default-mode hide")
        expectState(false, in: .default, "Default-mode reveal")
        expectState(true, in: .eventTracking, "Tracking-mode hide")
        expectState(false, in: .eventTracking, "Tracking-mode reveal")

        // A Space event must invalidate and force an update even when the last
        // published state is unchanged; polling alone cannot pass this check.
        let invalidations = windows.invalidations
        let eventCount = applied.count
        let eventStart = ProcessInfo.processInfo.systemUptime
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        _ = pump(for: 0.15) { windows.invalidations > invalidations && applied.count > eventCount }
        check(windows.invalidations == invalidations + 1, "Space event did not invalidate fullscreen state")
        check(applied.count > eventCount && applied.last?.1.isEmpty == true, "Space event did not force immediate apply")
        check(ProcessInfo.processInfo.systemUptime - eventStart < 0.16, "Space event response exceeded 160ms")
        print(String(format: "Space-event invalidate/apply %.1fms", (ProcessInfo.processInfo.systemUptime - eventStart) * 1000))

        windows.fullscreen = [id]
        let callbackCount = applied.count
        windows.onFullscreenStateChange?()
        check(applied.count == callbackCount + 1 && applied.last?.1 == [id], "State-provider callback was not applied synchronously")
        activeTarget = false
        controller.refresh()
        check(applied.last?.1.isEmpty == true, "Removed display retained hidden state")
        activeTarget = true
        controller.refresh()
        check(applied.last?.1 == [id], "Reconnected target did not use current fullscreen state")

        // Stop immediately after posting an event, before its MainActor task can
        // execute. A previously retained provider callback must also be harmless.
        let lateCallback = windows.onFullscreenStateChange
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        controller.stop()
        let stoppedReads = windows.reads
        let stoppedInvalidations = windows.invalidations
        let stoppedCount = applied.count
        check(windows.stops == 1, "Stop did not terminate fullscreen monitoring")
        check(windows.onFullscreenStateChange == nil, "Stop retained the provider callback")
        lateCallback?()
        controller.invalidate()
        controller.refresh(force: true)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        _ = pump(for: 0.25)
        check(windows.reads == stoppedReads, "Timer or queued work read state after stop")
        check(windows.invalidations == stoppedInvalidations, "Queued Space event invalidated state after stop")
        check(applied.count == stoppedCount, "Late work applied visibility after stop")
        check(NSApp.windows.allSatisfy { !$0.isVisible }, "Checks showed a window")

        failures.forEach { print("FAIL: \($0)") }
        print("\(checks) DockVisibilityController checks, \(failures.count) failures; stub fullscreen provider, no UI or input")
        exit(failures.isEmpty ? 0 : 1)
    }
}
