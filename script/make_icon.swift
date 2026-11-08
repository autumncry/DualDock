import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = base * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(size) / 1024)
        transform.concat()
        let background = NSBezierPath(roundedRect: NSRect(x: 68, y: 68, width: 888, height: 888), xRadius: 205, yRadius: 205)
        NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.29, blue: 0.52, alpha: 1), ending: NSColor(calibratedRed: 0.05, green: 0.10, blue: 0.22, alpha: 1))!.draw(in: background, angle: 70)
        for (rect, alpha) in [(NSRect(x: 350, y: 420, width: 420, height: 310), 0.55), (NSRect(x: 230, y: 280, width: 450, height: 335), 1.0)] {
            NSColor.white.withAlphaComponent(alpha).setStroke()
            let screen = NSBezierPath(roundedRect: rect, xRadius: 35, yRadius: 35)
            screen.lineWidth = 24
            screen.stroke()
            NSColor(calibratedRed: 0.42, green: 0.82, blue: 0.95, alpha: alpha).setFill()
            for index in 0..<4 {
                NSBezierPath(roundedRect: NSRect(x: rect.midX - 105 + CGFloat(index) * 56, y: rect.minY + 32, width: 42, height: 42), xRadius: 10, yRadius: 10).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
