import ApplicationServices
import CoreGraphics
import Foundation

struct FullscreenDisplayFrame: Equatable, Sendable {
    let id: CGDirectDisplayID
    /// Core Graphics coordinates, with the primary display's top at y = 0.
    let frame: CGRect
}

struct FullscreenFallbackInput: Equatable, Sendable {
    let displays: [FullscreenDisplayFrame]
    let accessibilityTrusted: Bool
    let ownProcessID: pid_t
}

/// Reads only displays for which native Space metadata is unavailable. Slow AX
/// applications cannot hold up the main run loop or publish an old Space result.
@MainActor
final class FullscreenFallbackService {
    typealias Reader = @Sendable (FullscreenFallbackInput) -> [CGDirectDisplayID: Bool]
    var onUpdate: (() -> Void)?

    private let reader: Reader
    private let now: () -> TimeInterval
    private let refreshInterval: TimeInterval
    private let maximumStateAge: TimeInterval = 1
    private let queue = DispatchQueue(label: "local.ronny.DualDock.fullscreen-fallback", qos: .userInitiated)
    private var input: FullscreenFallbackInput?
    private struct Confirmation {
        let value: Bool
        let time: TimeInterval
    }
    private var states: [CGDirectDisplayID: Confirmation] = [:]
    private var generation: UInt64 = 0
    private var reading = false
    private var pending = false
    private var lastStartedAt = -TimeInterval.infinity

    init(reader: @escaping Reader = { AccessibilityFullscreenReader.read($0) },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         refreshInterval: TimeInterval = 0.25) {
        self.reader = reader
        self.now = now
        self.refreshInterval = refreshInterval
    }

    /// Returns the last completed result immediately and schedules a bounded
    /// background refresh. Missing values mean the reader could not establish a
    /// state. Keep an earlier confirmation briefly, but never let repeated AX
    /// timeouts keep the Dock hidden indefinitely after leaving fullscreen.
    func update(_ next: FullscreenFallbackInput) -> [CGDirectDisplayID: Bool] {
        if next != input {
            generation &+= 1
            input = next
            let frames = Dictionary(uniqueKeysWithValues: next.displays.map { ($0.id, $0.frame) })
            states = states.filter { frames[$0.key] != nil }
            lastStartedAt = -.infinity
            pending = !next.displays.isEmpty
        }
        if next.displays.isEmpty {
            pending = false
            states.removeAll()
            return [:]
        }
        expireStates(at: now())
        requestIfNeeded()
        return states.mapValues(\.value)
    }

    /// Space changes invalidate in-flight reads as well as the refresh interval.
    func invalidate() {
        generation &+= 1
        lastStartedAt = -.infinity
        pending = input?.displays.isEmpty == false
        requestIfNeeded()
    }

    func stop() {
        generation &+= 1
        input = nil
        states.removeAll()
        pending = false
        lastStartedAt = -.infinity
    }

    private func expireStates(at time: TimeInterval) {
        states = states.filter { time - $0.value.time < maximumStateAge }
        // update() returns the expired snapshot to its caller directly. Do not
        // emit a synchronous callback here and reenter that caller's refresh.
    }

    private func requestIfNeeded() {
        guard let input, !input.displays.isEmpty, !reading,
              pending || now() - lastStartedAt >= refreshInterval else { return }
        reading = true
        pending = false
        lastStartedAt = now()
        let requestGeneration = generation
        let reader = reader
        queue.async { [weak self] in
            let result = autoreleasepool { reader(input) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reading = false
                if requestGeneration == self.generation, self.input == input {
                    let validIDs = Set(input.displays.map(\.id))
                    let previous = self.states.mapValues(\.value)
                    let time = self.now()
                    self.expireStates(at: time)
                    for (id, state) in result where validIDs.contains(id) {
                        self.states[id] = Confirmation(value: state, time: time)
                    }
                    if self.states.mapValues(\.value) != previous { self.onUpdate?() }
                }
                if self.pending { self.requestIfNeeded() }
            }
        }
    }
}

private enum AccessibilityFullscreenReader {
    /// The total budget is shared by all candidate apps and each individual IPC
    /// timeout is limited to the remaining budget. No app is activated or changed.
    static func read(_ input: FullscreenFallbackInput) -> [CGDirectDisplayID: Bool] {
        let ids = input.displays.map(\.id)
        guard input.accessibilityTrusted else { return Dictionary(uniqueKeysWithValues: ids.map { ($0, false) }) }
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.16
        var candidates: [pid_t: Set<CGDirectDisplayID>] = [:]
        for row in rows {
            guard row[kCGWindowLayer as String] as? Int == 0,
                  let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != input.ownProcessID,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            let covered = Set(input.displays.filter { covers(frame, screen: $0.frame) }.map(\.id))
            if !covered.isEmpty { candidates[pid, default: []].formUnion(covered) }
        }
        var result = Dictionary(uniqueKeysWithValues: ids.map { ($0, false) })
        func markUnknown(_ affected: Set<CGDirectDisplayID>) {
            for id in affected where result[id] != true { result.removeValue(forKey: id) }
        }
        for (pid, affected) in candidates.sorted(by: { $0.key < $1.key }) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { markUnknown(affected); continue }
            let application = AXUIElementCreateApplication(pid)
            let (value, error) = value(application, kAXWindowsAttribute as CFString, deadline: deadline)
            guard error == .success, let windows = value as? [AXUIElement] else { markUnknown(affected); continue }
            for window in windows {
                let (full, error) = self.value(window, "AXFullScreen" as CFString, deadline: deadline)
                if error == .cannotComplete { markUnknown(affected); break }
                guard full as? Bool == true else { continue }
                guard let frame = frame(window, deadline: deadline) else { markUnknown(affected); continue }
                for display in input.displays where covers(frame, screen: display.frame) { result[display.id] = true }
            }
        }
        return result
    }

    private static func value(_ element: AXUIElement, _ name: CFString, deadline: TimeInterval) -> (CFTypeRef?, AXError) {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return (nil, .cannotComplete) }
        AXUIElementSetMessagingTimeout(element, Float(min(0.025, remaining)))
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name, &value)
        return (value, error)
    }

    private static func frame(_ window: AXUIElement, deadline: TimeInterval) -> CGRect? {
        guard let position = value(window, kAXPositionAttribute as CFString, deadline: deadline).0,
              let size = value(window, kAXSizeAttribute as CFString, deadline: deadline).0,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func covers(_ frame: CGRect, screen: CGRect) -> Bool {
        let intersection = frame.intersection(screen)
        return screen.width > 0 && screen.height > 0 && !intersection.isNull
            && intersection.width >= screen.width * 0.97 && intersection.height >= screen.height * 0.95
    }
}
