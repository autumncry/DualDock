import AppKit
import DualDockCore

/// Coordinates visibility only; window placement and popup ownership stay with
/// DisplayCoordinator. The 100ms common-mode timer never performs AX queries.
@MainActor
final class DockVisibilityController {
    struct Target {
        let id: CGDirectDisplayID
        let screen: NSScreen
        let visibleFrame: CGRect
        let edge: DockEdge
        let backdrop: CGRect
        let pointerInside: Bool
        let interacting: Bool
    }

    private let windows: WindowService
    private let targets: () -> [Target]
    private let autoHide: () -> Bool
    private let apply: (Set<CGDirectDisplayID>) -> Void
    private let obstruction = WindowObstructionService()
    private var states: [CGDirectDisplayID: DockVisibilityPolicy] = [:]
    private var hidden: Set<CGDirectDisplayID> = []
    private var previousAutoHide: Bool?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var stopped = false

    init(windows: WindowService, targets: @escaping () -> [Target], autoHide: @escaping () -> Bool,
         apply: @escaping (Set<CGDirectDisplayID>) -> Void) {
        self.windows = windows
        self.targets = targets
        self.autoHide = autoHide
        self.apply = apply
        windows.onFullscreenStateChange = { [weak self] in self?.refresh() }
        obstruction.onUpdate = { [weak self] in self?.refresh() }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.invalidate() }
            })
        }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func invalidate() {
        guard !stopped else { return }
        windows.invalidateFullscreenState()
        obstruction.invalidate()
        refresh(force: true)
    }

    func refresh(force: Bool = false) {
        guard !stopped else { return }
        let all = targets()
        let valid = Set(all.map(\.id))
        states = states.filter { valid.contains($0.key) }
        let fullscreen = windows.fullscreenDisplayIDs(screens: all.map(\.screen))
        let enabled = autoHide()
        if previousAutoHide != enabled {
            obstruction.invalidate(clear: true)
            states.removeAll()
            previousAutoHide = enabled
        }
        // A forced apply is also used by live resizing; it must not turn every
        // pointer sample into a WindowServer query. invalidate() resets the read
        // deadline for actual Space, activation and display changes.
        if enabled { obstruction.refresh() }
        let pointer = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        var next: Set<CGDirectDisplayID> = []
        for target in all {
            var state = states[target.id] ?? DockVisibilityPolicy()
            let edge = DockVisibilityPolicy.activationRegion(backdrop: target.backdrop, edge: target.edge,
                                                              visibleScreen: target.visibleFrame)
            let visible = state.update(now: now, fullscreen: fullscreen.contains(target.id), autoHide: enabled,
                maximized: enabled && obstruction.frames.contains {
                    DockVisibilityPolicy.isMaximizedWindow($0, in: target.visibleFrame)
                },
                pointerAtEdge: edge.contains(pointer), pointerInsideDock: target.pointerInside,
                interacting: target.interacting)
            states[target.id] = state
            if !visible { next.insert(target.id) }
        }
        if force || next != hidden {
            hidden = next
            apply(next)
        }
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        windows.onFullscreenStateChange = nil
        windows.stopFullscreenMonitoring()
        obstruction.stop()
        states.removeAll()
    }
}
