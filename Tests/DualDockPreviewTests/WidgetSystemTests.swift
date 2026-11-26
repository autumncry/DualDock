import XCTest
import AppKit
@testable import DualDock

final class WidgetSystemTests: XCTestCase {
    func testCPUTicksMeasureDeltaAndDoNotFabricateAnInitialReading() {
        let first = LocalCPUTicks(user: 7, sys: 9, idle: 10, nice: 0)
        XCTAssertNil(first.utilization(since: first))
        let next = LocalCPUTicks(user: 10, sys: 10, idle: 26, nice: 0)
        XCTAssertEqual(next.utilization(since: first), 20)
        let rollover = LocalCPUTicks(user: UInt32.max - 1, sys: 0, idle: 9, nice: 0)
        XCTAssertEqual(LocalCPUTicks(user: 0, sys: 0, idle: 17, nice: 0).utilization(since: rollover), 20)
    }

    @MainActor func testFocusTimerPausesRestoresAndFinishesAcrossRelaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var clock = Date(timeIntervalSince1970: 100_000)
        let timer = LocalToolMetrics(directory: dir, now: {clock})
        timer.setFocusDuration(minutes: 2)
        timer.toggleFocus()
        XCTAssertEqual(timer.focusEndsAt, clock.addingTimeInterval(120))
        clock = clock.addingTimeInterval(20)
        timer.toggleFocus()
        XCTAssertNil(timer.focusEndsAt)
        XCTAssertEqual(timer.focusRemaining, 100)
        timer.stop()
        let restored = LocalToolMetrics(directory: dir, now:{clock})
        XCTAssertEqual(restored.focusDuration,120)
        XCTAssertEqual(restored.focusRemaining,100)
        restored.toggleFocus()
        restored.stop()
        clock = clock.addingTimeInterval(130)
        let expired = LocalToolMetrics(directory: dir, now:{clock})
        XCTAssertNil(expired.focusEndsAt)
        XCTAssertEqual(expired.focusRemaining,0)
        expired.toggleFocus()
        XCTAssertEqual(expired.focusEndsAt, clock.addingTimeInterval(120))
        expired.stop()
    }

    @MainActor func testScreenRecordingPaneRetriesOnlyIfOpeningFails() async {
        var urls: [URL] = []
        XCTAssertTrue(ScreenRecordingSettings.openPane { url in urls.append(url); return true })
        XCTAssertEqual(urls.count,1)
        XCTAssertEqual(urls[0].query,"Privacy_ScreenCapture")
        urls.removeAll()
        XCTAssertTrue(ScreenRecordingSettings.openPane { url in urls.append(url); return urls.count == 2 })
        XCTAssertEqual(urls.count,2)
        XCTAssertEqual(urls[1].query,"Privacy_ScreenCapture")
        XCTAssertFalse(ScreenRecordingSettings.openPane { _ in false })
    }
}
