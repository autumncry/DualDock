import Foundation
import CoreGraphics

public enum NativeDockMetricsStatus: String, Equatable, Sendable {
    case accessibility
    case preferences
    case cached
    case fallback
}

/// Geometry is expressed in logical points. This is a snapshot, not a user preference.
public struct NativeDockMetrics: Equatable, Sendable {
    public let iconSize: Double
    public let barThickness: Double
    public let leadingPadding: Double
    public let trailingPadding: Double
    public let itemSpacing: Double
    public let separatorLength: Double
    public let magnifiedIconSize: Double
    public let magnificationEnabled: Bool

    /// A conservative fallback, not a claim about Apple's default Dock settings.
    public static let fallback = NativeDockMetrics(iconSize: 48, barThickness: 60,
        leadingPadding: 6, trailingPadding: 6, itemSpacing: 0, separatorLength: 12,
        magnifiedIconSize: 48, magnificationEnabled: false)

    public init(iconSize: Double, barThickness: Double, leadingPadding: Double,
                trailingPadding: Double, itemSpacing: Double, separatorLength: Double,
                magnifiedIconSize: Double, magnificationEnabled: Bool) {
        func bounded(_ value: Double, fallback: Double, min lower: Double, max upper: Double) -> Double {
            let finite = value.isFinite ? value : fallback
            return (min(upper, max(lower, finite)) * 64).rounded() / 64
        }
        let side = bounded(iconSize, fallback: 48, min: 1, max: 128)
        self.iconSize = side
        self.barThickness = bounded(barThickness, fallback: side + 12, min: side, max: side + 32)
        self.leadingPadding = bounded(leadingPadding, fallback: 6, min: 0, max: 24)
        self.trailingPadding = bounded(trailingPadding, fallback: 6, min: 0, max: 24)
        self.itemSpacing = bounded(itemSpacing, fallback: 0, min: 0, max: 16)
        self.separatorLength = bounded(separatorLength, fallback: 12, min: 0, max: 128)
        self.magnifiedIconSize = bounded(magnifiedIconSize, fallback: side, min: side, max: 128)
        self.magnificationEnabled = magnificationEnabled
    }

    public var magnificationScale: Double {
        magnificationEnabled ? max(1, magnifiedIconSize / iconSize) : 1
    }

    public func applyingMagnification(_ preferences: NativeDockPreferences?) -> NativeDockMetrics {
        guard let preferences else { return self }
        return NativeDockMetrics(iconSize: iconSize, barThickness: barThickness,
            leadingPadding: leadingPadding, trailingPadding: trailingPadding,
            itemSpacing: itemSpacing, separatorLength: separatorLength,
            magnifiedIconSize: preferences.magnifiedIconSize ?? magnifiedIconSize,
            magnificationEnabled: preferences.magnificationEnabled ?? magnificationEnabled)
    }
}

public enum NativeDockAxis: String, Equatable, Sendable {
    case horizontal
    case vertical
}

/// Only the four allowlisted appearance preferences needed by adaptive mode.
public struct NativeDockPreferences: Equatable, Sendable {
    public let iconSize: Double?
    public let magnifiedIconSize: Double?
    public let magnificationEnabled: Bool?
    public let axis: NativeDockAxis?

    public init(iconSize: Double?, magnifiedIconSize: Double?, magnificationEnabled: Bool?,
                axis: NativeDockAxis?) {
        func size(_ value: Double?) -> Double? {
            guard let value, value.isFinite else { return nil }
            return min(128, max(16, value))
        }
        self.iconSize = size(iconSize)
        self.magnifiedIconSize = size(magnifiedIconSize)
        self.magnificationEnabled = magnificationEnabled
        self.axis = axis
    }

    public var hasKnownValues: Bool {
        iconSize != nil || magnifiedIconSize != nil || magnificationEnabled != nil || axis != nil
    }

    public var fallbackMetrics: NativeDockMetrics {
        let side = iconSize ?? NativeDockMetrics.fallback.iconSize
        return NativeDockMetrics(iconSize: side, barThickness: side + 12,
            leadingPadding: 6, trailingPadding: 6, itemSpacing: 0, separatorLength: 12,
            magnifiedIconSize: magnifiedIconSize ?? side,
            magnificationEnabled: magnificationEnabled ?? false)
    }
}

public struct NativeDockAXItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case application, separator, other }
    public let kind: Kind
    public let frame: CGRect
    public init(kind: Kind, frame: CGRect) { self.kind = kind; self.frame = frame }
}

public struct NativeDockAXSnapshot: Equatable, Sendable {
    public let frame: CGRect
    public let items: [NativeDockAXItem]
    public let isComplete: Bool
    public init(frame: CGRect, items: [NativeDockAXItem], isComplete: Bool = true) {
        self.frame = frame; self.items = items; self.isComplete = isComplete
    }
}

public enum NativeDockMetricsParser {
    public static func measured(preferences: NativeDockPreferences?, snapshot: NativeDockAXSnapshot) -> NativeDockMetrics? {
        func valid(_ frame: CGRect) -> Bool {
            frame.minX.isFinite && frame.minY.isFinite && frame.maxX.isFinite && frame.maxY.isFinite
                && frame.width.isFinite && frame.height.isFinite
                && frame.width > 0 && frame.height > 0
        }
        guard valid(snapshot.frame) else { return nil }
        let items = snapshot.items.filter { valid($0.frame) }
        let apps = items.filter { $0.kind == .application }
        guard !apps.isEmpty else { return nil }
        // Prefer the explicit native orientation; do not confuse a wide
        // magnified hit region with the long axis of a vertical Dock.
        let axis = preferences?.axis ?? (snapshot.frame.width >= snapshot.frame.height ? .horizontal : .vertical)
        func length(_ rect: CGRect) -> Double { Double(axis == .horizontal ? rect.width : rect.height) }
        func cross(_ rect: CGRect) -> Double { Double(axis == .horizontal ? rect.height : rect.width) }
        func start(_ rect: CGRect) -> Double { Double(axis == .horizontal ? rect.minX : rect.minY) }
        func end(_ rect: CGRect) -> Double { Double(axis == .horizontal ? rect.maxX : rect.maxY) }
        func median(_ values: [Double]) -> Double { let sorted = values.sorted(); return sorted[sorted.count / 2] }
        let lengths = apps.map { length($0.frame) }.filter { $0 >= 1 && $0 <= 256 }.sorted()
        guard let minimum = lengths.first else { return nil }
        // A stable lower cluster excludes nearby magnified icons. Capping by
        // the preference also handles a tiny Dock whose every item is enlarged.
        var cluster = lengths.filter { $0 <= minimum + 0.5 }
        if cluster.count == 1, lengths.count >= 3 {
            var clusters: [[Double]] = []
            for length in lengths {
                if let first = clusters.last?.first, length - first <= 0.5 {
                    clusters[clusters.count - 1].append(length)
                } else { clusters.append([length]) }
            }
            // Dock insertion animations can briefly expose one very small
            // application tile. A uniform majority is stronger evidence than
            // that singleton; mixed magnification sizes without a majority
            // still retain their lower base-size cluster.
            if let majority = clusters.first(where: { $0.count > lengths.count / 2 }),
               let first = majority.first, first > minimum + 0.5 {
                cluster = majority
            }
        }
        let side = min(preferences?.iconSize ?? 128, median(cluster))
        guard side >= 1 else { return nil }
        let extras = apps.map { cross($0.frame) - length($0.frame) }.filter { $0 >= 6 && $0 <= 24 }
        let extra = extras.isEmpty ? 12 : median(extras)
        var padding = 6.0
        if snapshot.isComplete, items.count == snapshot.items.count,
           let first = items.min(by: { start($0.frame) < start($1.frame) }),
           let last = items.max(by: { end($0.frame) < end($1.frame) }) {
            let leading = start(first.frame) - start(snapshot.frame)
            let trailing = end(snapshot.frame) - end(last.frame)
            if leading >= 0, trailing >= 0, leading <= 24, trailing <= 24, abs(leading - trailing) <= 2 {
                padding = (leading + trailing) / 2
            }
        }
        let ordered = items.sorted { start($0.frame) < start($1.frame) }
        var gaps: [Double] = []
        for (a, b) in zip(ordered, ordered.dropFirst()) where a.kind == .application && b.kind == .application {
            // Measure only the base-sized cluster; enlarged neighbours should
            // not influence persistent spacing or cause animation feedback.
            guard abs(length(a.frame) - side) <= 0.5, abs(length(b.frame) - side) <= 0.5 else { continue }
            let gap = start(b.frame) - end(a.frame)
            if gap >= -0.5, gap <= 16 { gaps.append(max(0, gap)) }
        }
        let separators = items.filter { $0.kind == .separator }.map { length($0.frame) }.filter { $0 > 0 && $0 <= 128 }
        return NativeDockMetrics(iconSize: side, barThickness: ceil(side + extra),
            leadingPadding: padding, trailingPadding: padding,
            itemSpacing: gaps.isEmpty ? 0 : median(gaps),
            separatorLength: separators.isEmpty ? 12 : median(separators),
            magnifiedIconSize: preferences?.magnifiedIconSize ?? side,
            magnificationEnabled: preferences?.magnificationEnabled ?? false)
    }
}
