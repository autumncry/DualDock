import SwiftUI
import DualDockCore

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @State private var selection: SettingsSection? = .general
    @State private var selectedDisplayID: String?
    private var selected: SettingsSection { selection ?? .general }

    init(store: AppStore, initialSection: SettingsSection = .general, displayID: String? = nil) {
        self.store = store
        _selection = State(initialValue: initialSection)
        _selectedDisplayID = State(initialValue: displayID)
    }


    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable().scaledToFit().frame(width: 30, height: 30).accessibilityHidden(true)
                    Text("DualDock").font(.system(size: 15, weight: .semibold))
                }.padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 20)
                List(SettingsSection.allCases, selection: $selection) { section in
                    Label {
                        Text(section.title).font(.system(size: 13)).lineLimit(1)
                    } icon: {
                        Image(systemName: section.symbol)
                            .font(.system(size: 14, weight: .regular))
                            .frame(width: 20, height: 20).accessibilityHidden(true)
                    }
                    .padding(.vertical, 3).tag(section)
                }
                .listStyle(.sidebar)
                .accessibilityLabel("设置分类")
                Text("改动即时生效")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.vertical, 17)
            }
            .frame(width: 182)
            .background(.regularMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selected.title).font(.system(size: 24, weight: .semibold))
                    Text(selected.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 26).padding(.top, 24).padding(.bottom, 20)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        content
                        if let message = store.message {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "info.circle").foregroundStyle(.secondary)
                                Text(message).textSelection(.enabled)
                                Spacer(minLength: 0)
                                Button { store.message = nil } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain).help("关闭提示").accessibilityLabel("关闭提示")
                            }
                            .padding(14)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 26).padding(.bottom, 26)
                }
                .id(selected)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        case .general: GeneralSettingsView(store: store)
        case .appearance: AppearanceSettingsView(store: store, selectedDisplayID: $selectedDisplayID)
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
    init(_ title: String, spacing: CGFloat = 15, @ViewBuilder content: () -> Content) {
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
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5))
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
