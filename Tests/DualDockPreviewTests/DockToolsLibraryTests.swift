import Foundation
import XCTest
import DualDockCore
@testable import DualDock

final class DockToolsLibraryTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WidgetLibrary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCatalogBilingualSearchAndDraggableIdentityRoundTrip() {
        XCTAssertEqual(ToolLibraryItem.matching(category: .ai, query: "claude 余量"), [.widget(.claudeQuota)])
        XCTAssertEqual(ToolLibraryItem.matching(category: .life, query: "calendar"), [.widget(.calendar)])
        XCTAssertEqual(ToolLibraryItem.matching(category: .system, query: "内存 swap"), [.widget(.systemStatus)])
        XCTAssertEqual(ToolLibraryItem.matching(category: .life, query: "月视图 week"), [.widget(.calendar)])
        XCTAssertTrue(ToolLibraryItem.matching(category: .system, query: "Gemini").isEmpty)
        XCTAssertEqual(Set(ToolLibraryItem.matching(category: .ai, query: "")), [.widget(.codexQuota), .widget(.claudeQuota), .widget(.geminiQuota)])
        for item in ToolLibraryItem.items { XCTAssertEqual(ToolLibraryItem(dragID: item.dragID), item) }
        XCTAssertNil(ToolLibraryItem(dragID: "../../../arbitrary"))
    }

    @MainActor func testRealShelvesAndDiskChangeOnlyOnConfirmation() throws {
        let directory = try fixture()
        let store = DockToolsStore(directory: directory)
        defer { store.stop() }
        let original = store.layout
        let all = original.slots.map(\.id)
        var canceled = store.beginEditing()
        canceled.layout.add(.init(kind: .codexQuota), before: all[0])
        canceled.layout.move(all[1], before: all[0])
        canceled.layout.resize(all[0], to: 4)
        canceled.layout.removeCard(original.slots[2].cards[0].id, from: all[2])
        XCTAssertNotEqual(canceled.layout, store.layout)
        store.discardDraft()
        XCTAssertEqual(store.layout, original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("tool-shelf.json").path))

        var draft = store.beginEditing()
        draft.layout.add(.init(kind: .geminiQuota), before: all[0])
        draft.layout.add(.init(kind: .geminiQuota), before: nil)
        draft.layout.move(all[0], before: nil)
        draft.layout.resize(all[1], to: 4)
        XCTAssertTrue(store.commit(draft))
        XCTAssertEqual(store.layout.slots.first?.cards.first?.kind, .geminiQuota)
        XCTAssertEqual(store.layout.slots.filter { $0.cards.contains { $0.kind == .geminiQuota } }.count, 1)
        XCTAssertEqual(store.layout.slots.last?.id, all[0])
        XCTAssertEqual(DockToolsStore(directory: directory).layout, draft.layout)
        for slot in store.layout.slots {
            XCTAssertEqual(store.selectedCard(in: slot, on: "A"), store.selectedCard(in: slot, on: "B"))
        }
    }

    @MainActor func testConfiguredDestinationAndCityRemainInDraftUntilDone() throws {
        let directory = try fixture()
        let store = DockToolsStore(directory: directory)
        defer { store.stop() }
        var draft = store.beginEditing()
        let destination = DockToolsLayout.Destination(kind: .website, value: "https://example.org", name: "Workspace")
        let card = DockToolsLayout.Card(kind: .launcher, destination: destination)
        let city = ToolWeatherCity(id: 123, name: "Example", region: nil, country: nil, latitude: 1, longitude: 2)
        draft.layout.add(card, before: draft.layout.slots.first?.id)
        draft.city = city
        XCTAssertNil(store.city)
        XCTAssertFalse(store.layout.slots.flatMap(\.cards).contains(card))
        XCTAssertTrue(store.commit(draft))
        let fresh = DockToolsStore(directory: directory)
        defer { fresh.stop() }
        XCTAssertEqual(fresh.city, city)
        XCTAssertEqual(fresh.layout.slots.first?.cards.first, card)
    }

    @MainActor func testConflictingDraftCannotOverwriteExternalLayout() throws {
        let directory = try fixture()
        let store = DockToolsStore(directory: directory)
        defer { store.stop() }
        var draft = store.beginEditing()
        draft.layout.add(.init(kind: .storage))
        let second = DockToolsStore(directory: directory)
        second.edit { $0.add(.init(kind: .battery)) }
        second.stop()
        XCTAssertFalse(store.commit(draft))
        XCTAssertNotNil(store.saveIssue)
        XCTAssertTrue(store.layout.contains(.battery))
        XCTAssertFalse(store.layout.contains(.storage))
        XCTAssertEqual(DockToolsStore(directory: directory).layout, second.layout)
    }
}
