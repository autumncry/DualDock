import SwiftUI
import DualDockCore

struct AppearanceSettingsView: View {
    @ObservedObject var store: AppStore
    @Binding var selectedDisplayID: String?
    private var adaptive: Bool { store.configuration.adaptiveSizing }
    private var availableDisplays: [DockDisplayInfo] { store.displays.filter { !$0.isMirrored } }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup("尺寸模式") {
                Toggle("完全自适应系统 Dock", isOn: Binding(
                    get: { adaptive }, set: { store.setAdaptiveSizing($0) }))
                Text("开启后，基础图标大小、栏厚度、间距、两端留白及悬停放大跟随系统 Dock。长度随应用数量适配，保持居中。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("屏幕位置仍可在“屏幕与位置”中分别选择。")
                    .foregroundStyle(.secondary)
            }
            if adaptive {
                SettingsGroup("当前系统 Dock") {
                    LabeledContent("图标大小", value: dockPoints(store.nativeDockMetrics.iconSize))
                    LabeledContent("栏厚度", value: dockPoints(store.nativeDockMetrics.barThickness))
                    LabeledContent("图标间距", value: dockPoints(store.nativeDockMetrics.itemSpacing))
                    LabeledContent("两端留白", value: "\(dockPoints(store.nativeDockMetrics.leadingPadding)) / \(dockPoints(store.nativeDockMetrics.trailingPadding))")
                    Text(nativeStatusDescription).foregroundStyle(.secondary)
                    Text("自适应模式下不提供尺寸滑块或边缘拖动。关闭后恢复手动尺寸设置。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                SettingsGroup("尺寸共享") {
                    Toggle("所有屏幕同步尺寸", isOn: Binding(get: { store.configuration.synchronizeSizes }, set: { value in
                        store.setSizeSynchronization(value, sourceDisplayID: selectedDisplayID)
                    }))
                    Text(store.configuration.synchronizeSizes
                         ? "尺寸同步到所有屏幕，屏幕位置仍单独保存。"
                         : "每块屏幕独立保存手动尺寸。重新开启同步时，会采用当前所选屏幕的尺寸。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !store.configuration.synchronizeSizes, !availableDisplays.isEmpty {
                        Picker("配置屏幕", selection: $selectedDisplayID) {
                            ForEach(availableDisplays, id: \.id) { display in
                                Text(display.name + (display.isPrimary ? "（主显示器）" : ""))
                                    .tag(Optional(display.id))
                            }
                        }
                    }
                }
                if let selectedDisplayID, availableDisplays.contains(where: { $0.id == selectedDisplayID }) {
                    ManualDockSizingSettingsView(store: store, displayID: selectedDisplayID)
                } else {
                    Label("暂未检测到可配置的显示器。连接显示器后即可调整尺寸。", systemImage: "display")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var nativeStatusDescription: String {
        switch store.nativeDockStatus {
        case .accessibility: return "已从系统 Dock 读取当前尺寸。"
        case .preferences: return "已读取系统 Dock 偏好；部分几何信息使用兼容值。"
        case .cached: return "暂时无法读取系统 Dock，正在沿用最近一次有效尺寸。"
        case .fallback: return "暂时无法读取系统 Dock，正在使用兼容尺寸，稍后会自动重试。"
        }
    }
}

private struct ManualDockSizingSettingsView: View {
    @ObservedObject var store: AppStore
    let displayID: String
    private var sizing: DockManualSizing { store.effectiveManualSizing(for: displayID) }
    private var bounds: DockResizeBounds { store.sizingBounds(for: displayID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup("栏尺寸") {
                DockSettingsSlider(title: "Dock 长度", valueText: dockPoints(sizing.length),
                                   value: binding(\.length), range: bounds.minLength...bounds.maxLength)
                DockSettingsSlider(title: "Dock 厚度", valueText: dockPoints(sizing.thickness),
                                   value: binding(\.thickness), range: bounds.minThickness...bounds.maxThickness)
                Text("上下位置时，长度对应宽度；左右位置时，长度对应高度。厚度控制贴边方向的宽窄。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("可拖动 Dock 的内侧边调整厚度、两端调整长度，内侧两个角可等比缩放。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            SettingsGroup("图标与排列") {
                DockSettingsSlider(title: "图标大小", valueText: dockPoints(store.iconSize(for: displayID)),
                                   value: binding(\.iconScale), range: 0.25...1.25)
                Text("手动调节图标在栏内的相对大小；以后改变 Dock 厚度或等比缩放时，会保留这个比例。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DockSettingsSlider(title: "图标间距", valueText: dockPoints(sizing.iconSpacing),
                                   value: binding(\.iconSpacing), range: 0...32)
                Text("长度不足以显示全部应用时，可以沿 Dock 方向滚动。尺寸限制会随显示器与位置调整。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<DockManualSizing, Double>) -> Binding<Double> {
        Binding(get: { sizing[keyPath: keyPath] }, set: { value in
            store.updateManualSizing(for: displayID) { $0[keyPath: keyPath] = value }
        })
    }
}
