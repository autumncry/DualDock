import SwiftUI

struct DockHelpSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup("整理应用") {
                Label("从 Finder 拖入应用，或在通用页中添加。", systemImage: "plus.app")
                Label("在另一图标中央停留片刻后松开，合成应用组。", systemImage: "folder")
                Label("点击文件夹展开；右键可重命名或拆分。", systemImage: "cursorarrow.click")
            }
            SettingsGroup("调整外观") {
                Text("先选择一个预设，再调大小、疏密和长度。预览会同步展示结果。")
                DisclosureGroup("大小与高级设置有什么区别？") {
                    Text("大小直接控制图标，栏高默认自动计算。疏密联动自动间距与留白。高级设置可单独固定参数，每项都能恢复自动；手动值不会被基础调节覆盖。")
                        .foregroundStyle(.secondary).padding(.top, 8)
                }
                DisclosureGroup("如何直接拖动 Dock？") {
                    Text("拖内侧边调整高度，图标保留比例；拖两端调整长度；拖内侧角落同时缩放两轴。在贴合内容模式下，两端拖动会设定留白。旋转到屏幕侧边后，方向随之旋转。")
                        .foregroundStyle(.secondary).padding(.top, 8)
                }
            }
            SettingsGroup("切换与管理窗口") {
                Text("右键应用图标，选择要操作的窗口。普通窗口在前台时，再点图标可最小化；继续点击可还原。后台窗口会先前置。")
                Text("全屏和最大化窗口只激活。悬停可看预览，右上角 × 请求关闭对应窗口；未保存内容由原应用确认。")
                    .foregroundStyle(.secondary)
            }
            SettingsGroup("多屏与全屏") {
                Text("每块屏幕可以单独选择位置，尺寸可选择同步。全屏时，在该屏 Dock 所在边缘停留即可唤出；移开后自动收起。")
                Text("镜像屏幕由 macOS 复制源屏幕的画面。")
                    .foregroundStyle(.secondary)
            }
            Text("设置入口：右键 Dock 空白处，或点击菜单栏的双屏图标。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }.fixedSize(horizontal: false, vertical: true)
    }
}
