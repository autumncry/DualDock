import Foundation
import CoreGraphics

/// Frame-rate-independent damping shared by pointer tracking and gentle return.
public struct DockAnimationTiming: Sendable {
    public private(set) var isRunning = false
    private var lastTimestamp: TimeInterval?

    public init() {}

    public mutating func resume() {
        guard !isRunning else { return }
        isRunning = true
        lastTimestamp = nil
    }

    public mutating func pause() {
        isRunning = false
        lastTimestamp = nil
    }

    public mutating func fraction(at timestamp: TimeInterval, returningToRest: Bool) -> CGFloat {
        guard isRunning, timestamp.isFinite else { return 0 }
        let dt = min(0.05, max(0.001, timestamp - (lastTimestamp ?? timestamp - 1.0 / 60.0)))
        lastTimestamp = timestamp
        let response: TimeInterval = returningToRest ? 0.15 : 0.09
        return CGFloat(1 - exp(-dt / response))
    }
}
