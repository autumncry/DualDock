import SwiftUI

struct PermissionsSettingsView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            permissionRow("屏幕录制", description: "为已打开的窗口生成缩略图。预览图只在本机内存中处理。",
                          granted: store.captureGranted) { store.requestCapture() }
            Divider()
            permissionRow("辅助功能", description: "识别、切换和关闭对应窗口，并读取系统 Dock 的布局信息。",
                          granted: store.accessibilityGranted) { store.requestAccessibility() }
            Button("刷新授权状态") { store.refreshPermissions() }
            Text("修改权限后如未立即生效，请退出并重新打开 DualDock。")
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
            Button(granted ? "已授权" : "授权", action: action).disabled(granted)
        }
    }
}
