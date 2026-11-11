import XCTest
@testable import DualDockCore

final class DockVisibilityPolicyTests: XCTestCase {
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

    func testObstructionHidesUntilEdgeDwellAndPreservesPopupInteraction() {
        var state = DockVisibilityPolicy()
        func update(_ time: Double, edge: Bool = false, inside: Bool = false, interacting: Bool = false) -> Bool {
            state.update(now: time, fullscreen: false, autoHide: true, obstructed: true,
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
        XCTAssertFalse(state.update(now: 0, fullscreen: true, autoHide: true, obstructed: false,
                                    pointerAtEdge: true, pointerInsideDock: true, interacting: true))
        XCTAssertTrue(state.update(now: 0.01, fullscreen: false, autoHide: true, obstructed: false,
                                   pointerAtEdge: false, pointerInsideDock: false, interacting: false))
        XCTAssertFalse(state.update(now: 0.02, fullscreen: true, autoHide: false, obstructed: false,
                                    pointerAtEdge: false, pointerInsideDock: false, interacting: false))
    }

    func testDisablingAutoHideAndIndependentDisplays() {
        var first = DockVisibilityPolicy(), second = DockVisibilityPolicy()
        XCTAssertFalse(first.update(now: 0, fullscreen: true, autoHide: true, obstructed: false,
                                    pointerAtEdge: false, pointerInsideDock: false, interacting: false))
        XCTAssertTrue(second.update(now: 0, fullscreen: false, autoHide: false, obstructed: true,
                                    pointerAtEdge: false, pointerInsideDock: false, interacting: false))
        XCTAssertTrue(first.update(now: 0.1, fullscreen: false, autoHide: false, obstructed: true,
                                   pointerAtEdge: false, pointerInsideDock: false, interacting: false))
    }

    func testPointerAlreadyUsingVisibleDockDoesNotLoseItWhenWindowArrives() {
        var state = DockVisibilityPolicy()
        XCTAssertTrue(state.update(now: 0, fullscreen: false, autoHide: true, obstructed: true,
                                   pointerAtEdge: false, pointerInsideDock: true, interacting: false))
        XCTAssertTrue(state.update(now: 0.2, fullscreen: false, autoHide: true, obstructed: true,
                                   pointerAtEdge: false, pointerInsideDock: false, interacting: false))
        XCTAssertFalse(state.update(now: 0.31, fullscreen: false, autoHide: true, obstructed: true,
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
