import Foundation
import XCTest
import DualDockCore
@testable import DualDock

final class DockToolsStoreTests: XCTestCase {
    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DualDock3Tools-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    @MainActor func testArrangementPersistsWhileStackChoiceIsIndependentPerDisplay() throws {
        let directory = try fixtureDirectory()
        let store = DockToolsStore(directory: directory)
        let stack = try XCTUnwrap(store.layout.slots.first(where: { $0.cards.count > 1 }))
        let first = try XCTUnwrap(store.selectedCard(in: stack, on: "A"))
        store.advance(stack, on: "B")
        XCTAssertNotEqual(store.selectedCard(in: stack, on: "B")?.id, first.id)
        XCTAssertEqual(store.selectedCard(in: stack, on: "A")?.id, first.id)
        store.edit { $0.resize(stack.id, to: 4); $0.move(stack.id, by: -1) }
        let fresh = DockToolsStore(directory: directory)
        XCTAssertEqual(store.layout, fresh.layout)
        XCTAssertEqual(fresh.layout.slots.first?.span, 4)
        XCTAssertEqual(fresh.layout.slots.first?.id, stack.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("tool-shelf.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("configuration.json").path))
    }

    @MainActor func testDetailLifetimeAndCorruptFilePreservation() throws {
        let directory = try fixtureDirectory()
        let url = directory.appendingPathComponent("tool-shelf.json")
        let previous = Data("preserve this unreadable file".utf8)
        try previous.write(to: url)
        let store = DockToolsStore(directory: directory)
        XCTAssertNotNil(store.saveIssue)
        store.edit { $0.add(.init(kind: .music)) }
        XCTAssertEqual(try Data(contentsOf: url), previous)
        let first = UUID(), second = UUID()
        store.setDetailOpen(true, cardID: first, on: "A")
        store.setDetailOpen(true, cardID: second, on: "A")
        store.setDetailOpen(false, cardID: first, on: "A")
        XCTAssertTrue(store.keepsShelfOpen(on: "A"))
        XCTAssertFalse(store.keepsShelfOpen(on: "B"))
        store.setShelfVisible(false, on: "A")
        XCTAssertFalse(store.keepsShelfOpen(on: "A"))
    }
}
