import Foundation
import Combine

enum SettingsCategory: String, CaseIterable {
    case dock, interaction, general, support

    var title: String {
        switch self {
        case .dock: return "Dock"
        case .interaction: return L("交互", "Interaction")
        case .general: return L("通用", "General")
        case .support: return L("支持", "Support")
        }
    }

    var symbol: String {
        switch self {
        case .dock: return "dock.rectangle"
        case .interaction: return "cursorarrow.click"
        case .general: return "gearshape"
        case .support: return "questionmark.circle"
        }
    }

    var sections: [SettingsSection] { SettingsSection.sidebarEntries.filter { $0.category == self } }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance, displays, contents
    case interaction, magnification, notifications
    case general, systemDock, apps, permissions
    case help, about
    var id: String { rawValue }

    var category: SettingsCategory {
        switch self {
        case .appearance, .displays, .contents: return .dock
        case .interaction, .magnification, .notifications: return .interaction
        case .general, .systemDock, .apps, .permissions: return .general
        case .help, .about: return .support
        }
    }

    private var names: (String, String) {
        switch self {
        case .appearance: return ("外观与尺寸", "Appearance & Size")
        case .displays: return ("屏幕与位置", "Displays & Position")
        case .contents: return ("显示内容", "Dock Contents")
        case .interaction: return ("窗口与预览", "Windows & Previews")
        case .magnification: return ("悬停放大", "Magnification")
        case .notifications: return ("消息提醒", "Notifications")
        case .general: return ("语言与启动", "Language & Startup")
        case .systemDock: return ("系统 Dock", "System Dock")
        case .apps: return ("应用与配置", "Apps & Configuration")
        case .permissions: return ("权限", "Permissions")
        case .help: return ("使用方法", "User Guide")
        case .about: return ("关于 DualDock", "About DualDock")
        }
    }

    // These short sections share a scrolling detail pane. Sizing, Help, and About
    // each have enough controls or content to use their own pane.
    var detailSections: [SettingsSection] {
        switch self {
        case .displays, .contents: return [.displays, .contents]
        case .interaction, .magnification, .notifications: return SettingsCategory.interaction.sections
        case .general, .systemDock, .apps, .permissions: return SettingsCategory.general.sections
        case .appearance, .help, .about: return [self]
        }
    }

    var title: String { L(names.0, names.1) }

    // Contents remains a scroll target and a searchable heading on the displays page.
    var sidebarEntry: Self { self == .contents ? .displays : self }
    static let sidebarEntries = allCases.filter { $0.sidebarEntry == $0 }

    var navigationTitle: String {
        self == .displays ? L("多屏和显示内容", "Displays & Content") : title
    }

    var sidebarTitle: String {
        switch self {
        case .interaction: return L(names.0, "Windows")
        case .apps: return L(names.0, "Manage Apps")
        default: return navigationTitle
        }
    }

    // Keep compound control labels intact. Chinese names such as “角标大小”
    // and English labels with prepositions should be searchable as displayed.
    private var keywords: String {
        switch self {
        case .appearance: return "大小 预设 图标间距 长度 Dock高度 两端留白 高级设置 尺寸模式 跟随系统Dock 恢复自动 同步各屏尺寸 放不下时先缩小图标 size preset icon spacing length Dock height end padding sizing mode advanced reset sync sizes across displays shrink icons before scrolling"
        case .displays: return "多屏和显示内容 外接显示器 方向 Dock位置 底部 顶部 左侧 右侧 调整所有屏幕尺寸 调整此屏幕尺寸 displays and content screen monitor display Dock position left right top bottom adjust size for all displays"
        case .contents: return "显示模式 固定应用与分组 运行应用 仅正在运行的应用 pinned apps and groups running apps only display mode"
        case .interaction: return "全屏 最大化窗口时隐藏Dock 自动隐藏 悬停显示窗口预览 关闭窗口 缩略图 close thumbnail fullscreen maximize auto-hide hide the dock for maximized windows show window previews on hover"
        case .magnification: return "鼠标悬停放大 动画 放大峰值 联动范围 曲线预览 hover animation magnify icons on hover peak magnification magnification range curve"
        case .notifications: return "显示消息数量角标 角标大小 未读 红点 叹号 message count show notification badges display badge badge size scale unread"
        case .general: return "显示语言 英文 中文 开机自启动 登录时启动 打开系统登录项 取消启动申请 display language english chinese launch at login open login items settings cancel request startup"
        case .systemDock: return "隐藏系统Dock 恢复系统Dock 自动隐藏 原生 hide the system Dock restore system Dock"
        case .apps: return "添加应用 重新导入系统Dock 打开配置目录 add apps import system Dock apps open configuration folder"
        case .permissions: return "屏幕录制 辅助功能 刷新授权状态 screen recording accessibility privacy refresh permissions grant access"
        case .help: return "帮助 教程 拖拽 整理 点击应用图标 切换窗口 前置 最小化 还原 右键选择窗口 help guide organize drag clicking app icons switch windows minimize restore right click"
        case .about: return "关于 版本 开源协议 项目主页 查看发布版本 提交问题与建议 下载 检查更新 软件更新 升级 反馈 支持 version check for updates software update install upgrade license github releases download support feedback"
        }
    }

    func matches(_ query: String) -> Bool {
        let words = (names.0 + " " + names.1 + " " + sidebarTitle + " " + keywords)
            .lowercased().split(whereSeparator: { $0.isWhitespace })
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
        return !terms.isEmpty && terms.allSatisfy { term in
            let latin = term.allSatisfy(\.isASCII)
            return words.contains { latin ? $0.hasPrefix(term) : $0.contains(term) }
        }
    }

    var symbol: String {
        switch self {
        case .appearance: return "slider.horizontal.3"
        case .displays: return "display"
        case .contents: return "square.grid.2x2"
        case .interaction: return "macwindow"
        case .magnification: return "plus.magnifyingglass"
        case .notifications: return "app.badge"
        case .general: return "globe"
        case .systemDock: return "dock.rectangle"
        case .apps: return "folder"
        case .permissions: return "lock.shield"
        case .help: return "book"
        case .about: return "info.circle"
        }
    }
}

/// One selection shared by the window toolbar, sidebar and detail pane.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published private(set) var selected: SettingsSection
    @Published var query = ""
    private var lastSection: [SettingsCategory: SettingsSection] = [:]

    init(_ section: SettingsSection = .general) { selected = section }

    var visibleSections: [SettingsSection] {
        guard isSearching else { return selected.category.sections }
        return SettingsSection.sidebarEntries.filter { entry in
            entry.matches(query) || (entry == .displays && SettingsSection.contents.matches(query))
        }
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func selectSidebarEntry(_ entry: SettingsSection) {
        if entry == .displays, isSearching, SettingsSection.contents.matches(query) {
            show(SettingsSection.contents)
        } else {
            show(entry)
        }
    }

    func show(_ section: SettingsSection) {
        selected = section
        lastSection[section.category] = section
        query = ""
    }

    func scrolled(to section: SettingsSection) {
        guard selected != section, !isSearching, selected.detailSections.contains(section) else { return }
        selected = section
        lastSection[section.category] = section
    }

    func show(_ category: SettingsCategory) {
        if let section = lastSection[category] ?? category.sections.first { show(section) }
    }
}
