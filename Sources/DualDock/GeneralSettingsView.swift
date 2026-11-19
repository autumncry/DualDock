import SwiftUI
import DualDockCore

struct GeneralSettingsView: View {
    @Environment(\.dualDockLanguage) private var localize
    let section: SettingsSection
    @ObservedObject var store: AppStore
    @StateObject private var launchAtLogin: LaunchAtLoginService

    init(store: AppStore, launchAtLogin: LaunchAtLoginService? = nil, section: SettingsSection = .general) {
        self.section = section
        self.store = store
        _launchAtLogin = StateObject(wrappedValue: launchAtLogin ?? LaunchAtLoginService())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if section == .general {
                HStack {
                    Text(localize("显示语言", "Display language"))
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Picker(localize("显示语言", "Display language"), selection: Binding(
                        get: { localize }, set: { AppLanguage.set($0) })) {
                            Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
                            Text(verbatim: "English").tag(AppLanguage.english)
                        }
                        .labelsHidden()
                        .frame(width: 156)
                }
            }
            if section == .contents {
                SettingsGroup(localize("显示内容", "Dock contents")) {
                    Picker(localize("显示模式", "Display mode"), selection: Binding(get: { store.configuration.mode }, set: { value in
                        store.update { $0.mode = value }
                    })) {
                        Text(localize("固定应用与分组 + 运行应用", "Pinned apps and groups, plus running apps")).tag(DockMode.standard)
                        Text(localize("仅正在运行的应用", "Running apps only")).tag(DockMode.runningOnly)
                    }.labelsHidden().pickerStyle(.radioGroup)
                    Text(localize("显示内容在所有屏幕同步；切回普通模式会恢复分组与排列。", "This choice applies to all displays. Switch back to pinned apps to restore your groups and order."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if section == .general {
                SettingsGroup(localize("启动", "Startup")) {
                    Toggle(localize("登录时启动", "Launch at login"), isOn: Binding(get: { launchAtLogin.isEnabled }, set: {
                        launchAtLogin.setEnabled($0)
                    }))
                    .disabled(!launchAtLogin.canChangeRegistration || launchAtLogin.status == .requiresApproval)
                    Text(loginDescription)
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if launchAtLogin.status == .requiresApproval || launchAtLogin.errorMessage != nil {
                        HStack {
                            Button(localize("打开系统登录项", "Open Login Items Settings")) { launchAtLogin.openSystemSettings() }
                            if launchAtLogin.status == .requiresApproval {
                                Button(localize("取消启动申请", "Cancel Request")) { launchAtLogin.setEnabled(false) }
                            }
                        }
                    }
                    if let error = launchAtLogin.errorMessage {
                        Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }
            if section == .systemDock {
                SettingsGroup(localize("系统 Dock", "System Dock")) {
                    Toggle(localize("隐藏系统 Dock", "Hide the system Dock"), isOn: Binding(get: { store.configuration.hideSystemDock }, set: {
                        store.setSystemDockHidden($0)
                    }))
                    Text(localize("正常退出时恢复系统 Dock。全屏时 DualDock 自动隐藏，鼠标停留在对应屏幕边缘即可唤出。", "Quitting DualDock restores the system Dock. In full screen, hold the pointer at the Dock edge to reveal DualDock."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(localize("恢复系统 Dock", "Restore System Dock")) { store.restoreSystemDock() }
                }
            }
            if section == .apps {
                SettingsGroup(localize("应用与配置", "Apps and configuration")) {
                    HStack {
                        Button(localize("添加应用…", "Add Apps…")) { store.addApplications() }
                        Button(localize("重新导入系统 Dock", "Import System Dock Apps")) { store.importPins() }
                    }
                    Text(localize("重新导入会补入尚未固定的应用，保留已有分组和顺序。应用组通过 Dock 上的拖拽整理。", "Import adds missing pinned apps and keeps your groups and order. Drag icons in the Dock to organize them."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(localize("打开配置目录", "Open Configuration Folder")) { store.revealConfiguration() }
                }
            }
        }
        .onAppear { launchAtLogin.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
    }

    private var loginDescription: String {
        switch launchAtLogin.status {
        case .notRegistered, .notFound: return localize("登录 macOS 后自动启动 DualDock。当前未开启。", "Start DualDock automatically when you log in to macOS.")
        case .enabled: return localize("已开启，下次登录 macOS 后会自动启动 DualDock。", "DualDock will start automatically the next time you log in.")
        case .requiresApproval: return localize("等待系统允许，尚未启用自动启动。请在系统登录项中允许 DualDock。", "Approval is pending. Allow DualDock in Login Items to enable automatic startup.")
        case .unknown: return localize("暂时无法读取登录启动状态，请稍后重试。", "Login item status is temporarily unavailable. Try again later.")
        }
    }
}
