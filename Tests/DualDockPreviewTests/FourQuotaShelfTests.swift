import AppKit
import SwiftUI
import XCTest
import DualDockCore
@testable import DualDock

@MainActor
final class FourQuotaShelfTests: XCTestCase {
    private actor Readers {
        var calls: [String: Int] = [:]
        var signInFailure = false
        func refuseSubscription() { signInFailure = true }

        func read(_ source: String) async throws -> AIQuotaSnapshot {
            calls[source, default: 0] += 1
            let now = Date()
            let percent: Double
            switch source {
            case "codex": percent = 61
            case "gemini": percent = 84
            case "claude":
                if signInFailure { throw AIQuotaError.signIn }
                percent = 75
            case "cursorCLI":
                // A stale legacy response must not replace a newer X-plan result.
                try? await Task.sleep(for: .milliseconds(150))
                percent = 34
            default:
                if signInFailure { throw AIQuotaError.signIn }
                percent = 52
            }
            return AIQuotaSnapshot(windows: [
                AIQuotaWindow(id: source, label: "", minutes: source == "xSubscription" ? 10080 : 300,
                              remainingPercent: percent, reset: now.addingTimeInterval(7200))
            ], updated: now, sourceIsCached: source == "claude" ? true : nil)
        }
    }

    private func fixture(readers: Readers, connectedCodex: Bool = false) throws -> DockToolsStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        if connectedCodex {
            try Data(#"{"codexEnabled":true,"pins":{}}"#.utf8).write(to: dir.appendingPathComponent("ai-quota-settings.json"))
        }
        let start = Calendar.current.date(bySettingHour: 14, minute: 30, second: 0, of: Date()) ?? Date()
        let data = ToolDataService.Environment(
            music: { _, _ in .track(title: "Northern Lights", artist: "DualDock Studio", playing: true) },
            calendar: { _ in .upcoming(title: "Design review", start: start, isAllDay: false) },
            conditions: { _ in throw URLError(.notConnectedToInternet) }, cities: { _, _ in [] })
        let quota = AIQuotaService.Environment(codex: { _ in try await readers.read("codex") },
            claudeSettings: dir.appendingPathComponent("claude.json"), executable: nil,
            antigravity: { try await readers.read("gemini") },
            claude: { try await readers.read("claude") }, cursor: { try await readers.read($0.rawValue) })
        return DockToolsStore(directory: dir, providerEnvironment: data, quotaEnvironment: quota)
    }

    private func host<V: View>(_ root: V, size: CGSize) -> NSPanel {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: root)
        panel.setContentSize(size)
        let left = NSScreen.screens.map(\.frame.minX).min() ?? 0
        panel.setFrameOrigin(NSPoint(x: left - size.width - 100, y: 0))
        panel.orderBack(nil)
        panel.contentView?.layoutSubtreeIfNeeded()
        return panel
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<120 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected the provider state to settle")
    }

    private func clickShelf(_ store: DockToolsStore, card: Int, display: String) async throws {
        // 4 cards at 3 x 48 pt + 2 x 5 pt internal spacing, with three gaps and 8 pt end padding.
        let size = CGSize(width: 639, height: 52)
        let panel = host(DockToolsShelfView(store: store, displayID: display, edge: .bottom, iconSize: 48),
                         size: size)
        defer { panel.close() }
        try await Task.sleep(for: .milliseconds(100))
        let point = NSPoint(x: 4 + 77 + 159 * card, y: 26)
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
        try await waitFor { store.keepsShelfOpen(on: display) }
    }

    func testFourRealCardRoutesAndSharedReadsAcrossDisplays() async throws {
        let readers = Readers(), providers: [AIQuotaProvider] = [.codex, .gemini, .claude, .cursor]
        let store = try fixture(readers: readers, connectedCodex: true)
        defer { store.stop() }
        let cards: [ShelfLayout.Kind] = [.codexQuota, .geminiQuota, .claudeQuota, .cursorQuota]
        XCTAssertEqual(cards.compactMap(\.quotaProvider), providers)
        store.edit { $0.slots = cards.map { .init(span: 3, cards: [.init(kind: $0)]) } }
        store.setSettingsPreviewVisible(true)
        try await Task.sleep(for: .milliseconds(90))
        let previewCalls = await readers.calls
        XCTAssertTrue(previewCalls.isEmpty, "An already-connected Codex account must also remain passive in Settings")

        store.setShelfVisible(true, on: "external")
        store.setShelfVisible(true, on: "internal")
        try await waitFor { store.quota.selected(.codex) != nil }
        for (index, provider) in providers.enumerated() {
            try await clickShelf(store, card: index, display: index.isMultiple(of: 2) ? "external" : "internal")
            try await waitFor { !store.quota.isRefreshing(provider) }
        }
        let counts = await readers.calls
        XCTAssertEqual(counts, ["codex": 2, "gemini": 1, "claude": 1])
        XCTAssertNil(store.quota.cursorSource)
        XCTAssertNil(store.quota.selected(.cursor))
        XCTAssertEqual(store.quota.snapshots[.claude]?.sourceIsCached, true)
        XCTAssertEqual(store.quota.selected(.claude)?.remainingPercent, 75)

        store.quota.setCursorSource(.cursorCLI)
        try await Task.sleep(for: .milliseconds(10))
        store.quota.setCursorSource(.xSubscription)
        try await waitFor { !store.quota.isRefreshing(.cursor) }
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(store.quota.cursorSource, .xSubscription)
        XCTAssertEqual(store.quota.selected(.cursor)?.id, "xSubscription")
        XCTAssertEqual(store.quota.selected(.cursor)?.remainingPercent, 52)
        await readers.refuseSubscription()
        try await clickShelf(store, card: 2, display: "internal")
        try await clickShelf(store, card: 3, display: "external")
        try await waitFor { !store.quota.isRefreshing(.cursor) && !store.quota.isRefreshing(.claude) }
        for provider in [AIQuotaProvider.cursor, .claude] {
            XCTAssertEqual(store.quota.issues[provider], .signIn)
            XCTAssertNil(store.quota.selected(provider))
        }
        XCTAssertEqual(store.quota.selected(.gemini)?.remainingPercent, 84)
        XCTAssertEqual(store.quota.selected(.codex)?.remainingPercent, 61)
    }

    func testRenderPublishedToolsShelfWithOnlyIllustrativeReadings() async throws {
        let readers = Readers()
        let store = try fixture(readers: readers)
        defer { store.stop() }
        let shortcut = try XCTUnwrap(store.layout.slots.last)
        store.edit { layout in
            layout.slots = [.init(span: 3, cards: [.init(kind: .music)]),
                            .init(span: 3, cards: [.init(kind: .calendar)]),
                            .init(span: 2, cards: [.init(kind: .focusTimer)]),
                            .init(span: 3, cards: [.init(kind: .geminiQuota)]), shortcut]
        }
        store.setShelfVisible(true, on: "sample")
        store.data.enableMusic()
        store.quota.refresh(.gemini)
        try await waitFor { store.quota.selected(.gemini) != nil }
        let size = CGSize(width: 687, height: 61)
        let shelf = DockToolsShelfView(store: store, displayID: "sample", edge: .bottom, iconSize: 52)
            .environment(\.dualDockLanguage, AppLanguage.simplifiedChinese)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(3)
        let panel = host(shelf, size: size)
        defer { panel.close() }
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        try await Task.sleep(for: .milliseconds(140))
        let view = try XCTUnwrap(panel.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 620)
        if let path = ProcessInfo.processInfo.environment["DUALDOCK_TOOL_RENDER_DIR"] {
            let dir = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("tools-shelf.png"))
        }
    }
}
