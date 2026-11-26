import AppKit
import DualDockCore
import Foundation

extension Notification.Name {
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
    private let url: URL
    private let readOnly: Bool
    private var visibleDisplays = Set<String>()
    private var openDetails: [String: Set<UUID>] = [:]

    var layout: ShelfLayout { settings.layout }
    var city: ToolWeatherCity? { settings.city }

    init(directory: URL, providerEnvironment: ToolDataService.Environment? = nil) {
        url = directory.appendingPathComponent("tool-shelf.json")
        data = ToolDataService(directory: directory, environment: providerEnvironment)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let decoded = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
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

    private func save(_ next: Settings) {
        guard !readOnly, next.layout.isValid else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(next).write(to: url, options: .atomic)
            let cityChanged = next.city != settings.city
            settings = next
            if cityChanged { data.setWeatherCity(next.city) }
            saveIssue = nil
            for display in visibleDisplays { updateDataVisibility(display) }
        } catch {
            saveIssue = LocalizedNotice("工具排列未能保存。请检查本地试用目录的写入权限。", "Could not save the tools. Check write access to the local preview directory.")
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
        updateDataVisibility(display)
    }

    func setDetailOpen(_ open: Bool, cardID: UUID, on displayID: String) {
        if open { openDetails[displayID, default: []].insert(cardID) }
        else { openDetails[displayID]?.remove(cardID) }
    }

    func keepsShelfOpen(on displayID: String) -> Bool {
        openDetails[displayID]?.isEmpty == false
    }

    func setShelfVisible(_ visible: Bool, on displayID: String) {
        if visible { visibleDisplays.insert(displayID) }
        else {
            visibleDisplays.remove(displayID)
            openDetails.removeValue(forKey: displayID)
        }
        updateDataVisibility(displayID)
    }

    private func updateDataVisibility(_ display: String) {
        let kinds = Set(layout.slots.compactMap { selectedCard(in: $0, on: display)?.kind })
        data.setVisible(visibleDisplays.contains(display), for: display,
                        music: kinds.contains(.music), calendar: kinds.contains(.calendar), weather: kinds.contains(.weather))
    }

    func stop() {
        for display in visibleDisplays { data.setVisible(false, for: display) }
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
    var label: String {
        switch self {
        case .music: return L("音乐", "Music")
        case .weather: return L("天气", "Weather")
        case .calendar: return L("日历", "Calendar")
        case .launcher: return L("快捷入口", "Shortcut")
        }
    }

    var symbol: String {
        switch self {
        case .music: return "music.note"
        case .weather: return "cloud.sun.fill"
        case .calendar: return "calendar"
        case .launcher: return "arrow.up.forward.app.fill"
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
