import Foundation
import XCTest
@testable import DualDock

final class AIQuotaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970:1_800_000_000)
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quota-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }
        return url
    }

    func testCodexReportsRealWindowsWithoutDefaultsOrDuplicateLegacyBucket() throws {
        let input = Data(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":20}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":28,"windowDurationMins":300,"resetsAt":1800003600},"secondary":{"usedPercent":100,"windowDurationMins":10080}},"review":{"limitName":"Review","primary":{"usedPercent":0,"windowDurationMins":15}},"empty":{"primary":{}}}}"#.utf8)
        let r = try AIQuotaParser.codex(input,now:now)
        XCTAssertEqual(r.windows.map(\.remainingPercent),[72,0,100]);XCTAssertEqual(r.windows.map(\.minutes),[300,10080,15])
        XCTAssertNil(r.windows[1].reset);XCTAssertEqual(r.windows[0].reset,now.addingTimeInterval(3600))
        XCTAssertThrowsError(try AIQuotaParser.codex(Data(#"{"rateLimits":{"primary":{"usedPercent":101}}}"#.utf8),now:now))
    }

    func testClaudeWhitelistsLimitsAndMissingRangesAreUnknown() throws {
        let data=Data(#"{"transcript_path":"PRIVATE","session_id":"PRIVATE","context_window":{"remaining_percentage":92},"rate_limits":{"five_hour":{"used_percentage":35,"resets_at":1800000720}}}"#.utf8)
        let r=try AIQuotaParser.claude(data,now:now)
        XCTAssertEqual(r.windows.map(\.remainingPercent),[65]); XCTAssertFalse(String(decoding:try JSONEncoder().encode(r),as:UTF8.self).contains("PRIVATE"))
        XCTAssertTrue(try AIQuotaParser.claude(Data(#"{"context_window":{"remaining_percentage":99}}"#.utf8),now:now).windows.isEmpty)
    }

    func testGeminiTextOnlyConsumesUnambiguousLimitSections() throws {
        let modern=try AIQuotaParser.gemini("Model usage\nPro         ▬▬▬▬▬▬▬    25%  Resets: 1:30 PM (1h 30m)\nFlash Lite    ▬▬▬    90%  Resets: 2 PM (2h)",now:now)
        XCTAssertEqual(modern.windows.map(\.remainingPercent),[75,10])
        XCTAssertEqual(modern.windows.first?.reset,now.addingTimeInterval(5400))
        let legacy=try AIQuotaParser.gemini("│ Model Usage             Reqs              Usage left  │\n│ gemini-2.5-pro             3                 7.5% (resets in 1h) │",now:now)
        XCTAssertEqual(legacy.windows.first?.remainingPercent,7.5);XCTAssertEqual(legacy.windows.first?.reset,now.addingTimeInterval(3600))
        XCTAssertThrowsError(try AIQuotaParser.gemini("Cache Hits 98%\nTokens Total: 881,042",now:now))
        XCTAssertEqual(try AIQuotaParser.gemini("32% used (Limit resets in 2h 40m)\nUsage limit: 1,000",now:now).windows.first?.remainingPercent,68)
        XCTAssertEqual(try AIQuotaParser.gemini("Limit reached, resets in 1m",now:now).windows.first?.remainingPercent,0)
    }

    func testGeminiBucketsKeepUnitsAndRejectInvalidOrUnavailableMetrics() throws {
        let r=try AIQuotaParser.gemini(#"{"buckets":[{"modelId":"Pro","remainingFraction":0.68,"resetTime":"2027-01-01T12:00:00.000Z"},{"modelId":"Flash","remainingAmount":"121","tokenType":"REQUESTS"},{"modelId":"no-value"},{"modelId":"invalid","remainingFraction":-1}]}"#,now:now)
        XCTAssertEqual(r.windows.map(\.label),["Pro","Flash"]);XCTAssertEqual(r.windows[0].remainingPercent,68)
        XCTAssertNotNil(r.windows[0].reset);XCTAssertEqual(r.windows[1].remainingCount,121);XCTAssertNil(r.windows[1].remainingPercent)
        XCTAssertThrowsError(try AIQuotaParser.gemini(#"{"buckets":[{"modelId":"unknown"}]}"#,now:now))
    }

    func testClaudeWrapperPreservesOutputStdinPermissionsOtherSettingsAndUninstalls() throws {
        let base=try scratch(),file=base.appendingPathComponent("settings.json"), dir=base.appendingPathComponent("LocalData")
        let exe=base.appendingPathComponent("helper with ' quote")
        let previous="printf 'state: '; /bin/cat; printf ' done\\n'"
        let original:[String:Any]=["other":["unrelated":true],"statusLine":["type":"command","command":previous,"padding":4]]
        try JSONSerialization.data(withJSONObject:original).write(to:file)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        try "#!/bin/sh\ncat >/dev/null\nexit 1\n".write(to:exe,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:exe.path)
        let token=try AIQuotaClaudeBridge.install(in:file,executable:exe,directory:dir)
        func load() throws -> [String:Any] { try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any]) }
        let entry=try XCTUnwrap(try load()["statusLine"] as? [String:Any])
        XCTAssertEqual(entry["padding"] as? Int,4)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        let command=try XCTUnwrap(entry["command"] as? String)
        let process=Process(),input=Pipe(),output=Pipe()
        process.executableURL=URL(fileURLWithPath:"/bin/sh");process.arguments=["-c",command];process.standardInput=input;process.standardOutput=output
        try process.run();let bytes=Data("{\"a\":1}\n\n".utf8)
        try input.fileHandleForWriting.write(contentsOf:bytes);try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus,0)
        XCTAssertEqual(String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self),"state: {\"a\":1}\n\n done\n")
        var withNewOption=try load();withNewOption["another"]="kept";try JSONSerialization.data(withJSONObject:withNewOption).write(to:file)
        try AIQuotaClaudeBridge.remove(from:file,directory:dir,token:token)
        XCTAssertEqual((try load()["statusLine"] as? [String:Any])?["command"] as? String,previous)
        XCTAssertEqual(try load()["another"] as? String,"kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath:dir.appendingPathComponent(AIQuotaClaudeBridge.connectionFile).path))
    }

    func testClaudeDoesNotOverrideUserReplacementOrRestoreOutdatedSnapshot() throws {
        let base=try scratch(), file=base.appendingPathComponent("settings.json"),dir=base.appendingPathComponent("local")
        let token=try AIQuotaClaudeBridge.install(in:file,executable:base.appendingPathComponent("helper"),directory:dir)
        let q=Data(#"{"rate_limits":{"five_hour":{"used_percentage":10}},"private":"not stored"}"#.utf8)
        try AIQuotaClaudeBridge.capture(bytes:q,directory:dir,token:token,now:now)
        try AIQuotaClaudeBridge.capture(bytes:Data("{}".utf8),directory:dir,token:token,now:now.addingTimeInterval(20))
        try AIQuotaClaudeBridge.capture(bytes:q,directory:dir,token:token,now:now.addingTimeInterval(5))
        let snapshot=dir.appendingPathComponent(AIQuotaClaudeBridge.snapshotFile)
        XCTAssertEqual(try JSONDecoder().decode(AIQuotaSnapshot.self,from:Data(contentsOf:snapshot)).windows,[])
        let changed=Data(#"{"statusLine":{"type":"command","command":"my-new-command"}}"#.utf8)
        try changed.write(to:file)
        try AIQuotaClaudeBridge.remove(from:file,directory:dir,token:token)
        try AIQuotaClaudeBridge.capture(bytes:q,directory:dir,token:token,now:now.addingTimeInterval(30))
        XCTAssertEqual(try Data(contentsOf:file),changed)
        XCTAssertFalse(FileManager.default.fileExists(atPath:snapshot.path))
    }

    func testOverlappingClaudeSnapshotsKeepNewestAndRevokedWritesAreIgnored() throws {
        let base = try scratch(), dir = base.appendingPathComponent("local"), file = base.appendingPathComponent("settings.json")
        let token = try AIQuotaClaudeBridge.install(in:file,executable:base.appendingPathComponent("helper"),directory:dir)
        let epoch = now
        DispatchQueue.concurrentPerform(iterations:12) { index in
            let sample = Data("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":\(index)}}}".utf8)
            do { try AIQuotaClaudeBridge.capture(bytes:sample,directory:dir,token:token,now:epoch.addingTimeInterval(Double(index))) }
            catch { XCTFail("Unexpected capture error: \(error)") }
        }
        let snapshot = dir.appendingPathComponent(AIQuotaClaudeBridge.snapshotFile)
        let latest = try JSONDecoder().decode(AIQuotaSnapshot.self,from:Data(contentsOf:snapshot))
        XCTAssertEqual(latest.windows.first?.remainingPercent,89)
        try AIQuotaClaudeBridge.remove(from:file,directory:dir,token:token)
        let newToken = try AIQuotaClaudeBridge.install(in:file,executable:base.appendingPathComponent("other"),directory:dir)
        XCTAssertNotEqual(newToken,token)
        try AIQuotaClaudeBridge.capture(bytes:Data("{}".utf8),directory:dir,token:token,now:now)
        XCTAssertFalse(FileManager.default.fileExists(atPath:snapshot.path))
    }

    func testCodexClientUsesOnlyReadOnlyRequestsAgainstIsolatedSubprocess() async throws {
        let base=try scratch();let binary=base.appendingPathComponent("codex")
        let script="""
        #!/bin/sh
        IFS= read -r init; case "$init" in *initialize*) ;; *) exit 3 ;; esac
        printf '%s\\n' '{"id":1,"result":{"userAgent":"fixture"}}'
        IFS= read -r initialized; IFS= read -r account
        case "$account" in *account*read*) ;; *) exit 4 ;; esac
        printf '%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt"}}}'
        IFS= read -r limits; case "$limits" in *account*rateLimits*read*) ;; *) exit 5 ;; esac
        printf '%s\\n' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":40,"windowDurationMins":300}}}}'
        IFS= read -r accountAgain; case "$accountAgain" in *account*read*) ;; *) exit 6 ;; esac
        printf '%s\\n' '{"id":4,"result":{"account":{"type":"chatgpt"}}}'
        """
        try script.write(to:binary,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:binary.path)
        let reading=try await AIQuotaCodex.read(binary:binary,environment:["HOME":base.path],timeout:6)
        XCTAssertEqual(reading.windows.first?.remainingPercent,60)
    }

    func testCodexProcessHasBoundedTimeout() async throws {
        let base=try scratch(),exe=base.appendingPathComponent("codex")
        try "#!/bin/sh\nexec /bin/sleep 15\n".write(to:exe,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:exe.path)
        let start=Date()
        do { _=try await AIQuotaCodex.read(binary:exe,environment:["HOME":base.path],timeout:0.2);XCTFail("Timeout missing") }
        catch { XCTAssertEqual(error as? AIQuotaError,.timeout) }
        XCTAssertLessThan(Date().timeIntervalSince(start),3)
    }

    @MainActor func testConsentSharedAcrossDisplaysAndManualPersistence() async throws {
        let base=try scratch();let moment=now
        actor Count { var value=0;func add(){value+=1} }
        let calls=Count()
        let env=AIQuotaService.Environment(codex:{_ in
            await calls.add()
            return try AIQuotaParser.codex(Data(#"{"rateLimits":{"primary":{"usedPercent":22}}}"#.utf8),now:moment)
        },now:{moment},claudeSettings:base.appendingPathComponent("claude.json"),executable:nil)
        let service=AIQuotaService(directory:base,environment:env)
        service.setVisible([.codex,.claude,.gemini],on:"internal")
        service.setVisible([.codex],on:"external")
        let zero=await calls.value;XCTAssertEqual(zero,0)
        service.connectCodex()
        for _ in 0..<60 where service.codexBusy {try await Task.sleep(for:.milliseconds(10))}
        let one=await calls.value;XCTAssertEqual(one,1)
        XCTAssertEqual(service.selected(.codex)?.remainingPercent,78)
        XCTAssertTrue(service.importGemini("Model usage\nFlash    ▬▬    35%  Resets: 1 PM (1h)"))
        service.stop()
        let restored=AIQuotaService(directory:base,environment:env)
        XCTAssertEqual(restored.selected(.gemini)?.remainingPercent,65)
        XCTAssertTrue(restored.isConnected(.codex));XCTAssertNil(restored.selected(.codex))
        restored.disconnect(.gemini);XCTAssertNil(restored.selected(.gemini));restored.stop()
    }
}
