import SwiftUI
import DualDockCore

struct InteractionSettingsView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup("自动隐藏") {
                Toggle("最大化窗口时隐藏 Dock", isOn: Binding(get: { store.configuration.autoHideWhenMaximized }, set: { value in
                    store.update { $0.autoHideWhenMaximized = value }
                }))
                Text("窗口铺满工作区时隐藏，边缘停留即可唤出。普通窗口遮挡不会触发。全屏应用也支持边缘唤出；使用分组、预览或菜单时保持显示。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            SettingsGroup("点击应用图标") {
                Text("后台窗口先前置，再次点击最小化；继续点击可还原同一个窗口。")
                Text("右键图标可选择具体窗口。全屏和最大化窗口只激活，不会被最小化。动画跟随系统与原应用。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            SettingsGroup("悬停放大") {
                if store.configuration.adaptiveSizing {
                    LabeledContent("跟随系统 Dock", value: store.nativeDockMetrics.magnificationEnabled ? "已开启放大" : "未开启放大")
                    if store.nativeDockMetrics.magnificationEnabled {
                        LabeledContent("放大后图标", value: dockPoints(store.nativeDockMetrics.magnifiedIconSize))
                    }
                    Text("完全自适应模式下，放大继续跟随系统 Dock，不提供手动曲线控件。关闭自适应后可分别调整峰值和联动范围。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Toggle("鼠标悬停放大", isOn: Binding(get: { store.configuration.magnificationEnabled }, set: { value in
                        store.update { $0.magnificationEnabled = value }
                    }))
                    DockSettingsSlider(title: "放大峰值",
                                       valueText: "\(Int((store.configuration.magnificationScale * 100).rounded()))%",
                                       value: Binding(get: { store.configuration.magnificationScale }, set: { value in
                        store.update { $0.magnificationScale = value }
                    }), range: 1...2.5, onEditingChanged: { if !$0 { store.flushPendingSave() } })
                    .disabled(!store.configuration.magnificationEnabled)
                    DockSettingsSlider(title: "联动范围",
                                       valueText: String(format: "左右各 %.1f 个图标", store.configuration.magnificationRadius),
                                       value: Binding(get: { store.configuration.magnificationRadius }, set: { value in
                        store.update { $0.magnificationRadius = value }
                    }), range: 1...4, onEditingChanged: { if !$0 { store.flushPendingSave() } })
                    .disabled(!store.configuration.magnificationEnabled)
                    Text("峰值决定指针下的图标放多大；收窄联动范围，可减小两侧图标的放大效果。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    MagnificationCurvePreview(peak: store.configuration.magnificationScale,
                                              radius: store.configuration.magnificationRadius,
                                              enabled: store.configuration.magnificationEnabled)
                }
                Text("鼠标附近的图标逐级联动，底板保持稳定。")
                    .foregroundStyle(.secondary)
            }
            SettingsGroup("窗口预览") {
                Toggle("悬停显示窗口预览", isOn: Binding(get: { store.configuration.showPreviews }, set: { value in
                    store.update { $0.showPreviews = value }
                }))
                Text("点击缩略图切换窗口，点击右上角 × 请求关闭对应窗口。未保存内容由原应用确认，无法取得有效截图的窗口不显示预览。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            SettingsGroup("消息提醒") {
                Toggle("显示消息数量角标", isOn: Binding(get: { store.configuration.showBadges }, set: { value in
                    store.update { $0.showBadges = value }
                }))
                Text(badgeDescription).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var badgeDescription: String {
        guard store.configuration.showBadges else { return "应用与应用组的角标已关闭。" }
        switch store.badgeStatus {
        case .permissionRequired: return "请在权限页允许辅助功能，以读取系统提供的角标。"
        case .unavailable: return "暂时无法读取系统角标，稍后会自动重试。"
        case .available, .disabled: return "单个应用显示原有数量；组内有未读提醒时，文件夹显示红色叹号。"
        }
    }
}
