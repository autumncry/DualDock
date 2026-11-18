import Foundation

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, displays, interaction, permissions, help, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "通用"
        case .appearance: return "外观与尺寸"
        case .displays: return "屏幕与位置"
        case .interaction: return "交互"
        case .permissions: return "权限"
        case .help: return "使用方法"
        case .about: return "关于"
        }
    }
    var subtitle: String {
        switch self {
        case .general: return "选择 Dock 显示的内容，管理常用应用。"
        case .appearance: return "调整大小、间距和长度，通过示例查看效果。"
        case .displays: return "为每块屏幕安排一个顺手的位置。"
        case .interaction: return "让窗口切换、放大与隐藏符合你的习惯。"
        case .permissions: return "开启需要的能力，所有窗口图像留在本机。"
        case .help: return "几步上手，整理属于你的工作空间。"
        case .about: return "版本信息、开源许可与项目支持。"
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
