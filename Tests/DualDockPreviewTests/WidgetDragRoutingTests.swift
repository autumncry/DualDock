import AppKit
import SwiftUI
import XCTest
import DualDockCore
@testable import DualDock

/// Exercise hit ownership, native drag items/pasteboard, registered AppKit drop
/// destinations and the resize handle without posting input to the desktop.
final class WidgetDragRoutingTests: XCTestCase {
    @MainActor func testAddReorderResizeAndRemoveThroughNativeEditor() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DockToolsStore(directory: directory)
        defer { store.stop() }
        let fixture = WidgetDraftFixture()
        let host = NSHostingView(rootView: DragFixtureView(fixture: fixture, store: store))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 600, height: 450),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func waitFor(_ predicate: () -> Bool) async throws {
            for _ in 0..<200 {
                host.layoutSubtreeIfNeeded()
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Native editor did not reflect the drop within two seconds")
        }
        func source(_ payload: String) -> ToolWidgetDragHandle.Handle? {
            descendants(host).compactMap { $0 as? ToolWidgetDragHandle.Handle }.first { $0.payload == payload }
        }
        func point(_ view: NSView) -> CGPoint {
            view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        }
        func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        func checkHit(_ view: NSView, at point: NSPoint) {
            XCTAssertIdentical(host.hitTest(host.superview?.convert(point, from: nil) ?? point), view)
        }
        func drop(_ payload: String, shelf: Bool, atStart: Bool = false) throws {
            let handle = try XCTUnwrap(source(payload))
            let origin = point(handle)
            checkHit(handle, at: origin)
            handle.mouseDown(with: try event(.leftMouseDown, at: origin))
            XCTAssertNil(handle.dragItem(at: CGPoint(x: origin.x + 1, y: origin.y)))
            let item = try XCTUnwrap(handle.dragItem(at: CGPoint(x: origin.x + 8, y: origin.y)))
            let writer = try XCTUnwrap(item.item as? NSPasteboardWriting)
            let destination = try XCTUnwrap(descendants(host).first {
                !$0.registeredDraggedTypes.isEmpty && ($0.enclosingScrollView != nil) == shelf
            })
            let x = atStart ? destination.bounds.minX + 2 : destination.bounds.maxX - 2
            let location = destination.convert(CGPoint(x: x, y: destination.bounds.midY), to: nil)
            let drag = WidgetFixtureDrag(window: window, point: location, writer: writer)
            XCTAssertFalse(destination.draggingEntered(drag).isEmpty)
            XCTAssertFalse(destination.draggingUpdated(drag).isEmpty)
            XCTAssertTrue(destination.prepareForDragOperation(drag))
            XCTAssertTrue(destination.performDragOperation(drag))
            destination.concludeDragOperation(drag)
        }

        let original = try XCTUnwrap(fixture.layout.slots.first?.id)
        let battery = "dualdock-library:widget.battery"
        try await waitFor { source(battery) != nil }
        try drop(battery, shelf: true)
        try await waitFor { fixture.layout.slots.count == 2 }
        let slot = try XCTUnwrap(fixture.layout.slots.last)
        XCTAssertEqual(slot.cards.first?.kind, .battery)
        let payload = "dualdock-slot:" + slot.id.uuidString
        try await waitFor { source(payload) != nil }
        try drop(payload, shelf: true, atStart: true)
        try await waitFor { fixture.layout.slots.map(\.id) == [slot.id, original] }

        let selected = try XCTUnwrap(source(payload))
        let center = point(selected)
        selected.mouseDown(with: try event(.leftMouseDown, at: center))
        selected.mouseUp(with: try event(.leftMouseUp, at: center))
        try await waitFor { descendants(host).contains { $0 is ToolSlotResizeHandle.Handle } }
        let resize = try XCTUnwrap(descendants(host).compactMap { $0 as? ToolSlotResizeHandle.Handle }.first)
        let grip = point(resize)
        checkHit(resize, at: grip)
        resize.mouseDown(with: try event(.leftMouseDown, at: grip))
        resize.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: grip.x + 96, y: grip.y)))
        try await waitFor { fixture.layout.slots.first?.span == 3 }
        resize.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: grip.x + 96, y: grip.y)))

        try drop(payload, shelf: false)
        try await waitFor { fixture.layout.slots.map(\.id) == [original] }
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("tool-shelf.json").path))
    }
}

@MainActor private final class WidgetDraftFixture: ObservableObject {
    @Published var layout = ShelfLayout(slots: [.init(span: 2, cards: [.init(kind: .systemStatus)])])
}

private struct DragFixtureView: View {
    @ObservedObject var fixture: WidgetDraftFixture
    let store: DockToolsStore
    var body: some View {
        VStack {
            DockToolsLayoutCanvas(store: store, layout: $fixture.layout, isEditing: true, onDropCatalog: { item, before in
                if case .widget(let kind) = item { fixture.layout.add(.init(kind: kind), before: before) }
            }, onEditDestination: { _ in })
            DockToolsLibrary(query: "", layout: fixture.layout, isEditing: true, category: .constant(.system),
                             showsCategoryStrip: false, add: { _ in })
        }.frame(width: 600, height: 450)
    }
}

private final class WidgetFixtureDrag: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint
    let draggingPasteboard = NSPasteboard.withUniqueName()
    @MainActor init(window: NSWindow, point: NSPoint, writer: NSPasteboardWriting) {
        draggingDestinationWindow = window
        draggingLocation = point
        super.init()
        draggingPasteboard.writeObjects([writer])
    }
    deinit { draggingPasteboard.releaseGlobally() }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move] }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?,
        classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var stop: ObjCBool = false
        for (i, object) in (draggingPasteboard.readObjects(forClasses: classes, options: searchOptions) ?? []).enumerated() {
            if let writer = object as? NSPasteboardWriting { block(NSDraggingItem(pasteboardWriter: writer), i, &stop) }
            if stop.boolValue { break }
        }
    }
}
