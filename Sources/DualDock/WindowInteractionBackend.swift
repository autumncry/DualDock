import AppKit
import ApplicationServices
import DualDockCore

/// Shared serial dispatch boundary for native reads; the operation is injected
/// so cancellation can be checked without enumerating or changing real windows.
enum WindowInteractionReadQueue {
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    static func read(on queue: DispatchQueue,
                     while isCurrent: @escaping @Sendable () -> Bool = { true },
                     operation: @escaping @Sendable (@escaping @Sendable () -> Bool) -> DockWindowInventory) async -> DockWindowInventory {
        let cancellation = Cancellation()
        let allowed: @Sendable () -> Bool = { !cancellation.isCancelled && isCurrent() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    guard allowed() else { continuation.resume(returning: .unavailable); return }
                    let result = operation(allowed)
                    continuation.resume(returning: allowed() ? result : .unavailable)
                }
            }
        } onCancel: {
            // Cancel only this read. The action epoch belongs to explicit
            // selection/stop events, never to a dismissed context menu.
            cancellation.cancel()
        }
    }
}

/// A native minimize/restore request and its observed state are separate facts.
/// The injected boundary keeps animation and messaging outcomes testable without
/// operating on another application's windows.
enum WindowMinimizedTransition {
    static func perform(press: (() -> AXError)? = nil, canSet: () -> AXError = { .success }, set: () -> AXError,
                        validate: () -> DockWindowActionOutcome?,
                        confirm: () -> DockWindowActionOutcome) -> DockWindowActionOutcome {
        if let stopped = validate() { return stopped }
        if let press {
            let result = press()
            // AXPress may time out while the app is still running its native
            // animation. A second mutation cannot establish whether it failed.
            if result == .success || result == .cannotComplete { return confirm() }
            guard result == .actionUnsupported || result == .notImplemented else { return rejection(result) }
        }
        if let stopped = validate() { return stopped }
        let capability = canSet()
        guard capability == .success else { return rejection(capability) }
        if let stopped = validate() { return stopped }
        let result = set()
        if result == .success || result == .cannotComplete { return confirm() }
        return rejection(result)
    }

    private static func rejection(_ error: AXError) -> DockWindowActionOutcome {
        switch error {
        case .invalidUIElement: return .missing
        case .actionUnsupported, .attributeUnsupported, .notImplemented: return .unsupported
        default: return .failed
        }
    }

    static func confirm(_ minimized: Bool, deadline: TimeInterval,
                        isCurrent: () -> Bool, exists: () -> Bool, read: () -> Bool?,
                        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                        pause: () -> Void = { Thread.sleep(forTimeInterval: 0.025) }) -> DockWindowActionOutcome {
        while now() < deadline {
            guard isCurrent() else { return .superseded }
            guard exists() else { return .missing }
            let state = read()
            guard isCurrent() else { return .superseded }
            guard exists() else { return .missing }
            if state == minimized { return .performed }
            pause()
        }
        return isCurrent() ? .failed : .superseded
    }
}

/// All Accessibility IPC is confined to one worker. Menu construction and Dock
/// pointer animation remain on the main actor without waiting synchronously.
@MainActor
final class WindowInteractionBackend {
    private final class ActionEpoch: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0
        func current() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
        func invalidate() { lock.lock(); value &+= 1; lock.unlock() }
    }
    private struct ProcessSnapshot: Sendable {
        let pid: pid_t
        let path: String
        let launchDate: Date
        let active: Bool
    }
    private struct Display: Sendable {
        let frame: CGRect
        let workarea: CGRect
    }
    private let queue = DispatchQueue(label: "local.ronny.DualDock.window-interaction", qos: .userInitiated)
    private let actionEpoch = ActionEpoch()

    func cancel() { actionEpoch.invalidate() }

    func read(for app: AppReference) async -> DockWindowInventory {
        guard !Task.isCancelled else { return .unavailable }
        let path = Self.canonical(app.path)
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let browserIcon = WeChatBrowserWindowRouter.hostURL(for: app) != nil
        let processes = NSWorkspace.shared.runningApplications.compactMap { running -> ProcessSnapshot? in
            guard !running.isTerminated, let url = running.bundleURL, let date = running.launchDate else { return nil }
            if browserIcon {
                guard running.activationPolicy == .regular, running.bundleIdentifier == app.id,
                      Self.canonical(url.path) == path else { return nil }
            } else if running.bundleIdentifier != app.id && Self.canonical(url.path) != path {
                return nil
            }
            return .init(pid: running.processIdentifier, path: Self.canonical(url.path), launchDate: date,
                         active: running.isActive && running.processIdentifier == frontPID)
        }
        guard !processes.isEmpty else { return .available([]) }
        guard AXIsProcessTrusted() else { return .permissionDenied }
        let displays = Self.displays()
        let epoch = actionEpoch
        let request = epoch.current()
        return await WindowInteractionReadQueue.read(on: queue, while: { epoch.current() == request }) { allowed in
            Self.discover(processes: processes, displays: displays, allowed: allowed)
        }
    }

    func perform(_ item: DockWindowItem, action: DockWindowAction, for app: AppReference) async -> DockWindowActionOutcome {
        guard AXIsProcessTrusted(), Self.liveApplication(item.id, expected: app) != nil else { return .missing }
        let displays = Self.displays()
        let epoch = actionEpoch
        let request = epoch.current()
        let allowed: @Sendable () -> Bool = {
            epoch.current() == request && (item.foregroundProxy.map { WeChatBrowserWindowRouter.isCurrentProxy($0, host: app) } ?? true)
        }
        let result: DockWindowActionOutcome = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Self.apply(item, action: action, expected: app, displays: displays, allowed: allowed)) }
        }
        if action == .minimize || result == .superseded { return result }
        // A stale AX object cannot identify a replacement document. The
        // WindowServer identity may still be valid even when AX has lost it.
        guard result == .performed || (action == .activate && result == .missing) else { return result }
        let visible = await recover(item.id, for: app, nativeTargetConfirmed: result == .performed, proxy:item.foregroundProxy, isCurrent:allowed)
        guard allowed(), !Task.isCancelled else { return .superseded }
        if visible { return .performed }
        guard result != .missing, Self.liveApplication(item.id, expected: app) != nil,
              VerifiedWindowActivation.sourceRow(windowID: item.id.windowID, pid: item.id.pid) != nil
        else { return .missing }
        return .failed
    }

    func recover(_ id: DockWindowIdentity, for app: AppReference) async -> Bool {
        let epoch = actionEpoch
        let request = epoch.current()
        return await recover(id, for: app, nativeTargetConfirmed: false, isCurrent: { epoch.current() == request })
    }

    private func recover(_ id: DockWindowIdentity, for app: AppReference, nativeTargetConfirmed: Bool,
                         proxy: WeChatBrowserWindowRouter.Instance? = nil, isCurrent: @escaping @Sendable () -> Bool) async -> Bool {
        await VerifiedWindowActivation.raise(windowID: id.windowID, pid: id.pid, launchDate: id.processLaunchDate,
            applicationPath: id.applicationPath, expectedApp: app, reopenOrderedOut: false,
            nativeTargetConfirmed: nativeTargetConfirmed, stableFor: proxy == nil ? 0 : 0.22,
            proxyFront: { proxy.map { WeChatBrowserWindowRouter.frontProxy($0,host:app) } ?? false }, isCurrent:isCurrent)
    }

    nonisolated private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func displays() -> [Display] {
        let screens = NSScreen.screens
        let top = screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID() })?.frame.maxY ?? 0
        func flip(_ frame: CGRect) -> CGRect {
            CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
        }
        return screens.map { .init(frame: flip($0.frame), workarea: flip($0.visibleFrame)) }
    }

    nonisolated private static func liveApplication(_ identity: DockWindowIdentity, expected: AppReference?) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: identity.pid), !app.isTerminated,
              app.launchDate == identity.processLaunchDate, let path = app.bundleURL?.path,
              canonical(path) == identity.applicationPath else { return nil }
        if let expected, app.bundleIdentifier != expected.id && canonical(expected.path) != identity.applicationPath { return nil }
        return app
    }

    private final class Reader {
        let deadline: TimeInterval
        let allowed: () -> Bool
        private(set) var hasReadFailure = false
        init(timeout: TimeInterval = 0.8, allowed: @escaping () -> Bool = { true }) {
            deadline = ProcessInfo.processInfo.systemUptime + timeout
            self.allowed = allowed
        }
        var expired: Bool { !allowed() || ProcessInfo.processInfo.systemUptime >= deadline }
        func prepare(_ element: AXUIElement) -> Bool {
            guard !expired else { return false }
            AXUIElementSetMessagingTimeout(element, Float(min(0.04, max(0.001, deadline - ProcessInfo.processInfo.systemUptime))))
            return true
        }
        func windowID(_ element: AXUIElement) -> CGWindowID? {
            guard prepare(element) else { return nil }
            return ActivationWindowIdentity.windowID(element)
        }
        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            guard prepare(element) else { hasReadFailure = true; return nil }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if error == .success { return value }
            // An unsupported optional attribute is normal. A timeout or other
            // failed IPC cannot establish that a previously selected window closed.
            if error != .attributeUnsupported && error != .noValue { hasReadFailure = true }
            return nil
        }
        func element(_ object: AXUIElement, _ attribute: String) -> AXUIElement? {
            guard let value = value(object, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        func frame(_ element: AXUIElement) -> CGRect? {
            guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute),
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
                  point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite else { return nil }
            return CGRect(origin: point, size: dimensions)
        }
        func windows(_ application: AXUIElement) -> [AXUIElement] {
            var result = value(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
            for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
                if let candidate = element(application, attribute), !result.contains(where: { CFEqual($0, candidate) }) { result.append(candidate) }
            }
            return result
        }
    }

    nonisolated private static func windowRows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    nonisolated private static func rowFrame(_ row: [String: Any]) -> CGRect? {
        (row[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
    }

    nonisolated private static func matchingID(_ window: AXUIElement, pid: pid_t, title: String?, frame: CGRect,
                                               rows: [[String: Any]]) -> CGWindowID? {
        if let exact = ActivationWindowIdentity.windowID(window) { return exact }
        guard let title, !title.isEmpty else { return nil }
        let matches = rows.filter { row in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  row[kCGWindowName as String] as? String == title, let candidate = rowFrame(row) else { return false }
            return abs(candidate.minX - frame.minX) <= 1 && abs(candidate.minY - frame.minY) <= 1
                && abs(candidate.width - frame.width) <= 1 && abs(candidate.height - frame.height) <= 1
        }
        return matches.count == 1 ? (matches[0][kCGWindowNumber as String] as? NSNumber)?.uint32Value : nil
    }

    /// AXStandardWindow includes some floating panels. WindowServer knows
    /// their actual layer; minimized and other-Space windows can lack a row.
    nonisolated static func eligibleContentWindow(id: CGWindowID, knownLayers: [CGWindowID: Int]) -> Bool {
        knownLayers[id].map { $0 == 0 } ?? true
    }

    nonisolated private static func discover(processes: [ProcessSnapshot], displays: [Display],
                                            allowed: @escaping @Sendable () -> Bool) -> DockWindowInventory {
        let reader = Reader(allowed: allowed)
        guard !reader.expired else { return .unavailable }
        let rows = windowRows()
        guard !reader.expired else { return .unavailable }
        var layers: [CGWindowID: Int] = [:]
        for row in rows {
            if let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
               let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue {
                layers[id] = layer
            }
        }
        let ordered = VerifiedWindowActivation.orderedOnscreenRows()
        var result: [DockWindowItem] = []
        for process in processes {
            let processIdentity = DockWindowIdentity(pid: process.pid, processLaunchDate: process.launchDate,
                                                     applicationPath: process.path, windowID: 0)
            guard liveApplication(processIdentity, expected: nil) != nil else { continue }
            let application = AXUIElementCreateApplication(process.pid)
            guard var windows = reader.value(application, kAXWindowsAttribute) as? [AXUIElement] else { return .unavailable }
            let focused = reader.element(application, kAXFocusedWindowAttribute)
            let main = reader.element(application, kAXMainWindowAttribute)
            for candidate in [focused, main].compactMap({ $0 }) where !windows.contains(where: { CFEqual($0, candidate) }) {
                windows.append(candidate)
            }
            var seen: Set<CGWindowID> = []
            for window in windows {
                guard !reader.expired else { return .unavailable }
                var pid: pid_t = 0
                guard AXUIElementGetPid(window, &pid) == .success else { return .unavailable }
                guard pid == process.pid else { continue }
                guard let role = reader.value(window, kAXRoleAttribute) as? String else { return .unavailable }
                guard role == kAXWindowRole else { continue }
                guard let subrole = reader.value(window, kAXSubroleAttribute) as? String else { return .unavailable }
                guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { continue }
                guard let frame = reader.frame(window) else { return .unavailable }
                guard frame.width >= 80, frame.height >= 50 else { continue }
                let rawTitle = reader.value(window, kAXTitleAttribute) as? String
                guard !reader.expired else { return .unavailable }
                guard let id = matchingID(window, pid: pid, title: rawTitle, frame: frame, rows: rows), id != 0 else { return .unavailable }
                guard eligibleContentWindow(id: id, knownLayers: layers), seen.insert(id).inserted else { continue }
                let minimized = reader.value(window, kAXMinimizedAttribute) as? Bool ?? false
                let fullscreen = reader.value(window, "AXFullScreen") as? Bool ?? false
                let isFocused = focused.map { CFEqual($0, window) } ?? false
                let identity = DockWindowIdentity(pid: pid, processLaunchDate: process.launchDate,
                                                  applicationPath: process.path, windowID: id)
                guard liveApplication(identity, expected: nil) != nil else { continue }
                let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(.init(id: identity, title: title?.isEmpty == false ? title! : L("未命名窗口", "Untitled Window"), frame: frame,
                    isMinimized: minimized, isFullscreen: fullscreen,
                    isMaximized: displays.contains { DockVisibilityPolicy.isMaximizedWindow(frame, in: $0.workarea)
                        || DockVisibilityPolicy.isMaximizedWindow(frame, in: $0.frame) },
                    isFrontmost: process.active && isFocused && !minimized
                        && VerifiedWindowActivation.isExposed(windowID: id, pid: process.pid, in: ordered),
                    isFocused: isFocused, isMain: main.map { CFEqual($0, window) } ?? false))
            }
        }
        guard !reader.expired, !reader.hasReadFailure else { return .unavailable }
        return .available(result.sorted {
            if $0.isFrontmost != $1.isFrontmost { return $0.isFrontmost }
            return $0.id.windowID < $1.id.windowID
        })
    }

    nonisolated private static func apply(_ item: DockWindowItem, action: DockWindowAction,
                                         expected: AppReference, displays: [Display],
                                         allowed: @escaping @Sendable () -> Bool) -> DockWindowActionOutcome {
        guard allowed() else { return .superseded }
        guard liveApplication(item.id, expected: expected) != nil else { return .missing }
        let reader = Reader(timeout: 1, allowed: allowed)
        let application = AXUIElementCreateApplication(item.id.pid)
        let windows = reader.windows(application)
        let identified = windows.map { ($0, reader.windowID($0)) }
        guard !reader.expired else { return .failed }
        let exact = identified.filter { $0.1 == item.id.windowID }.map(\.0)
        let target: AXUIElement?
        if exact.count == 1 { target = exact[0] }
        else if identified.allSatisfy({ $0.1 == nil }) {
            let rows = windowRows()
            let matches = windows.filter { window in
                guard let frame = reader.frame(window),
                      let title = reader.value(window, kAXTitleAttribute) as? String, title == item.title,
                      abs(frame.minX - item.frame.minX) <= 1, abs(frame.minY - item.frame.minY) <= 1,
                      abs(frame.width - item.frame.width) <= 1, abs(frame.height - item.frame.height) <= 1 else { return false }
                return matchingID(window, pid: item.id.pid, title: title,
                                  frame: frame, rows: rows) == item.id.windowID
            }
            target = matches.count == 1 ? matches[0] : nil
        } else { target = nil }
        guard let target, !reader.expired, liveApplication(item.id, expected: expected) != nil else { return .missing }
        var pid: pid_t = 0
        guard AXUIElementGetPid(target, &pid) == .success, pid == item.id.pid else { return .missing }
        let minimized = reader.value(target, kAXMinimizedAttribute) as? Bool
        let validate: () -> DockWindowActionOutcome? = {
            guard allowed() else { return .superseded }
            guard !reader.expired else { return .failed }
            guard liveApplication(item.id, expected: expected) != nil else { return .missing }
            return nil
        }
        if action == .minimize {
            // A user focus change or newly maximized window wins over a queued
            // click. Never minimize a different/newly focused document.
            let focused = reader.element(application, kAXFocusedWindowAttribute)
            let ownerFocused = reader.value(application, kAXFrontmostAttribute) as? Bool == true &&
                focused.map { CFEqual($0, target) } == true
            let proxyFocused = item.foregroundProxy.map {
                WeChatBrowserWindowRouter.frontProxy($0, host: expected) && focused.map { CFEqual($0, target) } != false
            } ?? false
            guard ownerFocused || proxyFocused,
                  VerifiedWindowActivation.isExposed(windowID: item.id.windowID, pid: item.id.pid,
                      in: VerifiedWindowActivation.orderedOnscreenRows()),
                  reader.value(target, "AXFullScreen") as? Bool != true,
                  let frame = reader.frame(target),
                  !displays.contains(where: { DockVisibilityPolicy.isMaximizedWindow(frame, in: $0.workarea)
                    || DockVisibilityPolicy.isMaximizedWindow(frame, in: $0.frame) }) else { return .superseded }
            if minimized == true { return .performed }
            var press: (() -> AXError)?
            if let button = reader.element(target, kAXMinimizeButtonAttribute), reader.value(button, kAXEnabledAttribute) as? Bool != false {
                press = { AXUIElementPerformAction(button, kAXPressAction as CFString) }
            }
            return WindowMinimizedTransition.perform(press: press, canSet: {
                var settable = DarwinBoolean(false)
                let status = AXUIElementIsAttributeSettable(target, kAXMinimizedAttribute as CFString, &settable)
                guard status == .success else { return status }
                return settable.boolValue ? .success : .attributeUnsupported
            }, set: {
                AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            }, validate: validate, confirm: {
                awaitState(true, window: target, identity: item.id, expected: expected, reader: reader)
            })
        }
        if minimized == true {
            let restored = WindowMinimizedTransition.perform(set: {
                AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }, validate: validate, confirm: {
                awaitState(false, window: target, identity: item.id, expected: expected, reader: reader)
            })
            guard restored == .performed else { return restored }
        }
        guard !reader.expired, liveApplication(item.id, expected: expected) != nil else { return .missing }
        _ = AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        guard allowed() else { return .superseded }
        _ = AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, target)
        guard allowed() else { return .superseded }
        // Some apps refuse AXRaise until activated. perform() verifies the
        // exact window after activation before reporting success to the caller.
        _ = AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        return .performed
    }

    nonisolated private static func awaitState(_ minimized: Bool, window: AXUIElement,
                                              identity: DockWindowIdentity, expected: AppReference,
                                              reader: Reader) -> DockWindowActionOutcome {
        WindowMinimizedTransition.confirm(minimized, deadline: reader.deadline,
            isCurrent: reader.allowed, exists: { liveApplication(identity, expected: expected) != nil },
            read: { reader.value(window, kAXMinimizedAttribute) as? Bool })
    }
}
