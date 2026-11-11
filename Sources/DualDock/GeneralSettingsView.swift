import SwiftUI
import DualDockCore

struct GeneralSettingsView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup("显示内容") {
                Picker("显示模式", selection: Binding(get: { store.configuration.mode }, set: { value in
                    store.update { $0.mode = value }
                })) {
                    Text("固定应用与分组 + 运行应用").tag(DockMode.standard)
                    Text("仅正在运行的应用").tag(DockMode.runningOnly)
                }.labelsHidden().pickerStyle(.radioGroup)
                Text("显示内容在所有屏幕同步。仅运行模式会平铺普通运行应用；切回后恢复原有分组与排列。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            SettingsGroup("系统 Dock") {
                Toggle("隐藏系统 Dock", isOn: Binding(get: { store.configuration.hideSystemDock }, set: {
                    store.setSystemDockHidden($0)
                }))
                Text("正常退出时恢复由 DualDock 修改的系统 Dock 设置。进入全屏应用时，只隐藏所在屏幕的 DualDock。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("恢复系统 Dock") { store.restoreSystemDock() }
            }
            SettingsGroup("应用与配置") {
                HStack {
                    Button("添加应用…") { store.addApplications() }
                    Button("重新导入系统 Dock") { store.importPins() }
                }
                Text("重新导入会补入尚未固定的应用，保留已有分组和顺序。应用组通过 Dock 上的拖拽整理。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("打开配置目录") { store.revealConfiguration() }
            }
        }
    }
}
