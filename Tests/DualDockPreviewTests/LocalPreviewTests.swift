import XCTest
import DualDockCore
@testable import DualDock

final class LocalPreviewTests: XCTestCase {
    @MainActor func testFirstLaunchUsesNativePinsAndSubsequentLaunchUsesOnlySavedSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("LocalData")
        let pin = AppReference(id: "test.native", name: "Native pin", path: "/example/Native.app")
        var imports = 0
        func launch() -> AppStore {
            AppStore(directory: directory, runningAppsProvider: { [] },
                     permissionsProvider: { (false, false) }, managesSystemDock: false,
                     initialPinnedApps: { imports += 1; return [pin] })
        }
        let first = launch()
        XCTAssertEqual(first.configuration.entries.flatMap(\.apps), [pin])
        XCTAssertFalse(first.configuration.hideSystemDock)
        XCTAssertEqual(first.edge(for: "new-display"), .bottom)
        first.update { config in
            config.displaySettings["internal"] = DockDisplaySettings(edge: .right)
            config.autoHideDock = true
        }
        first.stopBackgroundServices()

        let reopened = launch()
        defer { reopened.stopBackgroundServices() }
        XCTAssertEqual(imports, 1)
        XCTAssertEqual(reopened.configuration.entries.flatMap(\.apps), [pin])
        XCTAssertEqual(reopened.edge(for: "internal"), .right)
        XCTAssertTrue(reopened.configuration.autoHideDock)
    }

    @MainActor func testExistingV11TrialUpgradesWithoutReseedingGroupsOrTools() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("configuration.json")
        let toolsURL = directory.appendingPathComponent("tool-shelf.json")
        let pagesURL = directory.appendingPathComponent("dock-pages.json")

        var preview = DockConfiguration()
        preview.entries = [DockEntry(name: "Trial group", apps: [
            AppReference(id: "fixture.trial", name: "Trial", path: "/example/Trial.app")
        ], isGroup: true)]
        preview.showBadges = false
        preview.autoHideDock = true
        preview.autoHideWhenMaximized = true
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preview)) as? [String: Any])
        legacy["version"] = 11
        legacy.removeValue(forKey: "folderAppearance")
        let original = try JSONSerialization.data(withJSONObject: legacy)
        try original.write(to: configURL)
        let tools = DockToolsStore(directory: directory)
        let id = try XCTUnwrap(tools.layout.slots.first?.id)
        tools.edit { $0.resize(id, to: 4); $0.move(id, by: 1) }
        let layout = try Data(contentsOf: toolsURL)
        tools.stop()
        let pages = Data(#"{"fixture-A":"apps","fixture-B":"tools"}"#.utf8)
        try pages.write(to: pagesURL)

        let store = AppStore(directory: directory, runningAppsProvider: { [] },
                             permissionsProvider: { (false, false) }, managesSystemDock: false)
        store.stopBackgroundServices()
        let upgraded = try JSONDecoder().decode(DockConfiguration.self, from: Data(contentsOf: configURL))
        XCTAssertEqual(upgraded.version, DockConfiguration.currentVersion)
        XCTAssertEqual(upgraded.entries, preview.entries)
        XCTAssertEqual(upgraded.folderAppearance, DockFolderAppearance())
        XCTAssertTrue(upgraded.autoHideDock)
        XCTAssertTrue(upgraded.autoHideWhenMaximized)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("configuration-before-v12.json")), original)
        XCTAssertEqual(try Data(contentsOf: toolsURL), layout)
        XCTAssertEqual(try Data(contentsOf: pagesURL), pages)
    }

    func testConfigurationDirectoryIsUnderProject() throws {
        let bundle = URL(fileURLWithPath: "/example/Preview/DualDock 3.app")
        XCTAssertEqual(try LocalPreviewConfiguration.directory(bundle: bundle, override: nil, preview: true).path,
                       "/example/Preview/LocalData")
        XCTAssertThrowsError(try LocalPreviewConfiguration.directory(bundle: bundle, override: "/example/Stable", preview: true))
        XCTAssertThrowsError(try LocalPreviewConfiguration.directory(bundle: bundle, override: "/example/Preview/../Stable", preview: true))
        let installed = try LocalPreviewConfiguration.directory(bundle: bundle, override: nil, preview: false)
        XCTAssertEqual(installed, LocalPreviewConfiguration.releaseDataDirectory)
        XCTAssertEqual(installed.lastPathComponent, "DualDock 3")
        XCTAssertNotEqual(LocalPreviewConfiguration.releaseBundleID, LocalPreviewConfiguration.bundleID)
    }
}
