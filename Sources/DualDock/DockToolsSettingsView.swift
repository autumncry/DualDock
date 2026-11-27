import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DualDockCore

struct DockToolsSettingsView: View {
    @Environment(\.dualDockLanguage) private var localize
    @ObservedObject var store: DockToolsStore
    @State private var sheet: Editor?
    @State private var draft: DockToolsStore.Draft?
    @State private var query = ""
    @State private var category = ToolLibraryCategory.all

    private enum Editor: Identifiable {
        case city
        case destination(ShelfLayout.Destination.Kind, ShelfLayout.Card?, UUID?)

        var id: String {
            switch self {
            case .city: return "city"
            case .destination(let kind, let card, let before): return kind.rawValue + (card?.id.uuidString ?? before?.uuidString ?? "")
            }
        }
    }

    private var layout: Binding<ShelfLayout> {
        Binding(get: { draft?.layout ?? store.layout }, set: { draft?.layout = $0 })
    }

    var body: some View {
        GeometryReader { area in
            contents(compact: area.size.height < 300 && draft != nil)
        }
        .onAppear {
            _ = store.refreshStoredLayout()
            store.setSettingsPreviewVisible(true)
            consumeCityRequest()
        }
        .onChange(of: store.cityEditorRequested) { _, _ in consumeCityRequest() }
        .onDisappear { endSession() }
        .onReceive(NotificationCenter.default.publisher(for: .dualDockSettingsDidClose)) { _ in endSession() }
        .onReceive(NotificationCenter.default.publisher(for: .dualDockSettingsDidOpen)) { _ in
            _ = store.refreshStoredLayout()
            store.setSettingsPreviewVisible(true)
            consumeCityRequest()
        }
        .sheet(item: $sheet) { editor in
            switch editor {
            case .city:
                DockToolsCityChooser(store: store) { city in draft?.city = city }
            case .destination(let kind, let card, let before):
                DockToolsLinkEditor(kind: kind, card: card) { target in
                    storeDestination(target, replacing: card, before: before)
                }
            }
        }
    }

    private func contents(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(localize("工具栏预览", "Tools Shelf Preview")).font(.system(size: 14, weight: .semibold))
                Spacer()
                if draft != nil && layout.wrappedValue.contains(.weather) {
                    Menu {
                        Button(localize("选择城市…", "Choose City…")) { sheet = .city }
                        if draft?.city != nil {
                            Button(localize("清除城市", "Clear Location")) { draft?.city = nil }
                        }
                    } label: {
                        Label(draft?.city?.name ?? localize("天气城市", "Weather city"), systemImage: "mappin")
                    }.fixedSize().controlSize(.small)
                }
                if draft != nil {
                    Button(localize("取消", "Cancel")) { cancel() }
                    Button(localize("确定", "Done")) {
                        if let current = draft, store.commit(current) { draft = nil }
                    }.buttonStyle(.borderedProminent)
                } else {
                    Button(localize("编辑", "Edit")) { draft = store.beginEditing() }.disabled(!store.canEdit)
                }
            }
            DockToolsLayoutCanvas(store: store, layout: layout, isEditing: draft != nil,
                                  onDropCatalog: add, onEditDestination: editDestination)
            if let issue = store.saveIssue {
                Text(issue.text).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text(localize("组件库", "Widget Library")).font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 8)
                if compact {
                    Picker(localize("组件分类", "Widget category"), selection: $category) {
                        ForEach(ToolLibraryCategory.allCases) { Text($0.title(localize)).tag($0) }
                    }.labelsHidden().frame(width: 92)
                }
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(localize("搜索组件", "Search widgets"), text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel(localize("清除组件搜索", "Clear widget search"))
                    }
                }
                .padding(.horizontal, 7).frame(width: 170, height: 25)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            DockToolsLibrary(query: query, layout: layout.wrappedValue,
                             isEditing: draft != nil, category: $category, showsCategoryStrip: !compact, add: { add($0, before: nil) })
                .disabled(!store.canEdit)
                .dropDestination(for: String.self) { items, _ in
                    guard var current = draft, let text = items.first,
                          let slotID = DockToolsLayoutCanvas.draggedSlot(text),
                          current.layout.slots.contains(where: { $0.id == slotID }) else { return false }
                    current.layout.slots.removeAll { $0.id == slotID }
                    draft = current
                    return true
                }
        }
    }

    private func endSession() {
        sheet = nil
        draft = nil
        store.setSettingsPreviewVisible(false)
    }

    private func cancel() {
        draft = nil
        store.discardDraft()
    }

    private func consumeCityRequest() {
        guard store.cityEditorRequested, store.canEdit else { return }
        if draft == nil { draft = store.beginEditing() }
        store.cityEditorRequested = false
        sheet = .city
    }

    private func add(_ entry: ToolLibraryItem, before: UUID?) {
        guard store.canEdit else { return }
        if draft == nil { draft = store.beginEditing() }
        switch entry {
        case .widget(let kind): draft?.layout.add(.init(kind: kind), before: before)
        case .destination(let kind):
            switch kind {
            case .application, .file: selectFile(kind, editing: nil, before: before)
            case .website, .shortcut: sheet = .destination(kind, nil, before)
            }
        }
    }

    private func editDestination(_ card: ShelfLayout.Card) {
        guard let kind = card.destination?.kind, draft != nil else { return }
        switch kind {
        case .application, .file: selectFile(kind, editing: card, before: nil)
        case .website, .shortcut: sheet = .destination(kind, card, nil)
        }
    }

    private func selectFile(_ kind: ShelfLayout.Destination.Kind, editing: ShelfLayout.Card?, before: UUID?) {
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
        storeDestination(.init(kind: kind, value: url.path, name: name), replacing: editing, before: before)
    }

    private func storeDestination(_ destination: ShelfLayout.Destination, replacing old: ShelfLayout.Card?, before: UUID?) {
        guard var current = draft else { return }
        if let old {
            for index in current.layout.slots.indices {
                if let position = current.layout.slots[index].cards.firstIndex(where: { $0.id == old.id }) {
                    current.layout.slots[index].cards[position] = .init(id: old.id, kind: .launcher, destination: destination)
                    break
                }
            }
        } else {
            current.layout.add(.init(kind: .launcher, destination: destination), before: before)
        }
        draft = current
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
    let store: DockToolsStore
    let choose: (ToolWeatherCity) -> Void
    @Environment(\.dualDockLanguage) private var localize
    @Environment(\.dismiss) private var dismiss
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
                            choose(city)
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
