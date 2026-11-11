import AppKit
import ApplicationServices
import DualDockCore

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
        var openApplication: (URL, @escaping (String?) -> Void) -> Void

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
                    NSWorkspace.shared.openApplication(at: url, configuration: options) { _, error in
                        Task { @MainActor in completion(error?.localizedDescription) }
                    }
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
    init(environment: Environment = .system) { self.environment = environment }

    func open(_ app: AppReference, at url: URL, onFailure: @escaping (String) -> Void) {
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

    nonisolated private static func isEmbedded(_ url: URL) -> Bool {
        url.deletingLastPathComponent().pathComponents.contains { $0.lowercased().hasSuffix(".app") }
    }

    private func openBundle(_ app: AppReference, at url: URL, onFailure: @escaping (String) -> Void) {
        guard environment.fileExists(url) else {
            onFailure("找不到 \(app.name)，请重新添加该应用。")
            return
        }
        environment.openApplication(url) { error in
            if let error { onFailure("无法打开 \(app.name)：\(error)") }
        }
    }
}
