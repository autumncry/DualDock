import SwiftUI

struct PermissionsSettingsView: View {
    @Environment(\.dualDockLanguage) private var localize
    @ObservedObject var store: AppStore
    @State private var showCaptureHelp = false
    @State private var attemptedRegistration = false

    var body: some View {
        SettingsGroup(localize("权限", "Permissions"), spacing: 10) {
            SettingsOptionRow(localize("屏幕录制", "Screen Recording"),
                              detail: localize("在本机内存中生成窗口缩略图。", "Generates window thumbnails in memory on this Mac."),
                              symbol: "record.circle") {
                if store.captureGranted {
                    grantedLabel
                } else {
                    Button(localize("打开屏幕录制设置", "Open Screen Recording Settings")) {
                        if !ScreenRecordingSettings.openPane() { showCaptureHelp = true }
                    }
                }
            }
            if !store.captureGranted {
                DisclosureGroup(localize("列表中没有此应用？", "App missing from the list?"), isExpanded: $showCaptureHelp) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(localize("在“系统设置 → 隐私与安全性 → 录屏与系统录音”中点 ＋，添加正在运行的这个 App。", "In System Settings → Privacy & Security → Screen & System Audio Recording, click + and add this copy of the app."))
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button(localize("在访达中显示此应用", "Show This App in Finder")) {
                                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                            }
                            Button(localize("请求系统登记", "Request System Access")) {
                                attemptedRegistration = true
                                store.requestCapture()
                            }.disabled(attemptedRegistration)
                        }
                    }.padding(.top, 4)
                }
            }
            Divider()
            permissionRow(localize("辅助功能", "Accessibility"), symbol: "accessibility",
                          description: localize("切换和关闭指定窗口，读取系统 Dock 布局。", "Activates and closes individual windows and reads the system Dock layout."),
                          granted: store.accessibilityGranted) { store.requestAccessibility() }
            Divider()
            HStack(alignment: .center, spacing: 12) {
                Text(localize("返回时会自动刷新。若 macOS 要求重启，请重新打开本应用。", "The status refreshes when you return. If macOS asks, quit and reopen this app."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(localize("刷新授权状态", "Refresh Permissions")) { store.refreshPermissions() }
                    .fixedSize()
            }
        }
    }

    private var grantedLabel: some View {
        Label(localize("已授权", "Granted"), systemImage: "checkmark.circle.fill")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary, .green)
    }

    private func permissionRow(_ title: String, symbol: String, description: String, granted: Bool,
                               action: @escaping () -> Void) -> some View {
        SettingsOptionRow(title, detail: description, symbol: symbol) {
            if granted {
                grantedLabel
            } else {
                Button(localize("授权", "Grant Access"), action: action)
                    .accessibilityLabel(localize("允许\(title)", "Grant \(title) access"))
            }
        }
    }
}

/// Unlike the one-time TCC consent prompt, the pane can be reopened after denial.
@MainActor
enum ScreenRecordingSettings {
    static func openPane(open: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
        let panes = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        ]
        return panes.compactMap(URL.init(string:)).contains(where: open)
    }
}
