import Foundation

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, displays, interaction, permissions, help, about
    var id: String { rawValue }
    var sidebarTitle: String {
        switch self {
        case .appearance: return L("外观与尺寸", "Appearance")
        case .displays: return L("屏幕与位置", "Displays")
        default: return title
        }
    }
    var title: String {
        switch self {
        case .general: return L("通用", "General")
        case .appearance: return L("外观与尺寸", "Appearance & Size")
        case .displays: return L("屏幕与位置", "Displays & Position")
        case .interaction: return L("交互", "Interaction")
        case .permissions: return L("权限", "Permissions")
        case .help: return L("使用方法", "User Guide")
        case .about: return L("关于", "About")
        }
    }
    var subtitle: String {
        switch self {
        case .general: return L("选择 Dock 显示的内容，管理常用应用。", "Choose which apps appear in the Dock and manage startup and language.")
        case .appearance: return L("调整大小、间距和长度，通过示例查看效果。", "Adjust size, spacing, and length using the sample Dock.")
        case .displays: return L("为每块屏幕安排一个顺手的位置。", "Choose a Dock edge for each display.")
        case .interaction: return L("让窗口切换、放大与隐藏符合你的习惯。", "Customize window switching, magnification, and hiding.")
        case .permissions: return L("开启需要的能力，所有窗口图像留在本机。", "Manage access for window controls and local previews.")
        case .help: return L("几步上手，整理属于你的工作空间。", "Learn how to organize apps and work across displays.")
        case .about: return L("版本信息、开源许可与项目支持。", "Version, open-source license, and project support.")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "slider.horizontal.3"
        case .displays: return "display"
        case .interaction: return "cursorarrow.click"
        case .permissions: return "lock.shield"
        case .help: return "questionmark.circle"
        case .about: return "info.circle"
        }
    }
}
