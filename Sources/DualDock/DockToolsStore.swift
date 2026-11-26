import AppKit
import DualDockCore
import Foundation

extension Notification.Name {
    static let dualDockSettingsDidClose = Notification.Name("DualDock.settingsDidClose")
    static let dualDockSettingsDidOpen = Notification.Name("DualDock.settingsDidOpen")
    static let showDualDockToolsSettings = Notification.Name("DualDock3.showToolsSettings")
}

typealias ShelfLayout = DockToolsLayout

@MainActor
final class DockToolsStore: ObservableObject {
    private struct Settings: Codable {
        var version = 1
        var layout: ShelfLayout
        var city: ToolWeatherCity?
    }

    @Published private var settings: Settings
    @Published private var selectedCards: [String: [UUID: UUID]] = [:]
    @Published private(set) var saveIssue: LocalizedNotice?
    let data: ToolDataService
    let metrics: LocalToolMetrics
    let quota: AIQuotaService
    @Published var cityEditorRequested = false
    private var previewOpen = false
    private let previewDemandID = "DualDock.settings.tools-preview"
    private(set) var referenceDisplayID = ""
    private let url: URL
    private var readOnly: Bool
    private var persistedBytes: Data?
    @Published private(set) var visibleDisplays = Set<String>()
    private var openDetails: [String: Set<UUID>] = [:]

    var layout: ShelfLayout { settings.layout }
    var city: ToolWeatherCity? { settings.city }
    var canEdit: Bool { !readOnly }

    func discardDraft() {
        if !readOnly { saveIssue = nil }
        _ = refreshStoredLayout()
    }

    init(directory: URL, providerEnvironment: ToolDataService.Environment? = nil) {
        url = directory.appendingPathComponent("tool-shelf.json")
        data = ToolDataService(directory: directory, environment: providerEnvironment)
        metrics = LocalToolMetrics(directory: directory)
        quota = AIQuotaService(directory: directory)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let bytes = try Data(contentsOf: url)
                persistedBytes = bytes
                let decoded = try JSONDecoder().decode(Settings.self, from: bytes)
                guard decoded.version == 1, decoded.layout.isValid else { throw CocoaError(.fileReadCorruptFile) }
                settings = decoded
                readOnly = false
            } catch {
                settings = Settings(layout: .initial)
                readOnly = true
                saveIssue = LocalizedNotice("无法读取工具排列。已有文件已保留。", "The tool layout could not be read. The existing file has been preserved.")
            }
        } else {
            settings = Settings(layout: .initial)
            readOnly = false
        }
        data.setWeatherCity(settings.city)
    }

    struct Draft {
        var layout: ShelfLayout
        var city: ToolWeatherCity?
        fileprivate let originalLayout: ShelfLayout
        fileprivate let originalCity: ToolWeatherCity?
    }

    func beginEditing() -> Draft {
        _ = refreshStoredLayout()
        return Draft(layout: settings.layout, city: settings.city, originalLayout: settings.layout, originalCity: settings.city)
    }

    @discardableResult func commit(_ draft: Draft) -> Bool {
        guard !refreshStoredLayout(), draft.originalLayout == settings.layout, draft.originalCity == settings.city else {
            saveIssue = LocalizedNotice("工具页已在其他位置修改。请取消后重新编辑。", "The shelf changed elsewhere. Cancel and edit the latest layout.")
            return false
        }
        guard draft.layout.isValid, !readOnly else { return false }
        guard draft.layout != settings.layout || draft.city != settings.city else { return true }
        var next = settings
        next.layout = draft.layout
        next.city = draft.city
        return save(next)
    }

    func requestCityEditor() {
        cityEditorRequested = true
        Self.openSettings()
    }

    func edit(_ change: (inout ShelfLayout) -> Void) {
        var next = settings
        change(&next.layout)
        guard next.layout != settings.layout else { return }
        save(next)
    }

    func setCity(_ value: ToolWeatherCity?) {
        var next = settings
        next.city = value
        save(next)
    }

    @discardableResult private func save(_ next: Settings) -> Bool {
        guard !readOnly, next.layout.isValid else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard !refreshStoredLayout() else {
                saveIssue = LocalizedNotice("工具排列已更新，请重新编辑。", "The shelf has changed. Start a new edit.")
                return false
            }
            let bytes = try encoder.encode(next)
            try bytes.write(to: url, options: .atomic)
            persistedBytes = bytes
            let cityChanged = next.city != settings.city
            settings = next
            if cityChanged { data.setWeatherCity(next.city) }
            saveIssue = nil
            for display in visibleDisplays { updateDataVisibility(display) }
            updatePreviewDemand()
            return true
        } catch {
            saveIssue = LocalizedNotice("工具排列未能保存。请检查本地试用目录的写入权限。", "Could not save the tools. Check write access to the local preview directory.")
            return false
        }
    }

    /// Reconcile another settings window or a Syncthing update before writing our draft.
    @discardableResult func refreshStoredLayout() -> Bool {
        do {
            let bytes = try FileManager.default.fileExists(atPath: url.path) ? Data(contentsOf: url) : nil
            guard bytes != persistedBytes || readOnly else { return false }
            let latest = try bytes.map { try JSONDecoder().decode(Settings.self, from: $0) } ?? Settings(layout: .initial)
            guard latest.version == 1 && latest.layout.isValid else { throw CocoaError(.fileReadCorruptFile) }
            settings = latest
            readOnly = false
            persistedBytes = bytes
            saveIssue = nil
            data.setWeatherCity(latest.city)
            for display in visibleDisplays { updateDataVisibility(display) }
            updatePreviewDemand()
            return true
        } catch {
            readOnly = true
            saveIssue = LocalizedNotice("无法读取工具排列。已有文件已保留。", "The tool layout could not be read. The existing file has been preserved.")
            return true
        }
    }

    func selectedCard(in slot: ShelfLayout.Slot, on display: String) -> ShelfLayout.Card? {
        let id = selectedCards[display]?[slot.id]
        return slot.cards.first { $0.id == id } ?? slot.cards.first
    }

    func advance(_ slot: ShelfLayout.Slot, on display: String, by offset: Int = 1) {
        guard slot.cards.count > 1, let selected = selectedCard(in: slot, on: display),
              let index = slot.cards.firstIndex(of: selected) else { return }
        let newIndex = (index + offset + slot.cards.count) % slot.cards.count
        selectedCards[display, default: [:]][slot.id] = slot.cards[newIndex].id
        referenceDisplayID = display
        updateDataVisibility(display)
        updatePreviewDemand()
    }

    func setDetailOpen(_ open: Bool, cardID: UUID, on displayID: String) {
        if open { openDetails[displayID, default: []].insert(cardID) }
        else { openDetails[displayID]?.remove(cardID) }
    }

    func keepsShelfOpen(on displayID: String) -> Bool {
        openDetails[displayID]?.isEmpty == false
    }

    func setShelfVisible(_ visible: Bool, on displayID: String) {
        if visible {
            referenceDisplayID = displayID
            if !visibleDisplays.contains(displayID) { visibleDisplays.insert(displayID) }
        } else {
            if visibleDisplays.contains(displayID) { visibleDisplays.remove(displayID) }
            openDetails.removeValue(forKey: displayID)
        }
        updateDataVisibility(displayID)
        updatePreviewDemand()
    }

    func setSettingsPreviewVisible(_ visible: Bool) {
        previewOpen = visible
        updatePreviewDemand()
    }

    private func updatePreviewDemand() {
        let kinds = Set(layout.slots.compactMap { selectedCard(in: $0, on: referenceDisplayID)?.kind })
        updateDemand(previewOpen, for: previewDemandID, kinds: kinds)
    }

    private func updateDataVisibility(_ display: String) {
        let kinds = Set(layout.slots.compactMap { selectedCard(in: $0, on: display)?.kind })
        updateDemand(visibleDisplays.contains(display), for: display, kinds: kinds)
    }

    private func updateDemand(_ active: Bool, for display: String, kinds: Set<ShelfLayout.Kind>) {
        metrics.setVisible(active, on: display, system: kinds.contains(.systemStatus),
                           battery: kinds.contains(.battery), disk: kinds.contains(.storage))
        quota.setVisible(active ? Set(kinds.compactMap(\.quotaProvider)) : [], on: display)
        data.setVisible(active, for: display,
                        music: kinds.contains(.music), calendar: kinds.contains(.calendar), weather: kinds.contains(.weather))
    }

    func stop() {
        setSettingsPreviewVisible(false)
        for display in visibleDisplays { data.setVisible(false, for: display) }
        metrics.stop()
        quota.stop()
        visibleDisplays.removeAll()
        openDetails.removeAll()
    }

    static func openSettings() {
        NotificationCenter.default.post(name: .showDualDockToolsSettings, object: nil)
    }

    static func open(_ destination: ShelfLayout.Destination) -> Bool {
        guard let url = destination.url else { return false }
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) { return false }
        return NSWorkspace.shared.open(url)
    }

    static func openApp(_ bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        return NSWorkspace.shared.open(url)
    }
}

extension ShelfLayout.Kind {
    var quotaProvider: AIQuotaProvider? {
        switch self {
        case .codexQuota: return .codex
        case .claudeQuota: return .claude
        case .geminiQuota: return .gemini
        default: return nil
        }
    }

    var isLocalMetric: Bool {
        [.systemStatus, .storage, .battery, .focusTimer].contains(self)
    }

    var label: String { name(in: .current) }

    func name(in language: AppLanguage) -> String {
        switch self {
        case .music: return language("音乐", "Music")
        case .weather: return language("天气", "Weather")
        case .calendar: return language("日历", "Calendar")
        case .launcher: return language("快捷入口", "Shortcut")
        case .systemStatus: return language("系统状态", "System Status")
        case .battery: return language("电池", "Battery")
        case .storage: return language("磁盘空间", "Disk Space")
        case .focusTimer: return language("专注计时", "Focus Timer")
        case .codexQuota: return language("Codex 余量", "Codex Quota")
        case .claudeQuota: return language("Claude Code 余量", "Claude Code Quota")
        case .geminiQuota: return language("Gemini CLI 余量", "Gemini CLI Quota")
        }
    }

    var symbol: String {
        switch self {
        case .music: return "music.note"
        case .weather: return "cloud.sun.fill"
        case .calendar: return "calendar"
        case .launcher: return "arrow.up.forward.app.fill"
        case .systemStatus: return "waveform.path.ecg"
        case .battery: return "battery.75percent"
        case .storage: return "internaldrive"
        case .focusTimer: return "timer"
        case .codexQuota: return "terminal"
        case .claudeQuota: return "asterisk"
        case .geminiQuota: return "sparkle"
        }
    }
}

extension ShelfLayout.Card {
    var title: String {
        guard let target = destination else { return kind.label }
        if target.kind == .application, target.value == "/System/Applications/Shortcuts.app" { return L("快捷指令", "Shortcuts") }
        return target.name
    }

    var symbol: String {
        guard let target = destination else { return kind.symbol }
        switch target.kind {
        case .file: return "folder.fill"
        case .website: return "globe"
        case .shortcut: return "square.2.layers.3d.fill"
        case .application: return "app.fill"
        }
    }
}
