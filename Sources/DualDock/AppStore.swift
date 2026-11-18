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
    @Published private(set) var displays: [DockDisplayInfo] = []
    @Published private(set) var nativeDockMetrics: NativeDockMetrics = .fallback
    @Published private(set) var nativeDockStatus: NativeDockMetricsStatus = .fallback
    @Published private(set) var resizeRevision: UInt64 = 0
    @Published private(set) var runningApps: [AppReference] = []
    @Published private(set) var badgeLabels: [String: String] = [:]
    @Published private(set) var badgeStatus: DockBadgeStatus = .disabled
    @Published var notice: LocalizedNotice?
    var message: String? {
        get { notice?.text }
        set { notice = newValue.map { LocalizedNotice(verbatim: $0) } }
    }
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var captureGranted = CGPreflightScreenCaptureAccess()
    let systemDock: SystemDockService
    let windows = WindowService()
    private let badgeService: DockBadgeService
    private let nativeMetricsService = NativeDockMetricsService()
    private let activationService = ApplicationActivationService()
    let directory: URL
    private let configURL: URL
    private let runningAppsProvider: (() -> [AppReference])?
    private let permissionsProvider: (() -> (accessibility: Bool, capture: Bool))?
    private var observers: [NSObjectProtocol] = []
    private var icons: [String: NSImage] = [:]
    private var artworkBounds: [String: CGRect] = [:]
    private var readOnly = false
    private var initialSetupComplete = false
    private var pendingSave: Task<Void, Never>?
    private struct ResizePreview: Equatable {
        let displayID: String?
        let originalSizing: DockManualSizing
        let sizing: DockManualSizing
    }
    private var resizePreview: ResizePreview?

    init(directory: URL,
         runningAppsProvider: (() -> [AppReference])? = nil,
         permissionsProvider: (() -> (accessibility: Bool, capture: Bool))? = nil,
         badgeService: DockBadgeService? = nil) {
        self.badgeService = badgeService ?? DockBadgeService()
        self.directory = directory
        self.runningAppsProvider = runningAppsProvider
        self.permissionsProvider = permissionsProvider
        configURL = directory.appendingPathComponent("configuration.json")
        systemDock = SystemDockService(directory: directory)
        var initial = DockConfiguration()
        var issue: LocalizedNotice?
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
                    issue = LocalizedNotice("配置来自较新的 DualDock，当前版本以只读方式打开。", "This configuration was saved by a newer version of DualDock and is open in read-only mode.")
                }
            } else {
                initial.insert(SystemDockService.importPinnedApps())
                initial.customSizing = .visualDefault
            }
        } catch {
            readOnly = true
            issue = LocalizedNotice("无法读取配置，原文件已保留。请打开配置目录检查。", "Could not read the configuration. Open the configuration folder to inspect the original file.").appending(.init(verbatim: error.localizedDescription), separator: "\n")
        }
        initial.normalizeAppearance()
        configuration = initial
        if let permissions = permissionsProvider?() {
            accessibilityGranted = permissions.accessibility
            captureGranted = permissions.capture
        }
        notice = issue
        do {
            try systemDock.recoverIfNeeded()
            if initial.hideSystemDock && !readOnly { try systemDock.setHidden(true) }
        } catch { notice = LocalizedNotice("系统 Dock 恢复失败", "Could not restore the system Dock").appending(SystemDockService.ServiceError.notice(for: error)) }
        refreshRunningApps()
        updateDisplays(DockDisplayInfo.current())
        nativeMetricsService.onUpdate = { [weak self] metrics, status in
            guard let self else { return }
            if self.nativeDockMetrics != metrics { self.nativeDockMetrics = metrics }
            if self.nativeDockStatus != status { self.nativeDockStatus = status }
        }
        self.badgeService.onUpdate = { [weak self] labels, status in
            guard let self else { return }
            if self.badgeLabels != labels { self.badgeLabels = labels }
            if self.badgeStatus != status { self.badgeStatus = status }
        }
        self.badgeService.setEnabled(configuration.showBadges)
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshRunningApps() }
            })
        }
        initialSetupComplete = true
        save()
        nativeMetricsService.start()
    }

    var displayedEntries: [DockEntry] {
        var known = configuration.mode == .runningOnly ? Set<String>() : configuration.allAppIDs
        let active = runningApps.filter { known.insert($0.id).inserted }
        let activeEntries = active.map { app in
            DockEntry(id: stableUUID(app.id), name: app.name, apps: [app])
        }
        return configuration.mode == .runningOnly ? activeEntries : configuration.entries + activeEntries
    }

    var pinnedCount: Int { configuration.mode == .standard ? configuration.entries.count : 0 }

    private var displayedEntryCount: Int {
        let activeIDs = Set(runningApps.map(\.id))
        return configuration.mode == .runningOnly ? activeIDs.count
            : configuration.entries.count + activeIDs.subtracting(configuration.allAppIDs).count
    }

    private var activeDisplays: [DockDisplayInfo] { displays.filter { !$0.isMirrored } }
    private var primaryDisplayID: String? {
        activeDisplays.first(where: \.isPrimary)?.id ?? activeDisplays.first?.id
    }

    var effectiveIconSize: Double { iconSize(for: nil) }
    var effectiveDockHeight: Double { Double(presentation(for: nil).style.barThickness) }
    var effectiveDockWidth: Double {
        let view = presentation(for: nil)
        let count = displayedEntries.count
        let divider = pinnedCount > 0 && pinnedCount < count ? pinnedCount : nil
        return Double(DockGeometry.make(count: count, edge: view.edge, style: view.style,
            maximumLength: view.maximumLength, fixedLength: view.fixedLength, dividerIndex: divider,
            resizeMargin: view.resizeMargin).bodyLength)
    }

    /// Compatibility for point-size tests and old callers. Runtime code should
    /// pass stable display snapshots to updateDisplays instead.
    func updateDisplayLimits(screenSizes: [CGSize]) {
        guard !screenSizes.isEmpty else { return }
        let snapshots = screenSizes.enumerated().map { index, size in
            let frame = CGRect(origin: .zero, size: size)
            return DockDisplayInfo(id: "size-snapshot-\(index)", runtimeID: UInt32(index + 1),
                name: "Display \(index + 1)", frame: frame, visibleFrame: frame, isPrimary: index == 0)
        }
        updateDisplays(snapshots)
    }

    func updateDisplays(_ snapshots: [DockDisplayInfo]) {
        let valid = snapshots.filter { Self.validDisplayFrame($0.frame) && Self.validDisplayFrame($0.visibleFrame) }
        if valid != displays {
            displays = valid
            cancelResizePreview()
        }
        // Empty transition snapshots remove the UI rows but retain the last
        // valid sizing limits and leave a pending width migration unresolved.
        guard let next = DockSizingLimits(screenSizes: valid.map { $0.frame.size }) else { return }
        if next != sizingLimits { sizingLimits = next }
        let migratedWidth = initializeDockWidthIfNeeded()
        let initializedPadding = initializeContentPaddingIfNeeded()
        if (migratedWidth || initializedPadding), initialSetupComplete { save() }
    }

    private static func validDisplayFrame(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite && frame.maxX.isFinite && frame.maxY.isFinite
            && frame.width > 0 && frame.height > 0
    }

    private func resolvedDisplayID(_ displayID: String?) -> String? {
        if let displayID, activeDisplays.contains(where: { $0.id == displayID }) { return displayID }
        return primaryDisplayID
    }

    private func isEditableDisplayReference(_ displayID: String?) -> Bool {
        guard let displayID else { return true }
        return activeDisplays.contains { $0.id == displayID }
    }

    private var sharedManualSizing: DockManualSizing {
        let base = configuration.iconSize.isFinite ? configuration.iconSize : 48
        return DockManualSizing(length: configuration.dockWidth ?? sizingLimits.maxWidth,
            thickness: manualThickness(for: base),
            iconScale: configuration.manualIconScale, iconSpacing: configuration.iconSpacing,
            contentPadding: configuration.manualContentPadding)
    }

    private func manualThickness(for iconSize: Double) -> Double {
        let value = iconSize * DockSizingLimits.heightPerIconPoint
        return value.isFinite ? value : Double.greatestFiniteMagnitude
    }

    func requestedManualSizing(for displayID: String?) -> DockManualSizing {
        let id = resolvedDisplayID(displayID)
        if let sizing = resolvedCustomSizing(for: id) { return sizing.manualSizing }
        if let preview = resizePreview,
           configuration.synchronizeSizes || preview.displayID == id { return preview.sizing }
        return contentFittedSizing(storedManualSizing(for: id), for: id)
    }

    private func storedManualSizing(for displayID: String?) -> DockManualSizing {
        let id = resolvedDisplayID(displayID)
        if !configuration.synchronizeSizes, let id,
           let sizing = configuration.displaySettings[id]?.manualSizing { return sizing }
        return sharedManualSizing
    }

    private func contentSpan(for sizing: DockManualSizing, displayID: String?) -> Double {
        let effective = sizingBounds(for: displayID).clamp(sizing)
        let icon = effective.resolvedIconSize
        let count = displayedEntryCount
        return DockContentLengthPolicy.contentSpan(count: count, iconSize: icon,
            gap: effective.iconSpacing * icon / 48, separatorLength: 13 * icon / 48,
            dividerIndex: pinnedCount > 0 && pinnedCount < count ? pinnedCount : nil)
    }

    private func contentFittedSizing(_ sizing: DockManualSizing, for displayID: String?) -> DockManualSizing {
        guard configuration.manualAutoLength else { return sizing }
        var result = sizing
        result.length = DockContentLengthPolicy.desiredLength(
            contentSpan: contentSpan(for: sizing, displayID: displayID), padding: sizing.contentPadding)
        return result
    }

    /// A disconnected display's manual profile cannot be bounded until that
    /// screen returns. Capture its original padding once at that point rather
    /// than silently falling back to another screen's whitespace.
    private func initializeContentPaddingIfNeeded() -> Bool {
        guard configuration.manualAutoLength, configuration.customSizing == nil,
              !readOnly, !activeDisplays.isEmpty else { return false }
        var next = configuration
        if configuration.synchronizeSizes {
            guard configuration.manualContentPadding == nil else { return false }
            var shared = sharedManualSizing
            let effective = sizingBounds(for: nil).clamp(shared)
            shared.contentPadding = DockContentLengthPolicy.capturedPadding(length: effective.length,
                contentSpan: contentSpan(for: effective, displayID: nil))
            assignSharedSizing(shared, to: &next)
            copySizing(shared, to: knownDisplayIDs(in: next), configuration: &next)
        } else {
            for display in activeDisplays {
                guard storedCustomSizing(for: display.id) == nil else { continue }
                let stored = storedManualSizing(for: display.id)
                guard stored.contentPadding == nil else { continue }
                var sizing = stored
                let effective = sizingBounds(for: display.id).clamp(sizing)
                sizing.contentPadding = DockContentLengthPolicy.capturedPadding(length: effective.length,
                    contentSpan: contentSpan(for: effective, displayID: display.id))
                var profile = next.displaySettings[display.id] ?? DockDisplaySettings()
                profile.manualSizing = sizing
                next.displaySettings[display.id] = profile
            }
        }
        guard next != configuration else { return false }
        configuration = next
        return true
    }

    func effectiveManualSizing(for displayID: String?) -> DockManualSizing {
        if let sizing = resolvedCustomSizing(for: displayID) { return sizing.manualSizing }
        let requested = requestedManualSizing(for: displayID)
        let bounds = sizingBounds(for: displayID)
        var effective = bounds.clamp(requested)
        if configuration.manualAutoLength {
            // The manual handle's minimum is a convenient resize target, not a
            // minimum content length. Fewer items must retain the same margins.
            effective.length = min(bounds.maxLength, max(1, requested.length))
        }
        return effective
    }

    func sizingBounds(for displayID: String?) -> DockResizeBounds {
        let selected = resolvedDisplayID(displayID)
        let candidates: [DockDisplayInfo]
        if configuration.synchronizeSizes { candidates = activeDisplays }
        else { candidates = activeDisplays.filter { $0.id == selected } }
        let maxLength = candidates.map { display -> Double in
            let edge = edge(for: display.id)
            return Double(edge.isHorizontal ? display.visibleFrame.width : display.visibleFrame.height)
        }.min() ?? sizingLimits.maxWidth
        let maxThickness = candidates.map { Double(min($0.visibleFrame.width, $0.visibleFrame.height)) * 0.12 }.min()
            ?? sizingLimits.maxHeight
        let largest = DockManualSizing(length: maxLength, thickness: maxThickness, iconScale: 1.25).resolvedIconSize
        return DockResizeBounds(minLength: min(maxLength, max(120, largest + 12)), maxLength: maxLength,
                                minThickness: min(33, maxThickness), maxThickness: maxThickness)
    }

    func customSizingBounds(for displayID: String?) -> DockResizeBounds {
        let bounds = sizingBounds(for: displayID)
        let height = resolvedCustomSizing(for: displayID)?.thickness ?? effectiveManualSizing(for: displayID).thickness
        return DockResizeBounds(minLength: 1, maxLength: bounds.maxLength,
            minThickness: min(16, height), maxThickness: bounds.maxThickness)
    }

    /// Length controls cannot request less than the current row plus minimal
    /// padding. Proportional corner resizing keeps the ordinary bounds because
    /// the icon row itself changes length as its thickness is scaled.
    func editingSizingBounds(for displayID: String?) -> DockResizeBounds {
        let bounds = sizingBounds(for: displayID)
        if let custom = storedCustomSizing(for: displayID), custom.lengthMode == .fit,
           let effective = resolvedCustomSizing(for: displayID) {
            let span: Double
            if let percent = custom.spacingPercent {
                span = DockOpticalSpacingPolicy.contentSpan(count: displayedEntryCount, iconSize: effective.iconSize,
                    spacingPercent: percent, contentBounds: contentBounds(for: displayedEntries),
                    edge: resolvedDisplayID(displayID).map { edge(for: $0) } ?? .bottom,
                    separatorLength: effective.separatorLength, dividerIndex: sizingDividerIndex)
            } else {
                span = DockContentLengthPolicy.contentSpan(count: displayedEntryCount,
                    iconSize: effective.iconSize, gap: effective.gap, separatorLength: effective.separatorLength,
                    dividerIndex: sizingDividerIndex)
            }
            let required = span + 2 * min(2, effective.padding)
            return DockResizeBounds(minLength: min(bounds.maxLength, required), maxLength: bounds.maxLength,
                minThickness: bounds.minThickness, maxThickness: bounds.maxThickness)
        }
        guard configuration.manualAutoLength, !configuration.adaptiveSizing else { return bounds }
        let required = contentSpan(for: requestedManualSizing(for: displayID), displayID: displayID)
            + 2 * DockContentLengthPolicy.minimumPadding
        return DockResizeBounds(minLength: min(bounds.maxLength, required), maxLength: bounds.maxLength,
            minThickness: bounds.minThickness, maxThickness: bounds.maxThickness)
    }

    func iconSize(for displayID: String?) -> Double {
        configuration.adaptiveSizing ? nativeDockMetrics.iconSize : effectiveManualSizing(for: displayID).resolvedIconSize
    }

    func edge(for displayID: String) -> DockEdge {
        configuration.displaySettings[displayID]?.edge ?? .bottom
    }

    func setEdge(_ edge: DockEdge, for displayID: String) {
        guard isEditableDisplayReference(displayID) else { return }
        update {
            var settings = $0.displaySettings[displayID] ?? DockDisplaySettings()
            settings.edge = edge
            $0.displaySettings[displayID] = settings
        }
    }

    func setAdaptiveSizing(_ value: Bool) {
        update { $0.adaptiveSizing = value }
        if value { nativeMetricsService.refresh() }
    }

    func setManualAutoLength(_ value: Bool, sourceDisplayID: String?) {
        if storedCustomSizing(for: sourceDisplayID) != nil {
            updateCustomSizing(for: sourceDisplayID) { $0.lengthMode = value ? .fit : .fixed }
            return
        }
        guard !configuration.adaptiveSizing, configuration.manualAutoLength != value,
              isEditableDisplayReference(sourceDisplayID) else { return }
        cancelResizePreview()
        var captured: [String: DockManualSizing] = [:]
        var shared = sharedManualSizing
        if value {
            let source = resolvedDisplayID(sourceDisplayID)
            let visible = effectiveManualSizing(for: source)
            shared.contentPadding = DockContentLengthPolicy.capturedPadding(length: visible.length,
                contentSpan: contentSpan(for: visible, displayID: source))
            for display in activeDisplays {
                var saved = storedManualSizing(for: display.id)
                let effective = effectiveManualSizing(for: display.id)
                saved.contentPadding = configuration.synchronizeSizes ? shared.contentPadding
                    : DockContentLengthPolicy.capturedPadding(length: effective.length,
                        contentSpan: contentSpan(for: effective, displayID: display.id))
                captured[display.id] = saved
            }
        }
        update { next in
            next.manualAutoLength = value
            if value {
                next.manualContentPadding = shared.contentPadding
                if next.synchronizeSizes {
                    self.copySizing(shared, to: self.knownDisplayIDs(in: next), configuration: &next)
                } else {
                    // A fresh enable captures the current manual layout, not a
                    // previous session's padding. Offline profiles defer that
                    // capture until their own bounds are available again.
                    for id in next.displaySettings.keys where captured[id] == nil {
                        next.displaySettings[id]?.manualSizing?.contentPadding = nil
                    }
                    for (id, sizing) in captured {
                        var profile = next.displaySettings[id] ?? DockDisplaySettings()
                        profile.manualSizing = sizing
                        next.displaySettings[id] = profile
                    }
                }
            }
        }
    }

    func setSizeSynchronization(_ value: Bool, sourceDisplayID: String?) {
        guard !configuration.adaptiveSizing, configuration.synchronizeSizes != value,
              isEditableDisplayReference(sourceDisplayID) else { return }
        cancelResizePreview()
        if configuration.customSizing != nil || configuration.displaySettings.values.contains(where: { $0.customSizing != nil }) {
            let current = customSizing(for: sourceDisplayID)
            update { next in
                next.synchronizeSizes = value
                if value { next.customSizing = current }
                let ids = value ? self.knownDisplayIDs(in: next) : Set(self.activeDisplays.map(\.id))
                for id in ids {
                    var settings = next.displaySettings[id] ?? DockDisplaySettings()
                    settings.customSizing = current
                    next.displaySettings[id] = settings
                }
            }
            return
        }
        var current = effectiveManualSizing(for: sourceDisplayID)
        if configuration.manualAutoLength {
            // Switching synchronization must not replace the fixed-width backup
            // with the currently content-derived width.
            current.length = storedManualSizing(for: sourceDisplayID).length
        }
        update { next in
            next.synchronizeSizes = value
            if value {
                self.assignSharedSizing(current, to: &next)
                self.copySizing(current, to: self.knownDisplayIDs(in: next), configuration: &next)
            } else {
                // Disconnected historical profiles remain stored, but connected
                // screens begin from what was actually visible before unlocking.
                self.copySizing(current, to: Set(self.activeDisplays.map(\.id)), configuration: &next)
            }
        }
    }

    func updateManualSizing(for displayID: String?, _ change: (inout DockManualSizing) -> Void) {
        guard !configuration.adaptiveSizing, isEditableDisplayReference(displayID) else { return }
        cancelResizePreview()
        let original = requestedManualSizing(for: displayID)
        var sizing = original
        change(&sizing)
        sizing.normalize()
        if let custom = storedCustomSizing(for: displayID) {
            let revised = custom.resized(from: original, to: sizing,
                maximumLength: sizingBounds(for: displayID).maxLength,
                count: displayedEntryCount, dividerIndex: sizingDividerIndex,
                contentBounds: contentBounds(for: displayedEntries), edge: resolvedDisplayID(displayID).map { edge(for: $0) } ?? .bottom)
            updateCustomSizing(for: displayID) { $0 = revised }
            return
        }
        sizing = contentSizingProposal(sizing, original: original, displayID: displayID)
        persistManualSizing(sizing, for: resolvedDisplayID(displayID))
    }

    private func contentSizingProposal(_ proposed: DockManualSizing, original: DockManualSizing,
                                       displayID: String?) -> DockManualSizing {
        guard configuration.manualAutoLength else { return proposed }
        var result = proposed
        let visibleOriginalLength = min(sizingBounds(for: displayID).maxLength, max(1, original.length))
        let editedLength = abs(proposed.length - original.length) > 0.000001
            && abs(proposed.length - visibleOriginalLength) > 0.000001
        if editedLength {
            result.contentPadding = DockContentLengthPolicy.capturedPadding(length: proposed.length,
                contentSpan: contentSpan(for: proposed, displayID: displayID))
        } else {
            result.contentPadding = original.contentPadding
        }
        return contentFittedSizing(result, for: displayID)
    }

    func setResizePreview(_ sizing: DockManualSizing?, for displayID: String?) {
        guard let sizing else {
            if let displayID, resizePreview?.displayID != displayID { return }
            cancelResizePreview()
            return
        }
        guard !configuration.adaptiveSizing, !readOnly, isEditableDisplayReference(displayID) else { return }
        var normalized = sizing
        normalized.normalize()
        let id = resolvedDisplayID(displayID)
        let original: DockManualSizing
        if let preview = resizePreview, preview.displayID == id {
            original = preview.originalSizing
        } else {
            original = resolvedCustomSizing(for: id)?.manualSizing
                ?? contentFittedSizing(storedManualSizing(for: id), for: id)
        }
        if storedCustomSizing(for: id) == nil {
            normalized = contentSizingProposal(normalized, original: original, displayID: id)
        }
        let preview = ResizePreview(displayID: id, originalSizing: original, sizing: normalized)
        guard preview != resizePreview else { return }
        resizePreview = preview
        resizeRevision &+= 1
    }

    func commitManualResize(_ sizing: DockManualSizing, for displayID: String?) {
        guard !configuration.adaptiveSizing, isEditableDisplayReference(displayID), let preview = resizePreview,
              preview.displayID == resolvedDisplayID(displayID) else { return }
        // Configuration is assigned before draft cancellation so synchronous
        // render observers cannot briefly snap back to the old committed size.
        var normalized = sizing
        normalized.normalize()
        if let custom = storedCustomSizing(for: preview.displayID) {
            let revised = custom.resized(from: preview.originalSizing, to: normalized,
                maximumLength: sizingBounds(for: preview.displayID).maxLength,
                count: displayedEntryCount, dividerIndex: sizingDividerIndex,
                contentBounds: contentBounds(for: displayedEntries), edge: resolvedDisplayID(displayID).map { edge(for: $0) } ?? .bottom)
            updateCustomSizing(for: preview.displayID) { $0 = revised }
            flushPendingSave()
            return
        }
        normalized = contentSizingProposal(normalized, original: preview.originalSizing, displayID: preview.displayID)
        persistManualSizing(normalized, for: preview.displayID)
        flushPendingSave()
    }

    private func cancelResizePreview() {
        guard resizePreview != nil else { return }
        resizePreview = nil
        resizeRevision &+= 1
    }

    private func persistManualSizing(_ sizing: DockManualSizing, for displayID: String?) {
        var sizing = sizing
        if configuration.manualAutoLength {
            sizing.length = storedManualSizing(for: displayID).length
        }
        update { next in
            if next.synchronizeSizes || displayID == nil {
                self.assignSharedSizing(sizing, to: &next)
                self.copySizing(sizing, to: self.knownDisplayIDs(in: next), configuration: &next)
            } else if let displayID {
                var settings = next.displaySettings[displayID] ?? DockDisplaySettings()
                settings.manualSizing = sizing
                next.displaySettings[displayID] = settings
            }
        }
        cancelResizePreview()
    }

    private func assignSharedSizing(_ sizing: DockManualSizing, to configuration: inout DockConfiguration) {
        configuration.dockWidth = sizing.length
        configuration.iconSize = sizing.thickness / DockSizingLimits.heightPerIconPoint
        configuration.manualIconScale = sizing.iconScale
        configuration.iconSpacing = sizing.iconSpacing
        configuration.manualContentPadding = sizing.contentPadding
    }

    private func knownDisplayIDs(in configuration: DockConfiguration) -> Set<String> {
        Set(configuration.displaySettings.keys).union(activeDisplays.map(\.id))
    }

    private func copySizing(_ sizing: DockManualSizing, to identifiers: Set<String>,
                            configuration: inout DockConfiguration) {
        for identifier in identifiers {
            var settings = configuration.displaySettings[identifier] ?? DockDisplaySettings()
            settings.manualSizing = sizing
            configuration.displaySettings[identifier] = settings
        }
    }

    private var sizingDividerIndex: Int? {
        pinnedCount > 0 && pinnedCount < displayedEntryCount ? pinnedCount : nil
    }

    private func storedCustomSizing(for displayID: String?) -> DockCustomSizing? {
        if !configuration.synchronizeSizes, let id = resolvedDisplayID(displayID) {
            return configuration.displaySettings[id]?.customSizing ?? configuration.customSizing
        }
        return configuration.customSizing
    }

    /// Reading the new controls does not rewrite or reinterpret a legacy layout.
    func customSizing(for displayID: String?) -> DockCustomSizing {
        storedCustomSizing(for: displayID) ?? .preserving(effectiveManualSizing(for: displayID),
            fitContent: configuration.manualAutoLength, maximumLength: sizingBounds(for: displayID).maxLength)
    }

    /// Express legacy canvas gaps in the new visible-body scale without
    /// rewriting a user's saved geometry just by opening Settings.
    func spacingPercent(for displayID: String?) -> Double {
        let preferences = customSizing(for: displayID)
        if let percent = preferences.spacingPercent { return percent }
        let style = presentation(for: displayID).style
        let id = resolvedDisplayID(displayID)
        let edge = id.map { self.edge(for: $0) } ?? .bottom
        let metrics = contentBounds(for: displayedEntries)
        let side = max(1, style.iconSize)
        let bounds = metrics.isEmpty ? [IconArtworkBounds.full] : metrics
        let pairs = bounds.count > 1 ? Array(zip(bounds, bounds.dropFirst())) : [(bounds[0], bounds[0])]
        let ratios = pairs.map { left, right -> Double in
            let a = edge.isHorizontal ? left.width : left.height
            let b = edge.isHorizontal ? right.width : right.height
            let trailing = edge.isHorizontal ? 1 - left.maxX : left.minY
            let leading = edge.isHorizontal ? right.minX : 1 - right.maxY
            let width = max(0.01, (a + b) / 2)
            return (Double(style.gap / side) + Double(trailing + leading)) / Double(width) * 100
        }
        return min(100, max(0, ratios.reduce(0, +) / Double(ratios.count)))
    }

    func setSpacingPercent(_ value: Double, for displayID: String?) {
        updateCustomSizing(for: displayID) { preferences in
            preferences.spacingPercent = value
            preferences.gapOverride = nil
            if preferences.alignment == .distribute { preferences.alignment = .center }
        }
    }

    func updateCustomSizing(for displayID: String?, _ change: (inout DockCustomSizing) -> Void) {
        guard !configuration.adaptiveSizing, isEditableDisplayReference(displayID) else { return }
        let original = customSizing(for: displayID)
        var preferences = original
        change(&preferences)
        if preferences.lengthMode != original.lengthMode || preferences.fixedLengthPercent != original.fixedLengthPercent {
            preferences.legacyFixedLength = nil
        }
        preferences.normalize()
        let id = resolvedDisplayID(displayID)
        update { next in
            if next.synchronizeSizes || id == nil {
                next.customSizing = preferences
                for key in self.knownDisplayIDs(in: next) {
                    var settings = next.displaySettings[key] ?? DockDisplaySettings()
                    settings.customSizing = preferences
                    next.displaySettings[key] = settings
                }
            } else if let id {
                var settings = next.displaySettings[id] ?? DockDisplaySettings()
                settings.customSizing = preferences
                next.displaySettings[id] = settings
            }
        }
    }

    func resetCustomSizingOverride(_ field: DockSizingOverride, for displayID: String?) {
        updateCustomSizing(for: displayID) { $0.reset(field) }
    }

    func resetCustomSizing(for displayID: String?) {
        updateCustomSizing(for: displayID) { $0 = .visualDefault }
    }

    private func resolvedCustomSizing(for displayID: String?) -> DockResolvedSizing? {
        guard var preferences = storedCustomSizing(for: displayID) else { return nil }
        let id = resolvedDisplayID(displayID)
        let bounds = sizingBounds(for: id)
        if let preview = resizePreview, configuration.synchronizeSizes || preview.displayID == id {
            // Capture shared preferences in the gesture's source orientation.
            // Each screen then resolves those same preferences on its own edge.
            let sourceID = preview.displayID
            preferences = preferences.resized(from: preview.originalSizing, to: preview.sizing,
                maximumLength: sizingBounds(for: sourceID).maxLength,
                count: displayedEntryCount, dividerIndex: sizingDividerIndex,
                contentBounds: contentBounds(for: displayedEntries), edge: sourceID.map { edge(for: $0) } ?? .bottom)
        }
        return DockCustomSizingResolver.resolve(preferences, count: displayedEntryCount,
            dividerIndex: sizingDividerIndex, maximumLength: bounds.maxLength, maximumHeight: bounds.maxThickness,
            contentBounds: preferences.spacingPercent == nil ? [] : contentBounds(for: displayedEntries),
            edge: id.map { edge(for: $0) } ?? .bottom)
    }

    func presentation(for displayID: String?, group: Bool = false) -> DockPresentation {
        let id = resolvedDisplayID(displayID)
        let display = activeDisplays.first { $0.id == id }
        let edge: DockEdge = group ? .bottom : id.map { self.edge(for: $0) } ?? .bottom
        let bounds = sizingBounds(for: id)
        let requested = requestedManualSizing(for: id)
        let effective = effectiveManualSizing(for: id)
        let icon = iconSize(for: id)
        let custom = resolvedCustomSizing(for: id)
        if group {
            return DockPresentation(displayID: id, edge: .bottom,
                style: DockGeometryStyle(iconSize: CGFloat(icon), barThickness: CGFloat(icon + 12),
                    gap: configuration.adaptiveSizing ? CGFloat(nativeDockMetrics.itemSpacing)
                        : CGFloat(custom?.gap ?? effective.iconSpacing * icon / 48),
                    leadingPadding: 6, trailingPadding: 6, separatorLength: 0, magnificationScale: 1,
                    spacingPercent: configuration.adaptiveSizing ? nil : storedCustomSizing(for: id)?.spacingPercent.map { CGFloat($0) }),
                maximumLength: max(1, (display?.visibleFrame.width ?? CGFloat(sizingLimits.maxWidth)) - 24),
                fixedLength: nil, resizeMargin: 0, resizeBounds: bounds,
                requestedManualSizing: requested, canResize: false)
        }
        if configuration.adaptiveSizing {
            let maximum = display.map { edge.isHorizontal ? $0.visibleFrame.width : $0.visibleFrame.height }
                ?? CGFloat(bounds.maxLength)
            return DockPresentation(displayID: id, edge: edge,
                style: DockGeometryStyle(iconSize: CGFloat(nativeDockMetrics.iconSize),
                    barThickness: CGFloat(nativeDockMetrics.barThickness), gap: CGFloat(nativeDockMetrics.itemSpacing),
                    leadingPadding: CGFloat(nativeDockMetrics.leadingPadding), trailingPadding: CGFloat(nativeDockMetrics.trailingPadding),
                    separatorLength: CGFloat(nativeDockMetrics.separatorLength), magnificationScale: CGFloat(nativeDockMetrics.magnificationScale)),
                maximumLength: max(1, maximum), fixedLength: nil, resizeMargin: 0,
                resizeBounds: bounds, requestedManualSizing: requested, canResize: false)
        }
        if let custom, let preferences = storedCustomSizing(for: id) {
            return DockPresentation(displayID: id, edge: edge,
                style: DockGeometryStyle(iconSize: custom.iconSize, barThickness: custom.thickness,
                    gap: custom.gap, leadingPadding: custom.padding, trailingPadding: custom.padding,
                    separatorLength: custom.separatorLength,
                    magnificationScale: configuration.magnificationEnabled ? configuration.magnificationScale : 1,
                    magnificationRadius: configuration.magnificationRadius,
                    contentAlignment: preferences.spacingPercent == nil ? preferences.alignment
                        : (preferences.alignment == .distribute ? .center : preferences.alignment),
                    contentBounds: preferences.spacingPercent == nil ? [] : contentBounds(for: displayedEntries),
                    spacingPercent: preferences.spacingPercent.map { CGFloat($0) }),
                maximumLength: bounds.maxLength, fixedLength: custom.length, resizeMargin: 6,
                resizeBounds: customSizingBounds(for: id),
                requestedManualSizing: requested, canResize: !readOnly,
                lengthResizeBounds: preferences.lengthMode == .fit ? editingSizingBounds(for: id) : nil)
        }
        let padding = configuration.manualAutoLength
            ? effective.contentPadding ?? DockContentLengthPolicy.minimumPadding : 6
        let resizeBounds = configuration.manualAutoLength
            ? DockResizeBounds(minLength: 1, maxLength: bounds.maxLength,
                minThickness: bounds.minThickness, maxThickness: bounds.maxThickness) : bounds
        return DockPresentation(displayID: id, edge: edge,
            style: DockGeometryStyle(iconSize: CGFloat(icon), barThickness: CGFloat(effective.thickness),
                gap: CGFloat(effective.iconSpacing * icon / 48), leadingPadding: CGFloat(padding), trailingPadding: CGFloat(padding),
                separatorLength: CGFloat(13 * icon / 48),
                magnificationScale: configuration.magnificationEnabled ? CGFloat(configuration.magnificationScale) : 1,
                magnificationRadius: CGFloat(configuration.magnificationRadius)),
            maximumLength: CGFloat(bounds.maxLength), fixedLength: CGFloat(effective.length), resizeMargin: 6,
            resizeBounds: resizeBounds, requestedManualSizing: requested, canResize: !readOnly,
            lengthResizeBounds: configuration.manualAutoLength ? editingSizingBounds(for: id) : nil)
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
        guard !readOnly else { notice = LocalizedNotice("配置目前为只读，请先检查配置文件。", "The configuration is read-only. Check the configuration file."); return }
        var next = configuration
        change(&next)
        next.normalizeAppearance()
        guard next != configuration else { return }
        if next.matchesExceptBadgeScale(configuration) {
            configuration = next
            scheduleSave()
            return
        }
        if next.synchronizeSizes,
           next.iconSize != configuration.iconSize || next.dockWidth != configuration.dockWidth
            || next.manualIconScale != configuration.manualIconScale || next.iconSpacing != configuration.iconSpacing
            || next.manualContentPadding != configuration.manualContentPadding {
            let sizing = DockManualSizing(length: next.dockWidth ?? sizingLimits.maxWidth,
                thickness: manualThickness(for: next.iconSize),
                iconScale: next.manualIconScale, iconSpacing: next.iconSpacing,
                contentPadding: next.manualContentPadding)
            copySizing(sizing, to: knownDisplayIDs(in: next), configuration: &next)
        }
        let deferSave = Self.onlyContinuousAppearanceChanged(from: configuration, to: next)
        configuration = next
        cancelResizePreview()
        badgeService.setEnabled(next.showBadges)
        if deferSave { scheduleSave() } else { save() }
    }

    func badgeLabel(for entry: DockEntry) -> String? {
        BadgeDisplayPolicy.label(for: entry, labels: badgeLabels, enabled: configuration.showBadges)
    }

    func stopBackgroundServices() {
        flushPendingSave()
        activationService.cancelPendingRecovery()
        badgeService.stop()
        nativeMetricsService.stop()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    func setSystemDockHidden(_ hidden: Bool) {
        guard !readOnly else { return }
        do {
            try systemDock.setHidden(hidden)
            update { $0.hideSystemDock = hidden }
        } catch { notice = LocalizedNotice("无法更改系统 Dock", "Could not change the system Dock").appending(SystemDockService.ServiceError.notice(for: error)) }
    }

    func restoreSystemDock() {
        do {
            try systemDock.restore()
            if !readOnly { update { $0.hideSystemDock = false } }
        } catch { notice = LocalizedNotice("系统 Dock 恢复失败", "Could not restore the system Dock").appending(SystemDockService.ServiceError.notice(for: error)) }
    }

    func importPins() {
        let apps = SystemDockService.importPinnedApps()
        guard !apps.isEmpty else { notice = LocalizedNotice("系统 Dock 中没有读到可导入的固定应用。", "No pinned applications were found in the system Dock."); return }
        update { $0.insert(apps) }
        notice = LocalizedNotice("已补入系统 Dock 中尚未固定的应用，现有分组和顺序已保留。", "Imported additional pinned apps from the system Dock and kept your groups and order.")
    }

    func addApplications() {
        let panel = NSOpenPanel()
        panel.title = L("添加应用到 DualDock", "Add Applications to DualDock")
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

    func iconContentBounds(for app: AppReference) -> CGRect {
        let key = app.id + "\n" + app.path
        if let cached = artworkBounds[key] { return cached }
        let measured = IconArtworkBounds.measure(icon(for: app))
        artworkBounds[key] = measured
        return measured
    }

    func contentBounds(for entries: [DockEntry]) -> [CGRect] {
        entries.map { entry in
            if entry.isGroup { return IconArtworkBounds.folder }
            return entry.apps.first.map { iconContentBounds(for: $0) } ?? IconArtworkBounds.full
        }
    }

    func isRunning(_ app: AppReference) -> Bool { runningApps.contains { $0.id == app.id } }

    func launch(_ app: AppReference) {
        activationService.open(app, at: resolvedURL(app)) { [weak self] message in
            self?.notice = message
        }
    }

    func cancelPendingActivationRecovery() {
        activationService.cancelPendingRecovery()
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
        if let permissions = permissionsProvider?() {
            accessibilityGranted = permissions.accessibility
            captureGranted = permissions.capture
        } else {
            accessibilityGranted = AXIsProcessTrusted()
            captureGranted = CGPreflightScreenCaptureAccess()
        }
        badgeService.refresh()
    }

    func revealConfiguration() { NSWorkspace.shared.open(directory) }

    private func resolvedURL(_ app: AppReference) -> URL {
        if FileManager.default.fileExists(atPath: app.path) { return URL(fileURLWithPath: app.path) }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id) ?? URL(fileURLWithPath: app.path)
    }

    private func refreshRunningApps() {
        let found = runningAppsProvider?() ?? NSWorkspace.shared.runningApplications.filter {
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
        pendingSave?.cancel()
        pendingSave = nil
        guard !readOnly else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: configURL, options: .atomic)
        } catch { notice = LocalizedNotice("配置保存失败", "Could not save the configuration").appending(SystemDockService.ServiceError.notice(for: error)) }
    }

    /// UI changes are published immediately; continuous slider motion does not
    /// perform JSON encoding and atomic filesystem replacement on every sample.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 150_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.flushPendingSave()
        }
    }

    func flushPendingSave() {
        guard pendingSave != nil else { return }
        save()
    }

    private static func onlyContinuousAppearanceChanged(from old: DockConfiguration,
                                                       to new: DockConfiguration) -> Bool {
        var appearanceOnly = old
        appearanceOnly.iconSize = new.iconSize
        appearanceOnly.iconSpacing = new.iconSpacing
        appearanceOnly.dockWidth = new.dockWidth
        appearanceOnly.manualIconScale = new.manualIconScale
        appearanceOnly.manualContentPadding = new.manualContentPadding
        appearanceOnly.customSizing = new.customSizing
        appearanceOnly.magnificationScale = new.magnificationScale
        appearanceOnly.magnificationRadius = new.magnificationRadius
        appearanceOnly.badgeScale = new.badgeScale
        for (id, profile) in new.displaySettings {
            var original = appearanceOnly.displaySettings[id] ?? DockDisplaySettings()
            original.manualSizing = profile.manualSizing
            original.customSizing = profile.customSizing
            appearanceOnly.displaySettings[id] = original
        }
        return appearanceOnly == new
    }

    private func stableUUID(_ value: String) -> UUID {
        // Running tiles keep identity across refreshes without touching the saved layout.
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}

extension DockConfiguration {
    /// Badge sizing invalidates tile artwork independently of Dock layout.
    func matchesExceptBadgeScale(_ other: Self) -> Bool {
        var copy = self
        copy.badgeScale = other.badgeScale
        return copy == other
    }
}
