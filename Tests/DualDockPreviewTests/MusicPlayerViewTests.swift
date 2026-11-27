import AppKit
import DualDockCore
import SwiftUI
import XCTest

@testable import DualDock

/// Replay only on test-owned windows, using a synthetic music client.
@MainActor
final class MusicPlayerViewTests: XCTestCase {
    private actor Commands {
        var playback: [ToolMusicCommand] = []
        var listReads = 0
        var cover: Data?
        func setCover(_ image: Data?) { cover = image }
        func details() -> ToolMusicPlayerRead {
            .player(
                .init(
                    trackID: "track-1", title: "Evening Walk", artist: "Studio Ensemble",
                    album: "Evening Sessions",
                    playing: true, position: 96, duration: 225, sampledAt: Date(), artwork: cover))
        }
        func list() -> ToolMusicPlaylist? {
            listReads += 1
            return .init(
                id: "fixture-list", name: "",
                tracks: [
                    .init(
                        id: "track-1", playlistID: "fixture-list", index: 1, title: "Evening Walk",
                        artist: "Studio Ensemble"),
                    .init(
                        id: "track-2", playlistID: "fixture-list", index: 2, title: "Before Dawn",
                        artist: "Studio Ensemble"),
                    .init(
                        id: "track-3", playlistID: "fixture-list", index: 3, title: "Coffee at Noon",
                        artist: "Studio Ensemble"),
                ], totalCount: 3)
        }
        func apply(_ request: ToolMusicCommand) -> ToolMusicState {
            if request != .status { playback.append(request) }
            return .track(title: "Evening Walk", artist: "Studio Ensemble", playing: true)
        }
    }

    private func scratch() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file
    }

    private func store(_ directory: URL, _ commands: Commands) -> DockToolsStore {
        DockToolsStore(
            directory: directory,
            providerEnvironment: .init(
                music: { request, _ in await commands.apply(request) },
                calendar: { _ in .empty },
                conditions: { _ in throw URLError(.notConnectedToInternet) },
                cities: { _, _ in [] },
                musicPlayer: { await commands.details() },
                musicPlaylist: { _ in await commands.list() }))
    }

    private func makeWindow(_ content: NSView, size: NSSize) -> NSWindow {
        _ = NSApplication.shared
        let rect = NSRect(origin: .zero, size: size)
        let panel = NSPanel(
            contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.setContentSize(size)
        let leftmost = NSScreen.screens.map(\.frame.minX).min() ?? 0
        panel.setFrameOrigin(NSPoint(x: leftmost - size.width - 200, y: 0))
        panel.orderBack(nil)
        XCTAssertFalse(NSScreen.screens.contains(where: { $0.frame.intersects(panel.frame) }))
        content.frame = rect
        content.layoutSubtreeIfNeeded()
        return panel
    }

    private func click(_ window: NSWindow, point: NSPoint, draggingTo end: NSPoint? = nil) {
        func event(_ type: NSEvent.EventType, _ location: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(event(.leftMouseUp, end ?? point), atStart: true)
        if let end {
            let midpoint = NSPoint(x: (point.x + end.x) / 2, y: (point.y + end.y) / 2)
            NSApp.postEvent(event(.leftMouseDragged, end), atStart: true)
            NSApp.postEvent(event(.leftMouseDragged, midpoint), atStart: true)
        }
        window.sendEvent(event(.leftMouseDown, point))
        while let pending = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp], until: .now, inMode: .default, dequeue: true)
        {
            window.sendEvent(pending)
        }
    }

    func testClickingPlayingShelfCardOpensPlayerWithoutToggling() async throws {
        let recorder = Commands()
        let directory = try scratch()
        let store = store(directory, recorder)
        defer { store.stop() }
        store.edit { $0.slots = [.init(span: 3, cards: [.init(kind: .music)])] }
        store.setShelfVisible(true, on: "music-test")
        store.data.enableMusic()
        try await Task.sleep(for: .milliseconds(100))
        let size = NSSize(width: 210, height: 52)
        let host = NSHostingView(
            rootView: DockToolsShelfView(store: store, displayID: "music-test", edge: .bottom, iconSize: 42)
                .frame(width: size.width, height: size.height))
        host.sizingOptions = []
        let window = makeWindow(host, size: size)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        click(window, point: .init(x: size.width / 2, y: size.height / 2))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(
            store.keepsShelfOpen(on: "music-test"), "Opening the player must keep its source Dock available")
        let actions = await recorder.playback
        XCTAssertEqual(actions, [], "Opening the player must not send playback commands")
    }
    func testPlayerTransportAndPlaylistFromRealNativeControls() async throws {
        let recorder = Commands()
        let directory = try scratch()
        let store = store(directory, recorder)
        defer { store.stop() }
        let image = NSImage(size: NSSize(width: 96, height: 96), flipped: false) { rect in
            NSGradient(starting: .systemPink, ending: .systemIndigo)?.draw(in: rect, angle: 35)
            NSColor.white.withAlphaComponent(0.8).setStroke()
            for radius in [24.0, 36.0, 48.0] {
                let circle = NSBezierPath(
                    ovalIn: NSRect(x: 47 - radius, y: 24 - radius, width: 2 * radius, height: 2 * radius))
                circle.lineWidth = 1.5
                circle.stroke()
            }
            return true
        }
        await recorder.setCover(image.tiffRepresentation)
        store.data.enableMusic()
        try await Task.sleep(for: .milliseconds(80))
        for language in [AppLanguage.simplifiedChinese, .english] {
            let root = MusicPlayerView(data: store.data)
                .environment(\.dualDockLanguage, language)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.locale, Locale(identifier: language.rawValue))
            let controller = NSHostingController(rootView: root)
            controller.sizingOptions = []
            let view = controller.view
            let window = makeWindow(view, size: NSSize(width: 302, height: 155))
            window.appearance = NSAppearance(named: language == .english ? .aqua : .darkAqua)
            defer { window.close() }
            func fit() async throws -> NSSize {
                try await Task.sleep(for: .milliseconds(90))
                let ideal = controller.sizeThatFits(in: CGSize(width: 302, height: 640))
                let size = CGSize(width: ceil(ideal.width), height: ceil(ideal.height))
                XCTAssertEqual(size.width, 302, accuracy: 1)
                XCTAssertGreaterThan(size.height, 90)
                XCTAssertLessThan(size.height, 570, "The player must fit on an ordinary display")
                window.setContentSize(size)
                view.frame = NSRect(origin: .zero, size: size)
                view.layoutSubtreeIfNeeded()
                return size
            }
            func capture(_ suffix: String) throws {
                let rect = view.bounds
                let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: rect))
                view.cacheDisplay(in: rect, to: rep)
                var shades = Set<Int>()
                for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                    for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                        if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                            c.alphaComponent > 0.7
                        {
                            shades.insert(Int(c.redComponent * 127))
                        }
                    }
                }
                XCTAssertGreaterThan(shades.count, 8, "Player should paint actual controls and track data")
                if let path = ProcessInfo.processInfo.environment["DUALDOCK_MUSIC_RENDER_DIR"] {
                    let folder = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(
                        to:
                            folder.appendingPathComponent("player-\(language.rawValue)-\(suffix).png"))
                }
            }
            let size = try await fit()
            XCTAssertNotNil(store.data.player)
            try capture("transport")
            let baseline = await recorder.playback.count
            // All three controls are centered on the bottom row of the closed player.
            for dx in [-63.0, 0, 63.0] {
                click(window, point: .init(x: size.width / 2 + dx, y: 33))
                try await Task.sleep(for: .milliseconds(70))
            }
            let actions = await Array(recorder.playback.dropFirst(baseline))
            XCTAssertEqual(actions, [.previous, .toggle, .next])
            let beforeScrub = await recorder.playback.count
            click(window, point: .init(x: 134, y: 70), draggingTo: .init(x: 197, y: 70))
            try await Task.sleep(for: .milliseconds(80))
            let seeks = await Array(recorder.playback.dropFirst(beforeScrub))
            XCTAssertEqual(seeks.count, 1, "A continuous scrub should issue exactly one seek on release")
            if case let .seek(seconds, trackID) = seeks.first {
                XCTAssertEqual(trackID, "track-1")
                XCTAssertGreaterThan(seconds, 150)
                XCTAssertLessThan(seconds, 220)
            } else {
                XCTFail("The slider must send a seek for the visible track")
            }
            let reads = await recorder.listReads
            click(window, point: .init(x: size.width - 29, y: size.height - 42))
            let expanded = try await fit()
            XCTAssertGreaterThan(
                expanded.height, size.height + 50, "The playlist should open inside the player")
            let newReads = await recorder.listReads
            XCTAssertGreaterThan(newReads, reads)
            XCTAssertEqual(store.data.playlist?.tracks.map(\.id), ["track-1", "track-2", "track-3"])
            try capture("playlist")
            let secondRow = try XCTUnwrap(store.data.playlist?.tracks.dropFirst().first)
            click(window, point: .init(x: 132, y: 16 + 57))
            try await Task.sleep(for: .milliseconds(80))
            let last = await recorder.playback.last
            XCTAssertEqual(last, .play(secondRow))
        }
    }

}
