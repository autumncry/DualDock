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
    @Published var message: String?
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var captureGranted = CGPreflightScreenCaptureAccess()
    let systemDock: SystemDockService
    let windows = WindowService()
    private let badgeService = DockBadgeService()
    private let nativeMetricsService = NativeDockMetricsService()
    private let activationService = ApplicationActivationService()
    let directory: URL
    private let configURL: URL
    private var observers: [NSObjectProtocol] = []
    private var icons: [String: NSImage] = [:]
    private var readOnly = false
    private var initialSetupComplete = false
    private var pendingSave: Task<Void, Never>?
    private struct ResizePreview: Equatable {
        let displayID: String?
        let originalSizing: DockManualSizing
        let sizing: DockManualSizing
    }
    private var resizePreview: ResizePreview?

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
        updateDisplays(DockDisplayInfo.current())
        nativeMetricsService.onUpdate = { [weak self] metrics, status in
            guard let self else { return }
            if self.nativeDockMetrics != metrics { self.nativeDockMetrics = metrics }
            if self.nativeDockStatus != status { self.nativeDockStatus = status }
        }
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
        nativeMetricsService.start()
    }

    var displayedEntries: [DockEntry] {
        let known = configuration.allAppIDs
        let active = configuration.mode == .runningOnly ? runningApps : runningApps.filter { !known.contains($0.id) }
        let activeEntries = active.map { app in
            DockEntry(id: stableUUID(app.id), name: app.name, apps: [app])
        }
        return configuration.mode == .runningOnly ? activeEntries : configuration.entries + activeEntries
    }

    var pinnedCount: Int { configuration.mode == .standard ? configuration.entries.count : 0 }

    private var displayedEntryCount: Int {
        guard configuration.mode == .standard else { return runningApps.count }
        let known = configuration.allAppIDs
        return configuration.entries.count + runningApps.reduce(0) { $0 + (known.contains($1.id) ? 0 : 1) }
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
        guard configuration.manualAutoLength, !readOnly, !activeDisplays.isEmpty else { return false }
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

    /// Length controls cannot request less than the current row plus minimal
    /// padding. Proportional corner resizing keeps the ordinary bounds because
    /// the icon row itself changes length as its thickness is scaled.
    func editingSizingBounds(for displayID: String?) -> DockResizeBounds {
        let bounds = sizingBounds(for: displayID)
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
            original = contentFittedSizing(storedManualSizing(for: id), for: id)
        }
        normalized = contentSizingProposal(normalized, original: original, displayID: id)
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

    func presentation(for displayID: String?, group: Bool = false) -> DockPresentation {
        let id = resolvedDisplayID(displayID)
        let display = activeDisplays.first { $0.id == id }
        let edge: DockEdge = group ? .bottom : id.map { self.edge(for: $0) } ?? .bottom
        let bounds = sizingBounds(for: id)
        let requested = requestedManualSizing(for: id)
        let effective = effectiveManualSizing(for: id)
        let icon = iconSize(for: id)
        if group {
            return DockPresentation(displayID: id, edge: .bottom,
                style: DockGeometryStyle(iconSize: CGFloat(icon), barThickness: CGFloat(icon + 12),
                    gap: configuration.adaptiveSizing ? CGFloat(nativeDockMetrics.itemSpacing) : CGFloat(effective.iconSpacing * icon / 48),
                    leadingPadding: 6, trailingPadding: 6, separatorLength: 0, magnificationScale: 1),
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
        guard !readOnly else { message = "配置目前为只读，请先检查配置文件。"; return }
        var next = configuration
        change(&next)
        next.normalizeAppearance()
        guard next != configuration else { return }
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
        activationService.open(app, at: resolvedURL(app)) { [weak self] message in
            self?.message = message
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
        pendingSave?.cancel()
        pendingSave = nil
        guard !readOnly else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: configURL, options: .atomic)
        } catch { message = "配置保存失败：\(error.localizedDescription)" }
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
        appearanceOnly.magnificationScale = new.magnificationScale
        appearanceOnly.magnificationRadius = new.magnificationRadius
        for (id, profile) in new.displaySettings {
            var original = appearanceOnly.displaySettings[id] ?? DockDisplaySettings()
            original.manualSizing = profile.manualSizing
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
