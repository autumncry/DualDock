import SwiftUI

struct PermissionsSettingsView: View {
    @Environment(\.dualDockLanguage) private var localize
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            permissionRow(localize("屏幕录制", "Screen Recording"), description: localize("为已打开的窗口生成缩略图。预览图只在本机内存中处理。", "Generates thumbnails of open windows. Previews are processed in memory on this Mac."),
                          granted: store.captureGranted) { store.requestCapture() }
            Divider()
            permissionRow(localize("辅助功能", "Accessibility"), description: localize("识别、切换和关闭对应窗口，并读取系统 Dock 的布局信息。", "Identifies, activates, and closes individual windows and reads system Dock layout information."),
                          granted: store.accessibilityGranted) { store.requestAccessibility() }
            Button(localize("刷新授权状态", "Refresh Permissions")) { store.refreshPermissions() }
            Text(localize("修改权限后如未立即生效，请退出并重新打开 DualDock。", "If a permission change has not taken effect, quit and reopen DualDock."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionRow(_ title: String, description: String, granted: Bool,
                               action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : "lock.circle")
                .foregroundStyle(granted ? Color.green : Color.secondary).font(.title2)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(granted ? localize("已授权", "Granted") : localize("授权", "Grant Access"), action: action).disabled(granted)
        }
    }
}
