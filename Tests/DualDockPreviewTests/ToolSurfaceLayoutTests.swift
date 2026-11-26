import AppKit
import XCTest
import DualDockCore
@testable import DualDock

final class ToolSurfaceLayoutTests: XCTestCase {
    @MainActor func testInactiveToolPageDefersResizingAndUsesCurrentSizeAtReveal() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = DockConfiguration()
        config.showBadges = false
        config.hideSystemDock = false
        config.entries = [.init(name: "Fixture", apps: [.init(id: "fixture.app", name: "Fixture", path: "/System/Applications/Notes.app")])]
        try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("configuration.json"))
        let store = AppStore(directory: directory, runningAppsProvider: { [] }, managesSystemDock: false)
        defer { store.stopBackgroundServices() }
        var presentation = store.presentation(for: nil)
        presentation.style.barThickness = 70
        presentation.style.iconSize = 42
        presentation.style.magnificationScale = 1
        let strip = DockStripView(), surface = NSView()
        var widths: [CGFloat] = []
        strip.installTools(DockShelfSurface(view: surface, update: { _, size in widths.append(size) }), initialPage: .apps)
        _ = strip.populate(entries: config.entries, store: store, maxWidth: 1000, presentation: presentation) { _ in }
        for step in 0..<24 {
            presentation.style.iconSize = 42 + CGFloat(step) / 3
            _ = strip.updatePresentation(presentation)
        }
        XCTAssertTrue(widths.isEmpty)
        strip.setShelfPage(.tools, animated: false)
        XCTAssertFalse(surface.isHidden)
        XCTAssertEqual(widths.last, presentation.style.iconSize)
        XCTAssertEqual(surface.frame, strip.backdropFrame.insetBy(dx: 3, dy: 3))
        presentation.style.iconSize += 1
        _ = strip.updatePresentation(presentation)
        XCTAssertEqual(widths.last, presentation.style.iconSize)
    }
}
