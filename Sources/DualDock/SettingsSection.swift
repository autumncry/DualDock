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
