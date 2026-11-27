import XCTest
@testable import DualDock

@MainActor
final class AntigravityRefreshTests: XCTestCase {
    private actor Client {
        var calls = 0
        func read() async throws -> AIQuotaSnapshot {
            calls += 1
            let attempt = calls
            // Even a provider that finishes after cancellation must not publish late data.
            try? await Task.sleep(for: .milliseconds(20))
            if attempt == 3 { throw AIQuotaError.signIn }
            return AIQuotaSnapshot(windows: [
                .init(id: "gemini-5h", label: "Gemini", minutes: 300, remainingPercent: Double(90 - attempt)),
                .init(id: "gemini-weekly", label: "Gemini", minutes: 10080, remainingPercent: Double(80 - attempt))
            ], updated: Date())
        }
    }

    private func waitForRead(_ service: AIQuotaService) async throws {
        for _ in 0..<200 where service.antigravityBusy {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(service.antigravityBusy)
    }

    func testExplicitClicksCoalesceAcrossDisplaysAndNeverMixLiveAndImportedReadings() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("ai-quota-settings.json")
        let legacy = Data(#"{"codexEnabled":false,"pins":{"gemini":"Flash"},"gemini":{"windows":[{"id":"Flash","label":"Flash","remainingPercent":25}],"updated":750000000}}"#.utf8)
        try legacy.write(to: file)
        let client = Client()
        let environment = AIQuotaService.Environment(codex: { _ in throw AIQuotaError.unavailable },
            claudeSettings: dir.appendingPathComponent("claude.json"), executable: nil,
            antigravity: { try await client.read() })
        let service = AIQuotaService(directory: dir, environment: environment)
        defer { service.stop() }
        service.setVisible([.gemini], on: "settings-preview")
        service.setVisible([.gemini], on: "display-a")
        service.setVisible([.gemini], on: "display-b")
        let initial = await client.calls
        XCTAssertEqual(initial, 0)
        XCTAssertNil(service.selected(.gemini))
        XCTAssertEqual(service.importedGeminiSnapshot?.windows.first?.remainingPercent, 25)

        service.refreshAntigravity()
        service.refreshAntigravity()
        try await waitForRead(service)
        let first = await client.calls
        XCTAssertEqual(first, 1)
        XCTAssertEqual(service.selected(.gemini)?.remainingPercent, 89)
        XCTAssertEqual(try Data(contentsOf: file), legacy, "A query should not write quota or account data to disk")

        service.pin("gemini-weekly", for: .gemini)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let pins = try XCTUnwrap(saved["pins"] as? [String: String])
        XCTAssertEqual(pins["gemini"], "Flash")
        XCTAssertEqual(pins["antigravity"], "gemini-weekly")
        service.refreshAntigravity()
        try await waitForRead(service)
        XCTAssertEqual(service.selected(.gemini)?.remainingPercent, 78)
        service.refreshAntigravity()
        try await waitForRead(service)
        XCTAssertEqual(service.issues[.gemini], .signIn)
        XCTAssertNil(service.selected(.gemini), "Do not show the previous account after a sign-in failure")

        service.refreshAntigravity()
        service.stop()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(service.selected(.gemini))
        XCTAssertFalse(service.antigravityBusy)
        let reopened = AIQuotaService(directory: dir, environment: environment)
        defer { reopened.stop() }
        XCTAssertNil(reopened.selected(.gemini))
        XCTAssertEqual(reopened.importedGeminiSnapshot?.windows.first?.remainingPercent, 25)
    }
}
