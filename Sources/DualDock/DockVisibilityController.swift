import AppKit
import DualDockCore

/// Coordinates visibility only; window placement and popup ownership stay with
/// DisplayCoordinator. The 100ms common-mode timer never performs AX queries.
@MainActor
final class DockVisibilityController {
    struct Snapshot: Equatable {
        let hidden: Set<CGDirectDisplayID>
        let fullscreen: Set<CGDirectDisplayID>
    }

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
    private let autoHideWhenMaximized: () -> Bool
    private let autoHideDock: () -> Bool
    private let apply: (Snapshot) -> Void
    private let pointer: () -> NSPoint
    private let obstruction = WindowObstructionService()
    private var states: [CGDirectDisplayID: DockVisibilityPolicy] = [:]
    private var knownSpaceIDs: [CGDirectDisplayID: UInt64] = [:]
    private var lastSnapshot = Snapshot(hidden: [], fullscreen: [])
    private var previousMaximizeSetting: Bool?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var stopped = false

    init(windows: WindowService, targets: @escaping () -> [Target],
         autoHideWhenMaximized: @escaping () -> Bool, autoHideDock: @escaping () -> Bool,
         pointer: @escaping () -> NSPoint = { NSEvent.mouseLocation },
         apply: @escaping (Snapshot) -> Void) {
        self.windows = windows
        self.targets = targets
        self.autoHideWhenMaximized = autoHideWhenMaximized
        self.autoHideDock = autoHideDock
        self.apply = apply
        self.pointer = pointer
        windows.onFullscreenStateChange = { [weak self] in self?.refresh() }
        obstruction.onUpdate = { [weak self] in self?.refresh() }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.invalidate(resetReveal: name == NSWorkspace.activeSpaceDidChangeNotification) }
            })
        }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func invalidate(resetReveal: Bool = false) {
        guard !stopped else { return }
        windows.invalidateFullscreenState()
        obstruction.invalidate()
        refresh(force: true, resetUnknownSpaces: resetReveal)
    }

    func refresh(force: Bool = false, resetUnknownSpaces: Bool = false) {
        guard !stopped else { return }
        let all = targets()
        let valid = Set(all.map(\.id))
        states = states.filter { valid.contains($0.key) }
        let fullscreen = windows.fullscreenDisplayIDs(screens: all.map(\.screen)).intersection(valid)
        // The native fullscreen read also supplies Space identities, so this
        // adds no WindowServer query. Detect changes on polls as well as events:
        // a poll may see the new Space before its workspace notification arrives.
        let currentSpaceIDs = windows.activeSpaceIDs.filter { valid.contains($0.key) }
        knownSpaceIDs = knownSpaceIDs.filter { valid.contains($0.key) }
        for id in valid {
            if let previous = knownSpaceIDs[id], let current = currentSpaceIDs[id] {
                if previous != current { states[id] = DockVisibilityPolicy(initiallyVisible: false) }
            } else if resetUnknownSpaces {
                // AX fallback has no Space identity. On a global Space event,
                // conservatively hide only unknown displays; known peers keep
                // their revealed Dock, menu, group, preview or drag interaction.
                states[id] = DockVisibilityPolicy(initiallyVisible: false)
            }
        }
        // Preserve the last known identity through a transient failed read so
        // a later successful read can still detect a fullscreen-to-fullscreen move.
        knownSpaceIDs.merge(currentSpaceIDs) { _, current in current }
        let alwaysHide = autoHideDock()
        let hideMaximized = autoHideWhenMaximized()
        if previousMaximizeSetting != hideMaximized {
            obstruction.invalidate(clear: true)
            previousMaximizeSetting = hideMaximized
        }
        // A forced apply is also used by live resizing; it must not turn every
        // pointer sample into a WindowServer query. invalidate() resets the read
        // deadline for actual Space, activation and display changes.
        if hideMaximized { obstruction.refresh() }
        let pointer = pointer()
        let now = ProcessInfo.processInfo.systemUptime
        var next: Set<CGDirectDisplayID> = []
        for target in all {
            var state = states[target.id] ?? DockVisibilityPolicy(initiallyVisible: target.pointerInside || target.interacting)
            let isFullscreen = fullscreen.contains(target.id)
            let physical = Self.fullscreenBounds(for: target.screen)
            let activationBounds = isFullscreen ? physical : target.visibleFrame
            let edge = DockVisibilityPolicy.activationRegion(backdrop: target.backdrop, edge: target.edge,
                                                              visibleScreen: activationBounds)
            // A visible system Dock may reserve part of the desktop. In ordinary
            // auto-hide mode accept the physical edge as well as the workspace edge.
            // The top hotspot stays under the menu bar and camera safe area.
            let physicalEdge = alwaysHide && !isFullscreen && target.edge != .top && physical != activationBounds &&
                DockVisibilityPolicy.activationRegion(backdrop: target.backdrop, edge: target.edge,
                                                     visibleScreen: physical).contains(pointer)
            let visible = state.update(now: now, fullscreen: isFullscreen, autoHide: hideMaximized,
                maximized: hideMaximized && !alwaysHide && obstruction.frames.contains {
                    DockVisibilityPolicy.isMaximizedWindow($0, in: target.visibleFrame)
                }, autoHideDock: alwaysHide, pointerAtEdge: edge.contains(pointer) || physicalEdge,
                pointerInsideDock: target.pointerInside, interacting: target.interacting)
            states[target.id] = state
            if !visible { next.insert(target.id) }
        }
        let snapshot = Snapshot(hidden: next, fullscreen: fullscreen)
        if force || snapshot != lastSnapshot {
            lastSnapshot = snapshot
            apply(snapshot)
        }
    }

    /// Fullscreen edge activation belongs to the physical display, not the
    /// normal desktop's Dock/menu-bar reservation. Respect the camera safe area.
    static func fullscreenBounds(for screen: NSScreen) -> CGRect {
        let frame = screen.frame
        let safe = screen.safeAreaInsets
        return CGRect(x: frame.minX + max(0, safe.left), y: frame.minY + max(0, safe.bottom),
                      width: max(1, frame.width - max(0, safe.left) - max(0, safe.right)),
                      height: max(1, frame.height - max(0, safe.top) - max(0, safe.bottom)))
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
        knownSpaceIDs.removeAll()
    }
}
