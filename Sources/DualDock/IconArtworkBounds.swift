import AppKit

/// Measures the visible body without modifying, cropping or enlarging artwork.
/// Soft shadows may overlap at zero spacing; solid icon bodies may not.
enum IconArtworkBounds {
    static let full = CGRect(x: 0, y: 0, width: 1, height: 1)
    static let folder = CGRect(x: 0.04, y: 0.10, width: 0.92, height: 0.73)

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
