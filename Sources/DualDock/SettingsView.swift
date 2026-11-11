import SwiftUI
import DualDockCore

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @State private var selection: SettingsSection? = .general
    @State private var selectedDisplayID: String?
    private var selected: SettingsSection { selection ?? .general }

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label {
                    Text(section.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                } icon: {
                    Image(systemName: section.symbol)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .frame(width: 22, height: 20)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 5)
                .tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 184)
            .accessibilityLabel("设置分类")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(selected.title).font(.system(size: 23, weight: .semibold))
                    content
                    if let message = store.message {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "info.circle")
                            Text(message).textSelection(.enabled)
                            Spacer(minLength: 0)
                            Button { store.message = nil } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).help("关闭提示")
                        }
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(.system(size: 13))
        .frame(minWidth: 640, minHeight: 440)
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
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 14, weight: .semibold))
            content
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DockSettingsSlider: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range.lowerBound...max(range.lowerBound + 0.001, range.upperBound))
                .disabled(range.lowerBound >= range.upperBound)
                .accessibilityLabel(title)
        }
    }
}

func dockPoints(_ value: Double) -> String {
    guard value.isFinite else { return "—" }
    return String(format: "%.0f pt", value)
}
