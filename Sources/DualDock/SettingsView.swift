import SwiftUI
import DualDockCore

private struct SettingsPageTitleKey: EnvironmentKey {
    static let defaultValue = ""
}

private extension EnvironmentValues {
    var settingsPageTitle: String {
        get { self[SettingsPageTitleKey.self] }
        set { self[SettingsPageTitleKey.self] = newValue }
    }
}

private struct DualDockLanguageKey: EnvironmentKey {
    static var defaultValue: AppLanguage { .current }
}

extension EnvironmentValues {
    var dualDockLanguage: AppLanguage {
        get { self[DualDockLanguageKey.self] }
        set { self[DualDockLanguageKey.self] = newValue }
    }
}

extension AppLanguage {
    func callAsFunction(_ chinese: String, _ english: String) -> String {
        self == .english ? english : chinese
    }
}

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @StateObject private var launchAtLoginService: LaunchAtLoginService
    @State private var language = AppLanguage.current
    @StateObject private var navigation: SettingsNavigation
    @State private var selectedDisplayID: String?
    @FocusState private var searchFocused: Bool
    private var selected: SettingsSection { navigation.selected }

    init(store: AppStore, initialSection: SettingsSection = .general, displayID: String? = nil,
         launchAtLoginService: LaunchAtLoginService? = nil, navigation: SettingsNavigation? = nil) {
        self.store = store
        _launchAtLoginService = StateObject(wrappedValue: launchAtLoginService ?? LaunchAtLoginService())
        _navigation = StateObject(wrappedValue: navigation ?? SettingsNavigation(initialSection))
        _selectedDisplayID = State(initialValue: displayID)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField(language("搜索设置", "Search settings"), text: $navigation.query)
                        .font(.system(size: 13))
                        .textFieldStyle(.plain).focused($searchFocused)
                        .onSubmit { if let first = navigation.visibleSections.first { navigation.show(first) } }
                        .onExitCommand { navigation.query = "" }
                    if navigation.isSearching {
                        Button { navigation.query = ""; searchFocused = true } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain).accessibilityLabel(language("清除搜索", "Clear search"))
                    }
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
                .padding(.horizontal, 10).padding(.top, 12)
                if navigation.visibleSections.isEmpty {
                    Text(language("没有匹配的设置", "No matching settings"))
                        .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 16)
                    Spacer()
                } else {
                    List(selection: Binding<SettingsSection?>(
                        get: { selected },
                        set: { if let section = $0 { navigation.show(section) } }
                    )) {
                        ForEach(navigation.visibleSections) { section in
                            HStack(spacing: 8) {
                                Image(systemName: section.symbol).font(.system(size: 15))
                                    .foregroundStyle(.secondary).frame(width: 19)
                                Text(section.sidebarTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            }.padding(.vertical, 5).tag(section)
                                .accessibilityLabel(section.title)
                                .help(section.title)
                        }
                    }.listStyle(.sidebar)
                        .id(language)
                }
            }
            .frame(width: 190).background(.regularMaterial)
            Divider()
            detailPane
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .environment(\.dualDockLanguage, language)
        .environment(\.locale, Locale(identifier: language.rawValue))
        .onReceive(NotificationCenter.default.publisher(for: .dualDockLanguageDidChange)) { _ in
            language = AppLanguage.current
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusDualDockSettingsSearch)) { _ in
            searchFocused = true
        }
        .font(.system(size: 13))
        .toggleStyle(.switch)
        .controlSize(.regular)
        .frame(minWidth: SettingsWindowController.minimumContentSize.width,
               minHeight: SettingsWindowController.minimumContentSize.height)
        .onAppear {
            reconcileDisplaySelection(store.displays)
            store.refreshPermissions()
        }
        .onReceive(store.$displays) { reconcileDisplaySelection($0) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshPermissions()
        }
    }

    @ViewBuilder private var detailPane: some View {
        let sections = selected.detailSections
        if sections.count == 1 {
            VStack(alignment: .leading, spacing: 0) {
                heading(selected)
                    .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        content(selected).environment(\.settingsPageTitle, selected.title)
                        notice
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22).padding(.bottom, 18)
                }
            }
            .id(selected)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 12) {
                                heading(section)
                                content(section).environment(\.settingsPageTitle, section.title)
                            }
                            .id(section)
                        }
                    }
                    .scrollTargetLayout()
                    notice
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22).padding(.vertical, 18)
            }
            .scrollPosition(id: Binding(
                get: { navigation.selected as SettingsSection? },
                set: { if let section = $0 { navigation.scrolled(to: section) } }
            ), anchor: .top)
            .id(sections[0])
        }
    }

    private func heading(_ section: SettingsSection) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Label {
                Text(section.title).font(.system(size: 18, weight: .semibold))
            } icon: {
                Image(systemName: section.symbol).foregroundStyle(Color.accentColor)
                    .font(.system(size: 22))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            if section == .appearance {
                SettingsDisplayScope(store: store, selectedDisplayID: $selectedDisplayID)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var notice: some View {
        if let message = store.message {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(message).textSelection(.enabled)
                Spacer(minLength: 0)
                Button { store.message = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help(L("关闭提示", "Dismiss message"))
                    .accessibilityLabel(L("关闭提示", "Dismiss message"))
            }
            .padding(14)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder private func content(_ section: SettingsSection) -> some View {
        switch section {
        case .general, .contents, .systemDock, .apps:
            GeneralSettingsView(section: section, store: store, launchAtLogin: launchAtLoginService)
        case .appearance: AppearanceSettingsView(store: store, selectedDisplayID: $selectedDisplayID, showsScope: false)
        case .displays:
            DisplayPositionSettingsView(store: store, selectedDisplayID: $selectedDisplayID) { id in
                selectedDisplayID = id
                navigation.show(SettingsSection.appearance)
            }
        case .interaction, .magnification, .notifications: InteractionSettingsView(store: store, section: section)
        case .permissions: PermissionsSettingsView(store: store)
        case .help: DockHelpSettingsView()
        case .about: AboutView()
        }
    }

    private func reconcileDisplaySelection(_ displays: [DockDisplayInfo]) {
        let available = displays.filter { !$0.isMirrored }
        if let selectedDisplayID, available.contains(where: { $0.id == selectedDisplayID }) { return }
        selectedDisplayID = available.first(where: \.isPrimary)?.id ?? available.first?.id
    }
}

struct SettingsGroup<Content: View>: View {
    @Environment(\.settingsPageTitle) private var pageTitle
    let title: String
    let content: Content
    let spacing: CGFloat
    init(_ title: String, spacing: CGFloat = 10, @ViewBuilder content: () -> Content) {
        self.title = title
        self.spacing = spacing
        self.content = content()
    }
    var body: some View {
        if title == pageTitle {
            GroupBox { rows }
        } else {
            GroupBox { rows } label: {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9).padding(.vertical, 7)
    }
}

struct DockSettingsSlider: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void = { _ in }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range.lowerBound...max(range.lowerBound + 0.001, range.upperBound),
                   onEditingChanged: onEditingChanged)
                .disabled(range.lowerBound >= range.upperBound)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
        }
    }
}

func dockPoints(_ value: Double) -> String {
    guard value.isFinite else { return "—" }
    return String(format: "%.0f pt", value)
}
