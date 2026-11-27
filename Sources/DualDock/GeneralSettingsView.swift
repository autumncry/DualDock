import SwiftUI
import DualDockCore

struct GeneralSettingsView: View {
    @Environment(\.dualDockLanguage) private var localize
    let section: SettingsSection
    @ObservedObject var store: AppStore
    @ObservedObject var launchAtLogin: LaunchAtLoginService

    var body: some View {
        SettingsGroup(section.title, spacing: 10) {
            switch section {
            case .general: languageAndStartup
            case .contents: contents
            case .systemDock: systemDock
            case .apps: apps
            default: EmptyView()
            }
        }
        .onAppear { if section == .general { launchAtLogin.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if section == .general { launchAtLogin.refresh() }
        }
    }

    private var languageAndStartup: some View {
        Group {
            SettingsOptionRow(localize("显示语言", "Display language"), symbol: "globe") {
                Picker(localize("显示语言", "Display language"), selection: Binding(
                    get: { localize }, set: { AppLanguage.set($0) })) {
                        Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
                        Text(verbatim: "English").tag(AppLanguage.english)
                    }
                    .labelsHidden()
                    .frame(width: 142)
            }
            Divider()
            SettingsSwitchRow(title: localize("登录时启动", "Launch at login"),
                              detail: loginDescription, symbol: "power",
                              isOn: Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.setEnabled($0) }))
                .disabled(!launchAtLogin.canChangeRegistration || launchAtLogin.status == .requiresApproval)
            if let error = launchAtLogin.errorMessage {
                Text(error)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if launchAtLogin.status == .requiresApproval || launchAtLogin.errorMessage != nil {
                HStack(spacing: 8) {
                    Button(localize("打开系统登录项", "Open Login Items Settings")) { launchAtLogin.openSystemSettings() }
                    if launchAtLogin.status == .requiresApproval {
                        Button(localize("取消启动申请", "Cancel Request")) { launchAtLogin.setEnabled(false) }
                    }
                }
            }
        }
    }

    private var contents: some View {
        Group {
            Picker(localize("显示模式", "Display mode"), selection: Binding(get: { store.configuration.mode }, set: { value in
                store.update { $0.mode = value }
            })) {
                Text(localize("固定应用与分组 + 运行应用", "Pinned apps and groups, plus running apps")).tag(DockMode.standard)
                Text(localize("仅正在运行的应用", "Running apps only")).tag(DockMode.runningOnly)
            }
            .labelsHidden().pickerStyle(.radioGroup).font(.system(size: 13))
            Text(localize("所有屏幕同步。切回固定应用模式会恢复分组和顺序。",
                          "Applies to all displays. Switching back to pinned apps restores your groups and order."))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var systemDock: some View {
        Group {
            SettingsSwitchRow(title: localize("隐藏系统 Dock", "Hide the system Dock"),
                              detail: store.waitingForSystemDock
                                ? localize("系统 Dock 已隐藏。如果它恢复显示，DualDock 3 会接手隐藏。",
                                           "The system Dock is already hidden. DualDock 3 will hide it if it becomes visible again.")
                                : localize("在所有屏幕上隐藏 macOS Dock。关闭开关或退出 DualDock 3 时，恢复本应用更改的设置。",
                                           "Hide the macOS Dock on all displays. Turning this off or quitting DualDock 3 restores the settings this app changed."),
                              isOn: Binding(get: { store.configuration.hideSystemDock }, set: { store.setSystemDockHidden($0) }))
            Divider()
            Button(localize("恢复系统 Dock", "Restore System Dock")) { store.restoreSystemDock() }
                .disabled(!store.configuration.hideSystemDock && !store.systemDock.hasRecoveryRecord)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var apps: some View {
        Group {
            SettingsOptionRow(localize("固定应用", "Pinned apps"),
                              detail: localize("在 Dock 上拖动图标即可整理分组。", "Drag icons in the Dock to organize groups."), symbol: "pin") {
                Button(localize("添加应用…", "Add Apps…")) { store.addApplications() }
            }
            Divider()
            SettingsOptionRow(localize("从系统 Dock 导入", "Import from System Dock"),
                              detail: localize("补入尚未固定的应用，保留分组和顺序。", "Add missing apps and keep your groups and order."), symbol: "square.and.arrow.down") {
                Button(localize("重新导入", "Import Apps")) { store.importPins() }
                    .accessibilityLabel(localize("重新导入系统 Dock", "Import System Dock Apps"))
            }
            Divider()
            SettingsOptionRow(localize("配置目录", "Configuration folder"), symbol: "folder") {
                Button(localize("在访达中打开", "Open in Finder")) { store.revealConfiguration() }
                    .accessibilityLabel(localize("打开配置目录", "Open Configuration Folder"))
            }
        }
    }

    private var loginDescription: String {
        switch launchAtLogin.status {
        case .notRegistered, .notFound:
            return localize("登录 macOS 后自动打开 DualDock 3。", "Open DualDock 3 when you sign in to macOS.")
        case .enabled:
            return localize("已开启，下次登录 macOS 时生效。", "Enabled for your next macOS login.")
        case .requiresApproval:
            return localize("等待批准，请在系统登录项中允许 DualDock 3。", "Approval pending. Allow DualDock 3 in Login Items.")
        case .unknown:
            return localize("暂时无法读取登录项状态，请稍后重试。", "Login item status is unavailable. Try again later.")
        }
    }
}
