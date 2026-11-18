import SwiftUI
import DualDockCore

struct DisplayPositionSettingsView: View {
    @Environment(\.dualDockLanguage) private var localize
    @ObservedObject var store: AppStore
    @Binding var selectedDisplayID: String?
    let onConfigureSize: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if store.displays.isEmpty {
                SettingsGroup(localize("等待显示器", "Waiting for a display")) {
                    Label(localize("连接显示器后，会在这里显示可用位置。", "Connect a display to choose its Dock position."), systemImage: "display")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(store.displays) { display in
                SettingsGroup(display.name + (display.isPrimary ? localize(" · 主显示器", " · Main display") : "")) {
                    HStack(alignment: .center, spacing: 24) {
                        positionDiagram(display).frame(width: 174, height: 112)
                        VStack(alignment: .leading, spacing: 13) {
                            Text("\(Int(display.frame.width.rounded())) × \(Int(display.frame.height.rounded())) pt")
                                .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                            Picker(localize("Dock 位置", "Dock position"), selection: positionBinding(display)) {
                                ForEach([DockEdge.bottom, .left, .right, .top], id: \.self) { edge in Text(edgeTitle(edge)).tag(edge) }
                            }.pickerStyle(.segmented).labelsHidden().disabled(display.isMirrored)
                                .accessibilityLabel(localize("\(display.name) Dock 位置", "Dock position on \(display.name)"))
                            if display.isMirrored {
                                Text(localize("镜像屏幕跟随源屏幕的画面与位置。", "This mirrored display uses the source display’s Dock position."))
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            } else {
                                Button(store.configuration.synchronizeSizes ? localize("调整所有屏幕尺寸", "Adjust Size for All Displays") : localize("调整此屏幕尺寸", "Adjust Size for This Display")) {
                                    selectedDisplayID = display.id
                                    onConfigureSize(display.id)
                                }.controlSize(.small)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Text(localize("位置始终按屏幕分别保存。尺寸是否共享，可在“外观与尺寸”中选择。", "Position is saved per display. Size synchronization is available in Appearance & Size."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func positionBinding(_ display: DockDisplayInfo) -> Binding<DockEdge> {
        Binding(get: { store.edge(for: display.id) }, set: { edge in
            selectedDisplayID = display.id
            store.setEdge(edge, for: display.id)
        })
    }
    private func positionDiagram(_ display: DockDisplayInfo) -> some View {
        let edge = store.edge(for: display.id)
        return ZStack {
            RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .underPageBackgroundColor))
            RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.22), lineWidth: 1)
            Image(systemName: display.isMirrored ? "rectangle.on.rectangle" : "display")
                .font(.system(size: 24, weight: .ultraLight)).foregroundStyle(.tertiary)
            ForEach([DockEdge.bottom, .left, .right, .top], id: \.self) { candidate in
                Button {
                    selectedDisplayID = display.id
                    store.setEdge(candidate, for: display.id)
                } label: {
                    Capsule().fill(candidate == edge ? Color.accentColor : Color.primary.opacity(0.12))
                        .frame(width: candidate.isHorizontal ? 64 : 5, height: candidate.isHorizontal ? 5 : 44)
                        .padding(7).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(display.isMirrored)
                .offset(x: candidate == .left ? -72 : (candidate == .right ? 72 : 0),
                        y: candidate == .top ? -42 : (candidate == .bottom ? 42 : 0))
                .accessibilityLabel(localize("\(display.name)，放在\(edgeTitle(candidate))", "Place the Dock on \(display.name) at the \(edgeTitle(candidate).lowercased()) edge"))
                .accessibilityValue(candidate == edge ? localize("已选择", "Selected") : localize("未选择", "Not selected"))
            }
        }
    }
}
