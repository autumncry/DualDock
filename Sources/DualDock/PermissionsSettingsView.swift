import SwiftUI

struct PermissionsSettingsView: View {
    @Environment(\.dualDockLanguage) private var localize
    @ObservedObject var store: AppStore

    var body: some View {
        SettingsGroup(localize("权限", "Permissions"), spacing: 10) {
            permissionRow(localize("屏幕录制", "Screen Recording"),
                          description: localize("在本机内存中生成窗口缩略图。", "Generates window thumbnails in memory on this Mac."),
                          granted: store.captureGranted) { store.requestCapture() }
            Divider()
            permissionRow(localize("辅助功能", "Accessibility"),
                          description: localize("切换和关闭指定窗口，读取系统 Dock 布局。", "Activates and closes individual windows and reads the system Dock layout."),
                          granted: store.accessibilityGranted) { store.requestAccessibility() }
            Divider()
            HStack(alignment: .center, spacing: 12) {
                Text(localize("授权后如未生效，请重新打开 DualDock。", "If changes haven’t taken effect, quit and reopen DualDock."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(localize("刷新授权状态", "Refresh Permissions")) { store.refreshPermissions() }
                    .fixedSize()
            }
        }
    }

    private func permissionRow(_ title: String, description: String, granted: Bool,
                               action: @escaping () -> Void) -> some View {
        SettingsOptionRow(title, detail: description) {
            if granted {
                Label(localize("已授权", "Granted"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary, .green)
            } else {
                Button(localize("授权", "Grant Access"), action: action)
                    .accessibilityLabel(localize("允许\(title)", "Grant \(title) access"))
            }
        }
    }
}
