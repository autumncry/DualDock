import SwiftUI
import DualDockCore

struct InteractionSettingsView: View {
    @Environment(\.dualDockLanguage) private var localize
    @ObservedObject var store: AppStore
    var section: SettingsSection = .interaction

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if section == .interaction {
                SettingsGroup(localize("自动隐藏", "Auto-hide")) {
                    Toggle(localize("最大化窗口时隐藏 Dock", "Hide the Dock for maximized windows"), isOn: Binding(get: { store.configuration.autoHideWhenMaximized }, set: { value in
                        store.update { $0.autoHideWhenMaximized = value }
                    }))
                    Text(localize("窗口铺满工作区时隐藏，边缘停留即可唤出。普通窗口遮挡不会触发。全屏应用也支持边缘唤出；使用分组、预览或菜单时保持显示。", "When a window fills the work area, hold the pointer at the Dock edge to reveal it. This also works in full screen. The Dock stays visible while a group, preview, or menu is open."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if section == .interaction {
                SettingsGroup(localize("点击应用图标", "Clicking app icons")) {
                    Text(localize("后台窗口先前置，再次点击最小化；继续点击可还原同一个窗口。", "Click an app to bring its selected window forward. Click again to minimize it, then again to restore it."))
                    Text(localize("右键图标可选择具体窗口。全屏和最大化窗口只激活，不会被最小化。动画跟随系统与原应用。", "Right-click an icon to select a window. Maximized and full-screen windows are brought forward. Animations follow macOS and the app."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if section == .magnification {
                SettingsGroup(localize("悬停放大", "Magnification")) {
                    if store.configuration.adaptiveSizing {
                        LabeledContent(localize("跟随系统 Dock", "Follow System Dock"), value: store.nativeDockMetrics.magnificationEnabled ? localize("已开启放大", "Magnification on") : localize("未开启放大", "Magnification off"))
                        if store.nativeDockMetrics.magnificationEnabled {
                            LabeledContent(localize("放大后图标", "Magnified icon size"), value: dockPoints(store.nativeDockMetrics.magnifiedIconSize))
                        }
                        Text(localize("完全自适应模式下，放大继续跟随系统 Dock，不提供手动曲线控件。关闭自适应后可分别调整峰值和联动范围。", "Magnification follows the system Dock. Choose Custom sizing to adjust the peak and range separately."))
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Toggle(localize("鼠标悬停放大", "Magnify icons on hover"), isOn: Binding(get: { store.configuration.magnificationEnabled }, set: { value in
                            store.update { $0.magnificationEnabled = value }
                        }))
                        DockSettingsSlider(title: localize("放大峰值", "Peak magnification"),
                                           valueText: "\(Int((store.configuration.magnificationScale * 100).rounded()))%",
                                           value: Binding(get: { store.configuration.magnificationScale }, set: { value in
                            store.update { $0.magnificationScale = value }
                        }), range: 1...2.5, onEditingChanged: { if !$0 { store.flushPendingSave() } })
                        .disabled(!store.configuration.magnificationEnabled)
                        DockSettingsSlider(title: localize("联动范围", "Magnification range"),
                                           valueText: String(format: localize("左右各 %.1f 个图标", "%.1f icons on either side"), store.configuration.magnificationRadius),
                                           value: Binding(get: { store.configuration.magnificationRadius }, set: { value in
                            store.update { $0.magnificationRadius = value }
                        }), range: 1...4, onEditingChanged: { if !$0 { store.flushPendingSave() } })
                        .disabled(!store.configuration.magnificationEnabled)
                        Text(localize("峰值决定指针下的图标放多大；收窄联动范围，可减小两侧图标的放大效果。", "The peak sets the size under the pointer. A narrower range reduces magnification on either side."))
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        MagnificationCurvePreview(peak: store.configuration.magnificationScale,
                                                  radius: store.configuration.magnificationRadius,
                                                  enabled: store.configuration.magnificationEnabled)
                    }
                    Text(localize("鼠标附近的图标逐级联动，底板保持稳定。", "Nearby icons scale smoothly while the Dock background stays in place."))
                        .foregroundStyle(.secondary)
                }
            }
            if section == .interaction {
                SettingsGroup(localize("窗口预览", "Window previews")) {
                    Toggle(localize("悬停显示窗口预览", "Show window previews on hover"), isOn: Binding(get: { store.configuration.showPreviews }, set: { value in
                        store.update { $0.showPreviews = value }
                    }))
                    Text(localize("点击缩略图切换窗口。支持关闭的窗口会在右上角显示 ×。未保存内容由原应用确认，无法取得有效截图的窗口不显示预览。", "Click a thumbnail to activate its window. A × appears when that window supports closing. The app handles unsaved changes. Windows without a usable thumbnail are omitted."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if section == .notifications {
                SettingsGroup(localize("消息提醒", "Notifications")) {
                    Toggle(localize("显示消息数量角标", "Show notification badges"), isOn: Binding(get: { store.configuration.showBadges }, set: { value in
                        store.update { $0.showBadges = value }
                    }))
                    DockSettingsSlider(title: localize("角标大小", "Badge size"),
                                       valueText: store.configuration.badgeScale.formatted(.percent.precision(.fractionLength(0))),
                                       value: Binding(get: { store.configuration.badgeScale }, set: { scale in
                        store.update { $0.badgeScale = scale }
                    }), range: DockConfiguration.badgeScaleRange,
                        onEditingChanged: { if !$0 { store.flushPendingSave() } })
                        .disabled(!store.configuration.showBadges)
                    Text(badgeDescription).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var badgeDescription: String {
        guard store.configuration.showBadges else { return localize("应用与应用组的角标已关闭。", "Badges are turned off for apps and groups.") }
        switch store.badgeStatus {
        case .permissionRequired: return localize("请在权限页允许辅助功能，以读取系统提供的角标。", "Grant Accessibility access in Permissions to read system Dock badges.")
        case .unavailable: return localize("暂时无法读取系统角标，稍后会自动重试。", "System badges are temporarily unavailable. DualDock will retry automatically.")
        case .available, .disabled: return localize("单个应用显示原有数量；组内有未读提醒时，文件夹显示红色叹号。", "An app shows its own badge. A group shows a red exclamation mark when any member has unread notifications.")
        }
    }
}
