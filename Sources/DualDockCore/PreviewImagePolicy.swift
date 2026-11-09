import CoreGraphics

public enum PreviewImagePolicy {
    /// Visual evidence only: callers must also establish that this is a hidden,
    /// inactive, AX-unmatched window with a generic application title. A real
    /// blank document must never be excluded just because its image is flat.
    public static func isUniformWindowShell(_ image: CGImage?) -> Bool {
        guard let image, image.width >= 32, image.height >= 32 else { return false }
        let width = image.width, height = image.height
        let (rowBytes, overflow) = width.multipliedReportingOverflow(by: 4)
        guard !overflow, let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { return false }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let center = (height / 2) * context.bytesPerRow + (width / 2) * 4
        guard pixels[center + 3] >= 250 else { return false }
        let reference = (Int(pixels[center]), Int(pixels[center + 1]), Int(pixels[center + 2]))
        let insetX = width / 8, insetY = height / 8
        var backgroundPixels = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = y * context.bytesPerRow + x * 4
                let matches = pixels[i + 3] >= 250
                    && abs(Int(pixels[i]) - reference.0) <= 2
                    && abs(Int(pixels[i + 1]) - reference.1) <= 2
                    && abs(Int(pixels[i + 2]) - reference.2) <= 2
                if matches { backgroundPixels += 1 }
                else if x >= insetX, x < width - insetX, y >= insetY, y < height - insetY {
                    // Even sparse text or a loading/protected-content indicator
                    // in the interior makes this a meaningful preview.
                    return false
                }
            }
        }
        // Permit only trivial corner chrome and rounded-edge antialiasing.
        return Double(backgroundPixels) / (Double(width) * Double(height)) >= 0.97
    }

    public static func hasVisiblePixels(_ image: CGImage?) -> Bool {
        guard let image, image.width > 0, image.height > 0 else { return false }
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return true
        default:
            break
        }

        // Normalize byte order before inspecting alpha. A non-nil screenshot
        // can still be an entirely transparent backing surface.
        let (rowBytes, overflow) = image.width.multipliedReportingOverflow(by: 4)
        guard !overflow,
              let context = CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
              ), let data = context.data else { return false }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        for row in 0..<image.height {
            let start = row * context.bytesPerRow
            for column in 0..<image.width where pixels[start + column * 4 + 3] > 0 {
                return true
            }
        }
        return false
    }
}
