import AppKit
import Combine

@MainActor
final class AIQuotaService: ObservableObject {
    struct Environment {
        var codex: @Sendable (String?) async throws -> AIQuotaSnapshot
        var now: () -> Date = Date.init
        var claudeSettings: URL
        var executable: URL?
        var captureDirectory: URL? = nil
        static var system: Self {
            Self(codex: { path in
                guard let bin = AIQuotaCodex.executable(override:path) else { throw AIQuotaError.notInstalled }
                return try await AIQuotaCodex.read(binary:bin)
            }, claudeSettings:AIQuotaClaudeBridge.settingsFile, executable:Bundle.main.executableURL,
               captureDirectory:AIQuotaClaudeBridge.runtimeDirectory)
        }
    }

    private struct Settings: Codable {
        var codexEnabled = false
        var codexPath: String?
        var pins: [String:String] = [:]
        var gemini: AIQuotaSnapshot?
    }

    let directory: URL
    private let env: Environment
    private var settings: Settings
    private let settingsFile: URL
    @Published private(set) var snapshots: [AIQuotaProvider:AIQuotaSnapshot] = [:]
    @Published private(set) var issues: [AIQuotaProvider:AIQuotaError] = [:]
    @Published private(set) var codexBusy = false
    @Published private(set) var claudeToken: UUID?
    @Published private var revision = 0
    private var visible: [String:Set<AIQuotaProvider>] = [:]
    private var details: [UUID:AIQuotaProvider] = [:]
    private var task: Task<Void,Never>?
    private var clock: Task<Void,Never>?
    private var generation = 0
    private var lastAttempt: Date?
    private var lastClaudeBytes: Data?
    private var savingAllowed = true

    init(directory: URL, environment: Environment = .system) {
        self.directory = directory
        self.env = environment
        settingsFile = directory.appendingPathComponent("ai-quota-settings.json")
        if FileManager.default.fileExists(atPath:settingsFile.path) {
            if let bytes = try? Data(contentsOf:settingsFile), let restored = try? JSONDecoder().decode(Settings.self,from:bytes) {
                settings = restored
            } else {
                settings = Settings(); savingAllowed = false
            }
        } else { settings = Settings() }
        snapshots[.gemini] = settings.gemini
        claudeToken = AIQuotaClaudeBridge.connection(in:directory)?.token
    }

    func isConnected(_ provider:AIQuotaProvider) -> Bool {
        switch provider {
        case .codex: return settings.codexEnabled
        case .claude: return claudeToken != nil
        case .gemini: return settings.gemini != nil
        }
    }

    func setVisible(_ providers:Set<AIQuotaProvider>, on display:String) {
        guard (visible[display] ?? []) != providers else { return }
        if providers.isEmpty { visible.removeValue(forKey:display) } else { visible[display] = providers }
        sync()
    }
    func setDetail(_ provider:AIQuotaProvider?, id:UUID) { details[id] = provider; sync() }
    private var demand: Set<AIQuotaProvider> { visible.values.reduce(Set(details.values),{ $0.union($1) }) }

    private func sync() {
        if !demand.contains(.codex) {
            if task != nil { cancelCodex() }
            lastAttempt = nil
        }
        if !demand.contains(where:{ isConnected($0) }) { clock?.cancel();clock = nil;return }
        tick()
        if clock == nil {
            clock = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for:.seconds(15)) } catch { break }
                    self?.tick()
                }
            }
        }
    }
    private func tick() {
        if demand.contains(.claude), claudeToken != nil { readClaude() }
        if demand.contains(.codex), settings.codexEnabled,
           lastAttempt.map({env.now().timeIntervalSince($0) >= 90}) ?? true { refreshCodex() }
        // Redraw a reset countdown even when the source is push-only.
        revision &+= 1
    }
    func stop() {
        visible.removeAll();details.removeAll()
        clock?.cancel();clock = nil;cancelCodex()
    }
    private func cancelCodex() { generation &+= 1; task?.cancel();task = nil;codexBusy = false }

    func connectCodex(executable:String? = nil) {
        var next = settings;next.codexEnabled = true;next.codexPath = executable ?? settings.codexPath
        guard persist(next,for:.codex) else { return }
        cancelCodex(); snapshots.removeValue(forKey:.codex)
        sync()
        refreshCodex()
    }
    func refreshCodex() {
        guard settings.codexEnabled, !codexBusy else { return }
        lastAttempt = env.now()
        let gen = generation, read = env.codex, path = settings.codexPath
        codexBusy = true
        task = Task { [weak self] in
            let result: Result<AIQuotaSnapshot,Error>
            do { result = .success(try await read(path)) } catch { result = .failure(error) }
            guard let self, !Task.isCancelled, gen == generation else { return }
            switch result {
            case .success(let fresh): snapshots[.codex] = fresh;issues[.codex] = nil
            case .failure(let error):
                // An unavailable account cannot establish the identity of a prior reading.
                snapshots[.codex] = nil;issues[.codex] = error as? AIQuotaError ?? .unavailable
            }
            codexBusy = false;task = nil
        }
    }

    func connectClaude() {
        guard claudeToken == nil, let exe = env.executable else { return }
        if let expected = env.captureDirectory, directory.standardizedFileURL.resolvingSymlinksInPath().path != expected.standardizedFileURL.resolvingSymlinksInPath().path {
            issues[.claude] = .writeFailed
            return
        }
        do {
            claudeToken = try AIQuotaClaudeBridge.install(in:env.claudeSettings, executable:exe, directory:directory)
            lastClaudeBytes = nil; snapshots[.claude] = nil; issues[.claude] = nil
            sync()
        } catch { issues[.claude] = error as? AIQuotaError ?? .writeFailed }
    }

    private func readClaude() {
        let file = directory.appendingPathComponent(AIQuotaClaudeBridge.snapshotFile)
        guard let size = try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize, size <= 32768,
              let bytes = try? Data(contentsOf:file) else {
            lastClaudeBytes = nil
            if snapshots[.claude] != nil { snapshots[.claude] = nil }
            return
        }
        guard bytes != lastClaudeBytes else { return }
        lastClaudeBytes = bytes
        guard let result = try? JSONDecoder().decode(AIQuotaSnapshot.self,from:bytes) else {
            snapshots[.claude] = nil;issues[.claude] = .invalid;return
        }
        snapshots[.claude] = result;issues[.claude] = nil
    }

    @discardableResult func importGemini(_ pasted:String) -> Bool {
        do {
            let reading = try AIQuotaParser.gemini(pasted,now:env.now())
            var next = settings;next.gemini = reading
            guard persist(next,for:.gemini) else { return false }
            snapshots[.gemini] = reading;issues[.gemini] = nil;sync()
            return true
        } catch { issues[.gemini] = .invalid;return false }
    }

    func disconnect(_ provider:AIQuotaProvider) {
        var next = settings;next.pins[provider.rawValue] = nil
        switch provider {
        case .codex: next.codexEnabled = false;next.codexPath = nil
        case .gemini: next.gemini = nil
        case .claude:
            if let token = claudeToken {
                do { try AIQuotaClaudeBridge.remove(from:env.claudeSettings,directory:directory,token:token) }
                catch { issues[provider] = error as? AIQuotaError ?? .writeFailed;return }
            }
            claudeToken = nil;lastClaudeBytes = nil
        }
        guard persist(next,for:provider) else { return }
        if provider == .codex { cancelCodex();lastAttempt = nil }
        snapshots[provider] = nil;issues[provider] = nil;sync()
    }

    func selected(_ provider:AIQuotaProvider) -> AIQuotaWindow? {
        guard let rows = snapshots[provider]?.windows else { return nil }
        return rows.first { $0.id == settings.pins[provider.rawValue] } ?? rows.first
    }
    func pin(_ id:String, for provider:AIQuotaProvider) {
        guard snapshots[provider]?.windows.contains(where:{$0.id == id}) == true else { return }
        var next=settings;next.pins[provider.rawValue]=id; _ = persist(next,for:provider)
    }

    func isExpired(_ window:AIQuotaWindow) -> Bool { window.reset.map { $0 <= env.now() } ?? false }
    func isStale(_ provider:AIQuotaProvider) -> Bool {
        snapshots[provider].map { env.now().timeIntervalSince($0.updated) >= 300 } ?? false
    }

    private func persist(_ next:Settings, for provider:AIQuotaProvider) -> Bool {
        do {
            guard savingAllowed else { throw AIQuotaError.writeFailed }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try JSONEncoder().encode(next).write(to:settingsFile,options:.atomic)
            settings=next;revision &+= 1;return true
        } catch { issues[provider] = .writeFailed;return false }
    }
}
