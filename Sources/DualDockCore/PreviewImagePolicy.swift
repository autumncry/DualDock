import CoreGraphics

public enum PreviewImagePolicy {
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
