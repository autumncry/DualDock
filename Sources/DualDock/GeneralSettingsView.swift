import SwiftUI
import DualDockCore

struct GeneralSettingsView: View {
    @ObservedObject var store: AppStore
    @StateObject private var launchAtLogin: LaunchAtLoginService

    init(store: AppStore, launchAtLogin: LaunchAtLoginService? = nil) {
        self.store = store
        _launchAtLogin = StateObject(wrappedValue: launchAtLogin ?? LaunchAtLoginService())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup("显示内容") {
                Picker("显示模式", selection: Binding(get: { store.configuration.mode }, set: { value in
                    store.update { $0.mode = value }
                })) {
                    Text("固定应用与分组 + 运行应用").tag(DockMode.standard)
                    Text("仅正在运行的应用").tag(DockMode.runningOnly)
                }.labelsHidden().pickerStyle(.radioGroup)
                Text("显示内容在所有屏幕同步；切回普通模式会恢复分组与排列。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            SettingsGroup("启动") {
                Toggle("登录时启动", isOn: Binding(get: { launchAtLogin.isEnabled }, set: {
                    launchAtLogin.setEnabled($0)
                }))
                .disabled(!launchAtLogin.canChangeRegistration || launchAtLogin.status == .requiresApproval)
                Text(loginDescription)
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if launchAtLogin.status == .requiresApproval {
                    HStack {
                        Button("打开系统登录项") { launchAtLogin.openSystemSettings() }
                        Button("取消启动申请") { launchAtLogin.setEnabled(false) }
                    }
                }
                if let error = launchAtLogin.errorMessage {
                    Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            SettingsGroup("系统 Dock") {
                Toggle("隐藏系统 Dock", isOn: Binding(get: { store.configuration.hideSystemDock }, set: {
                    store.setSystemDockHidden($0)
                }))
                Text("正常退出时恢复系统 Dock。全屏时 DualDock 自动隐藏，鼠标停留在对应屏幕边缘即可唤出。")
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
        .onAppear { launchAtLogin.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
    }

    private var loginDescription: String {
        switch launchAtLogin.status {
        case .notRegistered: return "登录 macOS 后自动启动 DualDock。当前未开启。"
        case .enabled: return "已开启，下次登录 macOS 后会自动启动 DualDock。"
        case .requiresApproval: return "等待系统允许，尚未启用自动启动。请在系统登录项中允许 DualDock。"
        case .notFound: return "系统未找到可注册的应用，请从“应用程序”中的 DualDock 重新打开。"
        case .unknown: return "暂时无法读取登录启动状态，请稍后重试。"
        }
    }
}
