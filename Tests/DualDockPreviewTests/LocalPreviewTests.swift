import XCTest
import DualDockCore
@testable import DualDock

final class LocalPreviewTests: XCTestCase {
    @MainActor func testSeedCopiesGroupsOnceAndSeparatesBothDisplays() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalURL = root.appendingPathComponent("stable.json")
        let dataDirectory = root.appendingPathComponent("LocalData")
        let trialURL = dataDirectory.appendingPathComponent("configuration.json")
        var stable = DockConfiguration()
        stable.entries = [DockEntry(name: "Editors", apps: [
            AppReference(id: "test.editor", name: "Editor", path: "/example/Editor.app"),
            AppReference(id: "test.notes", name: "Notes", path: "/example/Notes.app")
        ], isGroup: true)]
        stable.folderAppearance = DockFolderAppearance(style: .glass,
            backgroundColor: DockFolderColor(red: 0.2, green: 0.6, blue: 0.7), backgroundOpacity: 0.46)
        stable.autoHideDock = true
        stable.autoHideWhenMaximized = false
        stable.displaySettings["internal"] = DockDisplaySettings(edge: .right)
        stable.hideSystemDock = true
        let initial = try JSONEncoder().encode(stable)
        try initial.write(to: originalURL)
        try LocalPreviewConfiguration.seed(directory: dataDirectory, originalURL: originalURL, displayIDs: ["internal","external"])
        let copy = try Data(contentsOf: trialURL)
        let imported = try JSONDecoder().decode(DockConfiguration.self, from: copy)
        XCTAssertEqual(imported.version, DockConfiguration.currentVersion)
        XCTAssertEqual(imported.entries, stable.entries)
        XCTAssertEqual(imported.folderAppearance, stable.folderAppearance)
        XCTAssertTrue(imported.autoHideDock)
        XCTAssertFalse(imported.autoHideWhenMaximized)
        XCTAssertEqual(imported.displaySettings["internal"]?.edge, .left)
        XCTAssertEqual(imported.displaySettings["external"]?.edge, .top)
        XCTAssertFalse(imported.hideSystemDock)
        XCTAssertEqual(try Data(contentsOf: originalURL), initial)
        stable.entries = []
        try JSONEncoder().encode(stable).write(to: originalURL)
        try LocalPreviewConfiguration.seed(directory: dataDirectory, originalURL: originalURL, displayIDs: ["external"])
        XCTAssertEqual(try Data(contentsOf: trialURL), copy)
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

        let stableURL = directory.appendingPathComponent("stable.json")
        var stable = DockConfiguration()
        stable.folderAppearance = DockFolderAppearance(style: .skeuomorphic)
        let stableData = try JSONEncoder().encode(stable)
        try stableData.write(to: stableURL)
        try LocalPreviewConfiguration.seed(directory: directory, originalURL: stableURL, displayIDs: ["fixture-A"])

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
        XCTAssertEqual(try Data(contentsOf: stableURL), stableData)
    }

    func testConfigurationDirectoryIsUnderProject() throws {
        let bundle = URL(fileURLWithPath: "/example/Preview/DualDock 3.app")
        XCTAssertEqual(try LocalPreviewConfiguration.directory(bundle: bundle, override: nil).path,
                       "/example/Preview/LocalData")
        XCTAssertThrowsError(try LocalPreviewConfiguration.directory(bundle: bundle, override: "/example/Stable"))
        XCTAssertThrowsError(try LocalPreviewConfiguration.directory(bundle: bundle, override: "/example/Preview/../Stable"))
    }
}
