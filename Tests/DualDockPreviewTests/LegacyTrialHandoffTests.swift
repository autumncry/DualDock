import AppKit
import XCTest
@testable import DualDock

@MainActor
final class LegacyTrialHandoffTests: XCTestCase {
    func testOnlyRetiredTrialIdentitiesAreSelected() {
        XCTAssertEqual(Set(LegacyTrialHandoff.bundleIdentifiers),
                       Set(["local.ronny.DualDock3", "local.ronny.DualDock3Preview"]))
        XCTAssertFalse(LegacyTrialHandoff.bundleIdentifiers.contains(LocalPreviewConfiguration.releaseBundleID))
    }

    func testSecondQuitRequestOnlyTargetsTheTrialStillRunning() async {
        var first = 0, second = 0, retries = 0
        let trials = [
            LegacyTrialHandoff.Instance(bundle: nil, quit: { first += 1 }, terminated: { first > 0 }),
            LegacyTrialHandoff.Instance(bundle: nil, quit: { second += 1 }, terminated: { second > 1 })
        ]
        let result = await LegacyTrialHandoff.waitForExit(trials, grace: 0) {
            retries += 1
            return true
        }
        XCTAssertTrue(result)
        XCTAssertEqual([first, second, retries], [1, 2, 1])
    }

    func testRefusingQuitCancelsStartupWithoutForcingTheOldProcess() async {
        var attempts = 0
        let trial = LegacyTrialHandoff.Instance(bundle: nil, quit: { attempts += 1 }, terminated: { false })
        let result = await LegacyTrialHandoff.waitForExit([trial], grace: 0) { false }
        XCTAssertFalse(result)
        XCTAssertEqual(attempts, 1)
    }
}
