import Foundation
import CoreGraphics
import DualDockCore

struct DockPresentation: Equatable, Sendable {
    let displayID: String?
    let edge: DockEdge
    let style: DockGeometryStyle
    var maximumLength: CGFloat
    let fixedLength: CGFloat?
    let resizeMargin: CGFloat
    let resizeBounds: DockResizeBounds
    let requestedManualSizing: DockManualSizing
    let canResize: Bool
    var lengthResizeBounds: DockResizeBounds? = nil
}
