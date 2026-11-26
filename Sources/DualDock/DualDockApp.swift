import AppKit
import SwiftUI
import DualDockCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var store: AppStore!
    var coordinator: DisplayCoordinator!
    private var toolsStore: DockToolsStore!
    private var settingsController: SettingsWindowController?
    var statusItem: NSStatusItem?
    private var diagnosticsTimer: Timer?
    private var terminationSignals: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            terminationSignals.append(source)
        }
        let preview = LocalPreviewConfiguration.isPreview
        let bundleID = preview ? LocalPreviewConfiguration.bundleID : LocalPreviewConfiguration.releaseBundleID
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != getpid() }
        if let existing {
            existing.activate(options: [])
            NSApp.terminate(nil)
            return
        }
        let args = ProcessInfo.processInfo.arguments
        let directory: URL
        let firstLaunch: Bool
        let override = args.firstIndex(of: "--config-dir").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let stableDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DualDock")
        if preview {
            do {
                directory = try LocalPreviewConfiguration.directory(bundle: Bundle.main.bundleURL, override: override)
                firstLaunch = !FileManager.default.fileExists(atPath: directory.appendingPathComponent("configuration.json").path)
                let original = override == nil ? stableDirectory.appendingPathComponent("configuration.json") : nil
                try LocalPreviewConfiguration.seed(directory: directory, originalURL: original,
                                                  displayIDs: DockDisplayInfo.current().map(\.id))
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = L("无法打开本地试用配置", "Cannot open local preview configuration")
                alert.runModal()
                NSApp.terminate(nil)
                return
            }
            AppLanguage.useLocalSettings(in: directory)
        } else {
            directory = override.map { URL(fileURLWithPath: $0) } ?? stableDirectory
            firstLaunch = !FileManager.default.fileExists(atPath: directory.appendingPathComponent("configuration.json").path)
        }
        store = AppStore(directory: directory, managesSystemDock: !preview)
        if !preview {
            SoftwareUpdateService.shared.beforeRelaunch = { [weak self] in self?.store?.flushPendingSave() }
        }
        toolsStore = DockToolsStore(directory: directory)
        coordinator = DisplayCoordinator(store: store, tools: toolsStore, pageStateDirectory: directory)
        NotificationCenter.default.addObserver(self, selector: #selector(openToolSettings),
                                               name: .showDualDockToolsSettings, object: nil)
        coordinator.showSettings = { [weak self] in self?.openSettings() }
        setupMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshMenuLanguage),
                                               name: .dualDockLanguageDidChange, object: nil)
        if preview && firstLaunch { openToolSettings() }
        else if firstLaunch || store.message != nil || args.contains("--settings") { openSettings() }
        if let index = args.firstIndex(of: "--diagnostics"), index + 1 < args.count {
            let url = URL(fileURLWithPath: args[index + 1])
            diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.writeDiagnostics(url) }
            }
        }
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = StatusItemIcon.make()
        statusItem?.button?.toolTip = "DualDock"
        if LocalPreviewConfiguration.isPreview {
            statusItem?.button?.toolTip = L("DualDock 3 · 本地试用", "DualDock 3 · Local preview")
            statusItem?.button?.title = "3"
            statusItem?.button?.imagePosition = .imageLeading
        }
        refreshMenuLanguage()
    }

    @objc private func refreshMenuLanguage() {
        let menu = NSMenu()
        menu.addAction(L("DualDock 3 设置…", "DualDock 3 Settings…")) { [weak self] in self?.openSettings() }
        menu.addAction(L("添加应用…", "Add Applications…")) { [weak self] in self?.store.addApplications() }
        menu.addItem(.separator())
        menu.addAction(L("切换本屏应用页与工具页", "Switch Dock Page on This Display")) { [weak self] in
            self?.coordinator.togglePageForPointerDisplay()
        }
        menu.addAction(L("编辑工具页…", "Edit Tools Page…")) { [weak self] in self?.openToolSettings() }
        if store.managesSystemDock {
            menu.addAction(L("恢复系统 Dock", "Restore System Dock")) { [weak self] in self?.store.restoreSystemDock() }
        }
        menu.addAction(L("重新检测显示器", "Detect Displays")) { [weak self] in self?.coordinator.refreshDisplays() }
        menu.addItem(.separator())
        menu.addAction(L("退出 DualDock 3", "Quit DualDock 3")) { NSApp.terminate(nil) }
        statusItem?.menu = menu
    }

    @objc private func openToolSettings() { openSettings(section: .tools) }

    func openSettings(section: SettingsSection? = nil) {
        coordinator?.resetMagnification()
        if settingsController == nil { settingsController = SettingsWindowController(store: store, tools: toolsStore) }
        store.refreshPermissions()
        settingsController?.show(section: section)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openSettings(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store?.managesSystemDock == true else { return .terminateNow }
        do { try store?.systemDock.restore() }
        catch {
            let alert = NSAlert()
            alert.messageText = L("系统 Dock 尚未恢复", "The system Dock could not be restored")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L("留在 DualDock", "Keep DualDock Open"))
            alert.addButton(withTitle: L("仍然退出，下次启动恢复", "Quit and Restore on Next Launch"))
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        diagnosticsTimer?.invalidate()
        settingsController?.stop()
        coordinator?.stop()
        toolsStore?.stop()
        store?.stopBackgroundServices()
    }

    private func writeDiagnostics(_ url: URL) {
        let screens: [[String: Any]] = coordinator.docks.map { id, dock in
            ["id": id, "name": dock.screen.localizedName, "visible": dock.panel.isVisible,
             "frame": NSStringFromRect(dock.panel.frame), "screenFrame": NSStringFromRect(dock.screen.frame),
             "backdropFrame": NSStringFromRect(dock.strip.backdropFrame),
             "backdropScreenFrame": NSStringFromRect(dock.panel.convertToScreen(dock.strip.convert(dock.strip.backdropFrame, to: nil))),
             "contentOrigin": NSStringFromPoint(dock.strip.frame.origin),
             "displayKey": dock.displayID,
             "page": String(describing: dock.strip.page),
             "edge": dock.strip.layoutGeometry?.edge.rawValue ?? "bottom",
             "bodyLength": dock.strip.layoutGeometry?.bodyLength ?? 0,
             "bodyThickness": dock.strip.layoutGeometry?.barThickness ?? 0,
             "ignoresMouseEvents": dock.panel.ignoresMouseEvents,
             "iconWidths": dock.strip.tiles.map { $0.visualIconBounds.width },
             "tiles": dock.strip.tiles.count,
             "firstTileWidth": dock.strip.tiles.first?.frame.width ?? 0,
             "firstIconWidth": dock.strip.tiles.first?.visualIconBounds.width ?? 0,
             "scrollOffsetX": dock.strip.scroll.contentView.bounds.origin.x,
             "scrollOffset": dock.strip.scrollOffset,
             "horizontalScrollerEnabled": dock.strip.scroll.hasHorizontalScroller,
             "viewportWidth": dock.strip.scroll.contentView.bounds.width,
             "documentWidth": dock.strip.document.frame.width,
             "runningDots": dock.strip.tiles.filter { $0.entry.apps.contains(where: store.isRunning) }.count]
        }
        let result: [String: Any] = ["screens": screens, "mode": store.configuration.mode.rawValue,
            "groups": store.configuration.entries.filter(\.isGroup).count,
            "runningApps": store.runningApps.count, "accessibility": AXIsProcessTrusted(),
            "screenCapture": CGPreflightScreenCaptureAccess(),
            "dockSize": store.effectiveIconSize, "iconSpacing": store.configuration.iconSpacing,
            "dockHeight": store.effectiveDockHeight, "dockWidth": store.effectiveDockWidth,
            "requestedIconSize": store.configuration.iconSize,
            "requestedDockWidth": store.configuration.dockWidth ?? 0,
            "autoAdjustWidth": store.configuration.autoAdjustWidth,
            "displayLanguage": AppLanguage.current.rawValue,
            "launchAtLogin": LaunchAtLoginService.Environment.system().status().rawValue,
            "adaptiveSizing": store.configuration.adaptiveSizing,
            "synchronizeSizes": store.configuration.synchronizeSizes,
            "nativeDock": ["iconSize": store.nativeDockMetrics.iconSize,
                           "thickness": store.nativeDockMetrics.barThickness,
                           "leadingPadding": store.nativeDockMetrics.leadingPadding,
                           "trailingPadding": store.nativeDockMetrics.trailingPadding,
                           "magnifiedIconSize": store.nativeDockMetrics.magnifiedIconSize],
            "sizeLimits": ["minWidth": store.sizingLimits.minWidth, "maxWidth": store.sizingLimits.maxWidth,
                           "minHeight": store.sizingLimits.minHeight, "maxHeight": store.sizingLimits.maxHeight],
            "magnificationEnabled": store.configuration.magnificationEnabled,
            "magnificationScale": store.configuration.magnificationScale,
            "showBadges": store.configuration.showBadges, "badgeAppCount": store.badgeLabels.count,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url, options: .atomic) }
    }
}

@main
struct DualDockApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
