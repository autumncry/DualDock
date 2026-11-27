import Foundation
import CoreGraphics

public enum DockShelfPage: String, Codable, Sendable {
    case apps, tools

    public var other: Self { self == .apps ? .tools : .apps }
    public var position: CGFloat { self == .apps ? 0 : 1 }
}

/// One trackpad contact stream has a single owner. Momentum continues to
/// belong to that owner, even though it arrives after the fingers lift.
public struct DockShelfGesture: Sendable {
    public enum Phase { case began, changed, ended, cancelled, momentum, wheel }
    public enum Result: Equatable {
        case pass, consume
        case preview(CGFloat)
        case settle(DockShelfPage)
    }
    private enum Axis { case waiting, along, across }
    private var axis: Axis = .waiting
    private var inContact = false
    private var consumeMomentum = false
    private var along: CGFloat = 0
    private var across: CGFloat = 0
    private var startPage: DockShelfPage = .apps

    public init() {}

    public mutating func update(phase: Phase, along deltaAlong: CGFloat, across deltaAcross: CGFloat,
                                travel: CGFloat, page: DockShelfPage, enabled: Bool) -> Result {
        if phase == .momentum { return consumeMomentum ? .consume : .pass }
        if phase == .wheel { return .pass }
        if phase == .began || (!inContact && phase == .changed) {
            inContact = true
            consumeMomentum = false
            axis = enabled ? .waiting : .along
            startPage = page
            along = 0
            across = 0
        }
        guard inContact else { return .pass }
        if !enabled && axis == .across {
            axis = .along
            return .settle(startPage)
        }
        if !enabled { axis = .along }

        along += deltaAlong.isFinite ? deltaAlong : 0
        across += deltaAcross.isFinite ? deltaAcross : 0
        if axis == .waiting && max(abs(along), abs(across)) >= 5 {
            if abs(across) > abs(along) * 1.25 { axis = .across; consumeMomentum = true }
            else if abs(along) >= abs(across) { axis = .along }
        }
        let distance = max(36, min(130, travel))
        if phase == .ended || phase == .cancelled {
            inContact = false
            guard axis == .across else { return .pass }
            let towardsOther = startPage == .apps ? across : -across
            return .settle(phase == .ended && towardsOther >= distance * 0.40 ? startPage.other : startPage)
        }
        switch axis {
        case .across: return .preview(max(0, min(1, startPage.position + across / distance)))
        case .waiting, .along: return .pass
        }
    }
}
