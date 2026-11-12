import AppKit
import ApplicationServices
import DualDockCore
import Darwin

/// Shared only between the main actor and the serial recovery queue.
final class ActivationRecoveryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Resolves an application click at the time of the click, without persisting PIDs.
@MainActor
final class ApplicationActivationService {
    struct Process: Equatable, Sendable {
        let pid: pid_t
        let bundleIdentifier: String?
        let bundlePath: String?
        let launchDate: Date?
        let regular: Bool
        let active: Bool
        let terminated: Bool
    }

    enum WindowRestoreResult: Sendable { case raised, noWindow, unavailable }
    typealias OpenCompletion = @MainActor (Process?, String?) -> Void
    struct WindowCandidate: Sendable {
        let token: Int
        let minimized: Bool
    }

    struct Environment {
        var processes: () -> [Process]
        var windowOrder: () -> [pid_t]
        var activate: (Process) -> Bool
        var restoreWindow: (Process) -> WindowRestoreResult
        var fileExists: (URL) -> Bool
        var openApplication: (URL, @escaping OpenCompletion) -> Void
        var recoverAfterOpen: @Sendable (Process, ActivationRecoveryCancellation) -> Void = { _, _ in }

        static var system: Environment {
            Environment(
                processes: { NSWorkspace.shared.runningApplications.map(Self.snapshot) },
                windowOrder: {
                    let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                         kCGNullWindowID) as? [[String: Any]] ?? []
                    return rows.compactMap { row in
                        guard row[kCGWindowLayer as String] as? Int == 0,
                              let pid = row[kCGWindowOwnerPID as String] as? Int else { return nil }
                        return pid_t(pid)
                    }
                },
                activate: { process in
                    guard let app = Self.liveApplication(matching: process) else { return false }
                    app.unhide()
                    return app.activate(options: [.activateAllWindows])
                },
                restoreWindow: { Self.restoreWindow(of: $0) },
                fileExists: { FileManager.default.fileExists(atPath: $0.path) },
                openApplication: { url, completion in
                    let options = NSWorkspace.OpenConfiguration()
                    options.activates = true
                    NSWorkspace.shared.openApplication(at: url, configuration: options) { app, error in
                        Task { @MainActor in completion(app.map(Self.snapshot), error?.localizedDescription) }
                    }
                }, recoverAfterOpen: { process, cancellation in
                    Self.recoverAfterOpen(process, cancellation: cancellation)
                })
        }

        private static func snapshot(_ app: NSRunningApplication) -> Process {
            Process(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier,
                    bundlePath: app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path,
                    launchDate: app.launchDate, regular: app.activationPolicy == .regular,
                    active: app.isActive, terminated: app.isTerminated)
        }

        private static func liveApplication(matching expected: Process) -> NSRunningApplication? {
            guard let app = NSRunningApplication(processIdentifier: expected.pid), !app.isTerminated else { return nil }
            let live = snapshot(app)
            guard live.bundleIdentifier == expected.bundleIdentifier, live.bundlePath == expected.bundlePath,
                  live.launchDate == expected.launchDate, live.regular == expected.regular else { return nil }
            return app
        }

        /// Native reopen remains authoritative. Only recover a known focused/main
        /// window if it still has no visible content window after that request.
        /// All AX IPC runs off the main actor, and never changes a window frame or
        /// its fullscreen attribute.
        private static func recoverAfterOpen(_ process: Process, cancellation: ActivationRecoveryCancellation) {
            let deadline = ProcessInfo.processInfo.systemUptime + 0.3
            func allowed() -> Bool {
                !cancellation.isCancelled && ProcessInfo.processInfo.systemUptime < deadline
                    && liveApplication(matching: process)?.isActive == true
            }
            guard allowed(), AXIsProcessTrusted() else { return }
            guard let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return }
            if ApplicationActivationService.hasVisibleContentWindow(processID: process.pid, windows: visible) { return }
            let application = AXUIElementCreateApplication(process.pid)
            func read(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
                guard allowed() else { return nil }
                AXUIElementSetMessagingTimeout(element, Float(min(0.03, max(0.001, deadline - ProcessInfo.processInfo.systemUptime))))
                var value: CFTypeRef?
                return AXUIElementCopyAttributeValue(element, attribute, &value) == .success ? value : nil
            }
            func element(_ value: CFTypeRef?) -> AXUIElement? {
                guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
                return (value as! AXUIElement)
            }
            // AXWindows may be empty for a fullscreen window in another Space.
            // The fresh explicit references can still identify that exact window.
            let focused = element(read(application, kAXFocusedWindowAttribute as CFString))
            guard let window = focused ?? element(read(application, kAXMainWindowAttribute as CFString)) else { return }
            var pid: pid_t = 0
            guard AXUIElementGetPid(window, &pid) == .success, pid == process.pid,
                  read(window, kAXRoleAttribute as CFString) as? String == kAXWindowRole as String,
                  read(window, kAXSubroleAttribute as CFString) as? String == kAXStandardWindowSubrole as String,
                  let minimized = read(window, kAXMinimizedAttribute as CFString) as? Bool,
                  let id = ActivationWindowIdentity.windowID(window), allowed() else { return }
            func ownedWindow() -> [String: Any]? {
                guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] else { return nil }
                return rows.first {
                    ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id
                        && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == process.pid
                }
            }
            guard let source = ownedWindow(), allowed() else { return }
            if !minimized, (source[kCGWindowIsOnscreen as String] as? Bool) == true { return }
            // A new focus choice must win over this asynchronous recovery.
            let currentFocused = element(read(application, kAXFocusedWindowAttribute as CFString))
            if let currentFocused, !CFEqual(currentFocused, window) { return }
            if currentFocused == nil {
                guard let currentMain = element(read(application, kAXMainWindowAttribute as CFString)),
                      CFEqual(currentMain, window) else { return }
            }
            guard ownedWindow() != nil, allowed() else { return }
            AXUIElementSetMessagingTimeout(window, Float(min(0.03, max(0.001, deadline - ProcessInfo.processInfo.systemUptime))))
            if minimized {
                guard AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else { return }
            }
            guard allowed() else { return }
            AXUIElementSetMessagingTimeout(application, Float(min(0.03, max(0.001, deadline - ProcessInfo.processInfo.systemUptime))))
            _ = AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, window)
            guard allowed() else { return }
            guard ownedWindow() != nil, allowed() else { return }
            AXUIElementSetMessagingTimeout(window, Float(min(0.03, max(0.001, deadline - ProcessInfo.processInfo.systemUptime))))
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }

        private static func restoreWindow(of process: Process) -> WindowRestoreResult {
            guard AXIsProcessTrusted(), liveApplication(matching: process) != nil else { return .unavailable }
            // A click may target an unresponsive helper. Bound AX work, and never
            // use another process/window when this process cannot respond.
            let deadline = ProcessInfo.processInfo.systemUptime + 0.3
            let application = AXUIElementCreateApplication(process.pid)
            AXUIElementSetMessagingTimeout(application, 0.04)
            func read(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                var value: CFTypeRef?
                return AXUIElementCopyAttributeValue(element, attribute, &value) == .success ? value : nil
            }
            guard let windows = read(application, kAXWindowsAttribute as CFString) as? [AXUIElement] else { return .unavailable }
            if windows.isEmpty { return .noWindow }
            func element(_ value: CFTypeRef?) -> AXUIElement? {
                guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
                return (value as! AXUIElement)
            }
            let focused = element(read(application, kAXFocusedWindowAttribute as CFString))
            let main = element(read(application, kAXMainWindowAttribute as CFString))
            func token(_ value: AXUIElement?) -> Int? {
                value.flatMap { value in windows.firstIndex { CFEqual($0, value) } }
            }
            if focused != nil && token(focused) == nil { return .unavailable }
            if focused == nil && main != nil && token(main) == nil { return .unavailable }
            var candidates: [WindowCandidate] = []
            for (index, window) in windows.enumerated() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                var pid: pid_t = 0
                guard AXUIElementGetPid(window, &pid) == .success, pid == process.pid else { continue }
                AXUIElementSetMessagingTimeout(window, 0.04)
                guard read(window, kAXRoleAttribute as CFString) as? String == kAXWindowRole as String,
                      read(window, kAXSubroleAttribute as CFString) as? String == kAXStandardWindowSubrole as String,
                      let minimized = read(window, kAXMinimizedAttribute as CFString) as? Bool else { continue }
                candidates.append(WindowCandidate(token: index, minimized: minimized))
            }
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  let selected = ApplicationActivationService.windowTarget(
                    candidates: candidates, focused: token(focused), main: token(main)),
                  liveApplication(matching: process) != nil else { return .unavailable }
            let window = windows[selected]
            if candidates.first(where: { $0.token == selected })?.minimized == true {
                guard AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else {
                    return .unavailable
                }
            }
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  liveApplication(matching: process) != nil else { return .unavailable }
            _ = AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, window)
            guard ProcessInfo.processInfo.systemUptime < deadline else { return .unavailable }
            return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success ? .raised : .unavailable
        }
    }

    private let environment: Environment
    private let recoveryQueue = DispatchQueue(label: "local.ronny.DualDock.activation-recovery", qos: .userInitiated)
    private var generation: UInt64 = 0
    private var pendingRecovery: ActivationRecoveryCancellation?
    init(environment: Environment = .system) { self.environment = environment }
    deinit { pendingRecovery?.cancel() }

    func cancelPendingRecovery() {
        generation &+= 1
        pendingRecovery?.cancel()
        pendingRecovery = nil
    }

    func open(_ app: AppReference, at url: URL, onFailure: @escaping (String) -> Void) {
        cancelPendingRecovery()
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        // Ordinary apps need their native reopen event, including when every
        // window is minimized or Accessibility data is unavailable. Only an
        // embedded helper requires process-specific activation instead.
        guard Self.isEmbedded(canonicalURL) else {
            openBundle(app, at: url, onFailure: onFailure)
            return
        }
        let expectedPath = canonicalURL.path
        let matches = environment.processes().filter {
            !$0.terminated && $0.bundlePath == expectedPath
                && ($0.bundleIdentifier == app.id || app.id == app.path)
        }
        let regular = matches.filter(\.regular)
        if !regular.isEmpty {
            guard let process = Self.processTarget(candidates: regular, windowOrder: environment.windowOrder()) else {
                onFailure("\(app.name) 有多个运行实例，暂时无法准确确定目标窗口。请从窗口预览中选择。")
                return
            }
            let activated = environment.activate(process)
            let restored = environment.restoreWindow(process)
            if !activated && restored != .raised {
                onFailure("无法切换到 \(app.name) 的现有窗口，请稍后重试。")
            }
            return
        }
        onFailure("\(app.name) 没有可切换的运行窗口，请先从所属应用中打开。")
    }

    nonisolated static func processTarget(candidates: [Process], windowOrder: [pid_t]) -> Process? {
        guard !candidates.isEmpty else { return nil }
        let active = candidates.filter(\.active)
        if active.count == 1 { return active[0] }
        if candidates.count == 1 { return candidates[0] }
        for pid in windowOrder {
            if let candidate = candidates.first(where: { $0.pid == pid }) { return candidate }
        }
        return nil
    }

    nonisolated static func windowTarget(candidates: [WindowCandidate], focused: Int?, main: Int?) -> Int? {
        if let focused { return candidates.contains(where: { $0.token == focused }) ? focused : nil }
        if let main { return candidates.contains(where: { $0.token == main }) ? main : nil }
        let visible = candidates.filter { !$0.minimized }
        if visible.count == 1 { return visible[0].token }
        return candidates.count == 1 ? candidates[0].token : nil
    }

    /// Input is a fresh onscreen WindowServer snapshot. Tiny Electron titlebar
    /// helper surfaces are not evidence that the editor window is already shown.
    nonisolated static func hasVisibleContentWindow(processID: pid_t, windows: [[String: Any]]) -> Bool {
        windows.contains { row in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (row[kCGWindowIsOnscreen as String] as? Bool) != false,
                  ((row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.05,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  !frame.isNull, !frame.isInfinite, frame.minX.isFinite, frame.minY.isFinite,
                  frame.width.isFinite, frame.height.isFinite else { return false }
            return frame.width >= 80 && frame.height >= 80
        }
    }

    nonisolated private static func isEmbedded(_ url: URL) -> Bool {
        url.deletingLastPathComponent().pathComponents.contains { $0.lowercased().hasSuffix(".app") }
    }

    private func openBundle(_ app: AppReference, at url: URL, onFailure: @escaping (String) -> Void) {
        guard environment.fileExists(url) else {
            onFailure("找不到 \(app.name)，请重新添加该应用。")
            return
        }
        let request = generation
        let expectedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        environment.openApplication(url) { [weak self] process, error in
            if let error { onFailure("无法打开 \(app.name)：\(error)") }
            guard error == nil, let self, self.generation == request,
                  let process, process.regular, !process.terminated,
                  process.bundlePath == expectedPath,
                  process.bundleIdentifier == app.id || app.id == app.path else { return }
            let cancellation = ActivationRecoveryCancellation()
            self.pendingRecovery = cancellation
            let recover = self.environment.recoverAfterOpen
            // Completion reports launch status, not completed activation. Give
            // the main run loop a turn; recovery checks the live isActive value
            // after this bounded grace period rather than this stale snapshot.
            self.recoveryQueue.asyncAfter(deadline: .now() + .milliseconds(100)) {
                guard !cancellation.isCancelled else { return }
                autoreleasepool { recover(process, cancellation) }
            }
        }
    }
}

private enum ActivationWindowIdentity {
    typealias Function = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    static let function: Function? = {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()
    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        guard let function else { return nil }
        var id: CGWindowID = 0
        return function(element, &id) == .success && id != 0 ? id : nil
    }
}
