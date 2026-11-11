import SwiftUI
import DualDockCore

struct DisplayPositionSettingsView: View {
    @ObservedObject var store: AppStore
    @Binding var selectedDisplayID: String?
    let onConfigureSize: (String) -> Void
    private let edges: [DockEdge] = [.bottom, .left, .right, .top]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("每块屏幕的位置独立保存。左右侧纵向排列，上下侧横向排列，应用夹与窗口预览朝屏幕内侧展开。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if store.displays.isEmpty {
                Label("暂未检测到显示器。", systemImage: "display").foregroundStyle(.secondary)
            }
            ForEach(store.displays, id: \.id) { display in
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("\(Int(display.frame.width.rounded())) × \(Int(display.frame.height.rounded())) pt")
                            .foregroundStyle(.secondary).monospacedDigit()
                        Picker("Dock 位置", selection: Binding(get: { store.edge(for: display.id) }, set: { edge in
                            selectedDisplayID = display.id
                            store.setEdge(edge, for: display.id)
                        })) {
                            ForEach(edges, id: \.self) { edge in
                                Label(edgeTitle(edge), systemImage: edgeSymbol(edge)).tag(edge)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(display.isMirrored)
                        .accessibilityLabel("\(display.name) Dock 位置")
                        if display.isMirrored {
                            Text("镜像屏幕跟随系统复制的画面，请在镜像源屏幕设置位置。")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Button("尺寸设置") {
                                selectedDisplayID = display.id
                                onConfigureSize(display.id)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                } label: {
                    Label(display.name + (display.isPrimary ? " · 主显示器" : "") + (display.isMirrored ? " · 镜像" : ""),
                          systemImage: "display")
                }
            }
            Text("接入或断开显示器时会自动更新列表；再次连接后沿用该显示器保存的位置。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func edgeTitle(_ edge: DockEdge) -> String {
        switch edge { case .bottom: return "底部"; case .left: return "左侧"; case .right: return "右侧"; case .top: return "上方" }
    }
    private func edgeSymbol(_ edge: DockEdge) -> String {
        switch edge { case .bottom: return "arrow.down"; case .left: return "arrow.left"; case .right: return "arrow.right"; case .top: return "arrow.up" }
    }
}
