import Foundation
import CoreGraphics

public enum DockEdge: String, Codable, CaseIterable, Sendable {
    case bottom, left, right, top

    public var isHorizontal: Bool { self == .bottom || self == .top }
}

/// Maps an ordered row (u) and distance inward from the screen edge (v) into
/// ordinary, unflipped AppKit coordinates. Images themselves are never rotated.
public struct DockAxisTransform: Equatable, Sendable {
    public let edge: DockEdge
    public let length: CGFloat
    public let thickness: CGFloat

    public init(edge: DockEdge, length: CGFloat, thickness: CGFloat) {
        self.edge = edge
        self.length = length
        self.thickness = thickness
    }

    public var physicalSize: CGSize {
        edge.isHorizontal ? CGSize(width: length, height: thickness) : CGSize(width: thickness, height: length)
    }

    public func pointToPhysical(_ point: CGPoint) -> CGPoint {
        switch edge {
        case .bottom: return point
        case .top: return CGPoint(x: point.x, y: thickness - point.y)
        case .left: return CGPoint(x: point.y, y: length - point.x)
        case .right: return CGPoint(x: thickness - point.y, y: length - point.x)
        }
    }

    public func pointToCanonical(_ point: CGPoint) -> CGPoint {
        switch edge {
        case .bottom: return point
        case .top: return CGPoint(x: point.x, y: thickness - point.y)
        case .left: return CGPoint(x: length - point.y, y: point.x)
        case .right: return CGPoint(x: length - point.y, y: thickness - point.x)
        }
    }

    public func rectToPhysical(_ rect: CGRect) -> CGRect {
        switch edge {
        case .bottom: return rect
        case .top: return CGRect(x: rect.minX, y: thickness - rect.maxY, width: rect.width, height: rect.height)
        case .left: return CGRect(x: rect.minY, y: length - rect.maxX, width: rect.height, height: rect.width)
        case .right: return CGRect(x: thickness - rect.maxY, y: length - rect.maxX, width: rect.height, height: rect.width)
        }
    }

    public func rectToCanonical(_ rect: CGRect) -> CGRect {
        switch edge {
        case .bottom: return rect
        case .top: return CGRect(x: rect.minX, y: thickness - rect.maxY, width: rect.width, height: rect.height)
        case .left: return CGRect(x: length - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        case .right: return CGRect(x: length - rect.maxY, y: thickness - rect.maxX, width: rect.height, height: rect.width)
        }
    }

    public func vectorToCanonical(_ vector: CGVector) -> CGVector {
        switch edge {
        case .bottom: return vector
        case .top: return CGVector(dx: vector.dx, dy: -vector.dy)
        case .left: return CGVector(dx: -vector.dy, dy: vector.dx)
        case .right: return CGVector(dx: -vector.dy, dy: -vector.dx)
        }
    }
}

public struct DockManualSizing: Codable, Equatable, Sendable {
    public var length: Double
    public var thickness: Double
    public var iconScale: Double
    public var iconSpacing: Double
    /// Per-side whitespace retained by manual content-fitting mode. The saved
    /// fixed length remains independent and is restored when that mode is off.
    public var contentPadding: Double?

    public init(length: Double, thickness: Double, iconScale: Double = 1, iconSpacing: Double = 14,
                contentPadding: Double? = nil) {
        self.length = length
        self.thickness = thickness
        self.iconScale = iconScale
        self.iconSpacing = iconSpacing
        self.contentPadding = contentPadding
        normalize()
    }

    public mutating func normalize() {
        length = length.isFinite ? max(1, length) : 1000
        thickness = thickness.isFinite ? max(1, thickness) : 66
        iconScale = iconScale.isFinite ? min(1.25, max(0.25, iconScale)) : 1
        iconSpacing = iconSpacing.isFinite ? min(32, max(0, iconSpacing)) : 14
        if let padding = contentPadding {
            contentPadding = padding.isFinite ? max(DockContentLengthPolicy.minimumPadding, padding) : nil
        }
    }

    public var resolvedIconSize: Double {
        min(max(1, thickness - 8), max(1, thickness / DockSizingLimits.heightPerIconPoint * iconScale))
    }

    private enum CodingKeys: String, CodingKey { case length, thickness, iconScale, iconSpacing, contentPadding }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        length = try values.decodeIfPresent(Double.self, forKey: .length) ?? 1000
        thickness = try values.decodeIfPresent(Double.self, forKey: .thickness) ?? 66
        iconScale = try values.decodeIfPresent(Double.self, forKey: .iconScale) ?? 1
        iconSpacing = try values.decodeIfPresent(Double.self, forKey: .iconSpacing) ?? 14
        contentPadding = try values.decodeIfPresent(Double.self, forKey: .contentPadding)
        normalize()
    }
}

public struct DockDisplaySettings: Codable, Equatable, Sendable {
    public var edge: DockEdge
    public var manualSizing: DockManualSizing?
    public init(edge: DockEdge = .bottom, manualSizing: DockManualSizing? = nil) {
        self.edge = edge
        self.manualSizing = manualSizing
    }
}
