import AppKit
import XCTest
@testable import DualDock

final class DockContextMenuVisibilityTests: XCTestCase {
    /// Drive the same tracking notifications as an AppKit/SwiftUI context menu
    /// without displaying a menu or posting input to the user's desktop.
    @MainActor func testMenuHoldsOnlyItsDockUntilTrackingEnds() async {
        _ = NSApplication.shared
        let first = DockPanel(), second = DockPanel()
        let firstStrip = DockStripView(), secondStrip = DockStripView()
        first.contentView = firstStrip
        second.contentView = secondStrip
        defer { first.close(); second.close() }

        let menu = NSMenu(), otherMenu = NSMenu()
        let center = NotificationCenter.default
        center.post(name: NSMenu.didBeginTrackingNotification, object: otherMenu)
        XCTAssertFalse(firstStrip.isInteracting)
        XCTAssertFalse(secondStrip.isInteracting)
        first.dispatchContextClick {
            XCTAssertTrue(firstStrip.isInteracting)
            center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        }
        XCTAssertTrue(firstStrip.isInteracting)
        XCTAssertFalse(secondStrip.isInteracting)
        center.post(name: NSMenu.didEndTrackingNotification, object: otherMenu)
        XCTAssertTrue(firstStrip.isInteracting)
        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertFalse(firstStrip.isInteracting)

        // A contextual click with no menu must not pin the Dock.
        second.dispatchContextClick { XCTAssertTrue(secondStrip.isInteracting) }
        XCTAssertFalse(secondStrip.isInteracting)
    }
}
