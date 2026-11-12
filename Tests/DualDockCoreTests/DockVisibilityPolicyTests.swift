import XCTest
@testable import DualDockCore

final class DockVisibilityPolicyTests: XCTestCase {
    func testOrdinaryWindowsCoveringDockRemainVisible() {
        let workspace = CGRect(x: 0, y: 0, width: 1800, height: 1129)
        let ordinary = [
            CGRect(x: 637, y: 52, width: 740, height: 796),
            CGRect(x: 0, y: 0, width: 1800, height: 500),
            CGRect(x: 0, y: -10, width: 1800, height: 1129)
        ]
        for frame in ordinary {
            var policy = DockVisibilityPolicy()
            let maximized = DockVisibilityPolicy.isMaximizedWindow(frame, in: workspace)
            XCTAssertTrue(policy.update(now: 0, fullscreen: false, autoHide: true,
                maximized: maximized, pointerAtEdge: false, pointerInsideDock: false, interacting: false),
                "An ordinary window covering Dock must not hide it: \(frame)")
        }
    }

    func testLegacyConfigurationKeepsAutoHideOffAndNewChoicePersists() throws {
        var saved = DockConfiguration()
        saved.dockWidth = 1325.5
        saved.entries = [.init(name: "Group", apps: [.init(id: "test", name: "Test", path: "/Applications/Test.app")], isGroup: true)]
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        legacy["version"] = 7
        legacy.removeValue(forKey: "autoHideWhenObstructed")
        var restored = try JSONDecoder().decode(DockConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(restored, saved)
        XCTAssertFalse(restored.autoHideWhenObstructed)
        restored.autoHideWhenObstructed = true
        XCTAssertEqual(try JSONDecoder().decode(DockConfiguration.self, from: JSONEncoder().encode(restored)), restored)
    }

    func testMaximizedAliasPreservesLegacyStorageKeyAndExistingChoice() throws {
        var restored = try JSONDecoder().decode(DockConfiguration.self,
            from: Data("{\"version\":8,\"autoHideWhenObstructed\":true}".utf8))
        XCTAssertTrue(restored.autoHideWhenMaximized)
        restored.autoHideWhenMaximized = false
        XCTAssertFalse(restored.autoHideWhenObstructed)
        restored.autoHideWhenMaximized = true
        let encoded = try JSONEncoder().encode(restored)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["autoHideWhenObstructed"] as? Bool, true)
        XCTAssertNil(object["autoHideWhenMaximized"], "The computed name must not split persisted state")
        XCTAssertEqual(try JSONDecoder().decode(DockConfiguration.self, from: encoded), restored)
    }

    func testWorkspaceFillAllowsRoundingAndSmallSymmetricTilingMargins() {
        let workspace = CGRect(x: 0, y: 0, width: 1800, height: 1129)
        for frame in [workspace,
                      CGRect(x: 0, y: -1, width: 1800, height: 1130),
                      CGRect(x: 0, y: 0, width: 1800, height: 1130),
                      CGRect(x: 2, y: -2, width: 1800, height: 1129),
                      workspace.insetBy(dx: 8, dy: 8),
                      workspace.insetBy(dx: 16, dy: 16),
                      workspace.insetBy(dx: 16, dy: 0)] {
            XCTAssertTrue(DockVisibilityPolicy.isMaximizedWindow(frame, in: workspace), "Expected workspace fill: \(frame)")
        }
    }

    func testCoverageAloneDoesNotMakeAnOrdinaryWindowMaximized() {
        let workspace = CGRect(x: 0, y: 0, width: 1800, height: 1129)
        for frame in [CGRect(x: 0, y: 0, width: 900, height: 1129),
                      CGRect(x: 16, y: 0, width: 1784, height: 1129),
                      CGRect(x: 0, y: 10, width: 1800, height: 1119),
                      CGRect(x: -500, y: -500, width: 3000, height: 2000),
                      workspace.insetBy(dx: 17, dy: 17), .null, .infinite] {
            XCTAssertFalse(DockVisibilityPolicy.isMaximizedWindow(frame, in: workspace), "Ordinary bounds: \(frame)")
        }
        for delta in [CGFloat(10), 32, 100] {
            for frame in [workspace.offsetBy(dx: 0, dy: -delta), workspace.offsetBy(dx: 0, dy: delta),
                          workspace.offsetBy(dx: -delta, dy: 0), workspace.offsetBy(dx: delta, dy: 0)] {
                XCTAssertFalse(DockVisibilityPolicy.isMaximizedWindow(frame, in: workspace), "Shifted full size: \(frame)")
            }
        }
    }

    func testMaximizationIsRelativeToEachDisplayAvailableArea() {
        let main = CGRect(x: 0, y: 0, width: 1800, height: 1129)
        let external = CGRect(x: -2560, y: 809, width: 2560, height: 1409)
        XCTAssertTrue(DockVisibilityPolicy.isMaximizedWindow(external, in: external))
        XCTAssertTrue(DockVisibilityPolicy.isMaximizedWindow(external.insetBy(dx: 12, dy: 12), in: external))
        XCTAssertFalse(DockVisibilityPolicy.isMaximizedWindow(external, in: main))
        XCTAssertFalse(DockVisibilityPolicy.isMaximizedWindow(main, in: external))
        XCTAssertFalse(DockVisibilityPolicy.isMaximizedWindow(main, in: .null))
        XCTAssertFalse(DockVisibilityPolicy.isMaximizedWindow(main, in: .infinite))
        let normalTiledWindows = [CGRect(x: 0, y: 0, width: 900, height: 1129),
                                  CGRect(x: 900, y: 0, width: 900, height: 1129)]
        XCTAssertFalse(normalTiledWindows.contains { DockVisibilityPolicy.isMaximizedWindow($0, in: main) })
    }

    func testRestoringOrMovingAWindowOutOfMaximizationShowsDockImmediately() {
        let workspace = CGRect(x: 0, y: 0, width: 1800, height: 1129)
        var state = DockVisibilityPolicy()
        XCTAssertFalse(state.update(now: 0, fullscreen: false, autoHide: true, maximized: true,
                                    pointerAtEdge: false, pointerInsideDock: false, interacting: false))
        let stillCoversDock = workspace.offsetBy(dx: 0, dy: -10)
        XCTAssertTrue(state.update(now: 0.01, fullscreen: false, autoHide: true,
            maximized: DockVisibilityPolicy.isMaximizedWindow(stillCoversDock, in: workspace),
            pointerAtEdge: false, pointerInsideDock: false, interacting: false))
    }

    func testMaximizedWindowHidesUntilEdgeDwellAndPreservesPopupInteraction() {
        var state = DockVisibilityPolicy()
        func update(_ time: Double, edge: Bool = false, inside: Bool = false, interacting: Bool = false) -> Bool {
            state.update(now: time, fullscreen: false, autoHide: true, maximized: true,
                         pointerAtEdge: edge, pointerInsideDock: inside, interacting: interacting)
        }
        XCTAssertFalse(update(0))
        XCTAssertFalse(update(0.1, inside: true), "Covered body is not an invisible activation target")
        XCTAssertFalse(update(1, edge: true))
        XCTAssertFalse(update(1.1, edge: true))
        XCTAssertTrue(update(1.13, edge: true))
        XCTAssertTrue(update(1.2), "Allow crossing the gap from screen edge to Dock")
        XCTAssertTrue(update(1.25, inside: true))
        XCTAssertTrue(update(3, interacting: true), "Folder/menu/preview owns the reveal")
        XCTAssertTrue(update(3.2))
        XCTAssertFalse(update(3.31))
    }

    func testFullscreenHidesImmediatelyAndNormalDesktopRestoresImmediately() {
        var state = DockVisibilityPolicy()
        XCTAssertFalse(state.update(now: 0, fullscreen: true, autoHide: true, maximized: false,
                                    pointerAtEdge: true, pointerInsideDock: true, interacting: true))
        XCTAssertTrue(state.update(now: 0.01, fullscreen: false, autoHide: true, maximized: false,
                                   pointerAtEdge: false, pointerInsideDock: false, interacting: false))
        XCTAssertFalse(state.update(now: 0.02, fullscreen: true, autoHide: false, maximized: false,
                                    pointerAtEdge: false, pointerInsideDock: false, interacting: false))
    }

    func testDisablingAutoHideAndIndependentDisplays() {
        var first = DockVisibilityPolicy(), second = DockVisibilityPolicy()
        XCTAssertFalse(first.update(now: 0, fullscreen: true, autoHide: true, maximized: false,
                                    pointerAtEdge: false, pointerInsideDock: false, interacting: false))
        XCTAssertTrue(second.update(now: 0, fullscreen: false, autoHide: false, maximized: true,
                                    pointerAtEdge: false, pointerInsideDock: false, interacting: false))
        XCTAssertTrue(first.update(now: 0.1, fullscreen: false, autoHide: false, maximized: true,
                                   pointerAtEdge: false, pointerInsideDock: false, interacting: false))
    }

    func testPointerAlreadyUsingVisibleDockDoesNotLoseItWhenWindowArrives() {
        var state = DockVisibilityPolicy()
        XCTAssertTrue(state.update(now: 0, fullscreen: false, autoHide: true, maximized: true,
                                   pointerAtEdge: false, pointerInsideDock: true, interacting: false))
        XCTAssertTrue(state.update(now: 0.2, fullscreen: false, autoHide: true, maximized: true,
                                   pointerAtEdge: false, pointerInsideDock: false, interacting: false))
        XCTAssertFalse(state.update(now: 0.31, fullscreen: false, autoHide: true, maximized: true,
                                    pointerAtEdge: false, pointerInsideDock: false, interacting: false))
    }

    func testObstructionUsesVisibleBodyAndIgnoresTouchingEdges() {
        let body = CGRect(x: 200, y: 8, width: 600, height: 64)
        XCTAssertTrue(DockVisibilityPolicy.isObstructed(body, by: [CGRect(x: 0, y: 0, width: 1000, height: 700)]))
        XCTAssertFalse(DockVisibilityPolicy.isObstructed(body, by: [CGRect(x: 0, y: 72, width: 1000, height: 700)]))
        XCTAssertFalse(DockVisibilityPolicy.isObstructed(body, by: [CGRect(x: 0, y: 120, width: 1000, height: 700)]))
        XCTAssertFalse(DockVisibilityPolicy.isObstructed(body, by: [.null, .infinite]))
    }

    func testFourActivationEdgesUseAvailableAreaAndDockSpan() {
        let screen = CGRect(x: -1600, y: 200, width: 1600, height: 900)
        let horizontal = CGRect(x: -1300, y: 208, width: 1000, height: 64)
        let vertical = CGRect(x: -1592, y: 350, width: 64, height: 600)
        XCTAssertEqual(DockVisibilityPolicy.activationRegion(backdrop: horizontal, edge: .bottom, visibleScreen: screen),
                       CGRect(x: -1300, y: 200, width: 1000, height: 3))
        XCTAssertEqual(DockVisibilityPolicy.activationRegion(backdrop: horizontal, edge: .top, visibleScreen: screen),
                       CGRect(x: -1300, y: 1097, width: 1000, height: 3))
        XCTAssertEqual(DockVisibilityPolicy.activationRegion(backdrop: vertical, edge: .left, visibleScreen: screen),
                       CGRect(x: -1600, y: 350, width: 3, height: 600))
        XCTAssertEqual(DockVisibilityPolicy.activationRegion(backdrop: vertical, edge: .right, visibleScreen: screen),
                       CGRect(x: -3, y: 350, width: 3, height: 600))
    }
}
