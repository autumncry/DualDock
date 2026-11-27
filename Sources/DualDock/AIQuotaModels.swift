import Foundation

enum AIQuotaProvider: String, CaseIterable, Codable, Identifiable {
    case codex, claude, gemini
    var id: String { rawValue }
    var name: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .gemini: return "Gemini"
        }
    }
}

struct AIQuotaWindow: Identifiable, Equatable, Codable {
    var id: String
    var label: String
    var minutes: Int?
    var remainingPercent: Double?
    var remainingCount: Int?
    var unit: String?
    var reset: Date?
    var roundedByCLI: Bool?

    var title: String { title(in: .current) }

    func title(in language: AppLanguage) -> String {
        guard let minutes else { return label }
        let period: String
        if minutes == 10080 { period = language("7 天", "7 days") }
        else if minutes.isMultiple(of: 1440) { period = language("\(minutes / 1440) 天", "\(minutes / 1440) days") }
        else if minutes.isMultiple(of: 60) { period = language("\(minutes / 60) 小时", "\(minutes / 60) hours") }
        else { period = language("\(minutes) 分钟", "\(minutes) min") }
        return label.isEmpty ? period : "\(label) · \(period)"
    }

    var amount: String {
        if let p = remainingPercent {
            // Rounding a small positive balance to zero would falsely report exhaustion.
            if p == 0 && roundedByCLI == true { return "≈0%" }
            if p > 0 && p < 0.1 { return "<0.1%" }
            return p.formatted(.number.precision(.fractionLength(0...1))) + "%"
        }
        if let n = remainingCount { return n.formatted() + (unit.map { " " + $0 } ?? "") }
        return "—"
    }
}

struct AIQuotaSnapshot: Codable, Equatable {
    let windows: [AIQuotaWindow]
    let updated: Date
}

enum AIQuotaError: Error, Equatable {
    case unavailable, signIn, notInstalled, timeout, invalid, conflict, writeFailed
    case antigravityMissing, antigravityOutdated

    var text: String {
        switch self {
        case .signIn: return L("请先在客户端登录支持配额查询的订阅账号。", "Sign in to a supported subscription in the client.")
        case .antigravityMissing:
            return L("未找到 Antigravity CLI（agy）。", "Antigravity CLI (agy) was not found.")
        case .antigravityOutdated:
            return L("请将 Antigravity CLI 更新到 1.1.11 或更高版本。", "Update Antigravity CLI to version 1.1.11 or later.")
        case .notInstalled: return L("未找到 Codex CLI。请先安装，或在详情中选择可执行文件。", "Install the Codex CLI or select its executable here.")
        case .timeout: return L("客户端响应超时，请稍后刷新。", "The client timed out. Refresh to retry.")
        case .invalid: return L("未识别到额度记录。请使用包含限额的统计结果。", "No quota rows were found. Use a result that contains limits.")
        case .conflict: return L("状态行已改变。请先检查 Claude Code 设置。", "The status line changed. Check your Claude Code settings.")
        case .writeFailed: return L("无法保存连接设置。请检查配置目录。", "Could not save the connection. Check the settings directory.")
        case .unavailable: return L("客户端暂未提供额度。", "The client has not supplied limits.")
        }
    }
}

enum AIQuotaParser {
    static func codex(_ data: Data, now: Date) throws -> AIQuotaSnapshot {
        struct Window: Decodable { let usedPercent: Double?; let windowDurationMins: Int?; let resetsAt: Double? }
        struct Limits: Decodable { let limitId, limitName: String?; let primary, secondary: Window? }
        struct Result: Decodable { let rateLimits: Limits?; let rateLimitsByLimitId: [String: Limits]? }
        let result = try JSONDecoder().decode(Result.self, from: data)
        var byID = result.rateLimitsByLimitId ?? [:]
        if let fallback = result.rateLimits {
            let id = fallback.limitId ?? "codex"
            if byID[id] == nil { byID[id] = fallback }
        }
        var windows: [AIQuotaWindow] = []
        for id in byID.keys.sorted(by: { lhs, rhs in lhs == "codex" ? rhs != "codex" : (rhs != "codex" && lhs < rhs) }) {
            guard let limits = byID[id] else { continue }
            for (key, win) in [("primary",limits.primary), ("secondary",limits.secondary)] {
                guard let win, let used = win.usedPercent, (0...100).contains(used) else { continue }
                let mins = win.windowDurationMins.flatMap { $0 > 0 ? $0 : nil }
                let scope = id == "codex" && mins != nil ? "" : (limits.limitName ?? id)
                windows.append(.init(id: "\(id)/\(key)", label: scope, minutes: mins, remainingPercent: 100-used,
                                     reset: date(win.resetsAt)))
            }
        }
        guard !windows.isEmpty else { throw AIQuotaError.unavailable }
        return .init(windows: windows, updated: now)
    }

    static func claude(_ data: Data, now: Date) throws -> AIQuotaSnapshot {
        // Codable visits only these keys; status-line input can also contain conversation metadata.
        struct Window: Decodable { let used_percentage, resets_at: Double? }
        struct Windows: Decodable { let five_hour, seven_day: Window? }
        struct Status: Decodable { let rate_limits: Windows? }
        let limits = try JSONDecoder().decode(Status.self, from: data).rate_limits
        let candidates = [("five_hour",300,limits?.five_hour),("seven_day",10080,limits?.seven_day)]
        let windows: [AIQuotaWindow] = candidates.compactMap { key, minutes, win in
            guard let used = win?.used_percentage, (0...100).contains(used) else { return nil }
            return .init(id:key, label:"", minutes:minutes, remainingPercent:100-used, reset:date(win?.resets_at))
        }
        return .init(windows: windows, updated: now)
    }

    private static func date(_ time: Double?) -> Date? {
        guard let t = time, t.isFinite, t > 0, t < 32_503_680_000 else { return nil }
        return Date(timeIntervalSince1970:t)
    }
}
