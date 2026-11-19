import SwiftUI

struct DockHelpSettingsView: View {
    @Environment(\.dualDockLanguage) private var localize
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup(localize("整理应用", "Organize apps")) {
                Label(localize("从 Finder 拖入应用，或在通用页中添加。", "Drag apps from Finder or add them in General."), systemImage: "plus.app")
                Label(localize("在另一图标中央停留片刻后松开，合成应用组。", "Hold an app over the center of another icon, then release to create a group."), systemImage: "folder")
                Label(localize("点击文件夹展开；右键可重命名或拆分。", "Click a folder to expand it. Right-click to rename or ungroup it."), systemImage: "cursorarrow.click")
            }
            SettingsGroup(localize("调整外观", "Adjust the Dock")) {
                Text(localize("先选择一个预设，再调大小、图标间距和长度。固定示例图标会随设置变化。", "Choose a preset, then adjust icon size, spacing, and Dock length. The sample icons reflect your settings."))
                DisclosureGroup(localize("大小与高级设置有什么区别？", "How do sizing controls work?")) {
                    Text(localize("大小控制图标，栏高默认自动计算。图标间距为 0 时可见边界贴合，100 时相隔约一个图标宽度。高级设置保留留白、高度与溢出选项，点击整条标题行即可展开。", "Size controls the icons. Dock height adjusts automatically. At 0% spacing, neighboring icons touch. At 100%, the gap is about one icon wide. Click the Advanced header to adjust padding, height, and overflow."))
                        .foregroundStyle(.secondary).padding(.top, 8)
                }
                DisclosureGroup(localize("如何直接拖动 Dock？", "How do I resize the Dock directly?")) {
                    Text(localize("拖内侧边调整高度，图标保留比例；拖两端调整长度；拖内侧角落同时缩放两轴。在贴合内容模式下，两端拖动会设定留白。旋转到屏幕侧边后，方向随之旋转。", "Drag the inner edge to change height, either end to change length, or an inner corner to scale both. Icons keep their proportions. In Fit mode, dragging an end changes the padding. These handles rotate with the Dock."))
                        .foregroundStyle(.secondary).padding(.top, 8)
                }
            }
            SettingsGroup(localize("切换与管理窗口", "Switch and manage windows")) {
                Text(localize("右键应用图标，选择要操作的窗口。普通窗口在前台时，再点图标可最小化；继续点击可还原。后台窗口会先前置。", "Right-click an app to choose a window. Click the icon to bring that window forward, click again to minimize it, and click once more to restore it."))
                Text(localize("全屏和最大化窗口只激活。悬停可看预览，可关闭的窗口右上角会显示 ×；未保存内容由原应用确认。", "Clicking a maximized or full-screen window brings it forward. Hover over an app to preview its windows. A × appears on windows that support closing. The app handles any unsaved changes."))
                    .foregroundStyle(.secondary)
            }
            SettingsGroup(localize("多屏与全屏", "Multiple displays and full screen")) {
                Text(localize("每块屏幕可以单独选择位置，尺寸可选择同步。全屏时，在该屏 Dock 所在边缘停留即可唤出；移开后自动收起。", "Choose an edge for each display and optionally sync Dock sizes. In full screen, hold the pointer at the Dock edge to reveal it. Move away to hide it again."))
                Text(localize("镜像屏幕由 macOS 复制源屏幕的画面。", "A mirrored display shows the same Dock as its source."))
                    .foregroundStyle(.secondary)
            }
            Text(localize("设置入口：右键 Dock 空白处，或点击菜单栏的双屏图标。", "To open Settings, right-click an empty area of the Dock or click the DualDock menu bar icon."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }.fixedSize(horizontal: false, vertical: true)
    }
}
