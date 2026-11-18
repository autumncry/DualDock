import Foundation
import CoreGraphics

public struct DockGeometryStyle: Equatable, Sendable {
    public var iconSize: CGFloat
    public var barThickness: CGFloat
    public var gap: CGFloat
    public var leadingPadding: CGFloat
    public var trailingPadding: CGFloat
    public var separatorLength: CGFloat
    public var magnificationScale: CGFloat
    public var magnificationRadius: CGFloat
    public var contentAlignment: DockContentAlignment
    public var contentBounds: [CGRect]
    public var spacingPercent: CGFloat?

    public init(iconSize: CGFloat, barThickness: CGFloat, gap: CGFloat,
                leadingPadding: CGFloat, trailingPadding: CGFloat,
                separatorLength: CGFloat = 13, magnificationScale: CGFloat = 1,
                magnificationRadius: CGFloat = 2.5, contentAlignment: DockContentAlignment = .center,
                contentBounds: [CGRect] = [], spacingPercent: CGFloat? = nil) {
        self.iconSize = iconSize
        self.barThickness = barThickness
        self.gap = gap
        self.leadingPadding = leadingPadding
        self.trailingPadding = trailingPadding
        self.separatorLength = separatorLength
        self.magnificationScale = magnificationScale
        self.magnificationRadius = magnificationRadius
        self.contentAlignment = contentAlignment
        self.contentBounds = contentBounds
        self.spacingPercent = spacingPercent
    }
}

/// Canonical layout plus a four-edge projection. Tile, icon and dot rectangles
/// are returned in physical document coordinates; icons remain upright.
public struct DockGeometry: Equatable, Sendable {
    public let edge: DockEdge
    public let canonicalCanvasSize: CGSize
    public let canonicalDocumentSize: CGSize
    public let canonicalBackdropRect: CGRect
    public let canonicalViewportRect: CGRect
    public let canonicalTileFrames: [CGRect]
    public let canonicalIconFrames: [CGRect]
    public let canonicalContentFrames: [CGRect]
    public let canonicalHitFrames: [CGRect]
    public let canonicalDotFrames: [CGRect]
    public let canonicalDividerFrame: CGRect?
    public let bodyLength: CGFloat
    public let barThickness: CGFloat
    private struct OpticalContext: Equatable, Sendable {
        let bounds: [CGRect]
        let percent: CGFloat
        let baseIconSize: CGFloat
        let outerInset: CGFloat
        let separatorLength: CGFloat
        let dividerIndex: Int?
    }
    private let opticalContext: OpticalContext?

    public var canvasTransform: DockAxisTransform {
        .init(edge: edge, length: canonicalCanvasSize.width, thickness: canonicalCanvasSize.height)
    }
    public var documentTransform: DockAxisTransform {
        .init(edge: edge, length: canonicalDocumentSize.width, thickness: canonicalDocumentSize.height)
    }
    public var canvasSize: CGSize { canvasTransform.physicalSize }
    public var documentSize: CGSize { documentTransform.physicalSize }
    public var backdropRect: CGRect { canvasTransform.rectToPhysical(canonicalBackdropRect) }
    public var viewportRect: CGRect { canvasTransform.rectToPhysical(canonicalViewportRect) }
    public var tileFrames: [CGRect] { canonicalTileFrames.map(documentTransform.rectToPhysical) }
    public var iconFrames: [CGRect] { canonicalIconFrames.map(documentTransform.rectToPhysical) }
    public var contentFrames: [CGRect] { canonicalContentFrames.map(documentTransform.rectToPhysical) }
    public var hitFrames: [CGRect] { canonicalHitFrames.map(documentTransform.rectToPhysical) }
    public var canonicalFocusFrames: [CGRect] { canonicalContentFrames }
    public var dotFrames: [CGRect] { canonicalDotFrames.map(documentTransform.rectToPhysical) }
    public var dividerFrame: CGRect? { canonicalDividerFrame.map(documentTransform.rectToPhysical) }
    public var scrollRange: CGFloat { max(0, canonicalDocumentSize.width - canonicalViewportRect.width) }
    public var initialScrollOffset: CGFloat { 0 }

    /// Anchor and center the visible bar, not its transparent magnification canvas.
    public func panelFrame(in placementBounds: CGRect, edgeInset: CGFloat = 8) -> CGRect {
        let body = backdropRect
        let desired: CGPoint
        switch edge {
        case .bottom: desired = CGPoint(x: placementBounds.midX - body.width / 2, y: placementBounds.minY + edgeInset)
        case .top: desired = CGPoint(x: placementBounds.midX - body.width / 2, y: placementBounds.maxY - edgeInset - body.height)
        case .left: desired = CGPoint(x: placementBounds.minX + edgeInset, y: placementBounds.midY - body.height / 2)
        case .right: desired = CGPoint(x: placementBounds.maxX - edgeInset - body.width, y: placementBounds.midY - body.height / 2)
        }
        return CGRect(x: desired.x - body.minX, y: desired.y - body.minY, width: canvasSize.width, height: canvasSize.height)
    }

    public static func make(count: Int, edge: DockEdge, style: DockGeometryStyle,
                            maximumLength: CGFloat, fixedLength: CGFloat? = nil,
                            focusIndex: CGFloat? = nil, dividerIndex: Int? = nil,
                            scrollOffset: CGFloat = 0, terminalAnchor: CGFloat? = nil,
                            resizeMargin: CGFloat = 0) -> DockGeometry {
        if let percent = style.spacingPercent, percent.isFinite {
            return makeOptical(count: count, edge: edge, style: style, maximumLength: maximumLength,
                fixedLength: fixedLength, focusIndex: focusIndex, dividerIndex: dividerIndex,
                scrollOffset: scrollOffset, terminalAnchor: terminalAnchor, resizeMargin: resizeMargin)
        }
        func finite(_ value: CGFloat, fallback: CGFloat) -> CGFloat { value.isFinite ? value : fallback }
        let n = max(0, count)
        let limit = max(1, finite(maximumLength, fallback: 1))
        let thickness = max(1, finite(style.barThickness, fallback: 66))
        let side = min(thickness, max(1, finite(style.iconSize, fallback: 48)))
        var gap = max(0, finite(style.gap, fallback: 0))
        let leading = max(0, finite(style.leadingPadding, fallback: 0))
        let trailing = max(0, finite(style.trailingPadding, fallback: 0))
        let separator = dividerIndex.map { $0 > 0 && $0 < n ? max(0, finite(style.separatorLength, fallback: 0)) : 0 } ?? 0
        let contentSpan = DockContentLengthPolicy.contentSpan(count: n, iconSize: Double(side),
            gap: Double(gap), separatorLength: Double(separator), dividerIndex: dividerIndex)
        var required = CGFloat(contentSpan) + leading + trailing
        let chosenLength = fixedLength.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? required
        let bodyLength = min(limit, max(1, chosenLength))
        let fits = required <= bodyLength + 0.000001
        if fits, style.contentAlignment == .distribute, n > 1 {
            gap += max(0, bodyLength - required) / CGFloat(n - 1)
            required = bodyLength
        }
        let scale = max(1, finite(style.magnificationScale, fallback: 1))
        let curve = DockMagnificationCurve(radius: style.magnificationRadius)
        let peak = n == 0 ? side : min(side * scale, max(side, fits ? limit : bodyLength))
        let delta = peak - side
        // Keep the window's transparent reserve independent of whether the row
        // currently fits. Dropping that reserve at the overflow threshold made
        // a subpixel resize change the window by tens of points in one frame.
        // Overflow still clips the document to the visible bar below.
        let reservedPeak = n == 0 ? side : min(side * scale, max(side, limit))
        let reservedDelta = reservedPeak - side
        let factor = curve.reserveFactor(itemCount: n)
        let handleMargin = max(0, finite(resizeMargin, fallback: 0))
        let desiredBleed = n > 0 ? ceil(reservedDelta * factor) : 0
        let endMargin = min(max(desiredBleed, handleMargin), max(0, (limit - bodyLength) / 2))
        let canvasLength = bodyLength + 2 * endMargin
        let canvasDepth = thickness + max(reservedDelta, handleMargin)
        let viewport = CGRect(x: fits ? 0 : endMargin, y: 0,
                              width: fits ? canvasLength : bodyLength, height: canvasDepth)
        let documentLength = fits ? viewport.width : max(viewport.width, required)
        let alignmentOffset = style.contentAlignment == .center || (style.contentAlignment == .distribute && n < 2)
            ? max(0, bodyLength - required) / 2 : 0
        let baseLeading = fits ? endMargin + leading + alignmentOffset : leading
        let offset = min(max(0, finite(scrollOffset, fallback: 0)), max(0, documentLength - viewport.width))
        let focus = focusIndex.flatMap { $0.isFinite && n > 0 ? min(CGFloat(n - 1), max(0, $0)) : nil }
        let outerInset = max(0, (thickness - side) / 2)
        let dotSide = min(4, max(0, outerInset - 1))
        // Indicators belong to the icon, not the edge of a taller backdrop.
        // Keep a 3pt gap where space allows, reducing it only for compact bars.
        let dotOriginV = max(0, outerInset - dotSide - 3)

        var baseIcons: [CGRect] = []
        var icons: [CGRect] = []
        var tiles: [CGRect] = []
        var dots: [CGRect] = []
        var separatorFrame: CGRect?
        var baseU = baseLeading
        var waveU: CGFloat = 0
        for index in 0..<n {
            if index == dividerIndex, separator > 0 {
                separatorFrame = CGRect(x: waveU - gap / 2 + separator / 2 - 0.5,
                                        y: max(2, thickness * 0.15), width: 1, height: max(1, thickness * 0.7))
                waveU += separator
                baseU += separator
            }
            let distance = focus.map { abs(CGFloat(index) - $0) } ?? curve.radius
            let weight = curve.weight(atDistance: distance)
            let size = side + delta * weight
            baseIcons.append(CGRect(x: baseU, y: outerInset, width: side, height: side))
            icons.append(CGRect(x: waveU, y: outerInset, width: size, height: size))
            tiles.append(CGRect(x: waveU - gap / 2, y: 0, width: size + gap, height: thickness + size - side))
            dots.append(CGRect(x: waveU + size / 2 - dotSide / 2, y: dotOriginV,
                               width: dotSide, height: dotSide))
            waveU += size + gap
            baseU += side + gap
        }
        var shift = baseLeading
        if let focus, let baseAnchor = position(focus, frames: baseIcons), let waveAnchor = position(focus, frames: icons) {
            // The view may preserve an endpoint displaced by the preceding
            // wave when the pointer jumps onto it. This is a bounded entry
            // anchor, never a continuously advancing raw pointer coordinate.
            let terminal = focus <= 0 || focus >= CGFloat(n - 1)
            let anchor = terminal ? terminalAnchor.flatMap { $0.isFinite ? $0 : nil } ?? baseAnchor : baseAnchor
            shift = anchor - waveAnchor
            let lower = Int(floor(focus)), upper = min(n - 1, Int(floor(focus)) + 1)
            let fraction = focus - CGFloat(lower)
            let left = icons[lower].minX + (icons[upper].minX - icons[lower].minX) * fraction + shift
            let right = icons[lower].maxX + (icons[upper].maxX - icons[lower].maxX) * fraction + shift
            if left < offset { shift += offset - left }
            else if right > offset + viewport.width { shift -= right - offset - viewport.width }
        }
        icons = icons.map { $0.offsetBy(dx: shift, dy: 0) }
        tiles = tiles.map { $0.offsetBy(dx: shift, dy: 0) }
        dots = dots.map { $0.offsetBy(dx: shift, dy: 0) }
        separatorFrame = separatorFrame.map { $0.offsetBy(dx: shift, dy: 0) }
        return DockGeometry(edge: edge, canonicalCanvasSize: CGSize(width: canvasLength, height: canvasDepth),
            canonicalDocumentSize: CGSize(width: documentLength, height: canvasDepth),
            canonicalBackdropRect: CGRect(x: endMargin, y: 0, width: bodyLength, height: thickness),
            canonicalViewportRect: viewport, canonicalTileFrames: tiles, canonicalIconFrames: icons,
            canonicalContentFrames: icons, canonicalHitFrames: tiles,
            canonicalDotFrames: dots, canonicalDividerFrame: separatorFrame,
            bodyLength: bodyLength, barThickness: thickness, opticalContext: nil)
    }

    private static func makeOptical(count: Int, edge: DockEdge, style: DockGeometryStyle,
                                    maximumLength: CGFloat, fixedLength: CGFloat?, focusIndex: CGFloat?,
                                    dividerIndex: Int?, scrollOffset: CGFloat, terminalAnchor: CGFloat?,
                                    resizeMargin: CGFloat) -> DockGeometry {
        func finite(_ value: CGFloat, fallback: CGFloat) -> CGFloat { value.isFinite ? value : fallback }
        let count = max(0, count)
        let limit = max(1, finite(maximumLength, fallback: 1))
        let thickness = max(1, finite(style.barThickness, fallback: 66))
        let side = min(thickness, max(1, finite(style.iconSize, fallback: 48)))
        let leading = max(0, finite(style.leadingPadding, fallback: 0))
        let trailing = max(0, finite(style.trailingPadding, fallback: 0))
        let percent = DockOpticalSpacingPolicy.fraction(style.spacingPercent ?? 0) * 100
        let separator = dividerIndex.map { $0 > 0 && $0 < count
            ? max(0, finite(style.separatorLength, fallback: 0)) : 0 } ?? 0
        let contentBounds = DockOpticalSpacingPolicy.canonicalBounds(style.contentBounds, count: count, edge: edge)
        let outerInset = max(0, (thickness - side) / 2)
        let base = DockOpticalSpacingPolicy.row(sizes: Array(repeating: side, count: count),
            bounds: contentBounds, spacingPercent: percent, outerInset: outerInset,
            separatorLength: separator, dividerIndex: dividerIndex)
        let required = (count == 0 ? max(120, side * 2) : base.span) + leading + trailing
        let requested = fixedLength.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? required
        let bodyLength = min(limit, max(1, requested))
        let fits = required <= bodyLength + 0.000001
        let scale = max(1, finite(style.magnificationScale, fallback: 1))
        let curve = DockMagnificationCurve(radius: style.magnificationRadius)
        let peak = count == 0 ? side : min(side * scale, max(side, fits ? limit : bodyLength))
        let delta = peak - side
        let reservedPeak = count == 0 ? side : min(side * scale, max(side, limit))
        let reserve = reservedPeak - side
        let handleMargin = max(0, finite(resizeMargin, fallback: 0))
        // Optical gaps grow with their adjacent artwork. Reserve that extra
        // wave width too, plus half an icon delta for asymmetric canvas margins.
        let opticalFactor = curve.reserveFactor(itemCount: count) * (1 + percent / 100) + 0.5
        let bleed = count > 0 ? ceil(reserve * opticalFactor) : 0
        let endMargin = min(max(bleed, handleMargin), max(0, (limit - bodyLength) / 2))
        let canvasLength = bodyLength + 2 * endMargin
        let canvasDepth = thickness + max(reserve, handleMargin)
        let viewport = CGRect(x: fits ? 0 : endMargin, y: 0,
                              width: fits ? canvasLength : bodyLength, height: canvasDepth)
        let documentLength = fits ? viewport.width : max(viewport.width, required)
        // Distributing leftover space would silently replace the chosen ratio.
        let alignmentOffset = style.contentAlignment == .start ? 0 : max(0, bodyLength - required) / 2
        let baseLeading = fits ? endMargin + leading + alignmentOffset : leading
        let offset = min(max(0, finite(scrollOffset, fallback: 0)), max(0, documentLength - viewport.width))
        let focus = focusIndex.flatMap { $0.isFinite && count > 0 ? min(CGFloat(count - 1), max(0, $0)) : nil }
        let sizes = (0..<count).map { index in
            side + delta * curve.weight(atDistance: focus.map { abs(CGFloat(index) - $0) } ?? curve.radius)
        }
        let wave = DockOpticalSpacingPolicy.row(sizes: sizes, bounds: contentBounds,
            spacingPercent: percent, outerInset: outerInset,
            separatorLength: separator, dividerIndex: dividerIndex)
        var shift = baseLeading
        if let focus, let baseAnchor = position(focus, frames: base.contents),
           let waveAnchor = position(focus, frames: wave.contents) {
            let terminal = focus <= 0 || focus >= CGFloat(count - 1)
            let anchor = terminal ? terminalAnchor.flatMap { $0.isFinite ? $0 : nil } ?? (baseAnchor + baseLeading)
                                  : baseAnchor + baseLeading
            shift = anchor - waveAnchor
            let lower = Int(floor(focus)), upper = min(count - 1, lower + 1)
            let fraction = focus - CGFloat(lower)
            let left = wave.contents[lower].minX
                + (wave.contents[upper].minX - wave.contents[lower].minX) * fraction + shift
            let right = wave.contents[lower].maxX
                + (wave.contents[upper].maxX - wave.contents[lower].maxX) * fraction + shift
            if left < offset { shift += offset - left }
            else if right > offset + viewport.width { shift -= right - offset - viewport.width }
        }
        let icons = wave.icons.map { $0.offsetBy(dx: shift, dy: 0) }
        let contents = wave.contents.map { $0.offsetBy(dx: shift, dy: 0) }
        let hits = DockOpticalSpacingPolicy.hitFrames(icons: icons, contents: contents,
            thickness: thickness, baseIconSize: side, separatorLength: separator, dividerIndex: dividerIndex)
        let tiles = zip(icons, hits).map { $0.union($1) }
        let dots = DockOpticalSpacingPolicy.dotFrames(contents: contents)
        let divider = wave.dividerX.map { CGRect(x: $0 + shift - 0.5,
            y: max(2, thickness * 0.15), width: 1, height: max(1, thickness * 0.7)) }
        return DockGeometry(edge: edge,
            canonicalCanvasSize: CGSize(width: canvasLength, height: canvasDepth),
            canonicalDocumentSize: CGSize(width: documentLength, height: canvasDepth),
            canonicalBackdropRect: CGRect(x: endMargin, y: 0, width: bodyLength, height: thickness),
            canonicalViewportRect: viewport, canonicalTileFrames: tiles, canonicalIconFrames: icons,
            canonicalContentFrames: contents, canonicalHitFrames: hits, canonicalDotFrames: dots,
            canonicalDividerFrame: divider, bodyLength: bodyLength, barThickness: thickness,
            opticalContext: OpticalContext(bounds: contentBounds, percent: percent, baseIconSize: side,
                outerInset: outerInset, separatorLength: separator, dividerIndex: dividerIndex))
    }

    public func documentPointToCanonical(_ point: CGPoint) -> CGPoint { documentTransform.pointToCanonical(point) }

    public func canonicalScrollOffset(clipBounds: CGRect, actualDocumentSize: CGSize? = nil) -> CGFloat {
        if edge.isHorizontal { return max(0, clipBounds.minX) }
        return max(0, (actualDocumentSize ?? documentSize).height - clipBounds.height - clipBounds.minY)
    }

    public func scrollOrigin(forCanonicalOffset offset: CGFloat, actualDocumentSize: CGSize? = nil,
                             actualViewportSize: CGSize? = nil) -> CGPoint {
        let document = actualDocumentSize ?? documentSize
        let viewport = actualViewportSize ?? viewportRect.size
        let range = max(0, edge.isHorizontal ? document.width - viewport.width : document.height - viewport.height)
        let bounded = min(range, max(0, offset))
        return edge.isHorizontal ? CGPoint(x: bounded, y: 0) : CGPoint(x: 0, y: range - bounded)
    }

    public func focusIndex(at coordinate: CGFloat) -> CGFloat? {
        guard let first = canonicalContentFrames.first, let last = canonicalContentFrames.last else { return nil }
        if coordinate <= first.midX { return 0 }
        if coordinate >= last.midX { return CGFloat(canonicalContentFrames.count - 1) }
        for index in 0..<(canonicalContentFrames.count - 1) {
            let left = canonicalContentFrames[index].midX, right = canonicalContentFrames[index + 1].midX
            if coordinate >= left && coordinate <= right {
                return CGFloat(index) + (coordinate - left) / max(0.000001, right - left)
            }
        }
        return nil
    }

    public func magnificationFocus(at physicalDocumentPoint: CGPoint, basedOn base: DockGeometry) -> CGFloat? {
        let point = documentPointToCanonical(physicalDocumentPoint)
        guard let first = canonicalHitFrames.first, let last = canonicalHitFrames.last,
              let baseFirst = base.canonicalHitFrames.first, let baseLast = base.canonicalHitFrames.last else { return nil }
        let inRow = point.x >= min(first.minX, baseFirst.minX) && point.x <= max(last.maxX, baseLast.maxX)
            && point.y >= 0 && point.y <= barThickness
        guard inRow || canonicalContentFrames.contains(where: { $0.contains(point) }) else { return nil }
        return base.focusIndex(at: point.x)
    }

    private static func position(_ index: CGFloat, frames: [CGRect]) -> CGFloat? {
        guard !frames.isEmpty else { return nil }
        let bounded = min(CGFloat(frames.count - 1), max(0, index))
        let lower = Int(floor(bounded)), upper = min(frames.count - 1, Int(floor(bounded)) + 1)
        return frames[lower].midX + (frames[upper].midX - frames[lower].midX) * (bounded - CGFloat(lower))
    }

    public func interpolated(to target: DockGeometry, fraction: CGFloat) -> DockGeometry {
        guard edge == target.edge, canonicalTileFrames.count == target.canonicalTileFrames.count,
              canonicalCanvasSize == target.canonicalCanvasSize, canonicalDocumentSize == target.canonicalDocumentSize,
              canonicalBackdropRect == target.canonicalBackdropRect else { return target }
        let t = min(1, max(0, fraction))
        if t == 0 { return self }
        if t == 1 { return target }
        func size(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            // A new peak can keep the whole strip animating indefinitely. Let
            // each imperceptible tail settle instead of resizing its bitmap for
            // fractional-pixel differences on every later frame. Only shrink
            // toward the target early: growing early could overlap a neighbor
            // whose position is still approaching the same zero-gap boundary.
            a >= b && a - b < 0.08 ? b : a + (b - a) * t
        }
        if opticalContext != nil || target.opticalContext != nil {
            guard let context = opticalContext, context == target.opticalContext else { return target }
            let sizes = zip(canonicalIconFrames, target.canonicalIconFrames).map { size($0.width, $1.width) }
            let row = DockOpticalSpacingPolicy.row(sizes: sizes, bounds: context.bounds,
                spacingPercent: context.percent, outerInset: context.outerInset,
                separatorLength: context.separatorLength, dividerIndex: context.dividerIndex)
            let firstX = (canonicalIconFrames.first?.minX ?? 0)
                + ((target.canonicalIconFrames.first?.minX ?? 0) - (canonicalIconFrames.first?.minX ?? 0)) * t
            let shift = firstX - (row.icons.first?.minX ?? 0)
            let icons = row.icons.map { $0.offsetBy(dx: shift, dy: 0) }
            let contents = row.contents.map { $0.offsetBy(dx: shift, dy: 0) }
            let hits = DockOpticalSpacingPolicy.hitFrames(icons: icons, contents: contents,
                thickness: barThickness, baseIconSize: context.baseIconSize,
                separatorLength: context.separatorLength, dividerIndex: context.dividerIndex)
            let tiles = zip(icons, hits).map { $0.union($1) }
            let divider = row.dividerX.map { CGRect(x: $0 + shift - 0.5,
                y: max(2, barThickness * 0.15), width: 1, height: max(1, barThickness * 0.7)) }
            return DockGeometry(edge: edge, canonicalCanvasSize: canonicalCanvasSize,
                canonicalDocumentSize: canonicalDocumentSize, canonicalBackdropRect: canonicalBackdropRect,
                canonicalViewportRect: canonicalViewportRect, canonicalTileFrames: tiles,
                canonicalIconFrames: icons, canonicalContentFrames: contents, canonicalHitFrames: hits,
                canonicalDotFrames: DockOpticalSpacingPolicy.dotFrames(contents: contents),
                canonicalDividerFrame: divider, bodyLength: bodyLength, barThickness: barThickness,
                opticalContext: context)
        }
        func rect(_ a: CGRect, _ b: CGRect) -> CGRect {
            CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
                   width: size(a.width, b.width), height: size(a.height, b.height))
        }
        func frames(_ a: [CGRect], _ b: [CGRect]) -> [CGRect] { zip(a, b).map { rect($0.0, $0.1) } }
        let divider: CGRect?
        if let a = canonicalDividerFrame, let b = target.canonicalDividerFrame { divider = rect(a, b) }
        else { divider = target.canonicalDividerFrame }
        let icons = frames(canonicalIconFrames, target.canonicalIconFrames)
        let tiles = icons.indices.map { index -> CGRect in
            let a = canonicalIconFrames[index], b = target.canonicalIconFrames[index]
            let ta = canonicalTileFrames[index], tb = target.canonicalTileFrames[index]
            func inset(_ from: CGFloat, _ to: CGFloat) -> CGFloat { from + (to - from) * t }
            let left = inset(a.minX - ta.minX, b.minX - tb.minX)
            let right = inset(ta.maxX - a.maxX, tb.maxX - b.maxX)
            let bottom = inset(a.minY - ta.minY, b.minY - tb.minY)
            let top = inset(ta.maxY - a.maxY, tb.maxY - b.maxY)
            let icon = icons[index]
            return CGRect(x: icon.minX - left, y: icon.minY - bottom,
                          width: icon.width + left + right, height: icon.height + bottom + top)
        }
        let dots = zip(frames(canonicalDotFrames, target.canonicalDotFrames), icons).map { dot, icon in
            CGRect(x: icon.midX - dot.width / 2, y: dot.minY, width: dot.width, height: dot.height)
        }
        return DockGeometry(edge: edge, canonicalCanvasSize: canonicalCanvasSize,
            canonicalDocumentSize: canonicalDocumentSize, canonicalBackdropRect: canonicalBackdropRect,
            canonicalViewportRect: canonicalViewportRect,
            canonicalTileFrames: tiles,
            canonicalIconFrames: icons,
            canonicalContentFrames: icons,
            canonicalHitFrames: tiles,
            canonicalDotFrames: dots,
            canonicalDividerFrame: divider, bodyLength: bodyLength, barThickness: barThickness, opticalContext: nil)
    }

    public func maximumDifference(from other: DockGeometry) -> CGFloat {
        guard edge == other.edge, canonicalIconFrames.count == other.canonicalIconFrames.count else { return .greatestFiniteMagnitude }
        var result = max(abs(bodyLength - other.bodyLength), abs(barThickness - other.barThickness),
                         abs(canonicalCanvasSize.width - other.canonicalCanvasSize.width),
                         abs(canonicalCanvasSize.height - other.canonicalCanvasSize.height))
        for (a, b) in zip(canonicalIconFrames, other.canonicalIconFrames) {
            result = max(result, abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
        }
        return result
    }
}
