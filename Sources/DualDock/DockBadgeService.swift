import AppKit
import ApplicationServices
import Darwin
import DualDockCore

enum DockBadgeStatus: Equatable, Sendable {
    case disabled
    case available
    case permissionRequired
    case unavailable
}

struct DockBadgeApplication: Sendable {
    let bundleID: String
    let processID: pid_t
}

struct DockBadgeReadInput: Sendable {
    let applications: [DockBadgeApplication]
    let dockProcessID: pid_t?
    let accessibilityTrusted: Bool
}

struct DockBadgeReadResult: Equatable, Sendable {
    let labels: [String: String]
    let status: DockBadgeStatus
}

/// Reads status labels without blocking the main-thread magnification animation.
/// Initialization is inert; the appearance setting explicitly starts polling.
@MainActor
final class DockBadgeService {
    typealias Reader = @Sendable (DockBadgeReadInput) -> DockBadgeReadResult
    var onUpdate: (([String: String], DockBadgeStatus) -> Void)?

    private let queue = DispatchQueue(label: "local.ronny.DualDock.badges", qos: .utility)
    private let reader: Reader
    private let inputProvider: () -> DockBadgeReadInput
    private var timer: Timer?
    private var enabled = false
    private var generation: UInt64 = 0
    private var reading = false
    private var refreshPending = false
    private var lastResult: DockBadgeReadResult?

    convenience init() {
        let native = NativeDockBadgeReader()
        self.init(reader: { native.read($0) }, inputProvider: Self.currentInput)
    }

    init(reader: @escaping Reader, inputProvider: @escaping () -> DockBadgeReadInput) {
        self.reader = reader
        self.inputProvider = inputProvider
    }

    deinit { timer?.invalidate() }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else {
            if !enabled { publish(DockBadgeReadResult(labels: [:], status: .disabled)) }
            return
        }
        self.enabled = enabled
        generation &+= 1
        timer?.invalidate()
        timer = nil
        refreshPending = false
        guard enabled else {
            publish(DockBadgeReadResult(labels: [:], status: .disabled))
            return
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
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
                if self.generation == requestGeneration {
                    self.publish(result)
                } else {
                    self.refreshPending = true
                }
                if self.refreshPending { self.refresh() }
            }
        }
    }

    func stop() { setEnabled(false) }

    private func publish(_ result: DockBadgeReadResult) {
        guard result != lastResult else { return }
        lastResult = result
        onUpdate?(result.labels, result.status)
    }

    private static func currentInput() -> DockBadgeReadInput {
        let applications = NSWorkspace.shared.runningApplications.compactMap { app -> DockBadgeApplication? in
            guard app.activationPolicy == .regular, !app.isTerminated,
                  app.processIdentifier != getpid(), let id = app.bundleIdentifier,
                  id != "com.apple.dock" else { return nil }
            return DockBadgeApplication(bundleID: id, processID: app.processIdentifier)
        }
        let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first { !$0.isTerminated }
        return DockBadgeReadInput(applications: applications, dockProcessID: dock?.processIdentifier,
                                 accessibilityTrusted: AXIsProcessTrusted())
    }
}

/// Only immutable function pointers are shared; each service serializes reads.
/// LaunchServices survives a system Dock restart, whereas its AX labels may lag.
private final class NativeDockBadgeReader: @unchecked Sendable {
    private typealias CreateASN = @convention(c) (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?
    private typealias CopyInformation = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private enum LabelLookup {
        case reported(String?)
        case unreported
        case unavailable
    }

    private let handle: UnsafeMutableRawPointer?
    private let createASN: CreateASN?
    private let copyInformation: CopyInformation?

    init() {
        let handle = dlopen(nil, RTLD_LAZY)
        self.handle = handle
        if let handle {
            createASN = dlsym(handle, "_LSASNCreateWithPid").map { unsafeBitCast($0, to: CreateASN.self) }
            copyInformation = dlsym(handle, "_LSCopyApplicationInformationItem").map { unsafeBitCast($0, to: CopyInformation.self) }
        } else {
            createASN = nil
            copyInformation = nil
        }
    }

    deinit { if let handle { dlclose(handle) } }

    func read(_ input: DockBadgeReadInput) -> DockBadgeReadResult {
        var labels: [String: String] = [:]
        var fallbackIDs: Set<String> = []
        var launchServicesResponded = false
        let groups = Dictionary(grouping: input.applications, by: \.bundleID)
        for (bundleID, applications) in groups {
            var reported: Set<String> = []
            var hasReport = false
            for application in applications {
                switch statusLabel(processID: application.processID) {
                case .reported(let label):
                    launchServicesResponded = true
                    hasReport = true
                    reported.insert(label ?? "")
                case .unreported:
                    launchServicesResponded = true
                case .unavailable:
                    break
                }
            }
            if hasReport, reported.count == 1 {
                if let label = reported.first, !label.isEmpty { labels[bundleID] = label }
            } else {
                // Conflicting instances need the Dock's actual merged label;
                // summing or choosing the largest would invent a badge count.
                fallbackIDs.insert(bundleID)
            }
        }

        var dockResponded = false
        if !fallbackIDs.isEmpty, input.accessibilityTrusted, let dockPID = input.dockProcessID {
            let fallback = accessibilityLabels(processID: dockPID, wantedIDs: fallbackIDs)
            dockResponded = fallback.responded
            for (id, label) in fallback.labels { labels[id] = label }
        }
        let status: DockBadgeStatus
        if launchServicesResponded || dockResponded || input.applications.isEmpty {
            status = .available
        } else if !input.accessibilityTrusted {
            status = .permissionRequired
        } else {
            status = .unavailable
        }
        return DockBadgeReadResult(labels: labels, status: status)
    }

    private func statusLabel(processID: pid_t) -> LabelLookup {
        guard let createASN, let copyInformation,
              let asn = createASN(kCFAllocatorDefault, processID)?.takeRetainedValue() else { return .unavailable }
        guard let raw = copyInformation(-2, asn, "StatusLabel" as CFString)?.takeRetainedValue() else { return .unreported }
        guard let dictionary = raw as? [String: Any] else { return .unavailable }
        guard let value = dictionary["label"] else { return .unreported }
        if let label = value as? String { return .reported(BadgeDisplayPolicy.normalizedLabel(label)) }
        return .unreported
    }

    private func accessibilityLabels(processID: pid_t, wantedIDs: Set<String>) -> (labels: [String: String], responded: Bool) {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        let root = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(root, 0.05)
        guard let children = value(root, kAXChildrenAttribute, deadline: deadline) as? [AXUIElement] else { return ([:], false) }
        var queue = children.map { ($0, 1) }
        var index = 0
        var labels: [String: String] = [:]
        var confirmedItems = 0
        while index < queue.count && index < 500 && ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth) = queue[index]
            index += 1
            AXUIElementSetMessagingTimeout(element, 0.05)
            if value(element, kAXRoleAttribute, deadline: deadline) as? String == "AXDockItem",
               let url = applicationURL(value(element, kAXURLAttribute, deadline: deadline)),
               let id = Bundle(url: url)?.bundleIdentifier, wantedIDs.contains(id) {
                let status = accessibilityStatusLabel(element, deadline: deadline)
                if status.confirmed {
                    confirmedItems += 1
                    if let label = status.label { labels[id] = label }
                }
            }
            if depth < 6, let children = value(element, kAXChildrenAttribute, deadline: deadline) as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return (labels, confirmedItems > 0)
    }

    private func value(_ element: AXUIElement, _ attribute: String, deadline: TimeInterval) -> CFTypeRef? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    private func accessibilityStatusLabel(_ element: AXUIElement, deadline: TimeInterval) -> (label: String?, confirmed: Bool) {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return (nil, false) }
        var result: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, "AXStatusLabel" as CFString, &result)
        if status == .success, let label = result as? String {
            return (BadgeDisplayPolicy.normalizedLabel(label), true)
        }
        return (nil, status == .noValue)
    }

    private func applicationURL(_ raw: CFTypeRef?) -> URL? {
        let url = (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:))
        guard let url, url.isFileURL else { return nil }
        let resolved = (try? URL(resolvingAliasFileAt: url)) ?? url
        return resolved.pathExtension.lowercased() == "app" ? resolved : nil
    }
}
