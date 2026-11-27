import XCTest
import SwiftUI
import DualDockCore
@testable import DualDock

@MainActor
final class SystemDockSettingsTests: XCTestCase {
    private final class DockPreferences {
        var values: [String: Any]
        var reloads = 0
        var failedReloadsRemaining = 0

        init(_ values: [String: Any]) { self.values = values }

        var environment: SystemDockService.Environment {
            .init(read: { self.values[$0] }, write: { self.values[$0] = $1 },
                  synchronize: { true }, restart: {
                      self.reloads += 1
                      if self.failedReloadsRemaining > 0 {
                          self.failedReloadsRemaining -= 1
                          throw NSError(domain: "TestDockReload", code: 1)
                      }
                  })
        }
    }

    private func fixtureDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        var config = DockConfiguration()
        config.showBadges = false
        try JSONEncoder().encode(config).write(to: dir.appendingPathComponent("configuration.json"))
        return dir
    }

    private func store(at dir: URL, with preferences: DockPreferences) -> AppStore {
        AppStore(directory: dir, runningAppsProvider: { [] }, permissionsProvider: { (false, false) },
                 systemDockEnvironment: preferences.environment)
    }

    private func savedHideOption(at dir: URL) throws -> Bool {
        try JSONDecoder().decode(DockConfiguration.self, from: Data(contentsOf: dir.appendingPathComponent("configuration.json"))).hideSystemDock
    }

    func testIndependentSwitchAndCrashRecoveryRetainTheUserOriginals() async throws {
        let dir = try fixtureDirectory()
        let prefs = DockPreferences(["autohide": false, "autohide-delay": 0.4])
        let first = store(at: dir, with: prefs)
        XCTAssertEqual(prefs.reloads, 0)
        XCTAssertFalse(first.configuration.hideSystemDock)
        first.setSystemDockHidden(true)
        XCTAssertTrue(try savedHideOption(at: dir))
        XCTAssertTrue(first.systemDock.hasRecoveryRecord)
        XCTAssertEqual(prefs.reloads, 1)
        first.stopBackgroundServices() // Simulate a process ending without its quit callback.

        let relaunched = store(at: dir, with: prefs)
        defer { relaunched.stopBackgroundServices() }
        XCTAssertTrue(relaunched.configuration.hideSystemDock)
        XCTAssertTrue(relaunched.systemDock.hasRecoveryRecord)
        let reloads = prefs.reloads
        relaunched.reconcileDeferredSystemDock()
        XCTAssertEqual(prefs.reloads, reloads)
        relaunched.restoreSystemDock()
        XCTAssertFalse(try savedHideOption(at: dir))
        XCTAssertFalse(relaunched.systemDock.hasRecoveryRecord)
        XCTAssertEqual(prefs.values["autohide"] as? Bool, false)
        XCTAssertEqual(prefs.values["autohide-delay"] as? Double, 0.4)
    }

    func testSystemSettingsSwitchOperatesWithoutAnInstalledSibling() async throws {
        _ = NSApplication.shared
        let dir = try fixtureDirectory()
        let prefs = DockPreferences(["autohide": false])
        let store = store(at: dir, with: prefs)
        defer { store.stopBackgroundServices() }
        let login = LaunchAtLoginService(environment: .init(status: { .notRegistered }, register: {}, unregister: {}, openSettings: {}))
        let root = GeneralSettingsView(section: .systemDock, store: store, launchAtLogin: login)
            .environment(\.dualDockLanguage, .simplifiedChinese)
            .frame(width: 490)
            .padding(10)
            .background(Color(nsColor: .windowBackgroundColor))
        let controller = NSHostingController(rootView: root)
        let panel = NSPanel(contentRect: NSRect(x: -8000, y: -8000, width: 510, height: 160),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentViewController = controller
        panel.orderBack(nil)
        defer { panel.close() }
        try await Task.sleep(for: .milliseconds(100))
        let size = controller.sizeThatFits(in: NSSize(width: 510, height: 500))
        panel.setContentSize(size)
        let host = controller.view
        host.layoutSubtreeIfNeeded()
        if let path = ProcessInfo.processInfo.environment["DUALDOCK_CONTROL_RENDER_DIR"] {
            let folder = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("system-dock-control.png"))
        }

        // The first row is the native hide switch; the recovery button is below.
        let point = NSPoint(x: size.width - 44, y: size.height - 61)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        func click() throws {
            NSApp.postEvent(try event(.leftMouseUp), atStart: true)
            panel.sendEvent(try event(.leftMouseDown))
            if let release = NSApp.nextEvent(matching: .leftMouseUp, until: .now, inMode: .default, dequeue: true) {
                panel.sendEvent(release)
            }
        }
        try click()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(try savedHideOption(at: dir))
        XCTAssertEqual(prefs.values["autohide"] as? Bool, true)
        XCTAssertTrue(store.systemDock.hasRecoveryRecord)

        try click()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(try savedHideOption(at: dir))
        XCTAssertEqual(prefs.values["autohide"] as? Bool, false)
        XCTAssertFalse(store.systemDock.hasRecoveryRecord)
    }

    func testDeferredOrStartupFailureLeavesSwitchOffAfterRollback() async throws {
        for duringStartup in [false, true] {
            let dir = try fixtureDirectory()
            let prefs = DockPreferences(["autohide": true, "autohide-delay": 1000.0])
            var active = store(at: dir, with: prefs)
            active.setSystemDockHidden(true)
            XCTAssertTrue(active.waitingForSystemDock)
            XCTAssertTrue(try savedHideOption(at: dir))

            prefs.values = ["autohide": false, "autohide-delay": 0.3]
            prefs.failedReloadsRemaining = 1
            if duringStartup {
                active.stopBackgroundServices()
                active = store(at: dir, with: prefs)
            } else {
                active.reconcileDeferredSystemDock()
            }
            XCTAssertNotNil(active.notice)
            XCTAssertFalse(active.waitingForSystemDock)
            XCTAssertFalse(active.configuration.hideSystemDock)
            XCTAssertFalse(try savedHideOption(at: dir))
            XCTAssertFalse(active.systemDock.hasRecoveryRecord)
            XCTAssertEqual(prefs.values["autohide"] as? Bool, false)
            XCTAssertEqual(prefs.values["autohide-delay"] as? Double, 0.3)
            active.reconcileDeferredSystemDock()
            XCTAssertEqual(prefs.reloads, 2, "One failed reload and one successful rollback; no automatic retry.")
            active.stopBackgroundServices()
        }
    }

    func testDeferredOwnerHandoffAndCancellation() async throws {
        let dir = try fixtureDirectory()
        let prefs = DockPreferences(["autohide": true, "autohide-delay": 1000.0])
        let store = store(at: dir, with: prefs)
        defer { store.stopBackgroundServices() }
        store.setSystemDockHidden(true)
        XCTAssertTrue(store.waitingForSystemDock)
        XCTAssertTrue(try savedHideOption(at: dir))
        store.reconcileDeferredSystemDock()
        store.restoreSystemDock()
        XCTAssertFalse(store.waitingForSystemDock)
        XCTAssertFalse(try savedHideOption(at: dir))
        XCTAssertEqual(prefs.reloads, 0)
        XCTAssertEqual(prefs.values["autohide-delay"] as? Double, 1000.0)

        store.setSystemDockHidden(true)
        prefs.values = ["autohide": false, "autohide-delay": 0.3]
        store.reconcileDeferredSystemDock()
        XCTAssertFalse(store.waitingForSystemDock)
        XCTAssertTrue(store.systemDock.hasRecoveryRecord)
        XCTAssertEqual(prefs.values["autohide-delay"] as? Double, 1000.0)
        store.reconcileDeferredSystemDock()
        XCTAssertEqual(prefs.reloads, 1, "Reloading the native Dock must not cause another reload.")
        store.restoreSystemDock()
        XCTAssertEqual(prefs.values["autohide"] as? Bool, false)
        XCTAssertEqual(prefs.values["autohide-delay"] as? Double, 0.3)
    }
}
