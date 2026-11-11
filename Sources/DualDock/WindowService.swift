import AppKit
import ApplicationServices
import Darwin
import DualDockCore
@preconcurrency import ScreenCaptureKit

struct WindowPreview: Identifiable {
    var id: UInt32 { windowID }
    let windowID: UInt32
    let pid: pid_t
    let title: String
    let image: NSImage?
    let frame: CGRect
    let identityTitle: String?
    let processLaunchDate: Date?
    let applicationPath: String?

    init(windowID: UInt32, pid: pid_t, title: String, image: NSImage?, frame: CGRect,
         identityTitle: String? = nil, processLaunchDate: Date? = nil, applicationPath: String? = nil) {
        self.windowID = windowID
        self.pid = pid
        self.title = title
        self.image = image
        self.frame = frame
        self.identityTitle = identityTitle
        self.processLaunchDate = processLaunchDate
        self.applicationPath = applicationPath
    }
}

enum WindowCloseResult: Equatable {
    /// The app accepted its native close action; a save confirmation may still be open.
    case requested
    case notFound
    case permissionRequired
    case unsupported
    case failed

    var message: String? {
        switch self {
        case .requested: return nil
        case .notFound: return "无法准确识别这个窗口，它可能已关闭或发生变化。请重新悬停获取预览后再试。"
        case .permissionRequired: return "请在 DualDock 的权限设置中允许辅助功能，再关闭窗口。"
        case .unsupported: return "这个窗口没有可用的关闭按钮，请在原应用中关闭。"
        case .failed: return "应用暂未接受关闭请求，请稍后重试或在原应用中关闭。"
        }
    }
}

/// Owns window discovery and thumbnails; callers decide whether a completed hover request is still current.
@MainActor
final class WindowService {
    private let native = NativeWindowAPI()
    private var contentRequest: Task<SCShareableContent, Error>?
    var onFullscreenStateChange: (() -> Void)?
    private lazy var fullscreenFallback: FullscreenFallbackService = {
        let service = FullscreenFallbackService()
        service.onUpdate = { [weak self] in self?.onFullscreenStateChange?() }
        return service
    }()

    func previews(for app: AppReference) async -> [WindowPreview] {
        guard CGPreflightScreenCaptureAccess(), !Task.isCancelled else { return [] }
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == app.id || $0.bundleURL?.standardizedFileURL.path == URL(fileURLWithPath: app.path).standardizedFileURL.path
        }
        let processIDs = Set(running.map(\.processIdentifier))
        guard !processIDs.isEmpty else { return [] }
        let applicationNames = Set([app.name] + running.flatMap { application -> [String] in
            var names = application.localizedName.map { [$0] } ?? []
            if let url = application.bundleURL, let bundle = Bundle(url: url) {
                names += ["CFBundleDisplayName", "CFBundleName"].compactMap {
                    bundle.object(forInfoDictionaryKey: $0) as? String
                }
            }
            return names
        })

        let content: SCShareableContent
        do {
            content = try await currentContent()
        } catch {
            return []
        }
        guard !Task.isCancelled else { return [] }
        let accessibility = accessibleWindows(processIDs: processIDs)
        var seenWindowIDs: Set<CGWindowID> = []
        let windows = content.windows.filter { window in
            guard let owner = window.owningApplication else { return false }
            return processIDs.contains(owner.processID) && window.windowLayer == 0
                && window.frame.width >= 80 && window.frame.height >= 50
                && !(accessibility.companionOverlayIDs[owner.processID]?.contains(window.windowID) ?? false)
                && PreviewWindowPolicy.shouldInclude(
                    isOnScreen: window.isOnScreen,
                    title: window.title,
                    hasAccessibleWindow: accessibility.knownWindowIDs[owner.processID].map { $0.contains(window.windowID) }
                )
                && seenWindowIDs.insert(window.windowID).inserted
        }.sorted { left, right in
            if left.isOnScreen != right.isOnScreen { return left.isOnScreen }
            return left.windowID < right.windowID
        }
        let shellCandidates = Set(windows.filter { window in
            guard let owner = window.owningApplication else { return false }
            return PreviewWindowPolicy.isBackgroundShellCandidate(
                isOnScreen: window.isOnScreen, isActive: window.isActive, title: window.title,
                applicationNames: applicationNames,
                hasAccessibleWindow: accessibility.knownWindowIDs[owner.processID].map { $0.contains(window.windowID) })
        }.map(\.windowID))

        // Capture at most three windows at once. Only fresh, visible image
        // content can become a preview; failed captures never reuse old cards.
        var snapshots: [UInt32: CGImage] = [:]
        var flatShellIDs: Set<UInt32> = []
        for offset in stride(from: 0, to: windows.count, by: 3) {
            guard !Task.isCancelled else { return [] }
            let batch = Array(windows[offset..<min(offset + 3, windows.count)])
            let captured = await withTaskGroup(of: (UInt32, CGImage?, Bool).self) { group in
                for window in batch {
                    group.addTask {
                        let image = await Self.capture(window)
                        let flatShell = shellCandidates.contains(window.windowID)
                            && PreviewImagePolicy.isUniformWindowShell(image)
                        return (window.windowID, image, flatShell)
                    }
                }
                var result: [UInt32: (image: CGImage, flatShell: Bool)] = [:]
                for await (id, image, flatShell) in group {
                    if let image { result[id] = (image, flatShell) }
                }
                return result
            }
            for (id, capture) in captured {
                snapshots[id] = capture.image
                if capture.flatShell { flatShellIDs.insert(id) }
            }
        }
        guard !Task.isCancelled, !snapshots.isEmpty,
              let latestContent = try? await currentContent(), !Task.isCancelled else { return [] }
        let liveProcessIDs = Set(running.filter { !$0.isTerminated }.map(\.processIdentifier))
        let currentWindowIDs = Set(latestContent.windows.compactMap { window -> CGWindowID? in
            guard let owner = window.owningApplication, liveProcessIDs.contains(owner.processID) else { return nil }
            return window.windowID
        })
        let confirmedShellIDs = Set(latestContent.windows.compactMap { window -> CGWindowID? in
            guard flatShellIDs.contains(window.windowID), let owner = window.owningApplication,
                  PreviewWindowPolicy.isBackgroundShellCandidate(
                    isOnScreen: window.isOnScreen, isActive: window.isActive, title: window.title,
                    applicationNames: applicationNames,
                    hasAccessibleWindow: accessibility.knownWindowIDs[owner.processID].map { $0.contains(window.windowID) })
            else { return nil }
            return window.windowID
        })
        let selectedIDs = PreviewWindowPolicy.availablePreviewIDs(
            orderedCandidates: windows.map(\.windowID),
            validSnapshotIDs: Set(snapshots.keys).subtracting(confirmedShellIDs),
            currentWindowIDs: currentWindowIDs
        )
        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        return selectedIDs.compactMap { id -> WindowPreview? in
            guard let window = windowsByID[id], let owner = window.owningApplication,
                  let image = snapshots[id] else { return nil }
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let process = running.first { $0.processIdentifier == owner.processID }
            return WindowPreview(
                windowID: window.windowID,
                pid: owner.processID,
                title: title?.isEmpty == false ? title! : app.name,
                image: NSImage(cgImage: image, size: .zero),
                frame: window.frame,
                identityTitle: title,
                processLaunchDate: process?.launchDate,
                applicationPath: process?.bundleURL?.standardizedFileURL.path
            )
        }
    }

    @discardableResult
    func activate(_ item: WindowPreview) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: item.pid), !app.isTerminated else { return false }
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            app.unhide()
            return app.activate(options: [])
        }

        let application = AXUIElementCreateApplication(item.pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        let windows = axWindows(application)
        let exact = windows.first { native.windowID(for: $0) == item.windowID }
        let target = exact ?? unambiguousMatch(item, in: windows)
        app.unhide()
        guard let target else { return app.activate(options: []) }

        AXUIElementSetMessagingTimeout(target, 0.2)
        _ = AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        _ = AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, target)
        let activated = app.activate(options: [])
        let raised = AXUIElementPerformAction(target, kAXRaiseAction as CFString) == .success
        return activated || raised
    }

    /// Press the matching window's own close button. Never substitute Cmd-W,
    /// the frontmost window, or application termination for a missing target.
    func close(_ item: WindowPreview, for expectedApp: AppReference) -> WindowCloseResult {
        guard AXIsProcessTrusted() else { return .permissionRequired }
        guard let app = NSRunningApplication(processIdentifier: item.pid), !app.isTerminated,
              WindowCloseTargetPolicy.matchesApplication(
                expected: expectedApp, capturedPath: item.applicationPath, capturedLaunchDate: item.processLaunchDate,
                liveBundleID: app.bundleIdentifier, livePath: app.bundleURL?.standardizedFileURL.path,
                liveLaunchDate: app.launchDate),
              sourceWindowExists(item) else { return .notFound }

        let application = AXUIElementCreateApplication(item.pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        var value: CFTypeRef?
        let query = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
        guard query == .success, let windows = value as? [AXUIElement] else { return .failed }
        let ids = windows.map { element -> CGWindowID? in
            AXUIElementSetMessagingTimeout(element, 0.15)
            return native.windowID(for: element)
        }
        // Normal exact-ID closes do not need per-window title/geometry queries.
        let needsFallback = ids.allSatisfy { $0 == nil }
        let candidates = zip(windows, ids).map { element, id in
            WindowCloseTargetPolicy.Candidate(windowID: id,
                title: needsFallback ? axValue(element, kAXTitleAttribute as CFString) as? String : nil,
                frame: needsFallback ? axFrame(element) : nil)
        }
        guard let index = WindowCloseTargetPolicy.candidateIndex(
            windowID: item.windowID, rawTitle: item.identityTitle, frame: item.frame, candidates: candidates)
        else { return .notFound }
        guard !needsFallback || fallbackSourceIsUnique(item) else { return .notFound }
        let target = windows[index]
        var closeValue: CFTypeRef?
        let closeQuery = AXUIElementCopyAttributeValue(target, kAXCloseButtonAttribute as CFString, &closeValue)
        if closeQuery == .noValue || closeQuery == .attributeUnsupported { return .unsupported }
        guard closeQuery == .success, let closeValue,
              CFGetTypeID(closeValue) == AXUIElementGetTypeID() else { return .failed }
        let closeButton = unsafeBitCast(closeValue, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(closeButton, 0.2)
        if axValue(closeButton, kAXEnabledAttribute as CFString) as? Bool == false { return .unsupported }

        // Recheck the source after the AX round trips. A closed stale preview
        // must never select a replacement with the same title or position.
        guard !app.isTerminated,
              needsFallback ? fallbackSourceIsUnique(item) : sourceWindowExists(item) else { return .notFound }
        let action = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
        guard action == .success else {
            return action == .actionUnsupported ? .unsupported : .failed
        }
        // Bring any native save-confirmation sheet into view, without choosing
        // Save/Discard or sending another close command.
        if !app.isTerminated, sourceWindowExists(item) {
            app.unhide()
            _ = app.activate(options: [])
        }
        return .requested
    }

    private func sourceWindowExists(_ item: WindowPreview) -> Bool {
        guard item.windowID != 0,
              let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow, .excludeDesktopElements], item.windowID) as? [[String: Any]]
        else { return false }
        return rows.contains {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == item.windowID
                && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == item.pid
        }
    }

    private func fallbackSourceIsUnique(_ item: WindowPreview) -> Bool {
        guard let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let sameProcess = rows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == item.pid }
        let windows = sameProcess.map { row -> WindowCloseTargetPolicy.Candidate in
            let frame = (row[kCGWindowBounds as String] as? [String: Any])
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            return .init(windowID: (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                         title: row[kCGWindowName as String] as? String, frame: frame)
        }
        return WindowCloseTargetPolicy.fallbackSourceIsUnique(
            windowID: item.windowID, rawTitle: item.identityTitle, frame: item.frame, windows: windows)
    }

    func fullscreenDisplayIDs(screens: [NSScreen]) -> Set<CGDirectDisplayID> {
        let states = native.fullscreenStates(screens: screens)
        var result = Set(states.compactMap { $0.value ? $0.key : nil })
        let unknownScreens = screens.filter { screen in
            guard let id = Self.displayID(screen) else { return false }
            return states[id] == nil
        }
        let primaryTop = NSScreen.screens.first(where: { Self.displayID($0) == CGMainDisplayID() })?.frame.maxY ?? 0
        let displays = unknownScreens.compactMap { screen -> FullscreenDisplayFrame? in
            guard let id = Self.displayID(screen) else { return nil }
            return .init(id: id, frame: CGRect(x: screen.frame.minX, y: primaryTop - screen.frame.maxY,
                                              width: screen.frame.width, height: screen.frame.height))
        }.sorted { $0.id < $1.id }
        // The native query is cheap and definitive when it knows the Space.
        // Only unknown displays enter the bounded background AX fallback.
        let fallback = fullscreenFallback.update(.init(displays: displays,
            accessibilityTrusted: AXIsProcessTrusted(), ownProcessID: ProcessInfo.processInfo.processIdentifier))
        result.formUnion(fallback.compactMap { $0.value ? $0.key : nil })
        return result
    }

    func invalidateFullscreenState() { fullscreenFallback.invalidate() }

    func stopFullscreenMonitoring() { fullscreenFallback.stop() }

    private func currentContent() async throws -> SCShareableContent {
        if let contentRequest { return try await contentRequest.value }
        let request = Task { try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }
        contentRequest = request
        defer { contentRequest = nil }
        return try await request.value
    }

    private struct AccessibleWindows {
        var knownWindowIDs: [pid_t: Set<CGWindowID>] = [:]
        var companionOverlayIDs: [pid_t: Set<CGWindowID>] = [:]
    }

    private func accessibleWindows(processIDs: Set<pid_t>) -> AccessibleWindows {
        var result = AccessibleWindows()
        guard AXIsProcessTrusted(), native.canResolveWindowIDs else { return result }
        for pid in processIDs {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.2)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            let identified = windows.compactMap { element -> (CGWindowID, AXUIElement)? in
                native.windowID(for: element).map { ($0, element) }
            }
            // Empty or incomplete AX results do not establish reliable absence.
            // A nonempty fully identified list can qualify a hidden generic
            // window for the separate, conservative flat-shell image check.
            if !identified.isEmpty, identified.count == windows.count {
                result.knownWindowIDs[pid] = Set(identified.map { $0.0 })
            }

            // ScreenCaptureKit also exposes app-owned overlays (for example a
            // watermark layer). They may have valid pixels and a different ID
            // even though they are not an independently usable window.
            let typed = identified.map { id, element in
                AXUIElementSetMessagingTimeout(element, 0.12)
                return (id, element, axValue(element, kAXSubroleAttribute as CFString) as? String)
            }
            guard typed.contains(where: { $0.2 == kAXUnknownSubrole }),
                  typed.contains(where: { $0.2 == kAXStandardWindowSubrole }) else { continue }
            var metadata = typed.compactMap { id, element, subrole -> PreviewWindowPolicy.AccessibilityWindow? in
                guard subrole == kAXUnknownSubrole || subrole == kAXStandardWindowSubrole else { return nil }
                return .init(windowID: id, frame: axFrame(element),
                             role: axValue(element, kAXRoleAttribute as CFString) as? String, subrole: subrole,
                             isMain: nil, isFocused: nil, isModal: nil, isMinimized: nil, hasWindowControls: nil)
            }
            let candidates = PreviewWindowPolicy.possibleCompanionOverlayIDs(in: metadata)
            for index in metadata.indices where candidates.contains(metadata[index].windowID) {
                let record = metadata[index]
                guard let element = identified.first(where: { $0.0 == record.windowID })?.1,
                      axValue(element, kAXMainAttribute as CFString) as? Bool == false,
                      axValue(element, kAXFocusedAttribute as CFString) as? Bool == false,
                      axValue(element, kAXModalAttribute as CFString) as? Bool == false,
                      axValue(element, kAXMinimizedAttribute as CFString) as? Bool == false,
                      hasWindowControls(element) == false else { continue }
                metadata[index] = .init(windowID: record.windowID, frame: record.frame,
                                        role: record.role, subrole: record.subrole,
                                        isMain: false, isFocused: false, isModal: false,
                                        isMinimized: false, hasWindowControls: false)
            }
            result.companionOverlayIDs[pid] = PreviewWindowPolicy.companionOverlayIDs(in: metadata)
        }
        return result
    }

    private func hasWindowControls(_ element: AXUIElement) -> Bool? {
        for attribute in [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute, "AXFullScreenButton"] {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            switch error {
            case .success:
                if value != nil { return true }
            case .noValue, .attributeUnsupported:
                continue
            default:
                // A timeout or failed query is not evidence that a control is absent.
                return nil
            }
        }
        return false
    }

    nonisolated private static func capture(_ window: SCWindow) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = min(480 / window.frame.width, 320 / window.frame.height, 1)
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
              PreviewImagePolicy.hasVisiblePixels(image) else { return nil }
        return image
    }

    private func unambiguousMatch(_ item: WindowPreview, in windows: [AXUIElement]) -> AXUIElement? {
        let titled = windows.filter { axValue($0, kAXTitleAttribute as CFString) as? String == item.title }
        if titled.count == 1 { return titled[0] }
        let candidates = titled.isEmpty ? windows : titled
        let positioned = candidates.filter { window in
            guard let frame = axFrame(window) else { return false }
            return abs(frame.minX - item.frame.minX) < 3 && abs(frame.minY - item.frame.minY) < 3
                && abs(frame.width - item.frame.width) < 3 && abs(frame.height - item.frame.height) < 3
        }
        return positioned.count == 1 ? positioned[0] : nil
    }

    private func axWindows(_ application: AXUIElement) -> [AXUIElement] {
        axValue(application, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
    }

    private func axValue(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
    }

    private func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let position = axValue(element, kAXPositionAttribute as CFString),
              let size = axValue(element, kAXSizeAttribute as CFString),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions)
        else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    fileprivate static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Private symbols stay behind optional function pointers so a system update can fall back to public AX APIs.
@MainActor
private final class NativeWindowAPI {
    private typealias WindowIDFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias ConnectionFunction = @convention(c) () -> UInt32
    private typealias SpacesFunction = @convention(c) (UInt32) -> Unmanaged<CFArray>?

    private let processHandle: UnsafeMutableRawPointer?
    private let skyLightHandle: UnsafeMutableRawPointer?
    private let getWindowID: WindowIDFunction?
    private let connectionID: ConnectionFunction?
    private let copyDisplaySpaces: SpacesFunction?

    init() {
        processHandle = dlopen(nil, RTLD_LAZY)
        let skyHandle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        skyLightHandle = skyHandle
        if let symbol = dlsym(processHandle, "_AXUIElementGetWindow") {
            getWindowID = unsafeBitCast(symbol, to: WindowIDFunction.self)
        } else {
            getWindowID = nil
        }
        let connectionNames: [String] = ["SLSMainConnectionID", "CGSMainConnectionID", "_CGSDefaultConnection"]
        let connection = connectionNames.compactMap { name in
            name.withCString { dlsym(skyHandle, $0) }
        }.first
        connectionID = connection.map { unsafeBitCast($0, to: ConnectionFunction.self) }
        let spaceNames: [String] = ["SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces"]
        let spaces = spaceNames.compactMap { name in
            name.withCString { dlsym(skyHandle, $0) }
        }.first
        copyDisplaySpaces = spaces.map { unsafeBitCast($0, to: SpacesFunction.self) }
    }

    deinit {
        if let skyLightHandle { dlclose(skyLightHandle) }
        if let processHandle { dlclose(processHandle) }
    }

    var canResolveWindowIDs: Bool { getWindowID != nil }

    func windowID(for element: AXUIElement) -> CGWindowID? {
        guard let getWindowID else { return nil }
        var id: CGWindowID = 0
        return getWindowID(element, &id) == .success && id != 0 ? id : nil
    }

    func fullscreenStates(screens: [NSScreen]) -> [CGDirectDisplayID: Bool] {
        guard let connectionID, let copyDisplaySpaces,
              let result = copyDisplaySpaces(connectionID())?.takeRetainedValue() as? [[String: Any]]
        else { return [:] }
        var states: [CGDirectDisplayID: Bool] = [:]
        for screen in screens {
            guard let id = WindowService.displayID(screen), let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { continue }
            let uuidString = CFUUIDCreateString(nil, uuid) as String
            let record = result.first { ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(uuidString) == .orderedSame }
            if let current = record?["Current Space"] as? [String: Any], let type = current["type"] as? Int {
                states[id] = type == 4
            }
        }
        // Older shared-Space configurations may report a single "Main" record instead of UUIDs.
        // A desktop Space is unambiguously non-fullscreen everywhere; fullscreen ownership falls back to AX geometry.
        if !NSScreen.screensHaveSeparateSpaces,
           let record = result.first(where: { $0["Display Identifier"] as? String == "Main" }),
           let current = record["Current Space"] as? [String: Any], let type = current["type"] as? Int, type != 4 {
            for screen in screens {
                if let id = WindowService.displayID(screen) { states[id] = false }
            }
        }
        return states
    }
}
