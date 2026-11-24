import AppKit
import DualDockCore

/// Stub state provider, deliberately compiled instead of the real WindowService.
/// These checks exercise the production controller's timer/observer lifecycle,
/// not real macOS fullscreen detection. No AX or WindowServer window reads occur.
@MainActor
final class WindowService {
    var onFullscreenStateChange: (() -> Void)?
    var fullscreen: Set<CGDirectDisplayID> = []
    var activeSpaceIDs: [CGDirectDisplayID: UInt64] = [:]
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
        // Two logical targets reuse one real geometry snapshot. This proves
        // per-display controller isolation, not physical multi-display UI.
        let secondaryID = id ^ 0x80000000
        let windows = WindowService()
        windows.activeSpaceIDs = [id: 1001, secondaryID: 2001]
        var activeTarget = true
        var secondaryTarget = false
        var secondaryInteracting = false
        var applied: [(TimeInterval, DockVisibilityController.Snapshot)] = []
        var pointer = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
        var autoHideDock = false
        var pointerInside = false
        var interacting = false
        var targetFrame = screen.visibleFrame
        let controller = DockVisibilityController(windows: windows, targets: {
            guard activeTarget else { return [] }
            let frame = targetFrame
            var targets = [DockVisibilityController.Target(id: id, screen: screen, visibleFrame: frame, edge: .bottom,
                backdrop: CGRect(x: frame.midX - 200, y: frame.minY + 8, width: 400, height: 60),
                pointerInside: pointerInside, interacting: interacting)]
            if secondaryTarget {
                targets.append(.init(id: secondaryID, screen: screen, visibleFrame: frame, edge: .bottom,
                    backdrop: CGRect(x: frame.midX - 200, y: frame.minY + 8, width: 400, height: 60),
                    pointerInside: false, interacting: secondaryInteracting))
            }
            return targets
        }, autoHideWhenMaximized: { false }, autoHideDock: { autoHideDock }, pointer: { pointer }, apply: { applied.append((ProcessInfo.processInfo.systemUptime, $0)) })
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
                applied.count > count && applied.last?.1.hidden.contains(id) == hidden
            }
            check(applied.count > count && applied.last?.1.hidden.contains(id) == hidden,
                  "\(label): state did not update within 190ms")
            check(latency < 0.2, "\(label): exceeded 200ms visibility budget")
            print(String(format: "%@ %.1fms", label, latency * 1000))
        }

        controller.refresh(force: true)
        check(applied.count == 1 && applied.last?.1.hidden.isEmpty == true, "Initial forced visible state missing")
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
        check(applied.count > eventCount && applied.last?.1.hidden.isEmpty == true, "Space event did not force immediate apply")
        check(ProcessInfo.processInfo.systemUptime - eventStart < 0.16, "Space event response exceeded 160ms")
        print(String(format: "Space-event invalidate/apply %.1fms", (ProcessInfo.processInfo.systemUptime - eventStart) * 1000))

        windows.fullscreen = [id]
        let callbackCount = applied.count
        windows.onFullscreenStateChange?()
        check(applied.count == callbackCount + 1 && applied.last?.1.hidden == [id], "State-provider callback was not applied synchronously")
        check(applied.last?.1.fullscreen == [id], "Snapshot did not identify fullscreen membership")

        // A fullscreen Space ignores the ordinary desktop's reserved bottom
        // area, and revealing remains available with maximize auto-hide off.
        let physical = DockVisibilityController.fullscreenBounds(for: screen)
        targetFrame = CGRect(x: physical.minX, y: physical.minY + 100,
                             width: physical.width, height: max(1, physical.height - 100))
        pointer = NSPoint(x: physical.midX, y: physical.minY + 1)
        controller.refresh()
        check(applied.last?.1.hidden == [id], "Fullscreen edge revealed without dwell")
        _ = pump(for: 0.25) { applied.last?.1.hidden.isEmpty == true }
        check(applied.last?.1.hidden.isEmpty == true && applied.last?.1.fullscreen == [id],
              "Fullscreen physical-edge dwell did not reveal while maximize auto-hide is off")
        pointerInside = true
        pointer = NSPoint(x: physical.midX, y: physical.minY + 40)
        controller.refresh(force: true)
        check(applied.last?.1.hidden.isEmpty == true, "Revealed fullscreen body lost visibility")
        interacting = true
        pointerInside = false
        pointer = NSPoint(x: physical.midX, y: physical.midY)
        _ = pump(for: 0.35)
        check(applied.last?.1.hidden.isEmpty == true, "Fullscreen popup interaction did not retain reveal")
        interacting = false
        _ = pump(for: 0.45) { applied.last?.1.hidden == [id] }
        check(applied.last?.1.hidden == [id], "Fullscreen Dock did not hide after pointer/interaction ended")

        pointer = NSPoint(x: physical.midX, y: physical.minY + 1)
        controller.refresh()
        _ = pump(for: 0.25) { applied.last?.1.hidden.isEmpty == true }
        check(applied.last?.1.hidden.isEmpty == true, "Second fullscreen reveal failed")
        pointerInside = true
        pointer = NSPoint(x: physical.midX, y: physical.minY + 40)
        controller.refresh()
        let beforeSpace = applied.count
        windows.activeSpaceIDs[id] = 1002
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        _ = pump(for: 0.1) { applied.count > beforeSpace }
        check(applied.last?.1.hidden == [id], "New fullscreen Space inherited an old body reveal")
        check(applied.last?.1.fullscreen == [id], "Space reset lost fullscreen classification")
        pointerInside = false

        secondaryTarget = true
        windows.fullscreen = [id, secondaryID]
        pointer = NSPoint(x: physical.midX, y: physical.minY + 1)
        controller.refresh()
        _ = pump(for: 0.25) { applied.last?.1.hidden.isEmpty == true }
        check(applied.last?.1.hidden.isEmpty == true, "Two logical fullscreen targets did not reveal")
        pointer = NSPoint(x: physical.midX, y: physical.midY)
        interacting = true
        secondaryInteracting = true
        controller.refresh()
        windows.activeSpaceIDs[secondaryID] = 2002
        let beforeOtherSpace = applied.count
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        _ = pump(for: 0.1) { applied.count > beforeOtherSpace }
        check(applied.last?.1.hidden == [secondaryID],
              "A Space change on B dismissed the unchanged fullscreen menu/group on A")

        // A timer may observe new metadata before the workspace notification.
        // Detect the identity change immediately rather than losing it to the poll.
        windows.activeSpaceIDs[id] = 1003
        controller.refresh()
        check(applied.last?.1.hidden == [id, secondaryID], "Polling missed a fullscreen-to-fullscreen Space change")
        interacting = false
        secondaryInteracting = false
        pointer = NSPoint(x: physical.midX, y: physical.minY + 1)
        controller.refresh()
        _ = pump(for: 0.25) { applied.last?.1.hidden.isEmpty == true }
        check(applied.last?.1.hidden.isEmpty == true, "Targets did not reveal after separate Space changes")
        pointer = NSPoint(x: physical.midX, y: physical.midY)
        interacting = true
        secondaryInteracting = true
        controller.refresh()
        let beforeLateEvent = applied.count
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        _ = pump(for: 0.1) { applied.count > beforeLateEvent }
        check(applied.last?.1.hidden.isEmpty == true, "Late event reset known unchanged Space identities")

        // Without private Space identity, a global event cannot identify which
        // display changed. Reset only unknown displays; preserve known peers.
        windows.activeSpaceIDs.removeValue(forKey: secondaryID)
        controller.refresh(force: true)
        check(applied.last?.1.hidden.isEmpty == true, "Missing metadata reset a reveal without a Space event")
        let beforeUnknownSpace = applied.count
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        _ = pump(for: 0.1) { applied.count > beforeUnknownSpace }
        check(applied.last?.1.hidden == [secondaryID], "Unknown Space fallback affected a known unchanged display")
        windows.activeSpaceIDs.removeValue(forKey: id)
        let beforeUnsupportedSpace = applied.count
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        _ = pump(for: 0.1) { applied.count > beforeUnsupportedSpace }
        check(applied.last?.1.hidden == [id, secondaryID], "Unavailable Space API retained an old fullscreen reveal")

        secondaryTarget = false
        interacting = false
        secondaryInteracting = false
        windows.fullscreen = [id]
        pointer = NSPoint(x: physical.midX, y: physical.midY)
        targetFrame = screen.visibleFrame

        activeTarget = false
        controller.refresh()
        check(applied.last?.1.hidden.isEmpty == true && applied.last?.1.fullscreen.isEmpty == true, "Removed display retained visibility state")
        activeTarget = true
        controller.refresh()
        check(applied.last?.1.hidden == [id], "Reconnected target did not use current fullscreen state")

        // Enable the ordinary desktop option while fullscreen is already
        // revealed. This must retain that display's active interaction.
        pointer = NSPoint(x: physical.midX, y: physical.minY + 1)
        controller.refresh()
        _ = pump(for: 0.26) { applied.last?.1.hidden.isEmpty == true }
        interacting = true
        pointer = NSPoint(x: physical.midX, y: physical.midY)
        autoHideDock = true
        controller.refresh(force: true)
        check(applied.last?.1.hidden.isEmpty == true && applied.last?.1.fullscreen == [id],
              "Turning on ordinary auto-hide interrupted an open fullscreen interaction")
        autoHideDock = false
        controller.refresh(force: true)
        check(applied.last?.1.hidden.isEmpty == true, "Turning off ordinary auto-hide interrupted fullscreen")
        interacting = false
        windows.fullscreen = []
        controller.refresh(force: true)
        check(applied.last?.1.hidden.isEmpty == true, "Returning to ordinary desktop with both settings off")
        autoHideDock = true
        targetFrame = CGRect(x: physical.minX, y: physical.minY + 80, width: physical.width, height: physical.height - 80)
        controller.refresh(force: true)
        check(applied.last?.1.hidden == [id] && applied.last?.1.fullscreen.isEmpty == true, "Ordinary desktop did not hide")
        pointer = NSPoint(x: physical.midX, y: physical.minY + 1)
        controller.refresh(force: true)
        check(applied.last?.1.hidden == [id], "A hidden Dock needs a deliberate edge dwell")
        _ = pump(for: 0.34) { applied.last?.1.hidden.isEmpty == true }
        check(applied.last?.1.hidden.isEmpty == true, "Physical bottom edge failed with reserved system Dock space")
        pointer = NSPoint(x: physical.midX, y: physical.midY)
        interacting = true
        _ = pump(.eventTracking, for: 0.34)
        check(applied.last?.1.hidden.isEmpty == true, "Tracking a desktop menu/resize lost the Dock")
        interacting = false
        _ = pump(for: 0.45) { applied.last?.1.hidden == [id] }
        check(applied.last?.1.hidden == [id], "Desktop did not hide after interaction ended")
        autoHideDock = false
        controller.refresh(force: true)
        check(applied.last?.1.hidden.isEmpty == true, "Turning desktop auto-hide off did not show the ordinary Dock")

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
