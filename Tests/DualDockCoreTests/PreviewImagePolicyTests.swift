import CoreGraphics
import XCTest
@testable import DualDockCore

final class PreviewImagePolicyTests: XCTestCase {
    func testRecognizesFlatShellWithOnlyTinyCornerChrome() throws {
        let context = try shellContext()
        context.setFillColor(CGColor(gray: 0.3, alpha: 1))
        context.fillEllipse(in: CGRect(x: 4, y: 94, width: 3, height: 3))
        XCTAssertTrue(PreviewImagePolicy.isUniformWindowShell(try XCTUnwrap(context.makeImage())))
    }

    func testInteriorContentPreventsFlatShellClassification() throws {
        let context = try shellContext()
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 45, y: 45, width: 2, height: 2))
        XCTAssertFalse(PreviewImagePolicy.isUniformWindowShell(try XCTUnwrap(context.makeImage())))
    }

    func testSubstantialWindowChromePreventsFlatShellClassification() throws {
        let context = try shellContext()
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 90, width: 100, height: 10))
        XCTAssertFalse(PreviewImagePolicy.isUniformWindowShell(try XCTUnwrap(context.makeImage())))
    }

    func testMissingAndTransparentCapturesAreNotOpaqueFlatShells() throws {
        XCTAssertFalse(PreviewImagePolicy.isUniformWindowShell(nil))
        let context = try shellContext()
        context.clear(CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertFalse(PreviewImagePolicy.isUniformWindowShell(try XCTUnwrap(context.makeImage())))
    }

    private func shellContext() throws -> CGContext {
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100,
            bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.16, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        return context
    }

    func testRejectsMissingCapture() {
        XCTAssertFalse(PreviewImagePolicy.hasVisiblePixels(nil))
    }

    func testRejectsFullyTransparentCaptureWithNonzeroRGBBytes() throws {
        // Invisible helper windows can have allocated image data while every
        // alpha byte is zero. RGB content must not make that a real preview.
        let bytes: [UInt8] = [60, 20, 10, 0, 0, 0, 0, 0]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        ))
        XCTAssertFalse(PreviewImagePolicy.hasVisiblePixels(image))
    }

    func testKeepsOpaqueBlackWindow() throws {
        let context = try bitmapContext()
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        XCTAssertTrue(PreviewImagePolicy.hasVisiblePixels(try XCTUnwrap(context.makeImage())))
    }

    func testKeepsSparseVisiblePixels() throws {
        let context = try bitmapContext()
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 7, y: 7, width: 1, height: 1))
        XCTAssertTrue(PreviewImagePolicy.hasVisiblePixels(try XCTUnwrap(context.makeImage())))
    }

    func testRejectsPremultipliedFirstTransparentImage() throws {
        let context = try bitmapContext(alpha: .premultipliedFirst)
        XCTAssertFalse(PreviewImagePolicy.hasVisiblePixels(try XCTUnwrap(context.makeImage())))
    }

    func testKeepsImageWithoutAlphaChannel() throws {
        let context = try bitmapContext(alpha: .noneSkipLast)
        XCTAssertTrue(PreviewImagePolicy.hasVisiblePixels(try XCTUnwrap(context.makeImage())))
    }

    private func bitmapContext(alpha: CGImageAlphaInfo = .premultipliedLast) throws -> CGContext {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: alpha.rawValue
        ))
        context.clear(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context
    }
}
