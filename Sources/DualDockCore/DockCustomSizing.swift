import Foundation

public enum DockLengthMode: String, Codable, CaseIterable, Sendable { case fit, fill, fixed }
public enum DockContentAlignment: String, Codable, CaseIterable, Sendable { case center, distribute, start }
public enum DockSizingOverride: CaseIterable, Sendable { case gap, padding, minimumHeight, fixedLength }

/// Requested points remain independent of screen limits and temporary overflow.
public struct DockCustomSizing: Codable, Equatable, Sendable {
    public var iconSize: Double = 48
    public var density: Double = 0.5
    public var lengthMode: DockLengthMode = .fit
    public var fixedLengthPercent: Double = 60
    public var gapOverride: Double?
    public var paddingOverride: Double?
    public var minimumHeightOverride: Double?
    public var alignment: DockContentAlignment = .center
    public var shrinkBeforeScroll = true
    /// Old fixed layouts used absolute points. Retain that request until the
    /// user explicitly chooses a new length mode or percentage.
    public var legacyFixedLength: Double?

    public init() {}

    public mutating func normalize() {
        iconSize = iconSize.isFinite ? max(1, iconSize) : 48
        density = density.isFinite ? min(1, max(0, density)) : 0.5
        fixedLengthPercent = fixedLengthPercent.isFinite ? min(100, max(20, fixedLengthPercent)) : 60
        gapOverride = gapOverride.flatMap { $0.isFinite ? max(0, $0) : nil }
        paddingOverride = paddingOverride.flatMap { $0.isFinite ? max(2, $0) : nil }
        minimumHeightOverride = minimumHeightOverride.flatMap { $0.isFinite ? max(1, $0) : nil }
        legacyFixedLength = legacyFixedLength.flatMap { $0.isFinite ? max(1, $0) : nil }
    }

    public mutating func reset(_ field: DockSizingOverride) {
        switch field {
        case .gap: gapOverride = nil
        case .padding: paddingOverride = nil
        case .minimumHeight: minimumHeightOverride = nil
        case .fixedLength: lengthMode = .fit; legacyFixedLength = nil
        }
    }

    public static func preserving(_ sizing: DockManualSizing, fitContent: Bool,
                                  maximumLength: Double) -> DockCustomSizing {
        var result = DockCustomSizing()
        result.iconSize = sizing.resolvedIconSize
        result.gapOverride = sizing.iconSpacing * result.iconSize / 48
        result.paddingOverride = fitContent ? sizing.contentPadding ?? 6 : 6
        result.minimumHeightOverride = sizing.thickness
        result.lengthMode = fitContent ? .fit : .fixed
        result.fixedLengthPercent = sizing.length / max(1, maximumLength) * 100
        result.legacyFixedLength = fitContent ? nil : sizing.length
        result.shrinkBeforeScroll = false
        result.normalize()
        return result
    }

    /// Convert existing native resize gestures to the new absolute-point model.
    /// A fit-mode end drag captures whitespace; inward/corner motion scales the
    /// visible icon-to-height ratio, regardless of the legacy slider ratio.
    public func resized(from original: DockManualSizing, to draft: DockManualSizing,
                        maximumLength: Double, count: Int, dividerIndex: Int?) -> DockCustomSizing {
        var result = self
        let changedHeight = abs(draft.thickness - original.thickness) > 0.000001
        let changedLength = abs(draft.length - original.length) > 0.000001
            && abs(draft.length - min(maximumLength, original.length)) > 0.000001
        if changedHeight {
            result.iconSize = original.resolvedIconSize * draft.thickness / max(1, original.thickness)
            result.minimumHeightOverride = draft.thickness
        }
        if changedLength {
            if lengthMode == .fit {
                let gap = result.gapOverride ?? result.iconSize * (0.04 + 0.26 * result.density)
                let span = DockContentLengthPolicy.contentSpan(count: count, iconSize: result.iconSize,
                    gap: gap, separatorLength: 13 * result.iconSize / 48, dividerIndex: dividerIndex)
                result.paddingOverride = max(2, (draft.length - span) / 2)
            } else {
                result.lengthMode = .fixed
                result.fixedLengthPercent = draft.length / max(1, maximumLength) * 100
                result.legacyFixedLength = nil
            }
        }
        result.normalize()
        return result
    }
}

public struct DockResolvedSizing: Equatable, Sendable {
    public let iconSize: Double
    public let gap: Double
    public let padding: Double
    public let thickness: Double
    public let length: Double
    public let separatorLength: Double
    public let isScrollable: Bool

    public var manualSizing: DockManualSizing {
        DockManualSizing(length: length, thickness: thickness,
            iconScale: iconSize * DockSizingLimits.heightPerIconPoint / max(1, thickness),
            iconSpacing: gap * 48 / max(1, iconSize), contentPadding: padding,
            absoluteIconSize: iconSize)
    }
}

public enum DockCustomSizingResolver {
    public static func resolve(_ preferences: DockCustomSizing, count: Int, dividerIndex: Int?,
                               maximumLength: Double, maximumHeight: Double) -> DockResolvedSizing {
        var p = preferences
        p.normalize()
        let limit = maximumLength.isFinite ? max(1, maximumLength) : 1000
        let heightLimit = maximumHeight.isFinite ? max(1, maximumHeight) : 100
        let n = max(0, count)
        var icon = min(p.iconSize, max(1, heightLimit - 4))
        var gap = p.gapOverride ?? icon * (0.04 + 0.26 * p.density)
        let padding = min(limit, p.paddingOverride ?? icon * (0.12 + 0.18 * p.density))
        let hasDivider = dividerIndex.map { $0 > 0 && $0 < n } == true
        func span(_ side: Double, _ spacing: Double) -> Double {
            DockContentLengthPolicy.contentSpan(count: n, iconSize: side, gap: spacing,
                separatorLength: hasDivider ? 13 * side / 48 : 0, dividerIndex: dividerIndex)
        }
        let requestedLength: Double
        switch p.lengthMode {
        case .fit: requestedLength = span(icon, gap) + 2 * padding
        case .fill: requestedLength = limit
        case .fixed: requestedLength = p.legacyFixedLength ?? limit * p.fixedLengthPercent / 100
        }
        let length = min(limit, max(1, requestedLength))
        if span(icon, gap) + 2 * padding > length {
            if n > 1 {
                let availableGap = (length - 2 * padding - Double(n) * icon
                    - (hasDivider ? 13 * icon / 48 : 0)) / Double(n - 1)
                gap = max(0, min(gap, availableGap))
            }
            if p.shrinkBeforeScroll, n > 0, span(icon, gap) + 2 * padding > length {
                let slots = Double(n) + (hasDivider ? 13.0 / 48 : 0)
                let candidate = (length - 2 * padding - Double(max(0, n - 1)) * gap) / slots
                icon = min(icon, max(min(24, icon), candidate))
            }
        }
        let minimumClearance = min(4, icon * 0.24)
        let thickness = min(heightLimit, p.minimumHeightOverride.map { max($0, icon + minimumClearance) }
            ?? (icon + 2 * padding))
        if p.alignment == .distribute, n > 1, span(icon, gap) + 2 * padding <= length {
            gap += (length - span(icon, gap) - 2 * padding) / Double(n - 1)
        }
        return DockResolvedSizing(iconSize: icon, gap: gap, padding: padding,
            thickness: thickness, length: length, separatorLength: 13 * icon / 48,
            isScrollable: span(icon, gap) + 2 * padding > length + 0.000001)
    }
}
