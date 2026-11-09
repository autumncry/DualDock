import Foundation

public struct AppReference: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var path: String

    public init(id: String, name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

public struct DockEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var apps: [AppReference]
    public var isGroup: Bool

    public init(id: UUID = UUID(), name: String, apps: [AppReference], isGroup: Bool = false) {
        self.id = id
        self.name = name
        self.apps = apps
        self.isGroup = isGroup
    }
}

public enum DockMode: String, Codable, CaseIterable, Sendable {
    case standard
    case runningOnly
}

public struct DockConfiguration: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public var version: Int = currentVersion
    public var entries: [DockEntry] = []
    public var mode: DockMode = .standard
    public var iconSize: Double = 48
    public var iconSpacing: Double = 14
    public var magnificationEnabled: Bool = true
    public var magnificationScale: Double = 5.0 / 3.0
    public var showPreviews: Bool = true
    public var hideSystemDock: Bool = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, entries, mode, iconSize, iconSpacing
        case magnificationEnabled, magnificationScale, showPreviews, hideSystemDock
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        version = max(storedVersion, Self.currentVersion)
        entries = try values.decodeIfPresent([DockEntry].self, forKey: .entries) ?? []
        mode = try values.decodeIfPresent(DockMode.self, forKey: .mode) ?? .standard
        iconSize = try values.decodeIfPresent(Double.self, forKey: .iconSize) ?? 48
        iconSpacing = try values.decodeIfPresent(Double.self, forKey: .iconSpacing) ?? 14
        magnificationEnabled = try values.decodeIfPresent(Bool.self, forKey: .magnificationEnabled) ?? true
        magnificationScale = try values.decodeIfPresent(Double.self, forKey: .magnificationScale) ?? 5.0 / 3.0
        showPreviews = try values.decodeIfPresent(Bool.self, forKey: .showPreviews) ?? true
        hideSystemDock = try values.decodeIfPresent(Bool.self, forKey: .hideSystemDock) ?? false
        normalizeAppearance()
    }

    public mutating func normalizeAppearance() {
        iconSize = iconSize.isFinite ? min(96, max(24, iconSize)) : 48
        iconSpacing = iconSpacing.isFinite ? min(32, max(0, iconSpacing)) : 14
        magnificationScale = magnificationScale.isFinite ? min(2.5, max(1, magnificationScale)) : 5.0 / 3.0
    }

    public var allAppIDs: Set<String> {
        Set(entries.flatMap(\.apps).map(\.id))
    }

    public mutating func insert(_ apps: [AppReference], before target: UUID? = nil) {
        guard target == nil || entries.contains(where: { $0.id == target }) else { return }
        var knownIDs = allAppIDs
        let additions = apps.compactMap { app -> DockEntry? in
            guard knownIDs.insert(app.id).inserted else { return nil }
            return DockEntry(name: app.name, apps: [app])
        }
        let insertionIndex = target.flatMap { id in entries.firstIndex { $0.id == id } } ?? entries.endIndex
        entries.insert(contentsOf: additions, at: insertionIndex)
    }
    public mutating func merge(appID: String, into target: UUID) {
        guard let targetEntry = entries.first(where: { $0.id == target }),
              !targetEntry.apps.contains(where: { $0.id == appID }),
              let app = entries.flatMap(\.apps).first(where: { $0.id == appID }) else { return }

        // Update source and target together so cleaning an empty source cannot
        // discard an empty target while the dragged app is in transit.
        for index in entries.indices {
            if entries[index].id == target {
                if !entries[index].isGroup {
                    entries[index].isGroup = true
                    entries[index].name = "应用组"
                }
                entries[index].apps.append(app)
            } else {
                entries[index].apps.removeAll { $0.id == appID }
            }
        }
        entries.removeAll { $0.apps.isEmpty }
    }

    public mutating func moveEntry(id: UUID, before target: UUID?) {
        guard id != target,
              target == nil || entries.contains(where: { $0.id == target }),
              let sourceIndex = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: sourceIndex)
        let targetIndex = target.flatMap { id in entries.firstIndex { $0.id == id } } ?? entries.endIndex
        entries.insert(entry, at: targetIndex)
    }

    public mutating func moveAppOut(appID: String, before target: UUID? = nil) {
        guard target == nil || entries.contains(where: { $0.id == target }),
              let sourceIndex = entries.firstIndex(where: { $0.apps.contains { $0.id == appID } }),
              let app = entries[sourceIndex].apps.first(where: { $0.id == appID }) else { return }

        let source = entries[sourceIndex]
        if !source.isGroup {
            moveEntry(id: source.id, before: target)
            return
        }

        removeApp(id: appID)
        // Moving the last member before its own group removes that anchor.
        // Keep the group's original position in that one case.
        let fallbackIndex = target == source.id ? min(sourceIndex, entries.count) : entries.endIndex
        let targetIndex = target.flatMap { id in entries.firstIndex { $0.id == id } } ?? fallbackIndex
        entries.insert(DockEntry(name: app.name, apps: [app]), at: targetIndex)
    }

    public mutating func moveMember(id: String, before target: String?, groupID: UUID) {
        guard id != target,
              let groupIndex = entries.firstIndex(where: { $0.id == groupID && $0.isGroup }),
              target == nil || entries[groupIndex].apps.contains(where: { $0.id == target }),
              let sourceIndex = entries[groupIndex].apps.firstIndex(where: { $0.id == id }) else { return }

        let app = entries[groupIndex].apps.remove(at: sourceIndex)
        let targetIndex = target.flatMap { id in entries[groupIndex].apps.firstIndex { $0.id == id } }
            ?? entries[groupIndex].apps.endIndex
        entries[groupIndex].apps.insert(app, at: targetIndex)
    }

    public mutating func removeApp(id: String) {
        for index in entries.indices {
            entries[index].apps.removeAll { $0.id == id }
        }
        entries.removeAll { $0.apps.isEmpty }
    }

    public mutating func removeEntry(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    public mutating func renameGroup(id: UUID, name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let index = entries.firstIndex(where: { $0.id == id && $0.isGroup }) else { return }
        entries[index].name = trimmedName
    }

    public mutating func ungroup(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.isGroup }) else { return }
        let group = entries.remove(at: index)
        let individualEntries = group.apps.map { DockEntry(name: $0.name, apps: [$0]) }
        entries.insert(contentsOf: individualEntries, at: index)
    }
}
