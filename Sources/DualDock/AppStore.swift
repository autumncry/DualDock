import AppKit
import ApplicationServices
import UniformTypeIdentifiers
import CryptoKit
import Combine
import DualDockCore

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var configuration: DockConfiguration
    @Published private(set) var sizingLimits: DockSizingLimits = .fallback
    @Published private(set) var runningApps: [AppReference] = []
    @Published private(set) var badgeLabels: [String: String] = [:]
    @Published private(set) var badgeStatus: DockBadgeStatus = .disabled
    @Published var message: String?
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var captureGranted = CGPreflightScreenCaptureAccess()
    let systemDock: SystemDockService
    let windows = WindowService()
    private let badgeService = DockBadgeService()
    let directory: URL
    private let configURL: URL
    private var observers: [NSObjectProtocol] = []
    private var icons: [String: NSImage] = [:]
    private var readOnly = false
    private var initialSetupComplete = false

    init(directory: URL) {
        self.directory = directory
        configURL = directory.appendingPathComponent("configuration.json")
        systemDock = SystemDockService(directory: directory)
        var initial = DockConfiguration()
        var issue: String?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: configURL.path) {
                let originalData = try Data(contentsOf: configURL)
                initial = try JSONDecoder().decode(DockConfiguration.self, from: originalData)
                if let raw = try JSONSerialization.jsonObject(with: originalData) as? [String: Any],
                   (raw["version"] as? Int ?? 1) < DockConfiguration.currentVersion {
                    let backup = directory.appendingPathComponent("configuration-before-v\(DockConfiguration.currentVersion).json")
                    if !FileManager.default.fileExists(atPath: backup.path) {
                        try originalData.write(to: backup, options: .atomic)
                    }
                }
                if initial.version > DockConfiguration.currentVersion {
                    readOnly = true
                    issue = "配置来自较新的 DualDock，当前版本以只读方式打开。"
                }
            } else {
                initial.insert(SystemDockService.importPinnedApps())
            }
        } catch {
            readOnly = true
            issue = "无法读取配置，原文件已保留。请打开配置目录检查。\n\(error.localizedDescription)"
        }
        initial.normalizeAppearance()
        configuration = initial
        message = issue
        do {
            try systemDock.recoverIfNeeded()
            if initial.hideSystemDock && !readOnly { try systemDock.setHidden(true) }
        } catch { message = "系统 Dock 恢复失败：\(error.localizedDescription)" }
        refreshRunningApps()
        updateDisplayLimits(screenSizes: NSScreen.screens.map { $0.frame.size })
        badgeService.onUpdate = { [weak self] labels, status in
            guard let self else { return }
            if self.badgeLabels != labels { self.badgeLabels = labels }
            if self.badgeStatus != status { self.badgeStatus = status }
        }
        badgeService.setEnabled(configuration.showBadges)
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshRunningApps() }
            })
        }
        initialSetupComplete = true
        save()
    }

    var displayedEntries: [DockEntry] {
        let active = configuration.mode == .runningOnly ? runningApps : runningApps.filter { !configuration.allAppIDs.contains($0.id) }
        let activeEntries = active.map { app in
            DockEntry(id: stableUUID(app.id), name: app.name, apps: [app])
        }
        return configuration.mode == .runningOnly ? activeEntries : configuration.entries + activeEntries
    }

    var pinnedCount: Int { configuration.mode == .standard ? configuration.entries.count : 0 }

    var effectiveIconSize: Double { sizingLimits.clampIconSize(configuration.iconSize) }
    var effectiveDockHeight: Double { sizingLimits.height(forIconSize: configuration.iconSize) }
    var effectiveDockWidth: Double {
        guard configuration.autoAdjustWidth else {
            return sizingLimits.clampWidth(configuration.dockWidth ?? sizingLimits.maxWidth)
        }
        let count = displayedEntries.count
        let divider = pinnedCount > 0 && pinnedCount < count ? pinnedCount : nil
        // Compute once for the current row, not for individual hover frames.
        // The saved manual width remains available when automatic mode ends.
        let automatic = DockWaveLayout.make(count: count, iconSize: CGFloat(effectiveIconSize),
            spacing: CGFloat(configuration.iconSpacing),
            magnificationScale: configuration.magnificationEnabled ? CGFloat(configuration.magnificationScale) : 1,
            focusIndex: nil, maxWidth: CGFloat(sizingLimits.maxWidth), hasControls: false,
            dividerIndex: divider, widthReferenceSpacing: CGFloat(configuration.dockWidthReferenceSpacing))
        return sizingLimits.clampWidth(Double(ceil(automatic.panelSize.width)))
    }

    func updateDisplayLimits(screenSizes: [CGSize]) {
        // A temporary empty screen list must not discard the last useful range
        // or write a transient display constraint into the user's preferences.
        guard let next = DockSizingLimits(screenSizes: screenSizes) else { return }
        if next != sizingLimits { sizingLimits = next }
        // Resolve legacy width only against a real display snapshot, never the
        // startup fallback. An empty-screen launch must not shrink preferences.
        if initializeDockWidthIfNeeded(), initialSetupComplete { save() }
    }

    @discardableResult
    private func initializeDockWidthIfNeeded() -> Bool {
        guard configuration.dockWidth == nil else { return false }
        let count = displayedEntries.count
        let divider = pinnedCount > 0 && pinnedCount < count ? pinnedCount : nil
        // Reconstruct the pre-independent-width layout once, including live
        // unpinned apps. Subsequent height/spacing/count changes keep this width.
        let legacy = DockWaveLayout.make(count: count, iconSize: CGFloat(min(96, configuration.iconSize)),
            spacing: CGFloat(configuration.iconSpacing),
            magnificationScale: configuration.magnificationEnabled ? CGFloat(configuration.magnificationScale) : 1,
            focusIndex: nil, maxWidth: CGFloat(max(1, sizingLimits.maxWidth - 32)), hasControls: false,
            dividerIndex: divider, widthReferenceSpacing: CGFloat(configuration.dockWidthReferenceSpacing))
        configuration.dockWidth = sizingLimits.clampWidth(Double(ceil(legacy.panelSize.width)))
        return true
    }

    func update(_ change: (inout DockConfiguration) -> Void) {
        guard !readOnly else { message = "配置目前为只读，请先检查配置文件。"; return }
        var next = configuration
        change(&next)
        next.normalizeAppearance()
        guard next != configuration else { return }
        configuration = next
        badgeService.setEnabled(next.showBadges)
        save()
    }

    func badgeLabel(for entry: DockEntry) -> String? {
        BadgeDisplayPolicy.label(for: entry, labels: badgeLabels, enabled: configuration.showBadges)
    }

    func stopBackgroundServices() {
        badgeService.stop()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    func setSystemDockHidden(_ hidden: Bool) {
        guard !readOnly else { return }
        do {
            try systemDock.setHidden(hidden)
            update { $0.hideSystemDock = hidden }
        } catch { message = "无法更改系统 Dock：\(error.localizedDescription)" }
    }

    func restoreSystemDock() {
        do {
            try systemDock.restore()
            if !readOnly { update { $0.hideSystemDock = false } }
        } catch { message = "系统 Dock 恢复失败：\(error.localizedDescription)" }
    }

    func importPins() {
        let apps = SystemDockService.importPinnedApps()
        guard !apps.isEmpty else { message = "系统 Dock 中没有读到可导入的固定应用。"; return }
        update { $0.insert(apps) }
        message = "已补入系统 Dock 中尚未固定的应用，现有分组和顺序已保留。"
    }

    func addApplications() {
        let panel = NSOpenPanel()
        panel.title = "添加应用到 DualDock"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            update { $0.insert(panel.urls.compactMap(Self.reference)) }
        }
    }

    static func reference(_ url: URL) -> AppReference? {
        let target = (try? URL(resolvingAliasFileAt: url)) ?? url
        guard target.pathExtension.lowercased() == "app", let bundle = Bundle(url: target) else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? target.deletingPathExtension().lastPathComponent
        return AppReference(id: bundle.bundleIdentifier ?? target.path, name: name, path: target.path)
    }

    func icon(for app: AppReference) -> NSImage {
        if let image = icons[app.id] { return image }
        let image = NSWorkspace.shared.icon(forFile: resolvedURL(app).path)
        icons[app.id] = image
        return image
    }

    func isRunning(_ app: AppReference) -> Bool { runningApps.contains { $0.id == app.id } }

    func launch(_ app: AppReference) {
        let url = resolvedURL(app)
        guard FileManager.default.fileExists(atPath: url.path) else { message = "找不到 \(app.name)，请重新添加该应用。"; return }
        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: options) { [weak self] _, error in
            if let error { Task { @MainActor in self?.message = error.localizedDescription } }
        }
    }

    func quit(_ app: AppReference) {
        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == app.id || $0.bundleURL?.path == app.path }.forEach { $0.terminate() }
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        refreshPermissions()
    }

    func requestCapture() {
        _ = CGRequestScreenCaptureAccess()
        refreshPermissions()
    }

    func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        captureGranted = CGPreflightScreenCaptureAccess()
        badgeService.refresh()
    }

    func revealConfiguration() { NSWorkspace.shared.open(directory) }

    private func resolvedURL(_ app: AppReference) -> URL {
        if FileManager.default.fileExists(atPath: app.path) { return URL(fileURLWithPath: app.path) }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id) ?? URL(fileURLWithPath: app.path)
    }

    private func refreshRunningApps() {
        let found = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != getpid() && $0.bundleIdentifier != "com.apple.dock"
        }.compactMap { app -> AppReference? in
            guard let url = app.bundleURL else { return nil }
            return AppReference(id: app.bundleIdentifier ?? url.path, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent, path: url.path)
        }
        var unique: [AppReference] = []
        for app in found where !unique.contains(where: { $0.id == app.id }) { unique.append(app) }
        let ordered = runningApps.compactMap { old in unique.first { $0.id == old.id } }
            + unique.filter { new in !runningApps.contains { $0.id == new.id } }
        if ordered != runningApps { runningApps = ordered }
    }

    private func save() {
        guard !readOnly else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: configURL, options: .atomic)
        } catch { message = "配置保存失败：\(error.localizedDescription)" }
    }

    private func stableUUID(_ value: String) -> UUID {
        // Running tiles keep identity across refreshes without touching the saved layout.
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}
