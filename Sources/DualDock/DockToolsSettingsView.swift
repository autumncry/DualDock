import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DualDockCore

struct DockToolsSettingsView: View {
    @Environment(\.dualDockLanguage) private var localize
    @ObservedObject var store: DockToolsStore
    @State private var sheet: Editor?

    private enum Editor: Identifiable {
        case city
        case destination(ShelfLayout.Destination.Kind, ShelfLayout.Card?)
        var id: String {
            switch self {
            case .city: return "city"
            case .destination(let kind, let card): return kind.rawValue + (card?.id.uuidString ?? "")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(localize("工具排列", "Tool Layout"), spacing: 8) {
                if store.layout.slots.isEmpty {
                    Text(localize("添加音乐、日历、天气或常用快捷入口。", "Add Music, Calendar, Weather, or a shortcut."))
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(store.layout.slots.enumerated()), id: \.element.id) { index, slot in
                    HStack(spacing: 8) {
                        Image(systemName: slot.cards.count > 1 ? "square.stack.3d.up" : slot.cards.first?.symbol ?? "app")
                            .foregroundStyle(.secondary).frame(width: 20)
                        Text(slot.cards.map(\.title).joined(separator: " · "))
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        Picker(localize("卡片宽度", "Card width"), selection: Binding(
                            get: { slot.span }, set: { width in store.edit { $0.resize(slot.id, to: width) } })) {
                            ForEach(1...4, id: \.self) { value in
                                Text(localize("\(value) 格", value == 1 ? "1 slot" : "\(value) slots")).tag(value)
                            }
                        }.labelsHidden().frame(width: 75)
                        Button { store.edit { $0.move(slot.id, by: -1) } } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                            .accessibilityLabel(localize("向前移", "Move earlier"))
                        Button { store.edit { $0.move(slot.id, by: 1) } } label: { Image(systemName: "chevron.down") }
                            .disabled(index == store.layout.slots.count - 1)
                            .accessibilityLabel(localize("向后移", "Move later"))
                        options(for: slot, at: index)
                    }
                    if index != store.layout.slots.count - 1 { Divider() }
                }
                HStack {
                    Menu(localize("添加工具", "Add Tool")) {
                        ForEach([ShelfLayout.Kind.music, .calendar, .weather], id: \.self) { kind in
                            Button(kind.label) { store.edit { $0.add(.init(kind: kind)) } }
                                .disabled(store.layout.slots.contains { $0.cards.contains { $0.kind == kind } })
                        }
                        Divider()
                        Button(localize("应用…", "Application…")) { selectFile(.application, editing: nil) }
                        Button(localize("文件或文件夹…", "File or Folder…")) { selectFile(.file, editing: nil) }
                        Button(localize("网址…", "Website…")) { sheet = .destination(.website, nil) }
                        Button(localize("系统快捷指令…", "macOS Shortcut…")) { sheet = .destination(.shortcut, nil) }
                    }.fixedSize()
                    Spacer()
                }
                Text(localize("各屏共享排列与宽度。叠放的工具占用同一格，点卡片上的箭头切换。", "All displays share this layout. Stacked tools share a slot. Use the arrow on the card to cycle through them."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            SettingsGroup(localize("天气城市", "Weather Location"), spacing: 6) {
                HStack {
                    Text(store.city.map { [$0.name, $0.country].compactMap { $0 }.joined(separator: " · ") }
                         ?? localize("尚未选择城市", "No city selected"))
                    Spacer()
                    Button(localize("选择城市…", "Choose City…")) { sheet = .city }
                    if store.city != nil {
                        Button { store.setCity(nil) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain)
                            .accessibilityLabel(localize("清除城市", "Clear location"))
                    }
                }
                Link(localize("城市搜索由 Open-Meteo 提供", "City search by Open-Meteo"), destination: URL(string: "https://open-meteo.com/")!)
                    .font(.system(size: 12))
            }

            if let issue = store.saveIssue {
                Text(issue.text).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $sheet) { editor in
            switch editor {
            case .city:
                DockToolsCityChooser(store: store)
            case .destination(let kind, let card):
                DockToolsLinkEditor(kind: kind, card: card) { target in storeDestination(target, replacing: card) }
            }
        }
    }

    private func options(for slot: ShelfLayout.Slot, at index: Int) -> some View {
        Menu {
            if index + 1 < store.layout.slots.count {
                Button(localize("与下一项叠放", "Stack with Next Tool")) {
                    store.edit { $0.stackWithNext(slot.id) }
                }
            }
            if slot.cards.count > 1 {
                Button(localize("拆分为独立卡片", "Separate Cards")) { store.edit { $0.unstack(slot.id) } }
            }
            ForEach(slot.cards) { card in
                if let d = card.destination {
                    Button(localize("编辑", "Edit") + " · " + card.title) {
                        switch d.kind {
                        case .application, .file: selectFile(d.kind, editing: card)
                        case .website, .shortcut: sheet = .destination(d.kind, card)
                        }
                    }
                }
                Button(localize("移除", "Remove") + " · " + card.title) {
                    store.edit { $0.removeCard(card.id, from: slot.id) }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(localize("卡片选项", "Card Options"))
    }

    private func selectFile(_ kind: ShelfLayout.Destination.Kind, editing: ShelfLayout.Card?) {
        let panel = NSOpenPanel()
        let isApp = kind == .application
        panel.title = isApp ? localize("选择应用", "Choose an App") : localize("选择文件或文件夹", "Choose a File or Folder")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = !isApp
        panel.canChooseFiles = true
        if isApp {
            panel.allowedContentTypes = [.applicationBundle]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = isApp ? url.deletingPathExtension().lastPathComponent : FileManager.default.displayName(atPath: url.path)
        storeDestination(.init(kind: kind, value: url.path, name: name), replacing: editing)
    }

    private func storeDestination(_ destination: ShelfLayout.Destination, replacing old: ShelfLayout.Card?) {
        store.edit { layout in
            if let old {
                for index in layout.slots.indices {
                    if let position = layout.slots[index].cards.firstIndex(where: { $0.id == old.id }) {
                        layout.slots[index].cards[position] = .init(id: old.id, kind: .launcher, destination: destination)
                        return
                    }
                }
            } else {
                layout.add(.init(kind: .launcher, destination: destination))
            }
        }
    }
}

private struct DockToolsLinkEditor: View {
    @Environment(\.dualDockLanguage) private var localize
    @Environment(\.dismiss) private var dismiss
    let kind: ShelfLayout.Destination.Kind
    let save: (ShelfLayout.Destination) -> Void
    @State private var name: String
    @State private var location: String

    init(kind: ShelfLayout.Destination.Kind, card: ShelfLayout.Card?, save: @escaping (ShelfLayout.Destination) -> Void) {
        self.kind = kind
        self.save = save
        _name = State(initialValue: card?.destination?.name ?? "")
        _location = State(initialValue: card?.destination?.value ?? "")
    }

    private var target: ShelfLayout.Destination {
        let value = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let alias = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(kind: kind, value: value,
                     name: alias.isEmpty ? (kind == .website ? URL(string: value)?.host ?? value : value) : alias)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == .website ? localize("网页快捷入口", "Website Shortcut") : localize("系统快捷指令", "macOS Shortcut"))
                .font(.headline)
            TextField(kind == .website ? "https://example.com" : localize("快捷指令中的完整名称", "Exact name in Shortcuts"), text: $location)
            TextField(localize("显示名称（可选）", "Display name (optional)"), text: $name)
            HStack {
                Spacer()
                Button(localize("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(localize("保存", "Save")) { save(target); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(target.url == nil)
            }
        }.padding(18).frame(width: 350)
    }
}

private struct DockToolsCityChooser: View {
    @Environment(\.dualDockLanguage) private var localize
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: DockToolsStore
    @State private var query = ""
    @State private var results = [ToolWeatherCity]()
    @State private var message: String?
    @State private var work: Task<Void, Never>?
    @State private var searching = false
    @State private var requestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localize("选择天气城市", "Choose a Weather Location")).font(.headline)
            HStack {
                TextField(localize("城市名，例如北京或 Singapore", "City name, such as Beijing or Singapore"), text: $query)
                    .onSubmit(search)
                Button(localize("搜索", "Search"), action: search)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searching)
            }
            if searching { ProgressView().controlSize(.small) }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(results) { city in
                        Button {
                            store.setCity(city)
                            dismiss()
                        } label: {
                            HStack {
                                Text([city.name, city.region, city.country].compactMap { $0 }.joined(separator: " · "))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }.padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider()
                    }
                }
            }.frame(height: 170)
            HStack {
                HStack(spacing: 6) {
                    Link("Open-Meteo", destination: URL(string: "https://open-meteo.com/")!)
                    Text("·")
                    Link("GeoNames", destination: URL(string: "https://www.geonames.org/")!)
                }.font(.caption)
                Spacer()
                Button(localize("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(18).frame(width: 390)
            .onChange(of: query) { _, _ in
                work?.cancel(); requestID = UUID(); results = []; message = nil; searching = false
            }
            .onDisappear { work?.cancel() }
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        work?.cancel()
        let id = UUID()
        requestID = id
        searching = true
        results = []
        message = nil
        work = Task { @MainActor in
            do {
                let matches = try await store.data.searchCities(term)
                guard !Task.isCancelled, requestID == id else { return }
                results = matches
                if matches.isEmpty { message = localize("未找到城市，请试试英文名。", "No matches. Try another city name.") }
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                message = localize("城市搜索暂不可用，请检查网络后重试。", "City search is unavailable. Check your connection and try again.")
            }
            searching = false
        }
    }
}
