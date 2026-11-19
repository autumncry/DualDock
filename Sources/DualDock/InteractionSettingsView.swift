import SwiftUI
import DualDockCore

struct InteractionSettingsView: View {
    @Environment(\.dualDockLanguage) private var localize
    @ObservedObject var store: AppStore
    var section: SettingsSection = .interaction

    var body: some View {
        SettingsGroup(section.title, spacing: 10) {
            switch section {
            case .interaction: windowOptions
            case .magnification: magnification
            case .notifications: notifications
            default: EmptyView()
            }
        }
    }

    private var windowOptions: some View {
        Group {
            SettingsSwitchRow(
                title: localize("最大化窗口时隐藏 Dock", "Hide the Dock for maximized windows"),
                detail: localize("窗口铺满或全屏时，停留在屏幕边缘可唤出 Dock。使用分组、预览或菜单时保持显示。",
                                 "Hold the pointer at the screen edge to reveal the Dock. It stays visible while you use a group, preview, or menu."),
                isOn: binding(\.autoHideWhenMaximized))
            Divider()
            SettingsSwitchRow(
                title: localize("悬停显示窗口预览", "Show window previews on hover"),
                detail: localize("点缩略图切换窗口，点 × 关闭对应窗口。未保存内容由原应用确认。",
                                 "Click a thumbnail to switch windows. Use × to close a window. The app confirms unsaved changes."),
                isOn: binding(\.showPreviews))
                .help(localize("仅显示取得有效截图的窗口。可关闭的窗口显示 ×。",
                               "Only windows with valid thumbnails appear. Windows that support closing show ×."))
            Divider()
            SettingsOptionLabel(
                title: localize("点击应用图标", "Clicking app icons"),
                detail: localize("点击依次前置、最小化和还原同一窗口。右键可选窗口。最大化或全屏的窗口只前置。",
                                 "Click to bring the selected window forward, then click again to minimize or restore it. Right-click to choose a window. Maximized and full-screen windows stay open."))
                .help(localize("窗口动画跟随 macOS 和原应用。", "Window animations follow macOS and the app."))
        }
    }

    @ViewBuilder
    private var magnification: some View {
        if store.configuration.adaptiveSizing {
            SettingsOptionRow(localize("跟随系统 Dock", "Follow System Dock"),
                              detail: localize("切换为自定义尺寸后，可调整放大峰值与联动范围。",
                                               "Choose Custom sizing to adjust the peak and range.")) {
                Text(store.nativeDockMetrics.magnificationEnabled ? localize("放大已开启", "Magnification on")
                                                                 : localize("放大已关闭", "Magnification off"))
                    .foregroundStyle(.secondary)
            }
            if store.nativeDockMetrics.magnificationEnabled {
                Divider()
                SettingsOptionRow(localize("放大后图标", "Magnified icon size")) {
                    Text(dockPoints(store.nativeDockMetrics.magnifiedIconSize)).monospacedDigit()
                }
            }
        } else {
            SettingsSwitchRow(title: localize("鼠标悬停放大", "Magnify icons on hover"),
                              detail: localize("放大指针附近的图标，Dock 底板保持稳定。",
                                               "Enlarge icons around the pointer while the Dock background stays fixed."),
                              isOn: binding(\.magnificationEnabled))
            Divider()
            DockSettingsSlider(title: localize("放大峰值", "Peak magnification"),
                               valueText: "\(Int((store.configuration.magnificationScale * 100).rounded()))%",
                               value: binding(\.magnificationScale), range: 1...2.5,
                               onEditingChanged: finishEditing)
                .disabled(!store.configuration.magnificationEnabled)
                .help(localize("指针下图标的最大放大比例。", "The maximum size of the icon under the pointer."))
            DockSettingsSlider(title: localize("联动范围", "Magnification range"),
                               valueText: String(format: localize("左右各 %.1f 个图标", "%.1f icons on either side"), store.configuration.magnificationRadius),
                               value: binding(\.magnificationRadius), range: 1...4,
                               onEditingChanged: finishEditing)
                .disabled(!store.configuration.magnificationEnabled)
                .help(localize("范围越窄，相邻图标放大越少。", "A narrower range magnifies fewer neighboring icons."))
            MagnificationCurvePreview(peak: store.configuration.magnificationScale,
                                      radius: store.configuration.magnificationRadius,
                                      enabled: store.configuration.magnificationEnabled)
        }
    }

    private var notifications: some View {
        Group {
            SettingsSwitchRow(title: localize("显示消息数量角标", "Show notification badges"),
                              detail: badgeDescription, isOn: binding(\.showBadges))
            Divider()
            DockSettingsSlider(title: localize("角标大小", "Badge size"),
                               valueText: store.configuration.badgeScale.formatted(.percent.precision(.fractionLength(0))),
                               value: binding(\.badgeScale), range: DockConfiguration.badgeScaleRange,
                               onEditingChanged: finishEditing)
                .disabled(!store.configuration.showBadges)
        }
    }

    private var badgeDescription: String {
        if store.configuration.showBadges {
            switch store.badgeStatus {
            case .permissionRequired:
                return localize("请在“权限”中允许辅助功能，以读取系统角标。", "Allow Accessibility in Permissions to read system Dock badges.")
            case .unavailable:
                return localize("暂时无法读取系统角标，稍后会自动重试。", "System badges are unavailable. DualDock will retry automatically.")
            case .available, .disabled:
                break
            }
        }
        return localize("应用显示消息数量，组内有未读时显示红色叹号。",
                        "Apps show their own counts. Groups show a red exclamation mark for unread items.")
    }

    private func binding<Value>(_ field: WritableKeyPath<DockConfiguration, Value>) -> Binding<Value> {
        Binding(get: { store.configuration[keyPath: field] }, set: { value in
            store.update { $0[keyPath: field] = value }
        })
    }

    private func finishEditing(_ editing: Bool) {
        if !editing { store.flushPendingSave() }
    }
}
