import XCTest
@testable import DualDockCore

final class DockAnimationTimingTests: XCTestCase {
    func testRetargetingDoesNotRestartTheActiveFrameClock() {
        var uninterrupted = DockAnimationTiming()
        var retargeted = DockAnimationTiming()
        uninterrupted.resume()
        retargeted.resume()
        for frame in 0..<120 {
            let timestamp = Double(frame) / 120
            if frame > 0 { retargeted.resume() }
            XCTAssertEqual(retargeted.fraction(at: timestamp, returningToRest: false),
                           uninterrupted.fraction(at: timestamp, returningToRest: false), accuracy: 0.000001)
        }
    }

    func testReturnIsGentlerThanTrackingWithoutOvershoot() {
        var tracking = DockAnimationTiming()
        var returning = DockAnimationTiming()
        tracking.resume()
        returning.resume()
        let trackingStep = tracking.fraction(at: 1, returningToRest: false)
        let returnStep = returning.fraction(at: 1, returningToRest: true)
        XCTAssertGreaterThan(trackingStep, returnStep)
        XCTAssertLessThan(trackingStep, 0.2)
        XCTAssertGreaterThan(returnStep, 0)
        var remaining: CGFloat = 1
        for frame in 1...90 {
            let fraction = returning.fraction(at: 1 + Double(frame) / 60, returningToRest: true)
            XCTAssertGreaterThan(fraction, 0)
            XCTAssertLessThan(fraction, 1)
            remaining *= 1 - fraction
        }
        XCTAssertLessThan(remaining, 0.001)
    }

    func testIdleResumeDoesNotCountTimeSpentPaused() {
        var timing = DockAnimationTiming()
        timing.resume()
        let initial = timing.fraction(at: 0, returningToRest: false)
        timing.pause()
        XCTAssertEqual(timing.fraction(at: 100, returningToRest: false), 0)
        timing.resume()
        XCTAssertEqual(timing.fraction(at: 100, returningToRest: false), initial, accuracy: 0.000001)
    }
}
