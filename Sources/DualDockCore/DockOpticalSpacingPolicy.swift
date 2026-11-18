import Foundation
import CoreGraphics

/// Measures spacing between artwork bounds while keeping the original square
/// image canvases intact. Bounds are normalized, unflipped image coordinates.
public enum DockOpticalSpacingPolicy {
    public static func normalizedBounds(_ value: CGRect) -> CGRect {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard value.minX.isFinite, value.minY.isFinite,
              value.width.isFinite, value.height.isFinite,
              value.width > 0, value.height > 0 else { return unit }
        let clipped = value.intersection(unit)
        guard !clipped.isNull, clipped.width >= 0.001, clipped.height >= 0.001 else { return unit }
        return clipped
    }

    public static func canonicalBounds(_ bounds: [CGRect], count: Int, edge: DockEdge) -> [CGRect] {
        let transform = DockAxisTransform(edge: edge, length: 1, thickness: 1)
        return (0..<max(0, count)).map { index in
            transform.rectToCanonical(normalizedBounds(bounds.indices.contains(index)
                ? bounds[index] : CGRect(x: 0, y: 0, width: 1, height: 1)))
        }
    }

    public static func contentSpan(count: Int, iconSize: Double, spacingPercent: Double,
                                   contentBounds: [CGRect] = [], edge: DockEdge = .bottom,
                                   separatorLength: Double = 0, dividerIndex: Int? = nil) -> Double {
        let side = iconSize.isFinite ? max(1, iconSize) : 48
        guard count > 0 else { return max(120, side * 2) }
        return Double(row(sizes: Array(repeating: CGFloat(side), count: count),
            bounds: canonicalBounds(contentBounds, count: count, edge: edge),
            spacingPercent: CGFloat(spacingPercent), outerInset: 0,
            separatorLength: CGFloat(separatorLength), dividerIndex: dividerIndex).span)
    }

    public static func meanGap(count: Int, iconSize: Double, spacingPercent: Double,
                               contentBounds: [CGRect] = [], edge: DockEdge = .bottom) -> Double {
        let side = iconSize.isFinite ? max(1, iconSize) : 48
        let bounds = canonicalBounds(contentBounds, count: count, edge: edge)
        let ratio = fraction(CGFloat(spacingPercent))
        guard bounds.count > 1 else { return side * Double(bounds.first?.width ?? 1) * Double(ratio) }
        let widths = zip(bounds, bounds.dropFirst()).map { ($0.width + $1.width) / 2 }
        return side * Double(widths.reduce(0, +) / CGFloat(widths.count) * ratio)
    }

    static func fraction(_ percent: CGFloat) -> CGFloat {
        percent.isFinite ? min(1, max(0, percent / 100)) : 0
    }

    struct Row {
        let icons: [CGRect]
        let contents: [CGRect]
        let span: CGFloat
        let dividerX: CGFloat?
    }

    /// Visible bounds advance monotonically even when asymmetric transparent
    /// margins make neighboring drawing canvases overlap or reverse origins.
    static func row(sizes: [CGFloat], bounds: [CGRect], spacingPercent: CGFloat,
                    outerInset: CGFloat, separatorLength: CGFloat, dividerIndex: Int?) -> Row {
        guard !sizes.isEmpty else { return Row(icons: [], contents: [], span: 0, dividerX: nil) }
        let ratio = fraction(spacingPercent)
        let separator = separatorLength.isFinite ? max(0, separatorLength) : 0
        var icons: [CGRect] = [], contents: [CGRect] = []
        var dividerX: CGFloat?
        for index in sizes.indices {
            let side = max(1, sizes[index])
            let bound = bounds[index]
            let x: CGFloat
            if let previous = contents.last {
                let gap = (previous.width + bound.width * side) / 2 * ratio
                let extra = dividerIndex == index ? separator : 0
                if extra > 0 { dividerX = previous.maxX + (gap + extra) / 2 }
                x = previous.maxX + gap + extra - bound.minX * side
            } else { x = 0 }
            let icon = CGRect(x: x, y: outerInset, width: side, height: side)
            icons.append(icon)
            contents.append(contentFrame(icon: icon, bound: bound))
        }
        let minimum = icons.map(\.minX).min() ?? 0
        let maximum = icons.map(\.maxX).max() ?? 0
        return Row(icons: icons.map { $0.offsetBy(dx: -minimum, dy: 0) },
                   contents: contents.map { $0.offsetBy(dx: -minimum, dy: 0) },
                   span: maximum - minimum, dividerX: dividerX.map { $0 - minimum })
    }

    static func contentFrame(icon: CGRect, bound: CGRect) -> CGRect {
        CGRect(x: icon.minX + bound.minX * icon.width,
               y: icon.minY + bound.minY * icon.height,
               width: bound.width * icon.width, height: bound.height * icon.height)
    }

    /// Assign each inter-icon gap to its nearest visible edge. Drawing canvases
    /// may overlap, but these ownership regions never do.
    static func hitFrames(icons: [CGRect], contents: [CGRect], thickness: CGFloat,
                          baseIconSize: CGFloat, separatorLength: CGFloat = 0,
                          dividerIndex: Int? = nil) -> [CGRect] {
        guard !icons.isEmpty else { return [] }
        let minimum = icons.map(\.minX).min() ?? 0
        let maximum = icons.map(\.maxX).max() ?? 0
        return icons.indices.map { index in
            let left = index == 0 ? minimum : (contents[index - 1].maxX + contents[index].minX) / 2
                + (dividerIndex == index ? separatorLength / 2 : 0)
            let right = index == icons.count - 1 ? maximum : (contents[index].maxX + contents[index + 1].minX) / 2
                - (dividerIndex == index + 1 ? separatorLength / 2 : 0)
            return CGRect(x: left, y: 0, width: max(0, right - left),
                          height: thickness + icons[index].height - baseIconSize)
        }
    }

    static func dotFrames(contents: [CGRect]) -> [CGRect] {
        contents.map { content in
            let side = min(4, max(0, content.minY - 1))
            return CGRect(x: content.midX - side / 2, y: max(0, content.minY - side - 3),
                          width: side, height: side)
        }
    }
}
