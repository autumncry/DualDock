import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let focusDualDockSettingsSearch = Notification.Name("DualDock.focusSettingsSearch")
}

/// A reusable regular window, independent of nonactivating Dock panels.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    var onVisibilityChange: ((Bool) -> Void)?
    private var previousApplication: NSRunningApplication?
    private var hasBeenPresented = false
    private var reportedVisible = false
    private var editingMenu: NSMenu?
    private let store: AppStore
    private let navigation: SettingsNavigation
    private var selectionObservation: AnyCancellable?
    var isPresented: Bool { window?.isVisible == true && window?.isMiniaturized == false }

    static let initialFrameSize = NSSize(width: 820, height: 560)
    static let minimumContentSize = NSSize(width: 740, height: 320)

    init(store: AppStore, navigation supplied: SettingsNavigation? = nil,
         launchAtLoginService: LaunchAtLoginService? = nil) {
        self.store = store
        let navigation = supplied ?? SettingsNavigation()
        self.navigation = navigation
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.initialFrameSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L("DualDock 设置", "DualDock Settings")
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        super.init(window: window)
        let content = NSHostingController(rootView: SettingsView(store: store,
            launchAtLoginService: launchAtLoginService, navigation: navigation))
        // The window owns its frame. Controls and translations reflow inside the detail scroll view.
        content.sizingOptions = []
        window.contentViewController = content
        window.delegate = self
        window.toolbarStyle = .preference
        let toolbar = NSToolbar(identifier: "DualDock.Settings.Categories")
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.delegate = self
        window.toolbar = toolbar
        window.contentMinSize = Self.minimumContentSize
        window.setFrame(NSRect(origin: window.frame.origin, size: Self.initialFrameSize), display: false)
        toolbar.centeredItemIdentifiers = Set(categoryIdentifiers)
        selectionObservation = navigation.$selected.sink { [weak toolbar] section in
            toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(section.category.rawValue)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(updateLanguage),
                                               name: .dualDockLanguageDidChange, object: nil)
    }
    required init?(coder: NSCoder) { nil }

    func windowWillResize(_ sender: NSWindow, to proposed: NSSize) -> NSSize {
        let chromeHeight = sender.frame.height - sender.contentLayoutRect.height
        return NSSize(width: max(Self.minimumContentSize.width, proposed.width),
                      height: max(Self.minimumContentSize.height + chromeHeight, proposed.height))
    }

    private var categoryIdentifiers: [NSToolbarItem.Identifier] {
        SettingsCategory.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { categoryIdentifiers }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { categoryIdentifiers }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { categoryIdentifiers }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let category = SettingsCategory(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = category.title
        item.image = NSImage(systemSymbolName: category.symbol, accessibilityDescription: nil)
        item.target = self
        item.action = #selector(selectCategory(_:))
        return item
    }

    @objc private func selectCategory(_ sender: NSToolbarItem) {
        if let category = SettingsCategory(rawValue: sender.itemIdentifier.rawValue) { navigation.show(category) }
    }

    func show() {
        guard let window else { return }
        if let previous = NSWorkspace.shared.frontmostApplication,
           previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = previous
        }
        installEditingMenuIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        if !hasBeenPresented { window.center(); hasBeenPresented = true }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if let screen = NSScreen.main { window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false) }
        store.refreshPermissions()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        publishVisibility()
    }

    @objc private func updateLanguage() {
        window?.title = L("DualDock 设置", "DualDock Settings")
        for item in window?.toolbar?.items ?? [] {
            if let category = SettingsCategory(rawValue: item.itemIdentifier.rawValue) { item.label = category.title }
        }
        if editingMenu != nil { installEditingMenuIfNeeded() }
    }

    func stop() {
        NotificationCenter.default.removeObserver(self, name: .dualDockLanguageDidChange, object: nil)
        previousApplication = nil
        window?.close()
        if let editingMenu, NSApp.mainMenu === editingMenu { NSApp.mainMenu = nil }
        editingMenu = nil
    }

    func windowWillClose(_ notification: Notification) {
        publishVisibility(false)
        if NSApp.isActive, let previousApplication, !previousApplication.isTerminated {
            previousApplication.activate(options: [])
        }
        previousApplication = nil
    }
    func windowDidMiniaturize(_ notification: Notification) { publishVisibility(false) }
    func windowDidDeminiaturize(_ notification: Notification) {
        publishVisibility()
    }

    private func publishVisibility(_ value: Bool? = nil) {
        let visible = value ?? isPresented
        guard visible != reportedVisible else { return }
        reportedVisible = visible
        onVisibilityChange?(visible)
    }

    private func installEditingMenuIfNeeded() {
        guard NSApp.mainMenu == nil || NSApp.mainMenu === editingMenu else { return }
        let menu = NSMenu()
        let appItem = NSMenuItem(title: "DualDock", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "DualDock")
        appMenu.addItem(withTitle: L("设置…", "Settings…"), action: #selector(requestSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("退出 DualDock", "Quit DualDock"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fileItem = NSMenuItem(title: L("文件", "File"), action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: L("文件", "File"))
        fileMenu.addItem(withTitle: L("关闭窗口", "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)
        let editItem = NSMenuItem(title: L("编辑", "Edit"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L("编辑", "Edit"))
        editMenu.addItem(withTitle: L("撤销", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L("重做", "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        for (title, action, key) in [(L("剪切", "Cut"), "cut:", "x"), (L("拷贝", "Copy"), "copy:", "c"), (L("粘贴", "Paste"), "paste:", "v"), (L("全选", "Select All"), "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("搜索设置", "Search Settings"), action: #selector(focusSearch),
                         keyEquivalent: "f").target = self
        editItem.submenu = editMenu
        menu.addItem(editItem)
        editingMenu = menu
        NSApp.mainMenu = menu
    }

    @objc private func requestSettings(_ sender: Any?) { show() }
    @objc private func focusSearch() {
        NotificationCenter.default.post(name: .focusDualDockSettingsSearch, object: nil)
    }
}
