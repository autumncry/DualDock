import AppKit
import SwiftUI
import XCTest
@testable import DualDock

final class GeminiQuotaImportTests: XCTestCase {
    @MainActor func testGuideRendersAndImportsOnlyOnClickInBothLanguages() async throws {
        _ = NSApplication.shared
        for language in [AppLanguage.simplifiedChinese, .english] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let service = AIQuotaService(directory: directory)
            defer { service.stop() }
            var clipboardReads = 0
            let controls = GeminiQuotaImportView(service: service, readClipboard: {
                clipboardReads += 1
                return "Model usage\nPro          ▬▬▬▬▬    35%  Resets: 1:30 PM (1h 30m)"
            })
            let view = VStack(alignment: .leading, spacing: 10) {
                Label(language("Gemini CLI 余量", "Gemini CLI quota"), systemImage: "sparkles").font(.headline)
                controls
            }
            .frame(width: 285, alignment: .leading).padding(14)
            .environment(\.dualDockLanguage, language)
            .background(Color(nsColor: .windowBackgroundColor))
            let controller = NSHostingController(rootView: view)
            let panel = NSPanel(contentRect: NSRect(x: -6000, y: -6000, width: 313, height: 270),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.contentViewController = controller
            panel.orderBack(nil)
            defer { panel.close() }
            try await Task.sleep(for: .milliseconds(100))
            let size = controller.sizeThatFits(in: .init(width: 313, height: 800))
            XCTAssertEqual(size.width, 313, accuracy: 1)
            XCTAssertLessThan(size.height, 420, "The first-use guide should fit in a small popover")
            panel.setContentSize(size)
            let host = controller.view
            host.layoutSubtreeIfNeeded()
            if let location = ProcessInfo.processInfo.environment["DUALDOCK_GEMINI_RENDER_DIR"] {
                let folder = URL(fileURLWithPath: location)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: image)
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(
                    to: folder.appendingPathComponent("gemini-import-\(language.rawValue).png"))
            }
            XCTAssertEqual(clipboardReads, 0)
            XCTAssertNil(service.selected(.gemini))

            let point = NSPoint(x: 55, y: 24)
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            }
            NSApp.postEvent(try event(.leftMouseUp), atStart: true)
            panel.sendEvent(try event(.leftMouseDown))
            if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .now, inMode: .default, dequeue: true) {
                panel.sendEvent(up)
            }
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(clipboardReads, 1)
            XCTAssertEqual(service.selected(.gemini)?.remainingPercent, 65)
            XCTAssertFalse(service.importGemini("Model Stats For Nerds\nCache Reads 90 (66%)"))
            XCTAssertEqual(service.selected(.gemini)?.remainingPercent, 65, "An invalid update must preserve the last snapshot")
        }
    }
}
