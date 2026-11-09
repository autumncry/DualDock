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
}

/// Owns window discovery and thumbnails; callers decide whether a completed hover request is still current.
@MainActor
final class WindowService {
    private let native = NativeWindowAPI()
    private var contentRequest: Task<SCShareableContent, Error>?
    private var fallbackFullscreenDate = Date.distantPast
    private var fallbackFullscreenIDs: Set<CGDirectDisplayID> = []

    func previews(for app: AppReference) async -> [WindowPreview] {
        guard CGPreflightScreenCaptureAccess(), !Task.isCancelled else { return [] }
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == app.id || $0.bundleURL?.standardizedFileURL.path == URL(fileURLWithPath: app.path).standardizedFileURL.path
        }
        let processIDs = Set(running.map(\.processIdentifier))
        guard !processIDs.isEmpty else { return [] }

        let content: SCShareableContent
        do {
            content = try await currentContent()
        } catch {
            return []
        }
        guard !Task.isCancelled else { return [] }
        let knownWindowIDs = accessibleWindowIDs(processIDs: processIDs)
        var seenWindowIDs: Set<CGWindowID> = []
        let windows = content.windows.filter { window in
            guard let owner = window.owningApplication else { return false }
            return processIDs.contains(owner.processID) && window.windowLayer == 0
                && window.frame.width >= 80 && window.frame.height >= 50
                && PreviewWindowPolicy.shouldInclude(
                    isOnScreen: window.isOnScreen,
                    title: window.title,
                    hasAccessibleWindow: knownWindowIDs[owner.processID].map { $0.contains(window.windowID) }
                )
                && seenWindowIDs.insert(window.windowID).inserted
        }.sorted { left, right in
            if left.isOnScreen != right.isOnScreen { return left.isOnScreen }
            return left.windowID < right.windowID
        }

        // Capture at most three windows at once. Only fresh, visible image
        // content can become a preview; failed captures never reuse old cards.
        var snapshots: [UInt32: CGImage] = [:]
        for offset in stride(from: 0, to: windows.count, by: 3) {
            guard !Task.isCancelled else { return [] }
            let batch = Array(windows[offset..<min(offset + 3, windows.count)])
            let captured = await withTaskGroup(of: (UInt32, CGImage?).self) { group in
                for window in batch {
                    group.addTask { (window.windowID, await Self.capture(window)) }
                }
                var result: [UInt32: CGImage] = [:]
                for await (id, image) in group {
                    if let image { result[id] = image }
                }
                return result
            }
            snapshots.merge(captured) { _, fresh in fresh }
        }
        guard !Task.isCancelled, !snapshots.isEmpty,
              let latestContent = try? await currentContent(), !Task.isCancelled else { return [] }
        let liveProcessIDs = Set(running.filter { !$0.isTerminated }.map(\.processIdentifier))
        let currentWindowIDs = Set(latestContent.windows.compactMap { window -> CGWindowID? in
            guard let owner = window.owningApplication, liveProcessIDs.contains(owner.processID) else { return nil }
            return window.windowID
        })
        let selectedIDs = PreviewWindowPolicy.availablePreviewIDs(
            orderedCandidates: windows.map(\.windowID),
            validSnapshotIDs: Set(snapshots.keys),
            currentWindowIDs: currentWindowIDs
        )
        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        return selectedIDs.compactMap { id -> WindowPreview? in
            guard let window = windowsByID[id], let owner = window.owningApplication,
                  let image = snapshots[id] else { return nil }
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return WindowPreview(
                windowID: window.windowID,
                pid: owner.processID,
                title: title?.isEmpty == false ? title! : app.name,
                image: NSImage(cgImage: image, size: .zero),
                frame: window.frame
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

    func fullscreenDisplayIDs(screens: [NSScreen]) -> Set<CGDirectDisplayID> {
        guard !screens.isEmpty else { return [] }
        let states = native.fullscreenStates(screens: screens)
        var result = Set(states.compactMap { $0.value ? $0.key : nil })
        let unknownScreens = screens.filter { screen in
            guard let id = Self.displayID(screen) else { return false }
            return states[id] == nil
        }
        guard !unknownScreens.isEmpty else { return result }
        // AX probing is needed only when private Space metadata is unavailable or incomplete.
        if Date().timeIntervalSince(fallbackFullscreenDate) > 1 {
            fallbackFullscreenIDs = accessibilityFullscreenDisplays(screens: screens)
            fallbackFullscreenDate = Date()
        }
        let unknownIDs = Set(unknownScreens.compactMap(Self.displayID))
        result.formUnion(fallbackFullscreenIDs.intersection(unknownIDs))
        return result
    }

    private func currentContent() async throws -> SCShareableContent {
        if let contentRequest { return try await contentRequest.value }
        let request = Task { try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }
        contentRequest = request
        defer { contentRequest = nil }
        return try await request.value
    }

    private func accessibleWindowIDs(processIDs: Set<pid_t>) -> [pid_t: Set<CGWindowID>] {
        guard AXIsProcessTrusted(), native.canResolveWindowIDs else { return [:] }
        var result: [pid_t: Set<CGWindowID>] = [:]
        for pid in processIDs {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.2)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            let ids = windows.compactMap { native.windowID(for: $0) }
            // A failed ID lookup or AX query is unknown coverage, not an absent window.
            if ids.count == windows.count { result[pid] = Set(ids) }
        }
        return result
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

    private func accessibilityFullscreenDisplays(screens: [NSScreen]) -> Set<CGDirectDisplayID> {
        guard AXIsProcessTrusted(),
              let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let primaryTop = NSScreen.screens.first(where: { Self.displayID($0) == CGMainDisplayID() })?.frame.maxY ?? 0
        let displayFrames = screens.compactMap { screen -> (CGDirectDisplayID, CGRect)? in
            guard let id = Self.displayID(screen) else { return nil }
            return (id, CGRect(x: screen.frame.minX, y: primaryTop - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height))
        }
        var candidatePIDs: Set<pid_t> = []
        for row in rows {
            guard row[kCGWindowLayer as String] as? Int == 0,
                  let pid = row[kCGWindowOwnerPID as String] as? Int,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }
            if displayFrames.contains(where: { Self.covers(frame, screen: $0.1) }) {
                candidatePIDs.insert(pid_t(pid))
            }
        }
        var result: Set<CGDirectDisplayID> = []
        for pid in candidatePIDs {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.12)
            for window in axWindows(application) {
                // A maximized window alone is insufficient: require the accessibility full-screen flag.
                guard axValue(window, "AXFullScreen" as CFString) as? Bool == true, let frame = axFrame(window) else { continue }
                for (id, displayFrame) in displayFrames where Self.covers(frame, screen: displayFrame) { result.insert(id) }
            }
        }
        return result
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

    private static func covers(_ frame: CGRect, screen: CGRect) -> Bool {
        let intersection = frame.intersection(screen)
        return screen.width > 0 && screen.height > 0 && !intersection.isNull
            && intersection.width >= screen.width * 0.97 && intersection.height >= screen.height * 0.95
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
