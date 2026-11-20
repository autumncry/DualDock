import SwiftUI
import DualDockCore

struct DisplayPositionSettingsView: View {
    @Environment(\.dualDockLanguage) private var localize
    @ObservedObject var store: AppStore
    @Binding var selectedDisplayID: String?
    let onConfigureSize: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.displays.isEmpty {
                SettingsGroup(localize("等待显示器", "Waiting for a display")) {
                    Label(localize("连接显示器后，会在这里显示可用位置。", "Connect a display to choose its Dock position."), systemImage: "display")
                        .foregroundStyle(.secondary)
                }
            } else {
                GroupBox {
                    VStack(spacing: 0) {
                        ForEach(store.displays) { display in
                            if display.id != store.displays.first?.id { Divider() }
                            displayRow(display)
                        }
                    }.padding(.horizontal, 5)
                }
                Text(localize("位置按屏幕保存；尺寸同步可在“外观与尺寸”中设置。", "Each display has its own position. Manage size synchronization in Appearance & Size."))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func displayRow(_ display: DockDisplayInfo) -> some View {
        HStack(spacing: 16) {
            positionDiagram(display).frame(width: 110, height: 68)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(display.name).font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text("\(Int(display.frame.width.rounded())) × \(Int(display.frame.height.rounded())) pt")
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                        .fixedSize()
                }
                HStack(spacing: 8) {
                    if display.isPrimary {
                        Text(localize("主显示器", "Main display")).foregroundStyle(.secondary)
                    }
                    if display.isMirrored {
                        Text(localize("镜像 · 跟随源屏幕", "Mirrored · Follows source")).foregroundStyle(.secondary)
                    } else {
                        Button(store.configuration.synchronizeSizes ? localize("调整所有屏幕尺寸", "Adjust Size for All Displays") : localize("调整此屏幕尺寸", "Adjust Size for This Display")) {
                            selectedDisplayID = display.id
                            onConfigureSize(display.id)
                        }.buttonStyle(.link)
                    }
                }.font(.system(size: 13))
                Picker(localize("Dock 位置", "Dock position"), selection: positionBinding(display)) {
                    ForEach([DockEdge.bottom, .left, .right, .top], id: \.self) { edge in Text(edgeTitle(edge)).tag(edge) }
                }.pickerStyle(.segmented).labelsHidden().disabled(display.isMirrored)
                    .accessibilityLabel(localize("\(display.name) Dock 位置", "Dock position on \(display.name)"))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 9)
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
            RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .underPageBackgroundColor))
            RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.22), lineWidth: 1)
            Image(systemName: display.isMirrored ? "rectangle.on.rectangle" : "display")
                .font(.system(size: 17, weight: .light)).foregroundStyle(.tertiary)
            ForEach([DockEdge.bottom, .left, .right, .top], id: \.self) { candidate in
                Button {
                    selectedDisplayID = display.id
                    store.setEdge(candidate, for: display.id)
                } label: {
                    Capsule().fill(candidate == edge ? Color.accentColor : Color.primary.opacity(0.12))
                        .frame(width: candidate.isHorizontal ? 38 : 4, height: candidate.isHorizontal ? 4 : 24)
                        .padding(8).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(display.isMirrored)
                .offset(x: candidate == .left ? -45 : (candidate == .right ? 45 : 0),
                        y: candidate == .top ? -24 : (candidate == .bottom ? 24 : 0))
                .accessibilityLabel(localize("\(display.name)，放在\(edgeTitle(candidate))", "Place the Dock on \(display.name) at the \(edgeTitle(candidate).lowercased()) edge"))
                .accessibilityValue(candidate == edge ? localize("已选择", "Selected") : localize("未选择", "Not selected"))
            }
        }
    }
}
