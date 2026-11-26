import XCTest
@testable import DualDockCore

final class DockToolsLayoutTests: XCTestCase {
    func testStackingAndSplittingPreserveCardIdentityAndOrder() throws {
        var layout = DockToolsLayout.initial
        let originalCards = layout.slots.flatMap(\.cards)
        let firstID = layout.slots[0].id
        layout.stackWithNext(firstID)
        XCTAssertEqual(layout.slots.count, 2)
        XCTAssertEqual(layout.slots[0].cards.map(\.kind), [.music, .calendar, .weather])
        XCTAssertEqual(layout.slots[0].id, firstID)
        XCTAssertEqual(layout.slots[0].span, 3)
        layout.unstack(firstID)
        XCTAssertEqual(layout.slots.flatMap(\.cards), originalCards)
        XCTAssertTrue(layout.isValid)
        let roundTrip = try JSONDecoder().decode(DockToolsLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(roundTrip, layout)
    }

    func testMovesRemovalAndWidthBounds() {
        var layout = DockToolsLayout.initial
        let stack = layout.slots[1]
        layout.resize(stack.id, to: 12)
        layout.move(stack.id, by: -1)
        XCTAssertEqual(layout.slots[0].span, 4)
        layout.move(stack.id, by: -1)
        XCTAssertEqual(layout.slots[0].id, stack.id)
        layout.resize(stack.id, to: 0)
        XCTAssertEqual(layout.slots[0].span, 1)
        for item in stack.cards { layout.removeCard(item.id, from: stack.id) }
        XCTAssertFalse(layout.slots.contains(where: { $0.id == stack.id }))
        XCTAssertTrue(layout.isValid)
    }

    func testShortcutsPreserveLiteralNamesAndOnlyWebLinksOpenAsWebsites() throws {
        let shortcut = DockToolsLayout.Destination(kind: .shortcut, value: "我的 Focus & Travel? #1", name: "Focus")
        let url = try XCTUnwrap(shortcut.url)
        XCTAssertEqual(url.scheme, "shortcuts")
        XCTAssertEqual(url.host, "run-shortcut")
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.queryItems?.first?.value, shortcut.value)
        XCTAssertNil(DockToolsLayout.Destination(kind: .website, value: "file:///tmp/items", name: "x").url)
        XCTAssertNil(DockToolsLayout.Destination(kind: .website, value: "unknown", name: "x").url)
        XCTAssertNil(DockToolsLayout.Destination(kind: .file, value: "relative/file", name: "x").url)
        XCTAssertEqual(DockToolsLayout.Destination(kind: .website, value: "https://example.org/a", name: "x").url?.host, "example.org")
    }

    func testInvalidCardIdentitiesAndEmptyStacksAreRejected() {
        let card = DockToolsLayout.Card(kind: .music)
        XCTAssertFalse(DockToolsLayout(slots: [.init(span: 1, cards: [card, card])]).isValid)
        XCTAssertFalse(DockToolsLayout(slots: [.init(span: 1, cards: [])]).isValid)
        XCTAssertFalse(DockToolsLayout(slots: [.init(span: 1, cards: [.init(kind: .launcher)])]).isValid)
        XCTAssertTrue(DockToolsLayout(slots: []).isValid)
    }
}
