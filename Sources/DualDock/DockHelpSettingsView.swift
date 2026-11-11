import SwiftUI

struct DockHelpSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsGroup("整理应用") {
                Text("从 Finder 拖入应用，或在通用页选择“添加应用”。拖到图标边缘可排序；在另一个应用图标中央停留片刻再松开，即可合成应用组。")
            }
            SettingsGroup("展开与编辑应用组") {
                Text("点击文件夹图标，成员横向展开。成员可组内重排或拖回主栏；右键文件夹可重命名或拆分。应用夹和窗口预览会朝屏幕内侧展开。")
            }
            SettingsGroup("手动改变大小") {
                Text("先在“外观与尺寸”关闭完全自适应。鼠标移到可调整边缘时会显示双向箭头：")
                VStack(alignment: .leading, spacing: 8) {
                    Text("• 内侧边：调整栏的厚度。底部 Dock 的内侧边就是上边缘。")
                    Text("• 两端：调整栏的长度。底部 Dock 对应左右边缘。")
                    Text("• 内侧两个角：按比例缩放长度和厚度。底部 Dock 对应左上角、右上角。")
                }
                Text("Dock 移到其他屏幕边缘后，拖动方向随之旋转。图标保留在外观页选定的相对比例。")
            }
            SettingsGroup("在多屏上使用") {
                Text("在“屏幕与位置”分别选择每块屏幕的底部、左侧、右侧或上方。尺寸可同步，也可在手动模式下分别保存；应用、分组和排列始终共享。镜像屏跟随系统复制画面。")
            }
            SettingsGroup("切换与关闭窗口") {
                Text("悬停运行中的应用可查看预览；点击图片切换，点击右上角 × 请求关闭该窗口。关闭请求不会代替原应用确认未保存内容。")
            }
            SettingsGroup("设置入口") {
                Text("右键 Dock 空白处，或点击菜单栏的双矩形图标打开设置。")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
