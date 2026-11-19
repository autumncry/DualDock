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
    var canClose: Bool

    init(windowID: UInt32, pid: pid_t, title: String, image: NSImage?, frame: CGRect,
         identityTitle: String? = nil, processLaunchDate: Date? = nil, applicationPath: String? = nil, canClose: Bool = false) {
        self.windowID = windowID
        self.pid = pid
        self.title = title
        self.image = image
        self.frame = frame
        self.identityTitle = identityTitle
        self.processLaunchDate = processLaunchDate
        self.applicationPath = applicationPath
        self.canClose = canClose
    }
}

enum WindowCloseResult: Equatable {
    /// The app accepted its native close action; a save confirmation may still be open.
    case requested
    case notFound
    case permissionRequired
    case unsupported
    case failed

    var notice: LocalizedNotice? {
        switch self {
        case .requested: return nil
        case .notFound: return LocalizedNotice("无法准确识别这个窗口，它可能已关闭或发生变化。请重新悬停获取预览后再试。", "Couldn’t identify this window. Hover over the app to refresh its previews, then try again.")
        case .permissionRequired: return LocalizedNotice("请在 DualDock 的权限设置中允许辅助功能，再关闭窗口。", "Allow Accessibility in DualDock’s Permissions settings to close a window.")
        case .unsupported: return LocalizedNotice("这个窗口没有可用的关闭按钮，请在原应用中关闭。", "This window has no available Close button. Close it in its app.")
        case .failed: return LocalizedNotice("应用暂未接受关闭请求，请稍后重试或在原应用中关闭。", "The app didn’t accept the close request. Try again or close the window in its app.")
        }
    }
}

/// Owns window discovery and thumbnails; callers decide whether a completed hover request is still current.
@MainActor
final class WindowService {
    private let native = NativeWindowAPI()
    private struct FailedReopen {
        let pid: pid_t
        let launchDate: Date
        let path: String
        let time: TimeInterval
    }
    private var failedReopens: [CGWindowID: FailedReopen] = [:]
    private var contentRequest: Task<SCShareableContent, Error>?
    var onFullscreenStateChange: (() -> Void)?
    /// Updated with the same native snapshot used by fullscreenDisplayIDs.
    /// Missing values mean private Space metadata is unavailable for that screen.
    private(set) var activeSpaceIDs: [CGDirectDisplayID: UInt64] = [:]
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
        let now = ProcessInfo.processInfo.systemUptime
        failedReopens = failedReopens.filter { now - $0.value.time < 30 }
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
            var preview = WindowPreview(
                windowID: window.windowID,
                pid: owner.processID,
                title: title?.isEmpty == false ? title! : app.name,
                image: NSImage(cgImage: image, size: .zero),
                frame: window.frame,
                identityTitle: title,
                processLaunchDate: process?.launchDate,
                applicationPath: process?.bundleURL?.standardizedFileURL.path
            )
            let inventory = accessibility.targets[owner.processID]
            let match = inventory.flatMap { resolvedTarget(preview, in: $0) }
            if let match, case .available = closeControl(of: match.element) { preview.canClose = true }
            if let failed = failedReopens[id] {
                let sameWindow = failed.pid == preview.pid && failed.launchDate == preview.processLaunchDate
                    && failed.path == preview.applicationPath
                let current = latestContent.windows.first { $0.windowID == id && $0.owningApplication?.processID == preview.pid }
                let sibling = latestContent.windows.contains { $0.windowID != id && $0.windowLayer == 0 && $0.isOnScreen
                    && $0.frame.width >= 80 && $0.frame.height >= 50 && $0.owningApplication?.processID == preview.pid }
                if let current, sameWindow, PreviewWindowPolicy.shouldSuppressAfterReopen(
                    failureAge: now - failed.time, isOnScreen: current.isOnScreen, isActive: current.isActive,
                    confirmedNoAXTarget: inventory != nil && match == nil, hasVisibleSibling: sibling,
                    onCurrentSpace: native.isOnCurrentSpace(id)) { return nil }
                failedReopens.removeValue(forKey: id)
            }
            return preview
        }
    }

    @discardableResult
    func activate(_ item: WindowPreview, for expectedApp: AppReference) async -> Bool {
        guard !Task.isCancelled, let app = liveApplication(for: item, expected: expectedApp),
              sourceWindowExists(item) else { return false }
        var reopenOrderedOut = true
        let application = AXUIElementCreateApplication(item.pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        let inventory = AXIsProcessTrusted() ? targets(of: application) : nil
        let exactMatch = inventory.flatMap { resolvedTarget(item, in: $0) }
        let confirmedNoAXTarget = inventory != nil && exactMatch == nil
        if let match = exactMatch {
            let target = match.element
            guard !Task.isCancelled, sourceWindowExists(item) else { return false }
            app.unhide()
            if axValue(target, kAXMinimizedAttribute as CFString) as? Bool == true {
                let restore = AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                // A native restoration can finish after the AX reply. Avoid
                // delivering an app reopen event during that animation.
                reopenOrderedOut = restore != .success && restore != .cannotComplete
            }
            _ = app.activate(options: [])
            _ = AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, target)
            _ = AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        }
        var reopened = false
        let activated = await VerifiedWindowActivation.raise(windowID: item.windowID, pid: item.pid,
            launchDate: item.processLaunchDate, applicationPath: item.applicationPath, expectedApp: expectedApp,
            reopenOrderedOut: reopenOrderedOut, didReopen: { reopened = true })
        if activated { failedReopens.removeValue(forKey: item.windowID) }
        else if reopened, !Task.isCancelled, confirmedNoAXTarget,
                let date = item.processLaunchDate, let path = item.applicationPath {
            // Retain only the attempted identity; the next fresh capture must
            // independently confirm it is still hidden and unaddressable.
            failedReopens[item.windowID] = FailedReopen(pid: item.pid, launchDate: date,
                path: path, time: ProcessInfo.processInfo.systemUptime)
        }
        return activated
    }

    private func liveApplication(for item: WindowPreview, expected: AppReference) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: item.pid), !app.isTerminated,
              WindowCloseTargetPolicy.matchesApplication(expected: expected, capturedPath: item.applicationPath,
                capturedLaunchDate: item.processLaunchDate, liveBundleID: app.bundleIdentifier,
                livePath: app.bundleURL?.standardizedFileURL.path, liveLaunchDate: app.launchDate) else { return nil }
        return app
    }

    /// Press the matching window's own close button. Never substitute Cmd-W,
    /// the frontmost window, or application termination for a missing target.
    func close(_ item: WindowPreview, for expectedApp: AppReference) -> WindowCloseResult {
        guard AXIsProcessTrusted() else { return .permissionRequired }
        guard let app = liveApplication(for: item, expected: expectedApp), sourceWindowExists(item) else { return .notFound }

        let application = AXUIElementCreateApplication(item.pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let inventory = targets(of: application) else { return .failed }
        guard let match = resolvedTarget(item, in: inventory) else { return .notFound }
        let closeButton: AXUIElement
        switch closeControl(of: match.element) {
        case .unavailable: return .unsupported
        case .failed: return .failed
        case .available(let button): closeButton = button
        }

        // Recheck the source after the AX round trips. A closed stale preview
        // must never select a replacement with the same title or position.
        guard !app.isTerminated,
              match.requiresFallback ? fallbackSourceIsUnique(item) : sourceWindowExists(item) else { return .notFound }
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

    private enum CloseControl {
        case available(AXUIElement)
        case unavailable
        case failed
    }

    private func closeControl(of window: AXUIElement) -> CloseControl {
        var value: CFTypeRef?
        let query = AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &value)
        if query == .noValue || query == .attributeUnsupported { return .unavailable }
        guard query == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .failed }
        let button = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(button, 0.15)
        guard (axValue(button, kAXEnabledAttribute as CFString) as? Bool) != false else { return .unavailable }
        var actions: CFArray?
        guard AXUIElementCopyActionNames(button, &actions) == .success else { return .failed }
        guard (actions as? [String])?.contains(kAXPressAction) == true else { return .unavailable }
        return .available(button)
    }

    private struct AXTarget {
        let element: AXUIElement
        let candidate: WindowCloseTargetPolicy.Candidate
    }

    /// A screenshot provider may expose windows which the app does not expose
    /// through Accessibility. Only real window elements can receive an action.
    private func targets(of application: AXUIElement) -> [AXTarget]? {
        var value: CFTypeRef?
        let query = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
        guard query == .success, var elements = value as? [AXUIElement] else { return nil }
        for key in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            guard let extra = axValue(application, key as CFString),
                  CFGetTypeID(extra) == AXUIElementGetTypeID() else { continue }
            let element = unsafeBitCast(extra, to: AXUIElement.self)
            if !elements.contains(where: { CFEqual($0, element) }) { elements.append(element) }
        }
        let identified = elements.compactMap { element -> (AXUIElement, CGWindowID?)? in
            AXUIElementSetMessagingTimeout(element, 0.15)
            guard axValue(element, kAXRoleAttribute as CFString) as? String == kAXWindowRole as String else { return nil }
            return (element, native.windowID(for: element))
        }
        let needsFallback = identified.allSatisfy { $0.1 == nil }
        return identified.map { element, id in
            AXTarget(element: element, candidate: .init(windowID: id,
                title: needsFallback ? axValue(element, kAXTitleAttribute as CFString) as? String : nil,
                frame: needsFallback ? axFrame(element) : nil))
        }
    }

    private func resolvedTarget(_ item: WindowPreview, in targets: [AXTarget])
        -> (element: AXUIElement, requiresFallback: Bool)? {
        let candidates = targets.map(\.candidate)
        guard let index = WindowCloseTargetPolicy.candidateIndex(windowID: item.windowID,
            rawTitle: item.identityTitle, frame: item.frame, candidates: candidates) else { return nil }
        let match = targets[index]
        var pid: pid_t = 0
        guard AXUIElementGetPid(match.element, &pid) == .success, pid == item.pid else { return nil }
        let requiresFallback = match.candidate.windowID == nil
        guard !requiresFallback || fallbackSourceIsUnique(item) else { return nil }
        return (match.element, requiresFallback)
    }

    private func sourceWindowExists(_ item: WindowPreview) -> Bool {
        VerifiedWindowActivation.sourceRow(windowID: item.windowID, pid: item.pid) != nil
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
        let snapshot = native.displaySpaces(screens: screens)
        activeSpaceIDs = snapshot.identifiers
        let states = snapshot.fullscreen
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

    func stopFullscreenMonitoring() {
        fullscreenFallback.stop()
        activeSpaceIDs.removeAll()
    }

    private func currentContent() async throws -> SCShareableContent {
        if let contentRequest { return try await contentRequest.value }
        let request = Task { try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }
        contentRequest = request
        defer { contentRequest = nil }
        return try await request.value
    }

    private struct AccessibleWindows {
        var targets: [pid_t: [AXTarget]] = [:]
        var knownWindowIDs: [pid_t: Set<CGWindowID>] = [:]
        var companionOverlayIDs: [pid_t: Set<CGWindowID>] = [:]
    }

    private func accessibleWindows(processIDs: Set<pid_t>) -> AccessibleWindows {
        var result = AccessibleWindows()
        guard AXIsProcessTrusted() else { return result }
        for pid in processIDs {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.2)
            guard let inventory = targets(of: application) else { continue }
            result.targets[pid] = inventory
            let identified = inventory.compactMap { target in
                target.candidate.windowID.map { ($0, target.element) }
            }
            // Empty or incomplete AX results do not establish reliable absence.
            // A nonempty fully identified list can qualify a hidden generic
            // window for the separate, conservative flat-shell image check.
            if !identified.isEmpty, identified.count == inventory.count {
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
    private typealias WindowSpacesFunction = @convention(c) (UInt32, UInt32, CFArray) -> Unmanaged<CFArray>?
    private typealias SpacesFunction = @convention(c) (UInt32) -> Unmanaged<CFArray>?

    private let processHandle: UnsafeMutableRawPointer?
    private let skyLightHandle: UnsafeMutableRawPointer?
    private let getWindowID: WindowIDFunction?
    private let connectionID: ConnectionFunction?
    private let copyDisplaySpaces: SpacesFunction?
    private let copyWindowSpaces: WindowSpacesFunction?

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
        let windowSpaces = ["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"]
            .compactMap { name in name.withCString { dlsym(skyHandle, $0) } }.first
        copyWindowSpaces = windowSpaces.map { unsafeBitCast($0, to: WindowSpacesFunction.self) }
    }

    deinit {
        if let skyLightHandle { dlclose(skyLightHandle) }
        if let processHandle { dlclose(processHandle) }
    }

    func isOnCurrentSpace(_ windowID: CGWindowID) -> Bool {
        guard let connectionID, let copyWindowSpaces, let copyDisplaySpaces else { return false }
        let connection = connectionID()
        guard let spaces = copyWindowSpaces(connection, 7, [NSNumber(value: windowID)] as CFArray)?
            .takeRetainedValue() as? [NSNumber],
              let displays = copyDisplaySpaces(connection)?.takeRetainedValue() as? [[String:Any]]
        else { return false }
        let active = Set(displays.compactMap { ($0["Current Space"] as? [String:Any]).flatMap(Self.spaceID) })
        return spaces.contains { active.contains($0.uint64Value) }
    }

    func windowID(for element: AXUIElement) -> CGWindowID? {
        guard let getWindowID else { return nil }
        var id: CGWindowID = 0
        return getWindowID(element, &id) == .success && id != 0 ? id : nil
    }

    struct DisplaySpaces {
        var fullscreen: [CGDirectDisplayID: Bool] = [:]
        var identifiers: [CGDirectDisplayID: UInt64] = [:]
    }

    func displaySpaces(screens: [NSScreen]) -> DisplaySpaces {
        guard let connectionID, let copyDisplaySpaces,
              let result = copyDisplaySpaces(connectionID())?.takeRetainedValue() as? [[String: Any]]
        else { return DisplaySpaces() }
        var states = DisplaySpaces()
        for screen in screens {
            guard let id = WindowService.displayID(screen), let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { continue }
            let uuidString = CFUUIDCreateString(nil, uuid) as String
            let record = result.first { ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(uuidString) == .orderedSame }
            if let current = record?["Current Space"] as? [String: Any] {
                if let type = current["type"] as? Int { states.fullscreen[id] = type == 4 }
                states.identifiers[id] = Self.spaceID(current)
            }
        }
        // Older shared-Space configurations may report a single "Main" record instead of UUIDs.
        // A desktop Space is unambiguously non-fullscreen everywhere; fullscreen ownership falls back to AX geometry.
        if !NSScreen.screensHaveSeparateSpaces,
           let record = result.first(where: { $0["Display Identifier"] as? String == "Main" }),
           let current = record["Current Space"] as? [String: Any] {
            for screen in screens {
                if let id = WindowService.displayID(screen) {
                    if let type = current["type"] as? Int, type != 4 { states.fullscreen[id] = false }
                    states.identifiers[id] = Self.spaceID(current)
                }
            }
        }
        return states
    }

    private static func spaceID(_ space: [String: Any]) -> UInt64? {
        guard let value = (space["ManagedSpaceID"] ?? space["id64"]) as? NSNumber,
              value.uint64Value > 0 else { return nil }
        return value.uint64Value
    }
}
