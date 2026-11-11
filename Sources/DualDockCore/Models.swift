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
    public static let currentVersion = 8
    public var version: Int = currentVersion
    public var entries: [DockEntry] = []
    public var mode: DockMode = .standard
    public var iconSize: Double = 48
    public var iconSpacing: Double = 14
    /// Legacy spacing baseline retained for migration to explicit manual width.
    public var dockWidthReferenceSpacing: Double = 14
    /// Saved manual width, retained during automatic mode. Nil values are initialized once using
    /// the live application row, before the app first renders and saves them.
    public var dockWidth: Double?
    /// Optional content-driven width; the stored dockWidth remains the manual choice.
    public var autoAdjustWidth: Bool = false
    public var manualIconScale: Double = 1
    public var synchronizeSizes: Bool = true
    public var displaySettings: [String: DockDisplaySettings] = [:]
    /// Keep the persisted compatibility key while upgrading its semantics.
    public var adaptiveSizing: Bool {
        get { autoAdjustWidth }
        set { autoAdjustWidth = newValue }
    }
    public var magnificationEnabled: Bool = true
    public var magnificationScale: Double = 5.0 / 3.0
    /// Influence radius in icon-center distances; independent of peak size.
    public var magnificationRadius: Double = 2.5
    public var showPreviews: Bool = true
    public var showBadges: Bool = true
    public var hideSystemDock: Bool = false
    public var autoHideWhenObstructed: Bool = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, entries, mode, iconSize, iconSpacing, dockWidthReferenceSpacing, dockWidth, autoAdjustWidth
        case manualIconScale, synchronizeSizes, displaySettings
        case magnificationEnabled, magnificationScale, magnificationRadius, showPreviews, showBadges, hideSystemDock, autoHideWhenObstructed
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        version = max(storedVersion, Self.currentVersion)
        entries = try values.decodeIfPresent([DockEntry].self, forKey: .entries) ?? []
        mode = try values.decodeIfPresent(DockMode.self, forKey: .mode) ?? .standard
        iconSize = try values.decodeIfPresent(Double.self, forKey: .iconSize) ?? 48
        if storedVersion < 5, iconSize.isFinite { iconSize = min(96, iconSize) }
        iconSpacing = try values.decodeIfPresent(Double.self, forKey: .iconSpacing) ?? 14
        // Preserve an existing installation's width at migration. Once stored,
        // this baseline remains independent from later spacing-slider changes.
        dockWidthReferenceSpacing = try values.decodeIfPresent(Double.self, forKey: .dockWidthReferenceSpacing) ?? iconSpacing
        dockWidth = try values.decodeIfPresent(Double.self, forKey: .dockWidth)
        autoAdjustWidth = try values.decodeIfPresent(Bool.self, forKey: .autoAdjustWidth) ?? false
        manualIconScale = try values.decodeIfPresent(Double.self, forKey: .manualIconScale) ?? 1
        synchronizeSizes = try values.decodeIfPresent(Bool.self, forKey: .synchronizeSizes) ?? true
        displaySettings = try values.decodeIfPresent([String: DockDisplaySettings].self, forKey: .displaySettings) ?? [:]
        magnificationEnabled = try values.decodeIfPresent(Bool.self, forKey: .magnificationEnabled) ?? true
        magnificationScale = try values.decodeIfPresent(Double.self, forKey: .magnificationScale) ?? 5.0 / 3.0
        magnificationRadius = try values.decodeIfPresent(Double.self, forKey: .magnificationRadius) ?? 2.5
        showPreviews = try values.decodeIfPresent(Bool.self, forKey: .showPreviews) ?? true
        showBadges = try values.decodeIfPresent(Bool.self, forKey: .showBadges) ?? true
        hideSystemDock = try values.decodeIfPresent(Bool.self, forKey: .hideSystemDock) ?? false
        autoHideWhenObstructed = try values.decodeIfPresent(Bool.self, forKey: .autoHideWhenObstructed) ?? false
        normalizeAppearance()
    }

    public mutating func normalizeAppearance() {
        // Store the requested height independently from currently connected
        // displays. DockSizingLimits clamps it before any rendering arithmetic.
        iconSize = iconSize.isFinite ? max(24, iconSize) : 48
        manualIconScale = manualIconScale.isFinite ? min(1.25, max(0.25, manualIconScale)) : 1
        for key in displaySettings.keys {
            displaySettings[key]?.manualSizing?.normalize()
        }
        if let width = dockWidth, !width.isFinite || width <= 0 { dockWidth = nil }
        iconSpacing = iconSpacing.isFinite ? min(32, max(0, iconSpacing)) : 14
        dockWidthReferenceSpacing = dockWidthReferenceSpacing.isFinite ? min(32, max(0, dockWidthReferenceSpacing)) : 14
        magnificationScale = magnificationScale.isFinite ? min(2.5, max(1, magnificationScale)) : 5.0 / 3.0
        magnificationRadius = magnificationRadius.isFinite ? min(4, max(1, magnificationRadius)) : 2.5
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
