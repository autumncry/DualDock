import Foundation
import DualDockCore

@MainActor
final class PreferenceFixture {
    var values: [String: Any] = [:]
    var syncFailuresRemaining = 0
    var restartFailuresRemaining = 0
    var writes = 0
    var restarts = 0
    var environment: SystemDockService.Environment {
        .init(read: { self.values[$0] }, write: { key, value in
            self.writes += 1
            self.values[key] = value
        }, synchronize: {
            if self.syncFailuresRemaining > 0 {
                self.syncFailuresRemaining -= 1
                return false
            }
            return true
        }, restart: {
            self.restarts += 1
            if self.restartFailuresRemaining > 0 {
                self.restartFailuresRemaining -= 1
                throw NSError(domain: "mock-restart", code: 1)
            }
        })
    }
}

@main
struct SystemDockChecks {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("Run via script/check_system_dock.sh with its temporary directory")
        }
        let temporaryDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var count = 0
        func scenario(_ name: String, _ check: (URL, PreferenceFixture, SystemDockService) throws -> Void) throws {
            let path = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: path) }
            let fixture = PreferenceFixture()
            let service = SystemDockService(directory: path, environment: fixture.environment)
            try check(path, fixture, service)
            count += 1
            print("PASS \(name)")
        }
        func mustThrow(_ fn: () throws -> Void) {
            do { try fn(); fatalError("Expected an error") } catch {}
        }
        try scenario("missing keys restore as absent; repeated enable preserves snapshot") { _, env, svc in
            try svc.setHidden(true)
            assert((env.values["autohide"] as? NSNumber)?.boolValue == true)
            assert((env.values["autohide-delay"] as? NSNumber)?.doubleValue == 1000)
            assert(svc.hasRecoveryRecord)
            let firstWrites = env.writes
            try svc.setHidden(true)
            assert(env.writes == firstWrites)
            try svc.restore()
            assert(env.values.isEmpty)
            assert(!svc.hasRecoveryRecord)
            assert(env.restarts == 3)
        }
        try scenario("already suppressed Dock remains owned by the original settings provider") { _, env, svc in
            env.values = ["autohide": true, "autohide-delay": 1000.0]
            try svc.setHidden(true)
            try svc.setHidden(true)
            assert(svc.isSuppressed && !svc.hasRecoveryRecord)
            try svc.restore()
            assert(env.writes == 0 && env.restarts == 0)
        }
        try scenario("deferred enable snapshots the restored, ordinary auto-hide settings") { _, env, svc in
            env.values = ["autohide": true, "autohide-delay": 2000.0]
            try svc.setHidden(true)
            assert(!svc.hasRecoveryRecord && env.writes == 0)
            env.values = ["autohide": true, "autohide-delay": 0.125]
            try svc.setHidden(true)
            assert(svc.hasRecoveryRecord && env.restarts == 1)
            try svc.setHidden(false)
            assert((env.values["autohide"] as? NSNumber)?.boolValue == true)
            assert((env.values["autohide-delay"] as? NSNumber)?.doubleValue == 0.125)
        }
        try scenario("recovery after a single key write preserves a dormant long delay") { _, env, svc in
            env.values = ["autohide": false, "autohide-delay": 2000.0]
            try svc.setHidden(true)
            // Recreate a crash after writing autohide, before changing the delay.
            env.values["autohide-delay"] = 2000.0
            try svc.recoverIfNeeded()
            assert((env.values["autohide"] as? NSNumber)?.boolValue == false)
            assert((env.values["autohide-delay"] as? NSNumber)?.doubleValue == 2000.0)
            assert(!svc.hasRecoveryRecord)
        }
        try scenario("another utility with a longer delay keeps its enabled flag on recovery") { _, env, svc in
            env.values = ["autohide": false, "autohide-delay": 0.2]
            try svc.setHidden(true)
            env.values["autohide-delay"] = 4000.0
            let writes = env.writes, restarts = env.restarts
            try svc.restore()
            assert((env.values["autohide"] as? NSNumber)?.boolValue == true)
            assert((env.values["autohide-delay"] as? NSNumber)?.doubleValue == 4000.0)
            assert(env.writes == writes && env.restarts == restarts && !svc.hasRecoveryRecord)
        }
        try scenario("restore preserves a setting changed by the user") { _, env, svc in
            env.values = ["autohide": false, "autohide-delay": 0.2, "orientation": "left"]
            try svc.setHidden(true)
            env.values["autohide-delay"] = 2.0
            try svc.restore()
            assert((env.values["autohide"] as? NSNumber)?.boolValue == false)
            assert((env.values["autohide-delay"] as? NSNumber)?.doubleValue == 2)
            assert(env.values["orientation"] as? String == "left")
        }
        try scenario("new instance recovers journal after interrupted hidden session") { path, env, svc in
            env.values = ["autohide": false]
            try svc.setHidden(true)
            let restarted = SystemDockService(directory: path, environment: env.environment)
            try restarted.recoverIfNeeded()
            assert((env.values["autohide"] as? NSNumber)?.boolValue == false)
            assert(env.values["autohide-delay"] == nil)
            assert(!restarted.hasRecoveryRecord)
        }
        try scenario("synchronize failure rolls back and propagates error") { _, env, svc in
            env.values = ["autohide": false, "autohide-delay": 0.5]
            env.syncFailuresRemaining = 1
            mustThrow { try svc.setHidden(true) }
            assert((env.values["autohide"] as? NSNumber)?.boolValue == false)
            assert((env.values["autohide-delay"] as? NSNumber)?.doubleValue == 0.5)
            assert(!svc.hasRecoveryRecord)
        }
        try scenario("hide restart failure rolls back and propagates error") { _, env, svc in
            env.values = ["autohide": false]
            env.restartFailuresRemaining = 1
            mustThrow { try svc.setHidden(true) }
            assert((env.values["autohide"] as? NSNumber)?.boolValue == false)
            assert(env.values["autohide-delay"] == nil)
            assert(!svc.hasRecoveryRecord)
        }
        try scenario("failed restore restart is retried even after preferences restored") { _, env, svc in
            try svc.setHidden(true)
            env.restartFailuresRemaining = 1
            mustThrow { try svc.restore() }
            assert(env.values.isEmpty)
            assert(svc.hasRecoveryRecord)
            let before = env.restarts
            try svc.recoverIfNeeded()
            assert(env.restarts == before + 1)
            assert(!svc.hasRecoveryRecord)
        }
        try scenario("failed restore synchronization retains journal for retry") { _, env, svc in
            try svc.setHidden(true)
            env.syncFailuresRemaining = 1
            mustThrow { try svc.restore() }
            assert(svc.hasRecoveryRecord)
            try svc.recoverIfNeeded()
            assert(env.values.isEmpty)
            assert(!svc.hasRecoveryRecord)
        }
        try scenario("corrupt journal never writes preferences") { path, env, svc in
            try Data("broken JSON".utf8).write(to: path.appendingPathComponent("system-dock-recovery.json"))
            mustThrow { try svc.restore() }
            mustThrow { try svc.setHidden(true) }
            assert(env.writes == 0 && env.restarts == 0)
            assert(svc.hasRecoveryRecord)
        }
        try scenario("journal with unexpected key is rejected before any write") { path, env, svc in
            try svc.setHidden(true)
            let journalURL = path.appendingPathComponent("system-dock-recovery.json")
            var journal = try JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as! [String: Any]
            var changes = journal["changes"] as! [[String: Any]]
            changes[0]["key"] = "orientation"
            journal["changes"] = changes
            try JSONSerialization.data(withJSONObject: journal).write(to: journalURL)
            let before = env.writes
            mustThrow { try svc.restore() }
            assert(env.writes == before)
            assert(svc.hasRecoveryRecord)
        }
        try scenario("enable after failed hide and rollback restarts really reapplies hiding") { _, env, svc in
            env.values = ["autohide": false, "autohide-delay": 0.5]
            env.restartFailuresRemaining = 2
            mustThrow { try svc.setHidden(true) }
            assert(svc.hasRecoveryRecord)
            assert((env.values["autohide"] as? NSNumber)?.boolValue == false)
            assert((env.values["autohide-delay"] as? NSNumber)?.doubleValue == 0.5)
            try svc.setHidden(true)
            assert((env.values["autohide"] as? NSNumber)?.boolValue == true)
            assert((env.values["autohide-delay"] as? NSNumber)?.doubleValue == 1000)
            assert(svc.hasRecoveryRecord)
            try svc.restore()
            assert((env.values["autohide"] as? NSNumber)?.boolValue == false)
            assert((env.values["autohide-delay"] as? NSNumber)?.doubleValue == 0.5)
            assert(!svc.hasRecoveryRecord)
        }
        print("\(count) system Dock checks passed; no actual Dock preferences changed")
    }
}
