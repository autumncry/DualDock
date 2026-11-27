import SwiftUI
import DualDockCore

/// A read-only mirror until Edit is chosen. The binding supplied in edit mode
/// belongs to the draft; none of the interactions below write the shared store.
struct DockToolsLayoutCanvas: View {
    @Environment(\.dualDockLanguage) private var text
    @ObservedObject var store: DockToolsStore
    @Binding var layout: ShelfLayout
    let isEditing: Bool
    let onDropCatalog: (ToolLibraryItem, UUID?) -> Void
    let onEditDestination: (ShelfLayout.Card) -> Void

    @State private var selected: UUID?
    @State private var shownMembers: [UUID: UUID] = [:]
    @State private var overShelf = false
    @State private var overRemoval = false
    private let unit: CGFloat = 43
    private let gap: CGFloat = 5

    static func draggedSlot(_ text: String) -> UUID? {
        let prefix = "dualdock-slot:"
        guard text.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(text.dropFirst(prefix.count)))
    }

    private var selection: ShelfLayout.Slot? { layout.slots.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: gap) {
                        ForEach(layout.slots) { slot in
                            tile(slot)
                        }
                        if layout.slots.isEmpty {
                            Text(isEditing ? text("从下方组件库拖入工具", "Drag a widget here from the library")
                                           : text("工具页为空", "Your tools page is empty"))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 10)
                    }
                    .frame(minWidth: max(0, proxy.size.width - 16), minHeight: 58, alignment: .leading)
                    .contentShape(Rectangle())
                    .dropDestination(for: String.self) { items, point in
                        guard isEditing, let payload = items.first else { return false }
                        let before = insertionTarget(at: point.x)
                        if let id = Self.draggedSlot(payload),
                           layout.slots.contains(where: { $0.id == id }) {
                            layout.move(id, before: before)
                            selected = id
                            return true
                        }
                        let prefix = "dualdock-library:"
                        guard payload.hasPrefix(prefix),
                              let item = ToolLibraryItem(dragID: String(payload.dropFirst(prefix.count))) else { return false }
                        onDropCatalog(item, before)
                        return true
                    } isTargeted: { overShelf = $0 && isEditing }
                    .padding(.horizontal, 8)
                }
                .scrollBounceBehavior(.basedOnSize)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(overShelf ? Color.accentColor : Color.secondary.opacity(0.24), lineWidth: overShelf ? 2 : 0.5)
                    .allowsHitTesting(false))
            }.frame(height: 62)
            if isEditing {
                if let slot = selection { inspector(slot) }
                Text(text("拖到这里移除", "Drop here to remove"))
                    .font(.system(size: 12)).foregroundStyle(overRemoval ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 23)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3]))
                        .foregroundStyle(overRemoval ? Color.accentColor : Color.secondary.opacity(0.38)).allowsHitTesting(false))
                    .contentShape(Rectangle())
                    .dropDestination(for: String.self) { items, _ in
                        guard let payload = items.first, let id = Self.draggedSlot(payload),
                              layout.slots.contains(where: { $0.id == id }) else { return false }
                        layout.slots.removeAll { $0.id == id }
                        return true
                    } isTargeted: { overRemoval = $0 }
            }
        }
        .onChange(of: isEditing) { _, editing in
            selected = editing ? layout.slots.first?.id : nil
            shownMembers = [:]
        }
        .onChange(of: layout.slots.map(\.id)) { _, ids in
            if isEditing && !ids.contains(where: { $0 == selected }) { selected = ids.first }
        }
    }

    private func length(_ span: Int) -> CGFloat { CGFloat(span) * (unit + gap) - gap }

    private func insertionTarget(at x: CGFloat) -> UUID? {
        var start: CGFloat = 0
        for slot in layout.slots {
            let width = length(slot.span)
            if x < start + width / 2 { return slot.id }
            start += width + gap
        }
        return nil
    }

    private func member(_ slot: ShelfLayout.Slot) -> ShelfLayout.Card? {
        let preferred = shownMembers[slot.id].flatMap { id in slot.cards.first { $0.id == id } }
        let actual = store.selectedCard(in: slot, on: store.referenceDisplayID)
        return preferred ?? actual ?? slot.cards.first
    }

    @ViewBuilder private func tile(_ slot: ShelfLayout.Slot) -> some View {
        if let card = member(slot) {
            let face = CanvasCard(card: card, span: slot.span, data: store.data, metrics: store.metrics, quota: store.quota)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            ZStack(alignment: .trailing) {
                if isEditing {
                    Button { selected = slot.id } label: { face }
                        .buttonStyle(.plain)
                        .accessibilityLabel(text("选择", "Select") + " " + card.title)
                        .overlay {
                            ToolWidgetDragHandle(payload: "dualdock-slot:" + slot.id.uuidString,
                                                 title: card.title, symbol: card.symbol) { selected = slot.id }
                        }
                } else {
                    face
                }
                if isEditing && selected == slot.id {
                    Capsule().fill(Color.accentColor.opacity(0.8)).frame(width: 2, height: 16)
                        .frame(width: 10,height: 42)
                        .contentShape(Rectangle())
                        .overlay {
                            ToolSlotResizeHandle(span: slot.span, pitch: unit + gap) {
                                layout.resize(slot.id, to: $0)
                            }
                        }
                        .help(text("拖动调整宽度", "Drag to resize"))
                        .accessibilityHidden(true)
                }
            }
            .frame(width: length(slot.span),height: 46)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isEditing && selected == slot.id ? Color.accentColor : .clear, lineWidth: 1.5)
                .allowsHitTesting(false))
            .accessibilityIdentifier("tool-canvas-slot-" + slot.id.uuidString)
        }
    }

    private func inspector(_ slot: ShelfLayout.Slot) -> some View {
        let index = layout.slots.firstIndex { $0.id == slot.id } ?? 0
        return HStack(spacing: 8) {
            if slot.cards.count > 1 {
                Menu {
                    ForEach(slot.cards) { card in
                        Button(card.title) { shownMembers[slot.id] = card.id }
                    }
                } label: { Label(member(slot)?.title ?? "", systemImage: "square.stack.3d.up") }
                    .fixedSize()
            } else {
                Text(member(slot)?.title ?? "").lineLimit(1)
            }
            Spacer(minLength: 2)
            Picker(text("宽度", "Width"), selection: Binding(
                get: { layout.slots.first { $0.id == slot.id }?.span ?? slot.span },
                set: { layout.resize(slot.id, to: $0) })) {
                ForEach(1...4, id: \.self) { i in Text(text("\(i) 格", i == 1 ? "1 slot" : "\(i) slots")).tag(i) }
            }.labelsHidden().frame(width: 66)
            Button { layout.move(slot.id, by: -1) } label: { Image(systemName: "chevron.left") }
                .disabled(index == 0).accessibilityLabel(text("向前移", "Move earlier"))
            Button { layout.move(slot.id, by: 1) } label: { Image(systemName: "chevron.right") }
                .disabled(index + 1 == layout.slots.count).accessibilityLabel(text("向后移", "Move later"))
            Menu {
                if index + 1 < layout.slots.count {
                    Button(text("与后一个工具叠放", "Stack with next tool")) { layout.stackWithNext(slot.id) }
                }
                if slot.cards.count > 1 {
                    Button(text("拆分堆栈", "Unstack")) { layout.unstack(slot.id) }
                }
                if let card = member(slot) {
                    if card.destination != nil {
                        Button(text("编辑快捷入口…", "Edit shortcut…")) { onEditDestination(card) }
                    }
                    Button(text("移除", "Remove") + " " + card.title) { layout.removeCard(card.id, from: slot.id) }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(text("卡片选项", "Card options"))
        }
        .controlSize(.small)
        .font(.system(size: 12))
    }
}

/// Track the original width and window coordinate throughout a drag, even
/// after a new card width moves the handle out from under the pointer.
struct ToolSlotResizeHandle: NSViewRepresentable {
    let span: Int
    let pitch: CGFloat
    let onResize: (Int) -> Void

    func makeNSView(context: Context) -> Handle { Handle(frame: .zero) }
    func updateNSView(_ handle: Handle, context: Context) {
        handle.span = span
        handle.pitch = pitch
        handle.onResize = onResize
        handle.setAccessibilityElement(false)
    }

    final class Handle: NSView {
        var span = 1
        var pitch: CGFloat = 48
        var onResize: ((Int) -> Void)?
        private var initial: (x: CGFloat, span: Int)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
        override func mouseDown(with event: NSEvent) { initial = (event.locationInWindow.x, span) }
        override func mouseDragged(with event: NSEvent) {
            guard let initial, pitch > 0 else { return }
            let steps = Int(((event.locationInWindow.x - initial.x) / pitch).rounded())
            let adjusted = min(4, max(1, initial.span + steps))
            if span != adjusted { onResize?(adjusted) }
        }
        override func mouseUp(with event: NSEvent) { initial = nil }
    }
}

private struct CanvasCard: View {
    @Environment(\.dualDockLanguage) private var text
    let card: ShelfLayout.Card
    let span: Int
    @ObservedObject var data: ToolDataService
    @ObservedObject var metrics: LocalToolMetrics
    let quota: AIQuotaService

    @ViewBuilder var body: some View {
        if let provider = card.kind.quotaProvider {
            AIQuotaPreviewView(provider: provider, service: quota, span: span)
                .allowsHitTesting(false)
        } else if card.kind == .systemStatus {
            SystemStatusFace(metrics: metrics, span: span, horizontal: true)
                .padding(.horizontal, span == 1 ? 2 : 5)
        } else if card.kind == .music {
            MusicShelfFace(data: data, compact: span == 1, horizontal: true)
                .padding(.horizontal, 5)
        } else if card.kind == .launcher, let destination = card.destination,
                  destination.kind == .application, let url = destination.url {
            HStack(spacing: 5) {
                Image(nsImage: DockToolArtwork.icon(at: url)).resizable()
                    .aspectRatio(contentMode: .fit).frame(width: 23, height: 23)
                if span > 1 { Text(card.title).font(.system(size: 12, weight: .medium)).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: span == 1 ? .center : .leading)
            .padding(.horizontal, 5)
            .accessibilityLabel(card.title)
        } else if card.kind == .focusTimer && metrics.focusEndsAt != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                contents(detail: formatTime(metrics.focusEndsAt?.timeIntervalSince(context.date) ?? 0))
            }
        } else { contents(detail: detail) }
    }

    private func contents(detail: String) -> some View {
        let layout = span == 1 ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 5))
        return layout {
            Image(systemName: card.symbol).font(.system(size: span == 1 ? 14 : 16))
                .foregroundStyle(Color.accentColor)
            if span > 1 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title).font(.system(size: 12, weight: .medium))
                    if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else if !detail.isEmpty {
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1).padding(.horizontal, span == 1 ? 2 : 7)
        .accessibilityElement(children: .combine).help(card.title + (detail.isEmpty ? "" : " · " + detail))
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let s = max(0,Int(ceil(seconds)))
        return String(format:"%d:%02d",s / 60,s % 60)
    }

    private var detail: String {
        switch card.kind {
        case .music, .systemStatus: return ""
        case .calendar:
            if case .upcoming(let title, _, _) = data.calendar { return title }
            return Date.now.formatted(.dateTime.month().day().locale(Locale(identifier:text.rawValue)))
        case .weather:
            if case .conditions(let reading, let stale) = data.weather {
                return (stale ? "≈" : "") + reading.temperature.formatted(.number.precision(.fractionLength(0))) + "°C"
            }
            return storeWeatherLabel
        case .battery: return metrics.batteryPercent.map { "\(Int($0))%" } ?? "—"
        case .storage: return metrics.diskAvailableBytes.map { ByteCountFormatter.string(fromByteCount:$0,countStyle:.file) } ?? "—"
        case .focusTimer: return formatTime(metrics.focusRemaining)
        case .launcher: return span == 1 ? card.title : ""
        case .codexQuota, .claudeQuota, .geminiQuota: return ""
        }
    }

    private var storeWeatherLabel: String {
        switch data.weather {
        case .loading: return text("更新中", "Updating")
        case .noCity: return text("待选城市", "Choose city")
        default: return "—"
        }
    }
}
