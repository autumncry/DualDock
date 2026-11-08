import AppKit
import SwiftUI
import DualDockCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var store: AppStore!
    var coordinator: DisplayCoordinator!
    var settingsWindow: NSWindow?
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
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "local.ronny.DualDock")
            .first { $0.processIdentifier != getpid() }
        if let existing {
            existing.activate(options: [])
            NSApp.terminate(nil)
            return
        }
        let args = ProcessInfo.processInfo.arguments
        let directory: URL
        if let index = args.firstIndex(of: "--config-dir"), index + 1 < args.count {
            directory = URL(fileURLWithPath: args[index + 1])
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DualDock")
        }
        let firstLaunch = !FileManager.default.fileExists(atPath: directory.appendingPathComponent("configuration.json").path)
        store = AppStore(directory: directory)
        coordinator = DisplayCoordinator(store: store)
        coordinator.showSettings = { [weak self] in self?.openSettings() }
        setupMenu()
        if firstLaunch || store.message != nil || args.contains("--settings") { openSettings() }
        if let index = args.firstIndex(of: "--diagnostics"), index + 1 < args.count {
            let url = URL(fileURLWithPath: args[index + 1])
            diagnosticsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.writeDiagnostics(url) }
            }
        }
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "DualDock")
        statusItem?.button?.toolTip = "DualDock"
        let menu = NSMenu()
        menu.addAction("DualDock 设置…") { [weak self] in self?.openSettings() }
        menu.addAction("切换显示模式") { [weak self] in self?.store.update { $0.mode = $0.mode == .standard ? .runningOnly : .standard } }
        menu.addAction("添加应用…") { [weak self] in self?.store.addApplications() }
        menu.addItem(.separator())
        menu.addAction("恢复系统 Dock") { [weak self] in self?.store.restoreSystemDock() }
        menu.addAction("重新检测显示器") { [weak self] in self?.coordinator.refreshDisplays() }
        menu.addItem(.separator())
        menu.addAction("退出 DualDock") { NSApp.terminate(nil) }
        statusItem?.menu = menu
    }

    func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 580), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "DualDock"
            window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: SettingsView(store: store))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        store.refreshPermissions()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openSettings(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do { try store?.systemDock.restore() }
        catch {
            let alert = NSAlert()
            alert.messageText = "系统 Dock 尚未恢复"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "留在 DualDock")
            alert.addButton(withTitle: "仍然退出，下次启动恢复")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        diagnosticsTimer?.invalidate()
        coordinator?.stop()
    }

    private func writeDiagnostics(_ url: URL) {
        let screens: [[String: Any]] = coordinator.docks.map { id, dock in
            ["id": id, "name": dock.screen.localizedName, "visible": dock.panel.isVisible,
             "frame": NSStringFromRect(dock.panel.frame), "screenFrame": NSStringFromRect(dock.screen.frame),
             "tiles": dock.strip.tiles.count, "runningDots": dock.strip.tiles.filter { $0.entry.apps.contains(where: store.isRunning) }.count]
        }
        let result: [String: Any] = ["screens": screens, "mode": store.configuration.mode.rawValue,
            "groups": store.configuration.entries.filter(\.isGroup).count,
            "runningApps": store.runningApps.count, "accessibility": AXIsProcessTrusted(),
            "screenCapture": CGPreflightScreenCaptureAccess(), "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"]
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
