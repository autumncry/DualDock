import AppKit
import DualDockCore

/// Measures the visible body without modifying, cropping or enlarging artwork.
/// Soft shadows may overlap at zero spacing; solid icon bodies may not.
enum IconArtworkBounds {
    static let full = CGRect(x: 0, y: 0, width: 1, height: 1)
    static let folder = CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)

    @MainActor static func measure(_ image: NSImage) -> CGRect {
        let side = 256
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: side * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap), let bytes = bitmap.bitmapData else { return full }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: CGRect(x: 0, y: 0, width: side, height: side), from: .zero,
                   operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        func bounds(threshold: UInt8) -> CGRect? {
            var x0 = side, y0 = side, x1 = -1, y1 = -1, count = 0
            for y in 0..<side {
                for x in 0..<side where bytes[y * bitmap.bytesPerRow + x * 4 + 3] >= threshold {
                    x0 = min(x0, x); x1 = max(x1, x)
                    y0 = min(y0, y); y1 = max(y1, y); count += 1
                }
            }
            guard count >= 4, x1 >= x0, y1 >= y0 else { return nil }
            // Bitmap rows are top-down, while NSImage and Dock tiles are not flipped.
            return CGRect(x: Double(x0) / Double(side), y: Double(side - y1 - 1) / Double(side),
                          width: Double(x1 - x0 + 1) / Double(side), height: Double(y1 - y0 + 1) / Double(side))
        }
        let result = bounds(threshold: 128) ?? bounds(threshold: 1) ?? full
        // Avoid pathological tiny artwork collapsing the target into a sliver.
        return result.width >= 0.1 && result.height >= 0.1 ? result : full
    }
}

/// The Dock tile, style chooser and drop animation share the same artwork and slots.
/// Rectangles use unflipped AppKit coordinates; members always stay upright.
@MainActor
enum DockFolderArtwork {
    private static let silverTop = NSColor(srgbRed: 0.975, green: 0.982, blue: 0.991, alpha: 1)
    private static let silverBottom = NSColor(srgbRed: 0.806, green: 0.832, blue: 0.864, alpha: 1)
    private static let silverFinish = NSGradient(starting: silverTop, ending: silverBottom)!

    static func defaultColor(for style: DockFolderStyle) -> NSColor {
        switch style {
        case .silver: return NSColor(srgbRed: 0.88, green: 0.90, blue: 0.92, alpha: 1)
        case .classic: return .systemBlue
        case .flat: return NSColor(srgbRed: 0.14, green: 0.62, blue: 0.52, alpha: 1)
        case .skeuomorphic: return NSColor(srgbRed: 0.72, green: 0.44, blue: 0.22, alpha: 1)
        case .glass: return NSColor(srgbRed: 0.27, green: 0.32, blue: 0.52, alpha: 1)
        }
    }

    static func contentBounds(for style: DockFolderStyle) -> CGRect {
        switch style {
        case .silver: return IconArtworkBounds.folder
        case .classic: return CGRect(x: 0.04, y: 0.10, width: 0.92, height: 0.73)
        case .flat: return CGRect(x: 0.06, y: 0.11, width: 0.88, height: 0.77)
        case .skeuomorphic: return CGRect(x: 0.05, y: 0.10, width: 0.90, height: 0.78)
        case .glass: return CGRect(x: 0.07, y: 0.08, width: 0.86, height: 0.84)
        }
    }

    static func visibleMemberCount(for style: DockFolderStyle) -> Int {
        style == .classic || style == .skeuomorphic ? 3 : 4
    }

    private static func rect(_ canvas: CGRect, _ x: CGFloat, _ y: CGFloat,
                             _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: canvas.minX + x * canvas.width, y: canvas.minY + y * canvas.height,
               width: width * canvas.width, height: height * canvas.height)
    }

    private static func body(in icon: CGRect, style: DockFolderStyle) -> CGRect {
        let b = contentBounds(for: style)
        return rect(icon, b.minX, b.minY, b.width, b.height)
    }

    static func memberFrame(index: Int?, count: Int, in icon: CGRect, style: DockFolderStyle) -> CGRect {
        let face = body(in: icon, style: style)
        guard let index, (0..<visibleMemberCount(for: style)).contains(index) else {
            return rect(face, 0.40, style == .classic || style == .skeuomorphic ? 0.32 : 0.40, 0.20, 0.20)
        }
        if style == .classic || style == .skeuomorphic {
            let centers: [CGFloat]
            switch count {
            case 1: centers = [0.5]
            case 2: centers = [0.37, 0.63]
            default: centers = [0.29, 0.5, 0.71]
            }
            let center = centers[min(index, centers.count - 1)]
            let size: CGFloat = style == .classic ? 0.31 : 0.295
            let y: CGFloat = style == .classic ? 0.18 : 0.19
            return rect(icon, center - size / 2, y + (index == 1 ? 0.035 : 0), size, size)
        }
        let grid: CGRect
        switch style {
        case .flat: grid = rect(icon, 0.15, 0.10, 0.70, 0.70)
        case .glass: grid = rect(icon, 0.07, 0.08, 0.79, 0.76)
        default: grid = face
        }
        let side = grid.width * 0.365
        let x = grid.minX + grid.width * (index.isMultiple(of: 2) ? 0.30 : 0.70)
        let y = grid.minY + grid.height * (index < 2 ? 0.70 : 0.30)
        return CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side)
    }

    static func draw(in icon: CGRect, appearance: DockFolderAppearance, icons: [NSImage]) {
        guard icon.width > 0, icon.height > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        let style = appearance.style
        let count = min(icons.count, visibleMemberCount(for: style))
        let opacity = CGFloat(appearance.backgroundOpacity)
        if opacity > 0 {
            // Composite the complete material once so internal seams and highlights
            // cannot become opaque where two translucent surfaces overlap.
            if opacity < 1 {
                context.saveGState()
                context.setAlpha(opacity)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            let tint = appearance.backgroundColor.map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) }
            let color = tint ?? defaultColor(for: style)
            switch style {
            case .silver: drawSilver(in: body(in: icon, style: style), tint: tint)
            case .classic: drawClassic(in: icon, tint: tint)
            case .flat: drawFlat(in: icon, color: color)
            case .skeuomorphic: drawLeather(in: icon, color: color)
            case .glass: drawGlass(in: icon, color: color)
            }
            if style == .silver {
                for index in count..<4 {
                    let frame = memberFrame(index: index, count: count, in: icon, style: style)
                    let well = frame.insetBy(dx: frame.width * 0.12, dy: frame.height * 0.12)
                    NSColor(white: 0.26, alpha: 0.085).setFill()
                    rounded(well, well.width * 0.24).fill()
                }
            }
            if opacity < 1 {
                context.endTransparencyLayer()
                context.restoreGState()
            }
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high
        for index in 0..<count {
            icons[index].draw(in: memberFrame(index: index, count: count, in: icon, style: style))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func rounded(_ r: CGRect, _ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    }

    private static func mix(_ color: NSColor, with other: NSColor, amount: CGFloat) -> NSColor {
        color.blended(withFraction: amount, of: other) ?? color
    }

    private static func drawSilver(in tray: CGRect, tint: NSColor?) {
        let side = tray.width
        let radius = side * 0.225
        let face = rounded(tray, radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
        shadow.shadowBlurRadius = side * 0.028
        shadow.shadowOffset = NSSize(width: 0, height: -side * 0.020)
        shadow.set()
        NSColor(white: 0.78, alpha: 1).setFill()
        face.fill()
        NSGraphicsContext.restoreGraphicsState()
        if let tint {
            NSGradient(starting: mix(tint, with: .white, amount: 0.29),
                       ending: mix(tint, with: .black, amount: 0.13))?.draw(in: face, angle: -90)
        } else {
            silverFinish.draw(in: face, angle: -90)
        }
        let line = side * 0.018
        let rim = rounded(tray.insetBy(dx: line / 2, dy: line / 2), radius - line / 2)
        NSColor.white.withAlphaComponent(0.72).setStroke()
        rim.lineWidth = line
        rim.stroke()
    }

    private static func drawClassic(in icon: CGRect, tint: NSColor?) {
        let w = icon.width
        let back = rect(icon, 0.04, 0.10, 0.92, 0.66)
        (tint ?? .systemBlue).withAlphaComponent(0.8).setFill()
        rounded(rect(icon, 0.04, 0.58, 0.42, 0.25), 0.08 * w).fill()
        rounded(back.offsetBy(dx: 0, dy: 0.04 * w), 0.09 * w).fill()
        NSColor.white.withAlphaComponent(0.88).setFill()
        rounded(rect(icon, 0.14, 0.31, 0.72, 0.41), 0.035 * w).fill()
        let front = rounded(rect(icon, 0.04, 0.10, 0.92, 0.52), 0.08 * w)
        let top = tint.map { mix($0, with: .white, amount: 0.33) } ?? .systemCyan
        NSGradient(starting: top, ending: tint ?? .systemBlue)?.draw(in: front, angle: -90)
    }

    private static func drawFlat(in icon: CGRect, color: NSColor) {
        // A stepped tab and one solid colour read clearly at small sizes.
        let w = icon.width
        color.setFill()
        rounded(rect(icon, 0.06, 0.65, 0.42, 0.23), 0.06 * w).fill()
        rounded(rect(icon, 0.06, 0.11, 0.88, 0.65), 0.08 * w).fill()
    }

    private static func drawLeather(in icon: CGRect, color: NSColor) {
        let w = icon.width
        let body = rounded(rect(icon, 0.05, 0.10, 0.90, 0.72), 0.10 * w)
        let deep = mix(color, with: .black, amount: 0.41)
        let light = mix(color, with: .white, amount: 0.28)
        // Paper dividers peeking above the saddle-stitched wallet.
        deep.setFill()
        rounded(rect(icon, 0.08, 0.61, 0.78, 0.27), 0.075 * w).fill()
        NSColor(srgbRed: 0.98, green: 0.93, blue: 0.82, alpha: 1).setFill()
        rounded(rect(icon, 0.13, 0.57, 0.76, 0.26), 0.045 * w).fill()
        NSGradient(starting: light, ending: deep)?.draw(in: body, angle: -90)

        let flap = rounded(rect(icon, 0.05, 0.53, 0.90, 0.27), 0.09 * w)
        NSGraphicsContext.saveGraphicsState()
        let seamShadow = NSShadow()
        seamShadow.shadowColor = NSColor.black.withAlphaComponent(0.40)
        seamShadow.shadowBlurRadius = 0.018 * w
        seamShadow.shadowOffset = CGSize(width: 0, height: -0.023 * w)
        seamShadow.set()
        color.setFill()
        flap.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: light, ending: color)?.draw(in: flap, angle: -90)
        if w >= 28 {
            let seam = rounded(rect(icon, 0.081, 0.132, 0.838, 0.638), 0.069 * w)
            seam.lineWidth = 0.009 * w
            seam.setLineDash([0.033 * w, 0.022 * w], count: 2, phase: 0)
            NSColor(white: 1, alpha: 0.49).setStroke()
            seam.stroke()
        }
        let clasp = rect(icon, 0.465, 0.588, 0.07, 0.07)
        let brass = NSBezierPath(ovalIn: clasp)
        NSGradient(starting: NSColor(srgbRed: 1, green: 0.91, blue: 0.65, alpha: 1),
                   ending: NSColor(srgbRed: 0.61, green: 0.40, blue: 0.14, alpha: 1))?.draw(in: brass, angle: -90)
    }

    private static func drawGlass(in icon: CGRect, color: NSColor) {
        let w = icon.width
        let back = rounded(rect(icon, 0.17, 0.22, 0.76, 0.70), 0.16 * w)
        mix(color, with: .white, amount: 0.47).withAlphaComponent(0.67).setFill()
        back.fill()
        let front = rounded(rect(icon, 0.07, 0.08, 0.79, 0.76), 0.17 * w)
        NSGradient(starting: mix(color, with: .white, amount: 0.18).withAlphaComponent(0.90),
                   ending: mix(color, with: .black, amount: 0.53).withAlphaComponent(0.93))?.draw(in: front, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        front.addClip()
        let shine = NSBezierPath(ovalIn: rect(icon, -0.42, 0.46, 1.76, 0.64))
        NSGradient(starting: NSColor(white: 1, alpha: 0.39), ending: NSColor(white: 1, alpha: 0.025))?
            .draw(in: shine, angle: -83)
        NSGraphicsContext.restoreGraphicsState()
        let rim = rounded(rect(icon, 0.079, 0.089, 0.772, 0.742), 0.161 * w)
        rim.lineWidth = w * 0.018
        NSColor(white: 1, alpha: 0.56).setStroke()
        rim.stroke()
    }
}
