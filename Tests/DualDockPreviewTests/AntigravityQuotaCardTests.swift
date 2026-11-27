import AppKit
import SwiftUI
import XCTest
@testable import DualDock

@MainActor
final class AntigravityQuotaCardTests: XCTestCase {
    private actor Usage {
        private(set) var requests = 0

        func read() -> AIQuotaSnapshot {
            requests += 1
            let now = Date.now
            return AIQuotaSnapshot(windows: [
                AIQuotaWindow(id: "gemini/short", label: "", minutes: 300,
                              remainingPercent: 90 - Double(requests), reset: now.addingTimeInterval(3600)),
                AIQuotaWindow(id: "gemini/week", label: "", minutes: 10080,
                              remainingPercent: 62, reset: now.addingTimeInterval(4 * 86_400))
            ], updated: now)
        }
    }

    private func makeService(read: @escaping @Sendable () async throws -> AIQuotaSnapshot) throws -> AIQuotaService {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return AIQuotaService(directory: directory, environment: .init(
            codex: { _ in throw AIQuotaError.unavailable },
            claudeSettings: directory.appendingPathComponent("claude.json"),
            executable: nil, antigravity: read))
    }

    private func window<V: View>(for view: V, size: NSSize) -> (NSPanel, NSHostingController<V>) {
        _ = NSApplication.shared
        let controller = NSHostingController(rootView: view)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentViewController = controller
        panel.setContentSize(size)
        let left = NSScreen.screens.map(\.frame.minX).min() ?? 0
        panel.setFrameOrigin(NSPoint(x: left - size.width - 200, y: 0))
        panel.orderBack(nil)
        controller.view.layoutSubtreeIfNeeded()
        return (panel, controller)
    }

    private func click(_ panel: NSPanel, at point: NSPoint) throws {
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
    }

    private func waitFor(_ operation: @escaping () -> Bool) async throws {
        for _ in 0..<100 {
            if operation() { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTFail("The quota interaction did not finish")
    }

    func testPreviewIsPassiveAndEachCardClickRefreshesAndOpensDetails() async throws {
        let counter = Usage()
        let service = try makeService { await counter.read() }
        defer { service.stop() }
        let size = NSSize(width: 180, height: 48)
        let preview = AIQuotaPreviewView(provider: .gemini, service: service, span: 3)
            .frame(width: size.width, height: size.height)
        let (previewPanel, _) = window(for: preview, size: size)
        defer { previewPanel.close() }
        service.setVisible([.gemini], on: "Settings")
        try await clickAfterLayout(previewPanel)
        let initialRequests = await counter.requests
        XCTAssertEqual(initialRequests, 0)
        XCTAssertNil(service.selected(.gemini))

        for (index, language) in [AppLanguage.simplifiedChinese, .english].enumerated() {
            var detailOpened = false
            let card = AIQuotaCardView(provider: .gemini, service: service, span: 3, horizontal: true) {
                detailOpened = $0
            }.environment(\.dualDockLanguage, language).frame(width: size.width, height: size.height)
            let (panel, _) = window(for: card, size: size)
            defer { panel.close() }
            try await clickAfterLayout(panel)
            let expected = 90 - Double(index + 1)
            try await waitFor { detailOpened && service.selected(.gemini)?.remainingPercent == expected }
            let requests = await counter.requests
            XCTAssertEqual(requests, index + 1)
            XCTAssertEqual(service.snapshots[.gemini]?.windows.count, 2)
            XCTAssertNotNil(service.selected(.gemini)?.reset)
            panel.orderOut(nil)
        }
    }

    private func clickAfterLayout(_ panel: NSPanel) async throws {
        try await Task.sleep(for: .milliseconds(90))
        let bounds = try XCTUnwrap(panel.contentView).bounds
        try click(panel, at: NSPoint(x: bounds.midX, y: bounds.midY))
        try await Task.sleep(for: .milliseconds(65))
    }

    func testPopoverRefreshButtonFetchesAgainInBothLanguages() async throws {
        let counter = Usage()
        let service = try makeService { await counter.read() }
        defer { service.stop() }
        service.refreshAntigravity()
        try await waitFor { service.selected(.gemini)?.remainingPercent == 89 }
        for (index, language) in [AppLanguage.simplifiedChinese, .english].enumerated() {
            let detail = AIQuotaDetail(provider: .gemini, service: service)
                .environment(\.dualDockLanguage, language)
                .environment(\.locale, Locale(identifier: language.rawValue))
                .background(Color(nsColor: .windowBackgroundColor))
            let (panel, controller) = window(for: detail, size: NSSize(width: 313, height: 240))
            defer { panel.close() }
            panel.appearance = NSAppearance(named: language == .english ? .aqua : .darkAqua)
            try await Task.sleep(for: .milliseconds(90))
            let size = controller.sizeThatFits(in: NSSize(width: 313, height: 600))
            XCTAssertEqual(size.width, 313, accuracy: 1)
            XCTAssertLessThan(size.height, 385)
            panel.setContentSize(size)
            controller.view.frame = NSRect(origin: .zero, size: size)
            controller.view.layoutSubtreeIfNeeded()
            if let location = ProcessInfo.processInfo.environment["DUALDOCK_GEMINI_RENDER_DIR"] {
                let folder = URL(fileURLWithPath: location)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let rep = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                controller.view.cacheDisplay(in: controller.view.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(
                    to: folder.appendingPathComponent("antigravity-quota-\(language.rawValue).png"))
            }
            try click(panel, at: NSPoint(x: size.width - 20, y: size.height - 23))
            try await waitFor { service.selected(.gemini)?.remainingPercent == 88 - Double(index) }
            let total = await counter.requests
            XCTAssertEqual(total, index + 2)
        }
    }
}
