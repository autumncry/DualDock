import SwiftUI
import DualDockCore

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @State private var section = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 25, weight: .medium)).foregroundStyle(.tint)
                    .frame(width: 52, height: 52).background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("DualDock").font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("每块屏幕，同一套工作空间").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Picker("设置分类", selection: $section) {
                Text("Dock").tag(0)
                Text("权限").tag(1)
                Text("使用方法").tag(2)
            }.pickerStyle(.segmented).padding(.horizontal, 24).padding(.bottom, 18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if section == 0 { dockSettings }
                    if section == 1 { permissions }
                    if section == 2 { instructions }
                    if let message = store.message {
                        HStack(alignment: .top) {
                            Image(systemName: "info.circle")
                            Text(message).font(.callout).textSelection(.enabled)
                            Spacer()
                            Button { store.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text("个人版 · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("打开配置目录") { store.revealConfiguration() }.buttonStyle(.link)
            }.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 550, height: 580)
        .onAppear { store.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.refreshPermissions() }
    }

    private var dockSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                Text("显示内容").font(.headline)
                Picker("显示模式", selection: Binding(get: { store.configuration.mode }, set: { value in store.update { $0.mode = value } })) {
                    Text("固定应用与分组 + 运行应用").tag(DockMode.standard)
                    Text("仅正在运行的应用").tag(DockMode.runningOnly)
                }.labelsHidden().pickerStyle(.radioGroup)
                Text("所有屏幕同步切换。返回普通模式时，分组和排列会恢复。").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Dock 大小").font(.headline)
                    Spacer()
                    Text("\(Int((store.configuration.iconSize / 48 * 100).rounded()))%").foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: Binding(get: { store.configuration.iconSize }, set: { value in store.update { $0.iconSize = value } }), in: 24...96)
                HStack { Text("小"); Spacer(); Text("大") }.font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("图标间距").font(.headline)
                Slider(value: Binding(get: { store.configuration.iconSpacing }, set: { value in store.update { $0.iconSpacing = value } }), in: 0...32)
                HStack { Text("紧凑"); Spacer(); Text("宽松") }.font(.caption).foregroundStyle(.secondary)
            }
            Text("所有屏幕同步应用大小与间距。超出屏幕宽度的内容可横向滚动。").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Toggle("鼠标悬停放大", isOn: Binding(get: { store.configuration.magnificationEnabled }, set: { value in store.update { $0.magnificationEnabled = value } }))
                HStack {
                    Text("放大幅度")
                    Spacer()
                    Text("\(Int((store.configuration.magnificationScale * 100).rounded()))%").foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: Binding(get: { store.configuration.magnificationScale }, set: { value in store.update { $0.magnificationScale = value } }), in: 1...2.5)
                    .disabled(!store.configuration.magnificationEnabled)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("显示消息数量角标", isOn: Binding(get: { store.configuration.showBadges }, set: { value in store.update { $0.showBadges = value } }))
                Text(badgeDescription).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("悬停显示窗口预览", isOn: Binding(get: { store.configuration.showPreviews }, set: { value in store.update { $0.showPreviews = value } }))
            VStack(alignment: .leading, spacing: 6) {
                Toggle("隐藏系统 Dock", isOn: Binding(get: { store.configuration.hideSystemDock }, set: { store.setSystemDockHidden($0) }))
                Text("退出 DualDock 后自动恢复。全屏应用只会隐藏所在屏幕的 DualDock。").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("添加应用…") { store.addApplications() }
                Button("重新导入系统 Dock") { store.importPins() }
                Spacer()
            }
            Text("重新导入会补入尚未固定的应用，保留已有分组和顺序。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var badgeDescription: String {
        guard store.configuration.showBadges else { return "应用与应用组的角标已关闭。" }
        switch store.badgeStatus {
        case .permissionRequired:
            return "请在权限页允许辅助功能，以读取系统提供的角标。"
        case .unavailable:
            return "暂时无法读取系统角标，稍后会自动重试。"
        case .available, .disabled:
            return "单个应用显示原有数量；组内有未读提醒时，文件夹显示红色叹号。"
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 24) {
            permissionRow("屏幕录制", description: "为已打开的窗口生成缩略图。预览图仅在内存中处理。", granted: store.captureGranted) { store.requestCapture() }
            permissionRow("辅助功能", description: "点击预览时准确切换窗口，并恢复最小化的窗口。", granted: store.accessibilityGranted) { store.requestAccessibility() }
            Button("刷新授权状态") { store.refreshPermissions() }
            Text("修改权限后如未立即生效，请退出并重新打开 DualDock。").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func permissionRow(_ title: String, description: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : "lock.circle")
                .foregroundStyle(granted ? Color.green : Color.secondary).font(.title2)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(description).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(granted ? "已授权" : "授权", action: action).disabled(granted)
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 20) {
            instruction("1", "整理应用", "从 Finder 拖入应用。拖到图标边缘可调整顺序；在另一个应用图标中央停留片刻再松开，即可合成应用组。")
            instruction("2", "展开与编辑分组", "点击应用组横向展开。成员可拖回主栏，也可在组内重排。右键应用组可以重命名或展开为独立应用。")
            instruction("3", "切换窗口", "悬停运行中的应用显示窗口预览，点击缩略图切换。无法捕获有效截图的窗口不显示预览。")
            instruction("4", "在多屏上使用", "扩展屏各有一条 Dock，镜像屏随系统复制。显示器连接变化时自动调整，全部屏幕共享布局。")
        }
    }

    private func instruction(_ number: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.system(.caption, design: .rounded).weight(.bold)).foregroundStyle(.tint)
                .frame(width: 25, height: 25).background(.tint.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(text).font(.callout).foregroundStyle(.secondary) }
        }
    }
}
