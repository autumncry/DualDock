import AppKit
import ApplicationServices
import CoreGraphics
import DualDockCore

struct NativeDockMetricsReadInput: Sendable {
    let dockProcessID: pid_t?
    let accessibilityTrusted: Bool
    let screenLocked: Bool
}

struct NativeDockMetricsReadResult: Sendable {
    let preferences: NativeDockPreferences?
    let observed: NativeDockMetrics?
}

/// Inert until AppStore starts it. No preferences are written, no app is
/// activated, and accessibility permission is never requested by this service.
@MainActor
final class NativeDockMetricsService {
    typealias Reader = @Sendable (NativeDockMetricsReadInput) -> NativeDockMetricsReadResult
    var onUpdate: ((NativeDockMetrics, NativeDockMetricsStatus) -> Void)?

    private let reader: Reader
    private let inputProvider: () -> NativeDockMetricsReadInput
    private let queue = DispatchQueue(label: "local.ronny.DualDock.native-metrics", qos: .utility)
    private var timer: Timer?
    private var enabled = false
    private var generation: UInt64 = 0
    private var reading = false
    private var refreshPending = false
    private var lastObserved: NativeDockMetrics?
    private var lastPreferenceMetrics: NativeDockMetrics?
    private var lastPublished: NativeDockMetrics?
    private var lastStatus: NativeDockMetricsStatus?

    convenience init() {
        self.init(reader: { SystemNativeDockMetricsReader.read($0) }, inputProvider: Self.currentInput)
    }

    init(reader: @escaping Reader, inputProvider: @escaping () -> NativeDockMetricsReadInput) {
        self.reader = reader
        self.inputProvider = inputProvider
    }

    deinit { timer?.invalidate() }

    func start() {
        guard !enabled else { return }
        enabled = true
        generation &+= 1
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func stop() {
        guard enabled else { return }
        enabled = false
        generation &+= 1
        timer?.invalidate()
        timer = nil
        refreshPending = false
    }

    func refresh() {
        guard enabled else { return }
        guard !reading else { refreshPending = true; return }
        reading = true
        refreshPending = false
        let requestGeneration = generation
        let input = inputProvider()
        let reader = reader
        queue.async { [weak self] in
            let result = autoreleasepool { reader(input) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reading = false
                guard self.enabled else { self.refreshPending = false; return }
                if requestGeneration == self.generation {
                    self.consume(result)
                } else {
                    self.refreshPending = true
                }
                if self.refreshPending { self.refresh() }
            }
        }
    }

    private func consume(_ result: NativeDockMetricsReadResult) {
        let metrics: NativeDockMetrics
        let status: NativeDockMetricsStatus
        if let observed = result.observed {
            lastObserved = observed
            metrics = observed
            status = .accessibility
        } else if let lastObserved {
            // Retain known geometry through lock/unlock and Dock relaunches.
            // Explicit native magnification preferences can still be followed.
            metrics = lastObserved.applyingMagnification(result.preferences)
            self.lastObserved = metrics
            status = .cached
        } else if let preferences = result.preferences, preferences.hasKnownValues {
            metrics = preferences.fallbackMetrics
            lastPreferenceMetrics = metrics
            status = .preferences
        } else if let lastPreferenceMetrics {
            metrics = lastPreferenceMetrics
            status = .cached
        } else {
            metrics = .fallback
            status = .fallback
        }
        guard metrics != lastPublished || status != lastStatus else { return }
        lastPublished = metrics
        lastStatus = status
        onUpdate?(metrics, status)
    }

    private static func currentInput() -> NativeDockMetricsReadInput {
        let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first { !$0.isTerminated }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return NativeDockMetricsReadInput(dockProcessID: dock?.processIdentifier,
            accessibilityTrusted: AXIsProcessTrusted(),
            screenLocked: session?["CGSSessionScreenIsLocked"] as? Bool ?? false)
    }
}

private enum SystemNativeDockMetricsReader {
    static func read(_ input: NativeDockMetricsReadInput) -> NativeDockMetricsReadResult {
        let preferences = preferences()
        guard input.accessibilityTrusted, !input.screenLocked, let pid = input.dockProcessID else {
            return .init(preferences: preferences, observed: nil)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.04)
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count, index < 32, ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth) = queue[index]
            index += 1
            AXUIElementSetMessagingTimeout(element, 0.04)
            let role = value(element, kAXRoleAttribute, deadline: deadline) as? String
            guard let children = value(element, kAXChildrenAttribute, deadline: deadline) as? [AXUIElement] else { continue }
            if role == "AXList", let listFrame = frame(element, deadline: deadline) {
                var items: [NativeDockAXItem] = []
                var complete = children.count <= 128
                for child in children.prefix(128) {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { complete = false; break }
                    AXUIElementSetMessagingTimeout(child, 0.04)
                    guard let subrole = value(child, kAXSubroleAttribute, deadline: deadline) as? String,
                          let itemFrame = frame(child, deadline: deadline) else { complete = false; continue }
                    let kind: NativeDockAXItem.Kind = subrole == "AXApplicationDockItem" ? .application
                        : (subrole == "AXSeparatorDockItem" ? .separator : .other)
                    items.append(.init(kind: kind, frame: itemFrame))
                }
                let snapshot = NativeDockAXSnapshot(frame: listFrame, items: items, isComplete: complete)
                if let observed = NativeDockMetricsParser.measured(preferences: preferences, snapshot: snapshot) {
                    return .init(preferences: preferences, observed: observed)
                }
            } else if depth < 3 {
                queue.append(contentsOf: children.prefix(32).map { ($0, depth + 1) })
            }
        }
        return .init(preferences: preferences, observed: nil)
    }

    private static func preferences() -> NativeDockPreferences? {
        let domain = "com.apple.dock" as CFString
        func read(_ key: String) -> CFPropertyList? {
            CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        func number(_ key: String) -> Double? {
            guard let raw = read(key), CFGetTypeID(raw) != CFBooleanGetTypeID() else { return nil }
            return (raw as? NSNumber)?.doubleValue
        }
        let rawMagnification = read("magnification")
        let magnification: Bool?
        if let number = rawMagnification as? NSNumber, number.doubleValue == 0 || number.doubleValue == 1 {
            magnification = number.boolValue
        } else { magnification = nil }
        let orientation = read("orientation") as? String
        let axis: NativeDockAxis? = orientation == "bottom" ? .horizontal
            : (["left", "right"].contains(orientation ?? "") ? .vertical : nil)
        let value = NativeDockPreferences(iconSize: number("tilesize"), magnifiedIconSize: number("largesize"),
                                          magnificationEnabled: magnification, axis: axis)
        return value.hasKnownValues ? value : nil
    }

    private static func value(_ element: AXUIElement, _ key: String, deadline: TimeInterval) -> CFTypeRef? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
    }

    private static func frame(_ element: AXUIElement, deadline: TimeInterval) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute, deadline: deadline),
              let size = value(element, kAXSizeAttribute, deadline: deadline),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
