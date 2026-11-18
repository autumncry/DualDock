import SwiftUI
import DualDockCore

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
    private let launchAtLoginService: LaunchAtLoginService?
    @State private var language = AppLanguage.current
    @State private var selection: SettingsSection? = .general
    @State private var selectedDisplayID: String?
    @FocusState private var focusedSection: SettingsSection?
    private var selected: SettingsSection { selection ?? .general }

    init(store: AppStore, initialSection: SettingsSection = .general, displayID: String? = nil,
         launchAtLoginService: LaunchAtLoginService? = nil) {
        self.store = store
        self.launchAtLoginService = launchAtLoginService
        _selection = State(initialValue: initialSection)
        _selectedDisplayID = State(initialValue: displayID)
    }


    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable().scaledToFit().frame(width: 26, height: 26).accessibilityHidden(true)
                    Text("DualDock").font(.system(size: 14, weight: .semibold))
                }.padding(.horizontal, 19).padding(.top, 23).padding(.bottom, 24)
                VStack(spacing: 5) {
                    ForEach(SettingsSection.allCases) { section in
                        Button { selection = section } label: {
                            HStack(spacing: 10) {
                                Image(systemName: section.symbol)
                                    .font(.system(size: 14, weight: .regular))
                                    .frame(width: 18, height: 18).accessibilityHidden(true)
                                Text(section.sidebarTitle).font(.system(size: 13, weight: selected == section ? .medium : .regular))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(selected == section ? Color.accentColor : Color.primary)
                            .padding(.horizontal, 11).frame(height: 34)
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                            .background(selected == section ? Color.accentColor.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .focused($focusedSection, equals: section)
                        .accessibilityLabel(section.title)
                        .accessibilityAddTraits(selected == section ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 10)
                .onMoveCommand { direction in
                    guard direction == .up || direction == .down,
                          let index = SettingsSection.allCases.firstIndex(of: focusedSection ?? selected) else { return }
                    let next = min(SettingsSection.allCases.count - 1, max(0, index + (direction == .down ? 1 : -1)))
                    selection = SettingsSection.allCases[next]
                    focusedSection = SettingsSection.allCases[next]
                }
                Spacer(minLength: 20)
                Text(language("改动即时生效", "Applied instantly"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.vertical, 17)
            }
            .frame(width: 176)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(selected.title).font(.system(size: 21, weight: .semibold))
                        Text(selected.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if selected == .appearance {
                        SettingsDisplayScope(store: store, selectedDisplayID: $selectedDisplayID)
                    }
                }
                .padding(.horizontal, 30).padding(.top, 23).padding(.bottom, 20)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        content
                        if let message = store.message {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "info.circle").foregroundStyle(.secondary)
                                Text(message).textSelection(.enabled)
                                Spacer(minLength: 0)
                                Button { store.message = nil } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain).help(L("关闭提示", "Dismiss message")).accessibilityLabel(L("关闭提示", "Dismiss message"))
                            }
                            .padding(14)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 30).padding(.bottom, 24)
                }
                .id(selected)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .environment(\.dualDockLanguage, language)
        .environment(\.locale, Locale(identifier: language.rawValue))
        .onReceive(NotificationCenter.default.publisher(for: .dualDockLanguageDidChange)) { _ in
            language = AppLanguage.current
        }
        .font(.system(size: 13))
        .toggleStyle(.switch)
        .controlSize(.regular)
        .frame(minWidth: 820, minHeight: 540)
        .onAppear {
            reconcileDisplaySelection(store.displays)
            store.refreshPermissions()
        }
        .onReceive(store.$displays) { reconcileDisplaySelection($0) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshPermissions()
        }
    }

    @ViewBuilder private var content: some View {
        switch selected {
        case .general: GeneralSettingsView(store: store, launchAtLogin: launchAtLoginService)
        case .appearance: AppearanceSettingsView(store: store, selectedDisplayID: $selectedDisplayID, showsScope: false)
        case .displays:
            DisplayPositionSettingsView(store: store, selectedDisplayID: $selectedDisplayID) { id in
                selectedDisplayID = id
                selection = .appearance
            }
        case .interaction: InteractionSettingsView(store: store)
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
    let title: String
    let content: Content
    let spacing: CGFloat
    init(_ title: String, spacing: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.title = title
        self.spacing = spacing
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5))
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
        }
    }
}

func dockPoints(_ value: Double) -> String {
    guard value.isFinite else { return "—" }
    return String(format: "%.0f pt", value)
}
