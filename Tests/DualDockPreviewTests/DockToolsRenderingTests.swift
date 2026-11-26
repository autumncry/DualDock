import AppKit
import SwiftUI
import XCTest
import DualDockCore
@testable import DualDock

/// Exercise the real hosting view on both axes. No panels are ordered on screen
/// and provider closures use a temporary local fixture.
final class DockToolsRenderingTests: XCTestCase {
    @MainActor func testNativeShelfPaintsCardDetailsAcrossOrientations() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = ToolDataService.Environment(
            music: { _, _ in .track(title: "Night Train", artist: "Fixture Artist", playing: true) },
            calendar: { _ in .upcoming(title: "Design Review", start: Date(timeIntervalSince1970: 1800000000), isAllDay: false) },
            conditions: { _ in throw URLError(.notConnectedToInternet) },
            cities: { _, _ in [] })
        let store = DockToolsStore(directory: directory, providerEnvironment: env)
        defer { store.stop() }
        store.setShelfVisible(true, on: "test-display")
        store.data.enableMusic()
        try await Task.sleep(for: .milliseconds(80))
        for edge in [DockEdge.bottom, .left] {
            let size = edge.isHorizontal ? CGSize(width: 520, height: 58) : CGSize(width: 58, height: 520)
            let view = NSHostingView(rootView: DockToolsShelfView(store: store, displayID: "test-display", edge: edge, iconSize: 52)
                .background(Color(nsColor: .windowBackgroundColor))
                .frame(width: size.width, height: size.height))
            let rect = NSRect(origin: .zero, size: size)
            view.sizingOptions = []
            _ = NSApplication.shared
            let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.setContentSize(size)
            view.frame = rect
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
            XCTAssertFalse(window.isVisible)
            XCTAssertEqual(view.bounds.size, size)
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: rect))
            view.cacheDisplay(in: rect, to: rep)
            let url = ProcessInfo.processInfo.environment["DUALDOCK_TOOL_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
            if let url {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    .write(to: url.appendingPathComponent("tool-shelf-" + edge.rawValue + ".png"))
            }
            // Tile artwork and text should paint into the shelf, even if the
            // hosting panel is nonactivating or not ordered in.
            var shades = Set<Int>()
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                    if let rgb = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), rgb.alphaComponent > 0.8 {
                        shades.insert(Int(rgb.redComponent * 255) / 4)
                    }
                }
            }
            XCTAssertGreaterThan(shades.count, 8, "Missing visible card detail for " + edge.rawValue)

            let stack = try XCTUnwrap(store.layout.slots.first(where: { $0.cards.count > 1 }))
            let initial = store.selectedCard(in: stack, on: "test-display")
            // Replay a local NSEvent at the independent stack control. Never
            // post a system event or move the user's pointer.
            let leftmost = NSScreen.screens.map(\.frame.minX).min() ?? 0
            window.setFrameOrigin(NSPoint(x: leftmost - size.width - 200, y: 0))
            window.orderBack(nil)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }))
            let mainLength = edge.isHorizontal ? size.width : size.height
            let length: CGFloat = 52 * 3 + 5 * 2
            let total = length * 2 + 52 + 10
            let mainPoint = (mainLength - total) / 2 + length * 2 + 5 - 14
            let location = edge.isHorizontal ? CGPoint(x: mainPoint, y: size.height / 2)
                : CGPoint(x: size.width / 2, y: size.height - mainPoint)
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            }
            NSApp.postEvent(event(.leftMouseUp), atStart: true)
            window.sendEvent(event(.leftMouseDown))
            if let released = NSApp.nextEvent(matching: .leftMouseUp, until: .now, inMode: .default, dequeue: true) {
                window.sendEvent(released)
            }
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertNotEqual(store.selectedCard(in: stack, on: "test-display")?.id, initial?.id)
            XCTAssertEqual(store.selectedCard(in: stack, on: "other-display")?.id, stack.cards.first?.id)
            store.advance(stack, on: "test-display", by: -1)
            window.close()
        }
    }
}
