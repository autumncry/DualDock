import AppKit
import DualDockCore

// The check script appends this file to a temporary copy of the production
// coordinator, so the extension can exercise its private snapshot application
// and popup construction without broadening the app's production interface.
extension DisplayCoordinator {
    fileprivate func applySnapshotForChecks(_ value: DockVisibilityController.Snapshot) { applyVisibility(value) }
    fileprivate var groupForChecks: DockPanel? { groupPanel }
    fileprivate var interactingDisplays: Set<CGDirectDisplayID> {
        Set(visibilityTargets().filter(\.interacting).map(\.id))
    }
    fileprivate var previewForChecks: DockPanel? { previewPanel }
    fileprivate func showPreviewForChecks(app: AppReference, tile: DockTile, screen: NSScreen, edge: DockEdge) {
        let item = WindowPreview(windowID: 424242, pid: 0, title: "Fixture",
            image: NSImage(size: NSSize(width: 200, height: 140)), frame: CGRect(x: 0, y: 0, width: 200, height: 140))
        showPreview([item], app: app, anchor: tileRect(tile), sourceRect: interactionRect(tile), screen: screen, edge: edge)
    }
}

@MainActor
private final class FixtureTools: DockShelfToolsProviding {
    var detailOnDisplay: String?
    func makeSurface(on displayID: String, presentation: DockPresentation) -> DockShelfSurface {
        DockShelfSurface(view: NSView(), update: { _, _ in })
    }
    func setShelfVisible(_ visible: Bool, on displayID: String) {}
    func keepsShelfOpen(on displayID: String) -> Bool { detailOnDisplay == displayID }
}

@main
struct FullscreenDockIntegrationChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let apps = [AppReference(id: "fullscreen.fixture.1", name: "One", path: "/System/Applications/Notes.app"),
                    AppReference(id: "fullscreen.fixture.2", name: "Two", path: "/System/Applications/TextEdit.app")]
        var config = DockConfiguration()
        config.hideSystemDock = false
        config.showBadges = false
        config.showPreviews = false
        config.autoHideWhenMaximized = false
        config.dockWidth = 600.37
        config.entries = [DockEntry(name: "Fixture group", apps: apps, isGroup: true), DockEntry(name: "Fixture app", apps: [apps[0]])]
        try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("configuration.json"))
        let store = AppStore(directory: directory, runningAppsProvider: { apps },
                             permissionsProvider: { (false, false) }, managesSystemDock: false)
        store.stopBackgroundServices()
        let tools = FixtureTools()
        let coordinator = DisplayCoordinator(store: store, presentsPanels: false,
            windowInteractions: WindowInteractionService(environment: .init(read: { _ in .available([]) }, perform: { _, _, _ in .unsupported })),
            tools: tools)
        defer { coordinator.stop(); store.stopBackgroundServices() }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        guard let dock = coordinator.docks.values.sorted(by: { $0.displayID < $1.displayID }).first else {
            fatalError("A real screen snapshot is required")
        }
        let id = DisplayCoordinator.id(dock.screen)
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) { checks += 1; if !condition { failures.append(message) } }
        func isOverlay(_ panel: NSWindow) -> Bool {
            panel.collectionBehavior.contains(.fullScreenAuxiliary) && panel.collectionBehavior.contains(.canJoinAllApplications)
        }
        func groupTile(_ dock: DisplayCoordinator.ScreenDock) -> DockTile { dock.strip.tiles.first { $0.entry.isGroup }! }
        func verifyPlacement(_ dock: DisplayCoordinator.ScreenDock, fullscreen: Bool, _ label: String) {
            let bounds = fullscreen ? DockVisibilityController.fullscreenBounds(for: dock.screen)
                : store.displays.first { $0.id == dock.displayID }!.visibleFrame
            let geometry = dock.strip.layoutGeometry!
            let desiredPanel = geometry.panelFrame(in: bounds)
            let expected = geometry.backdropRect.offsetBy(dx: desiredPanel.minX, dy: desiredPanel.minY)
            let actual = dock.panel.convertToScreen(dock.strip.convert(dock.strip.backdropFrame, to: nil))
            check(abs(actual.minX - expected.minX) < 0.000001 && abs(actual.minY - expected.minY) < 0.000001,
                  "\(label): incorrect physical Dock placement")
        }

        if let menu = groupTile(dock).menuProvider?() {
            menu.delegate?.menuWillOpen?(menu)
            check(coordinator.interactingDisplays == [id], "An open native menu should hold only its source display")
            menu.delegate?.menuDidClose?(menu)
            check(coordinator.interactingDisplays.isEmpty, "Closing a menu must release its display")
        } else {
            check(false, "Missing native menu for the fixture tile")
        }

        for edge in DockEdge.allCases {
            store.setEdge(edge, for: dock.displayID)
            coordinator.refreshDisplays()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            coordinator.applySnapshotForChecks(.init(hidden: [], fullscreen: []))
            check(!isOverlay(dock.panel), "\(edge): normal panel opted into fullscreen before reveal")
            verifyPlacement(dock, fullscreen: false, "\(edge) normal")
            let otherFrames = coordinator.docks.filter { $0.key != id }.mapValues { $0.panel.frame }
            groupTile(dock).onPress?()
            check(coordinator.groupForChecks != nil && !isOverlay(coordinator.groupForChecks!), "\(edge): normal group membership wrong")

            coordinator.applySnapshotForChecks(.init(hidden: [id], fullscreen: [id]))
            check(!isOverlay(dock.panel), "\(edge): hidden fullscreen panel joined before edge reveal")
            check(coordinator.groupForChecks == nil, "\(edge): fullscreen entry retained ordinary group")
            check(!dock.panel.isVisible, "Fixture showed a panel")

            coordinator.applySnapshotForChecks(.init(hidden: [], fullscreen: [id]))
            check(isOverlay(dock.panel), "\(edge): revealed Dock did not join fullscreen")
            verifyPlacement(dock, fullscreen: true, "\(edge) revealed")
            for (otherID, frame) in otherFrames {
                let other = coordinator.docks[otherID]!
                check(!isOverlay(other.panel) && other.panel.frame == frame, "\(edge): other display changed when first display revealed")
            }
            groupTile(dock).onPress?()
            check(coordinator.groupForChecks != nil && isOverlay(coordinator.groupForChecks!), "\(edge): group did not inherit fullscreen membership")
            coordinator.showPreviewForChecks(app: apps[0], tile: groupTile(dock), screen: dock.screen, edge: edge)
            check(coordinator.previewForChecks != nil && isOverlay(coordinator.previewForChecks!), "\(edge): preview did not inherit fullscreen membership")

            coordinator.applySnapshotForChecks(.init(hidden: [id], fullscreen: [id]))
            check(!isOverlay(dock.panel), "\(edge): hidden Dock retained fullscreen overlay membership")
            check(coordinator.groupForChecks == nil && coordinator.previewForChecks == nil, "\(edge): hiding did not dismiss fullscreen popups")
            coordinator.applySnapshotForChecks(.init(hidden: [], fullscreen: [id]))
            check(isOverlay(dock.panel), "\(edge): repeated fullscreen reveal failed")
            groupTile(dock).onPress?()
            coordinator.applySnapshotForChecks(.init(hidden: [], fullscreen: []))
            check(!isOverlay(dock.panel), "\(edge): exit retained fullscreen membership")
            check(coordinator.groupForChecks == nil, "\(edge): exit retained fullscreen popup")
            verifyPlacement(dock, fullscreen: false, "\(edge) exit")

            if let other = coordinator.docks.values.first(where: { DisplayCoordinator.id($0.screen) != id }) {
                coordinator.applySnapshotForChecks(.init(hidden: [], fullscreen: [id]))
                groupTile(other).onPress?()
                let normalGroup = coordinator.groupForChecks
                check(normalGroup != nil && !isOverlay(normalGroup!), "\(edge): normal-screen popup inherited another display's fullscreen state")
                coordinator.applySnapshotForChecks(.init(hidden: [id], fullscreen: [id]))
                check(coordinator.groupForChecks === normalGroup, "\(edge): hiding first display dismissed another display's popup")
                coordinator.dismissPopups()
            }
        }
        // Exercise the actual panel owner and paging host across ordinary edge
        // hides, then a fullscreen edge hide. Detail interaction belongs only
        // to the display on which the popover was opened.
        dock.strip.setShelfPage(.tools, animated: false)
        tools.detailOnDisplay = dock.displayID
        check(coordinator.interactingDisplays == [id],
              "An open tool detail must keep precisely its own display engaged")
        tools.detailOnDisplay = nil
        check(coordinator.interactingDisplays.isEmpty,
              "Dismissing the tool detail left its Dock engaged")
        for fullscreen: Set<CGDirectDisplayID> in [[], [id]] {
            coordinator.applySnapshotForChecks(.init(hidden: [id], fullscreen: fullscreen))
            check(dock.strip.page == .tools && !isOverlay(dock.panel),
                  "Auto-hiding lost the tools page or retained fullscreen overlay membership")
            coordinator.applySnapshotForChecks(.init(hidden: [], fullscreen: fullscreen))
            check(dock.strip.page == .tools && isOverlay(dock.panel) == fullscreen.contains(id),
                  "Revealing lost the tools page or used the wrong desktop/fullscreen membership")
            check(coordinator.docks.filter { $0.key != id }.values.allSatisfy { $0.strip.page == .apps },
                  "Revealing the tool shelf changed another display's page")
        }

        check(NSApp.windows.allSatisfy { !$0.isVisible }, "Fixture presented a visible window")
        print("Fullscreen Dock integration: \(checks) checks, \(failures.count) failures, \(coordinator.docks.count) displays; hidden panels only")
        failures.forEach { print("FAIL: \($0)") }
        exit(failures.isEmpty ? 0 : 1)
    }
}
