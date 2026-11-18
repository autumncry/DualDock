import AppKit
import SwiftUI

/// A reusable regular window, independent of nonactivating Dock panels.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onVisibilityChange: ((Bool) -> Void)?
    private var previousApplication: NSRunningApplication?
    private var hasBeenPresented = false
    private var reportedVisible = false
    private var editingMenu: NSMenu?
    private let store: AppStore
    var isPresented: Bool { window?.isVisible == true && window?.isMiniaturized == false }

    init(store: AppStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L("DualDock 设置", "DualDock Settings")
        window.minSize = NSSize(width: 820, height: 580)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.contentViewController = NSHostingController(rootView: SettingsView(store: store))
        // Hosting can adopt the view's minimum fitting size during attachment.
        // Keep the intended initial desktop layout; later resizing stays free.
        window.setContentSize(NSSize(width: 1060, height: 760))
        super.init(window: window)
        window.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(updateLanguage),
                                               name: .dualDockLanguageDidChange, object: nil)
    }
    required init?(coder: NSCoder) { nil }

    func show() {
        guard let window else { return }
        if let previous = NSWorkspace.shared.frontmostApplication,
           previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = previous
        }
        installEditingMenuIfNeeded()
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
    func windowDidDeminiaturize(_ notification: Notification) { publishVisibility() }

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
        editItem.submenu = editMenu
        menu.addItem(editItem)
        editingMenu = menu
        NSApp.mainMenu = menu
    }

    @objc private func requestSettings(_ sender: Any?) { show() }
}
