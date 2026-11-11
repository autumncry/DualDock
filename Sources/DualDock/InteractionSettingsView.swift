import SwiftUI
import DualDockCore

struct InteractionSettingsView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup("悬停放大") {
                if store.configuration.adaptiveSizing {
                    LabeledContent("跟随系统 Dock", value: store.nativeDockMetrics.magnificationEnabled ? "已开启放大" : "未开启放大")
                    if store.nativeDockMetrics.magnificationEnabled {
                        LabeledContent("放大后图标", value: dockPoints(store.nativeDockMetrics.magnifiedIconSize))
                    }
                    Text("完全自适应模式下，放大开关和尺寸由系统 Dock 决定。关闭自适应后可在这里手动调整。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Toggle("鼠标悬停放大", isOn: Binding(get: { store.configuration.magnificationEnabled }, set: { value in
                        store.update { $0.magnificationEnabled = value }
                    }))
                    DockSettingsSlider(title: "放大幅度",
                                       valueText: "\(Int((store.configuration.magnificationScale * 100).rounded()))%",
                                       value: Binding(get: { store.configuration.magnificationScale }, set: { value in
                        store.update { $0.magnificationScale = value }
                    }), range: 1...2.5)
                    .disabled(!store.configuration.magnificationEnabled)
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
