import AppKit
import SwiftUI
import XCTest
@testable import DualDock

final class SystemResourceTests: XCTestCase {
    func testMemoryCountsResidentAndCompressedBackingOnce() throws {
        var stats = vm_statistics64_data_t()
        stats.internal_page_count = 820
        stats.purgeable_count = 20
        stats.wire_count = 100
        stats.compressor_page_count = 50
        stats.external_page_count = 300
        stats.total_uncompressed_pages_in_compressor = 440
        let page: UInt64 = 16_384
        let total = 2_000 * page
        let usage = try XCTUnwrap(SystemResourceSnapshot.memoryUsage(stats, pageBytes: page, total: total))
        XCTAssertEqual(usage.used, 950 * page)
        XCTAssertEqual(usage.total, total)

        stats.purgeable_count = 830
        XCTAssertEqual(SystemResourceSnapshot.memoryUsage(stats, pageBytes: page, total: total)?.used, 150 * page)
        XCTAssertNil(SystemResourceSnapshot.memoryUsage(stats, pageBytes: 0, total: total))
        XCTAssertNil(SystemResourceSnapshot.memoryUsage(stats, pageBytes: page, total: 100))
        XCTAssertNil(SystemResourceSnapshot.memoryUsage(stats, pageBytes: UInt64.max, total: total))
        XCTAssertNotNil(SystemByteUsage(used: 0, total: 0))
        XCTAssertNil(SystemByteUsage(used: 5, total: 1))
    }

    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0

        func read() -> SystemResourceSnapshot {
            lock.withLock { reads += 1 }
            return SystemResourceSnapshot(memory: nil, swap: SystemByteUsage(used: 0, total: 0))
        }

        var count: Int { lock.withLock { reads } }
    }

    @MainActor func testSystemSamplerFollowsSharedDisplayDemand() async throws {
        let probe = Probe()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metrics = LocalToolMetrics(directory: directory, readResources: { probe.read() })
        defer { metrics.stop() }
        XCTAssertNil(metrics.systemResources)
        metrics.setVisible(true, on: "first", system: true, battery: false, disk: false)
        for _ in 0..<300 where metrics.systemResources == nil { try await Task.sleep(for: .milliseconds(10)) }
        let resources = try XCTUnwrap(metrics.systemResources)
        XCTAssertNil(resources.memory)
        XCTAssertEqual(resources.swap, SystemByteUsage(used: 0, total: 0))
        let samples = probe.count
        XCTAssertGreaterThan(samples, 0)
        metrics.setVisible(true, on: "second", system: true, battery: false, disk: false)
        metrics.setVisible(false, on: "first", system: true, battery: false, disk: false)
        XCTAssertNotNil(metrics.systemResources)
        XCTAssertEqual(probe.count, samples)
        metrics.setVisible(false, on: "second", system: true, battery: false, disk: false)
        XCTAssertNil(metrics.systemResources)
        try await Task.sleep(for: .milliseconds(2_100))
        XCTAssertEqual(probe.count, samples)
    }

    @MainActor func testSystemDetailsRenderValuesInBothLanguages() async throws {
        _ = NSApplication.shared
        let gibibyte: UInt64 = 1 << 30
        let sample = SystemResourceSnapshot(memory: SystemByteUsage(used: 9 * gibibyte, total: 24 * gibibyte),
                                            swap: SystemByteUsage(used: gibibyte, total: 6 * gibibyte))
        for language in [AppLanguage.simplifiedChinese, .english] {
            let loc = Locale(identifier: language.rawValue)
            let view = SystemStatusDetail(cpu: 43, resources: sample)
                .environment(\.dualDockLanguage, language)
                .environment(\.locale, loc)
                .background(Color(nsColor: .windowBackgroundColor))
            let controller = NSHostingController(rootView: view)
            controller.sizingOptions = []
            let size = controller.sizeThatFits(in: CGSize(width: 300, height: 320))
            let rect = NSRect(origin: .zero, size: CGSize(width: ceil(size.width), height: ceil(size.height)))
            let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: language == .english ? .aqua : .darkAqua)
            window.contentView = controller.view
            window.setContentSize(rect.size)
            controller.view.frame = rect
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            controller.view.layoutSubtreeIfNeeded()
            XCTAssertFalse(window.isVisible)
            XCTAssertEqual(rect.width, 270)
            XCTAssertGreaterThan(rect.height, 125)
            let rep = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: rect))
            controller.view.cacheDisplay(in: rect, to: rep)
            defer { window.close() }
            if let path = ProcessInfo.processInfo.environment["DUALDOCK_SYSTEM_RENDER_DIR"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("system-status-\(language.rawValue).png"))
            }
        }
    }
}
