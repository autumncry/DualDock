import Foundation
import XCTest
@testable import DualDockCore

final class ModelTests: XCTestCase {
    private let safari = AppReference(id: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app")
    private let notes = AppReference(id: "com.apple.Notes", name: "备忘录", path: "/System/Applications/Notes.app")
    private let terminal = AppReference(id: "com.apple.Terminal", name: "终端", path: "/System/Applications/Utilities/Terminal.app")

    func testMergingPlainApplicationsCreatesGroupWithoutDuplicateMembership() {
        var configuration = DockConfiguration()
        configuration.insert([safari, notes, terminal])
        let target = configuration.entries[0].id

        configuration.merge(appID: notes.id, into: target)

        XCTAssertEqual(configuration.entries.count, 2)
        XCTAssertEqual(configuration.entries[0].id, target)
        XCTAssertTrue(configuration.entries[0].isGroup)
        XCTAssertFalse(configuration.entries[0].name.isEmpty)
        XCTAssertEqual(configuration.entries[0].apps, [safari, notes])
        XCTAssertEqual(configuration.entries[1].apps, [terminal])
        XCTAssertEqual(configuration.allAppIDs.count, 3)
    }

    func testMovingBetweenGroupsPreservesTargetAndRemovesEmptySource() {
        let source = DockEntry(name: "浏览", apps: [safari], isGroup: true)
        let target = DockEntry(name: "工作", apps: [notes, terminal], isGroup: true)
        var configuration = DockConfiguration()
        configuration.entries = [source, target]

        configuration.merge(appID: safari.id, into: target.id)

        XCTAssertEqual(configuration.entries.count, 1)
        XCTAssertEqual(configuration.entries[0].id, target.id)
        XCTAssertEqual(configuration.entries[0].name, "工作")
        XCTAssertEqual(configuration.entries[0].apps, [notes, terminal, safari])
    }

    func testMergingIntoEmptyGroupDoesNotLoseSourceApplication() {
        let group = DockEntry(name: "工作", apps: [], isGroup: true)
        var configuration = DockConfiguration()
        configuration.entries = [DockEntry(name: safari.name, apps: [safari]), group]

        configuration.merge(appID: safari.id, into: group.id)

        XCTAssertEqual(configuration.entries.count, 1)
        XCTAssertEqual(configuration.entries.first?.id, group.id)
        XCTAssertEqual(configuration.entries.first?.apps, [safari])
        XCTAssertEqual(configuration.entries.first?.name, "工作")
    }

    func testMovingAppOutPreservesReferenceAndRetainsNamedSingleMemberGroup() {
        let group = DockEntry(name: "日常", apps: [safari, notes], isGroup: true)
        let target = DockEntry(name: terminal.name, apps: [terminal])
        var configuration = DockConfiguration()
        configuration.entries = [group, target]

        configuration.moveAppOut(appID: notes.id, before: target.id)

        XCTAssertEqual(configuration.entries.map(\.apps), [[safari], [notes], [terminal]])
        XCTAssertEqual(configuration.entries[0].id, group.id)
        XCTAssertEqual(configuration.entries[0].name, "日常")
        XCTAssertTrue(configuration.entries[0].isGroup)
        XCTAssertFalse(configuration.entries[1].isGroup)
    }

    func testMovingLastMemberBeforeItsOwnGroupPreservesPosition() {
        let group = DockEntry(name: "日常", apps: [notes], isGroup: true)
        var configuration = DockConfiguration()
        configuration.entries = [DockEntry(name: safari.name, apps: [safari]), group,
                                 DockEntry(name: terminal.name, apps: [terminal])]

        configuration.moveAppOut(appID: notes.id, before: group.id)

        XCTAssertEqual(configuration.entries.map(\.apps), [[safari], [notes], [terminal]])
        XCTAssertFalse(configuration.entries[1].isGroup)
    }

    func testRunningOnlyRoundTripPreservesLayoutAndSettings() throws {
        var configuration = DockConfiguration()
        configuration.entries = [DockEntry(name: "日常", apps: [safari, notes], isGroup: true)]
        configuration.iconSize = 56
        configuration.showPreviews = false
        configuration.hideSystemDock = true
        let savedEntries = configuration.entries
        configuration.mode = .runningOnly

        let encoded = try JSONEncoder().encode(configuration)
        var restored = try JSONDecoder().decode(DockConfiguration.self, from: encoded)

        XCTAssertEqual(restored, configuration)
        restored.mode = .standard
        XCTAssertEqual(restored.entries, savedEntries)
    }

    func testInsertingDuplicatesAndDroppingWithinOwnGroupAreNoOps() {
        var configuration = DockConfiguration()
        configuration.insert([safari, safari, notes])
        XCTAssertEqual(configuration.entries.count, 2)
        let target = configuration.entries[0].id
        configuration.merge(appID: notes.id, into: target)
        let grouped = configuration

        configuration.insert([safari, notes])
        configuration.merge(appID: safari.id, into: target)

        XCTAssertEqual(configuration, grouped)
    }

    func testInvalidTargetsAndMissingSourcesDoNotLoseItems() {
        var configuration = DockConfiguration()
        configuration.entries = [DockEntry(name: "日常", apps: [safari, notes], isGroup: true),
                                 DockEntry(name: terminal.name, apps: [terminal])]
        let original = configuration

        configuration.merge(appID: notes.id, into: UUID())
        configuration.merge(appID: "missing", into: configuration.entries[0].id)
        configuration.moveEntry(id: configuration.entries[0].id, before: UUID())
        configuration.moveAppOut(appID: notes.id, before: UUID())

        XCTAssertEqual(configuration, original)
    }

    func testEntryReorderingHandlesBothDirectionsAndOwnTarget() {
        var configuration = DockConfiguration()
        configuration.insert([safari, notes, terminal])
        let original = configuration.entries
        configuration.moveEntry(id: original[1].id, before: original[1].id)
        XCTAssertEqual(configuration.entries, original)

        configuration.moveEntry(id: original[2].id, before: original[0].id)
        XCTAssertEqual(configuration.entries.map(\.id), [original[2].id, original[0].id, original[1].id])
        configuration.moveEntry(id: original[2].id, before: nil)
        XCTAssertEqual(configuration.entries, original)
    }

    func testUngroupPreservesMemberOrderAndRenameRejectsBlankName() {
        let group = DockEntry(name: "日常", apps: [notes, terminal], isGroup: true)
        var configuration = DockConfiguration()
        configuration.entries = [DockEntry(name: safari.name, apps: [safari]), group]
        configuration.renameGroup(id: group.id, name: "  工作  ")
        configuration.renameGroup(id: group.id, name: " \n ")
        XCTAssertEqual(configuration.entries[1].name, "工作")

        configuration.ungroup(id: group.id)

        XCTAssertEqual(configuration.entries.map(\.apps), [[safari], [notes], [terminal]])
        XCTAssertTrue(configuration.entries.allSatisfy { !$0.isGroup })
        XCTAssertEqual(configuration.entries[1].name, notes.name)
    }

    func testRemovingMemberCleansEmptyGroupAndRemovingEntryKeepsOtherEntries() {
        let group = DockEntry(name: "日常", apps: [safari, notes], isGroup: true)
        let other = DockEntry(name: terminal.name, apps: [terminal])
        var configuration = DockConfiguration()
        configuration.entries = [group, other]

        configuration.removeApp(id: safari.id)
        XCTAssertEqual(configuration.entries[0].apps, [notes])
        configuration.removeApp(id: notes.id)
        XCTAssertEqual(configuration.entries, [other])
        configuration.removeEntry(id: other.id)
        XCTAssertTrue(configuration.entries.isEmpty)
    }

    func testMemberReorderingPreservesMembershipAndRejectsBadTargets() {
        let group = DockEntry(name: "日常", apps: [safari, notes, terminal], isGroup: true)
        var configuration = DockConfiguration()
        configuration.entries = [group]

        configuration.moveMember(id: terminal.id, before: safari.id, groupID: group.id)
        XCTAssertEqual(configuration.entries[0].apps, [terminal, safari, notes])
        configuration.moveMember(id: terminal.id, before: nil, groupID: group.id)
        XCTAssertEqual(configuration.entries, [group])

        configuration.moveMember(id: safari.id, before: safari.id, groupID: group.id)
        configuration.moveMember(id: safari.id, before: "missing", groupID: group.id)
        configuration.moveMember(id: safari.id, before: notes.id, groupID: UUID())
        XCTAssertEqual(configuration.entries, [group])
    }
}
