import Foundation

/// App and widget layouts are intentionally separate. An app's running state
/// never adds or removes a tool from the shelf.
public struct DockToolsLayout: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case music, calendar, weather, launcher
        case systemStatus, battery, storage, focusTimer
        case codexQuota, claudeQuota, geminiQuota, cursorQuota

        public var defaultSpan: Int {
            switch self {
            case .music, .codexQuota, .claudeQuota, .geminiQuota, .cursorQuota: return 3
            case .calendar, .systemStatus, .storage, .focusTimer: return 2
            case .weather, .launcher, .battery: return 1
            }
        }
    }

    public struct Destination: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, CaseIterable, Sendable {
            case application, file, website, shortcut
        }
        public var kind: Kind
        public var value: String
        public var name: String
        public init(kind: Kind, value: String, name: String) {
            self.kind = kind
            self.value = value
            self.name = name
        }

        public var url: URL? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            switch kind {
            case .application, .file:
                guard trimmed.hasPrefix("/") else { return nil }
                return URL(fileURLWithPath: trimmed).standardizedFileURL
            case .website:
                guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
                      ["https", "http"].contains(scheme), url.host?.isEmpty == false else { return nil }
                return url
            case .shortcut:
                var components = URLComponents()
                components.scheme = "shortcuts"
                components.host = "run-shortcut"
                components.queryItems = [URLQueryItem(name: "name", value: trimmed)]
                return components.url
            }
        }
    }

    public struct Card: Identifiable, Codable, Equatable, Sendable {
        public let id: UUID
        public let kind: Kind
        public let destination: Destination?
        public init(id: UUID = UUID(), kind: Kind, destination: Destination? = nil) {
            self.id = id
            self.kind = kind
            self.destination = destination
        }
    }

    public struct Slot: Identifiable, Codable, Equatable, Sendable {
        public let id: UUID
        public var span: Int
        public var cards: [Card]
        public init(id: UUID = UUID(), span: Int, cards: [Card]) {
            self.id = id
            self.span = min(4, max(1, span))
            self.cards = cards
        }
    }

    public var slots: [Slot]

    public init(slots: [Slot]) {
        self.slots = slots
    }

    public static var initial: Self {
        Self(slots: [
            Slot(span: 3, cards: [Card(kind: .music)]),
            Slot(span: 3, cards: [Card(kind: .calendar), Card(kind: .weather)]),
            Slot(span: 1, cards: [Card(kind: .launcher, destination:
                .init(kind: .application, value: "/System/Applications/Shortcuts.app", name: "Shortcuts"))])
        ])
    }

    public func contains(_ kind: Kind) -> Bool {
        slots.contains { $0.cards.contains { $0.kind == kind } }
    }

    public mutating func add(_ card: Card, before beforeID: UUID? = nil) {
        guard card.kind == .launcher || !contains(card.kind) else { return }
        let slot = Slot(span: card.kind.defaultSpan, cards: [card])
        let index = beforeID.flatMap { id in slots.firstIndex { $0.id == id } } ?? slots.endIndex
        slots.insert(slot, at: index)
    }

    public mutating func move(_ id: UUID, by amount: Int) {
        guard let old = slots.firstIndex(where: { $0.id == id }) else { return }
        let new = old + amount
        guard slots.indices.contains(new), old != new else { return }
        slots.insert(slots.remove(at: old), at: new)
    }

    public mutating func move(_ id: UUID, before beforeID: UUID?) {
        guard id != beforeID, let old = slots.firstIndex(where: { $0.id == id }) else { return }
        let slot = slots.remove(at: old)
        let index = beforeID.flatMap { next in slots.firstIndex { $0.id == next } } ?? slots.endIndex
        slots.insert(slot, at: index)
    }

    public mutating func resize(_ id: UUID, to span: Int) {
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return }
        slots[index].span = min(4, max(1, span))
    }

    /// Keep the leading slot's position, width, and identity. Merging makes
    /// the following slot's cards part of the same fixed-size container.
    public mutating func stackWithNext(_ id: UUID) {
        guard let index = slots.firstIndex(where: { $0.id == id }), index + 1 < slots.count else { return }
        let next = slots.remove(at: index + 1)
        slots[index].cards.append(contentsOf: next.cards)
    }

    public mutating func unstack(_ id: UUID) {
        guard let index = slots.firstIndex(where: { $0.id == id }), slots[index].cards.count > 1 else { return }
        let old = slots[index]
        slots[index].cards = [old.cards[0]]
        slots.insert(contentsOf: old.cards.dropFirst().map { Slot(span: old.span, cards: [$0]) }, at: index + 1)
    }

    public mutating func removeCard(_ id: UUID, from slotID: UUID) {
        guard let index = slots.firstIndex(where: { $0.id == slotID }) else { return }
        slots[index].cards.removeAll { $0.id == id }
        if slots[index].cards.isEmpty { slots.remove(at: index) }
    }

    public var isValid: Bool {
        let slotIDs = slots.map(\.id)
        let cards = slots.flatMap(\.cards)
        return Set(slotIDs).count == slotIDs.count && Set(cards.map(\.id)).count == cards.count &&
            slots.allSatisfy { (1...4).contains($0.span) && !$0.cards.isEmpty } &&
            cards.allSatisfy { $0.kind == .launcher ? $0.destination?.url != nil : $0.destination == nil }
    }
}
