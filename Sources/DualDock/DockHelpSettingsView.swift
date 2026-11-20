import SwiftUI

struct DockHelpSettingsView: View {
    @Environment(\.dualDockLanguage) private var localize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    guideRow(localize("整理应用", "Organize apps"), symbol: "folder") {
                        Text(localize("从 Finder 拖入应用，也可在“通用”中添加。将图标拖到另一个图标中央，稍作停留再松开即可成组。点击展开分组，右键重命名或拆分。", "Drag apps from Finder or add them in General. Hold an icon over another, then release to make a group. Click to expand the group or right-click to rename or ungroup it."))
                    }
                    Divider()
                    guideRow(localize("切换窗口", "Switch windows"), symbol: "macwindow") {
                        Text(localize("点击图标前置窗口，再点最小化，继续点还原。右键可指定窗口。最大化或全屏窗口只前置。悬停可查看预览，可关闭的窗口会显示 ×，未保存内容由原应用确认。", "Click an icon to bring its window forward, click again to minimize, and again to restore. Right-click to choose a window. Full-screen and maximized windows stay open. Hover to preview a window. The × closes supported windows with the app’s usual save confirmation."))
                    }
                    Divider()
                    guideRow(localize("多屏与全屏", "Displays & full screen"), symbol: "display") {
                        Text(localize("每块屏幕可单独设定位置，尺寸可选择同步。镜像屏幕跟随源屏幕。全屏时，指针在 Dock 所在边缘停留即可唤出，移开后收起。", "Set a position for each display and optionally sync their sizes. Mirrored displays follow their source. In full screen, hold the pointer at the Dock edge to reveal it and move away to hide it."))
                    }
                }.padding(.horizontal, 6)
            }
            SettingsGroup(localize("调整外观", "Adjust the Dock"), spacing: 8) {
                Text(localize("选择预设，再调大小、图标间距和长度。示例图标会随设置变化。", "Choose a preset, then adjust size, spacing, and length. The sample icons follow these settings."))
                DisclosureGroup(localize("大小与高级设置有什么区别？", "How do sizing controls work?")) {
                    Text(localize("大小控制图标，栏高默认自动计算。0% 间距使可见图标边缘贴合，100% 留出约一个图标宽度。展开“高级设置”可调整留白、栏高与溢出行为。", "Size controls the icons and the Dock normally grows to fit them. At 0% spacing the visible edges touch. At 100% the gap is about one icon wide. Open Advanced for padding, Dock height, and overflow."))
                        .foregroundStyle(.secondary).padding(.top, 4)
                }
                DisclosureGroup(localize("如何直接拖动 Dock？", "How do I resize the Dock directly?")) {
                    Text(localize("拖内侧边调整高度，图标保留比例。拖两端调整长度，贴合内容时，两端拖动设定留白。拖内侧角落等比缩放，拖动方向随 Dock 位置旋转。", "Drag the inner edge to change height or either end to change length. In Fit mode, dragging an end sets the padding. Drag an inner corner to scale both axes. Icons keep their proportions and the handles follow the Dock position."))
                        .foregroundStyle(.secondary).padding(.top, 4)
                }
            }
            Text(localize("右键 Dock 空白处或点击菜单栏的 DualDock 图标即可打开设置。", "Open Settings from the menu bar icon or by right-clicking an empty area of the Dock."))
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func guideRow<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label {
                Text(title).font(.system(size: 14, weight: .medium))
            } icon: {
                Image(systemName: symbol).foregroundStyle(.secondary)
            }.frame(width: 128, alignment: .leading)
            content().font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 9)
    }
}
