import Foundation

enum AIQuotaProvider: String, CaseIterable, Codable, Identifiable {
    case codex, claude, gemini
    var id: String { rawValue }
    var name: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .gemini: return "Gemini CLI"
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

    var title: String {
        guard let minutes else { return label }
        let period: String
        if minutes == 10080 { period = L("7 天", "7 days") }
        else if minutes.isMultiple(of: 1440) { period = L("\(minutes / 1440) 天", "\(minutes / 1440) days") }
        else if minutes.isMultiple(of: 60) { period = L("\(minutes / 60) 小时", "\(minutes / 60) hours") }
        else { period = L("\(minutes) 分钟", "\(minutes) min") }
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

    var text: String {
        switch self {
        case .signIn: return L("请先在客户端登录支持配额查询的订阅账号。", "Sign in to a supported subscription in the client.")
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

    static func gemini(_ data: String, now: Date) throws -> AIQuotaSnapshot {
        guard !data.isEmpty, data.utf8.count <= 128*1024 else { throw AIQuotaError.invalid }
        var windows: [AIQuotaWindow] = []
        func insert(_ win: AIQuotaWindow) {
            if !windows.contains(where: { $0.id == win.id }) { windows.append(win) }
        }
        let text = data.trimmingCharacters(in:.whitespacesAndNewlines)
        if text.hasPrefix("{") {
            struct Bucket: Decodable {
                let modelId, tokenType, resetTime: String?
                let remainingFraction: Double?
                let remainingAmount: Int?

                private enum CodingKeys: String, CodingKey { case modelId, tokenType, resetTime, remainingFraction, remainingAmount }
                init(from decoder:Decoder) throws {
                    let c = try decoder.container(keyedBy:CodingKeys.self)
                    modelId = try c.decodeIfPresent(String.self,forKey:.modelId)
                    tokenType = try c.decodeIfPresent(String.self,forKey:.tokenType)
                    resetTime = try c.decodeIfPresent(String.self,forKey:.resetTime)
                    remainingFraction = try c.decodeIfPresent(Double.self,forKey:.remainingFraction)
                    // The Code Assist schema encodes this integer as a string.
                    if let string = try? c.decode(String.self,forKey:.remainingAmount) {
                        remainingAmount = Int(string)
                    } else { remainingAmount = try c.decodeIfPresent(Int.self,forKey:.remainingAmount) }
                }
            }
            struct Response: Decodable { let buckets: [Bucket] }
            let buckets: [Bucket]
            do { buckets = try JSONDecoder().decode(Response.self, from:Data(text.utf8)).buckets }
            catch { throw AIQuotaError.invalid }
            for bucket in buckets {
                guard let model = bucket.modelId, !model.isEmpty, model.count <= 100 else { continue }
                let percent = bucket.remainingFraction.flatMap { (0...1).contains($0) ? $0*100 : nil }
                let count = bucket.remainingAmount.flatMap { $0 >= 0 ? $0 : nil }
                guard percent != nil || count != nil else { continue }
                let unit = bucket.tokenType
                let iso = ISO8601DateFormatter()
                let reset = bucket.resetTime.flatMap { ts -> Date? in
                    if let t = iso.date(from:ts) { return t }
                    iso.formatOptions.insert(.withFractionalSeconds)
                    return iso.date(from:ts)
                }
                insert(.init(id:model+"/"+(unit ?? ""), label:model, remainingPercent:percent,
                             remainingCount:count, unit:unit, reset:reset))
            }
        } else {
            // Distinguish legacy "Usage left" from modern "Model usage" (a USED bar).
            // Token, cache hit and tool-success percentages from other sections must never match.
            let clear = text.replacingOccurrences(of:"\\x1B\\[[0-?]*[ -/]*[@-~]", with:"", options:.regularExpression)
            enum Format { case left, usedBars }
            var format: Format?
            for raw in clear.components(separatedBy:.newlines) {
                let line = raw.trimmingCharacters(in: CharacterSet(charactersIn:" │┃\t\r"))
                if line.localizedCaseInsensitiveContains("Usage left") { format = .left; continue }
                if line.lowercased() == "model usage" { format = .usedBars; continue }
                if let used = matches(#"^([0-9]+(?:\.[0-9]+)?)%\s+used(?:\s*\(Limit resets in ([^)]+)\))?$"#,line),
                   let pct = Double(used[0]), (0...100).contains(pct) {
                    insert(.init(id:"shared",label:L("共享配额","Shared quota"),remainingPercent:100-pct,reset:relative(used[1],now:now),roundedByCLI:true))
                    continue
                }
                if let hit = matches(#"^Limit reached(?:, resets in (.+))?$"#,line) {
                    insert(.init(id:"shared",label:L("共享配额","Shared quota"),remainingPercent:0,reset:relative(hit[0],now:now)))
                    continue
                }
                guard let mode = format else { continue }
                let pattern = mode == .left
                    ? #"^((?:gemini-[A-Za-z0-9._-]+|Pro|Flash(?: Lite)?))\s+(?:[\d,]+\s+)?([0-9]+(?:\.[0-9]+)?)%\s*(.*)$"#
                    : #"^((?:gemini-[A-Za-z0-9._-]+|Pro|Flash(?: Lite)?))\s+[▬━─█▓▒░▉▊▋▌▍▎▏▰▱●○· ]*\s+([0-9]+(?:\.[0-9]+)?)%\s*(.*)$"#
                guard let groups = matches(pattern,line), let pct = Double(groups[1]), (0...100).contains(pct) else { continue }
                insert(.init(id:groups[0],label:groups[0],remainingPercent:mode == .left ? pct : 100-pct,
                             reset:relative(groups[2],now:now),roundedByCLI:true))
            }
        }
        guard !windows.isEmpty else { throw AIQuotaError.invalid }
        return .init(windows:windows,updated:now)
    }

    private static func matches(_ pattern:String, _ text:String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern:pattern,options:[.caseInsensitive]),
              let m = re.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)) else { return nil }
        return (1..<m.numberOfRanges).map { Range(m.range(at:$0),in:text).map { String(text[$0]) } ?? "" }
    }

    private static func relative(_ text:String, now:Date) -> Date? {
        // Accept the duration only; a formatted local clock is ambiguous across dates/zones.
        let duration = text.components(separatedBy:"(").last?.trimmingCharacters(in:CharacterSet(charactersIn:" )")) ?? ""
        let trimmed = duration.replacingOccurrences(of:"(?i)^(?:resets?\\s+in|resets?:)\\s*",with:"",options:.regularExpression)
        guard let m = matches(#"^\s*(?:(\d+)d\s*)?(?:(\d+)h\s*)?(?:(\d+)m\s*)?(?:(\d+)s\s*)?$"#,trimmed),
              m.contains(where:{ !$0.isEmpty }) else { return nil }
        let seconds = zip(m,[86400.0,3600,60,1]).reduce(0.0) { $0 + (Double($1.0) ?? 0)*$1.1 }
        guard seconds.isFinite, seconds > 0, seconds < 366*86400 else { return nil }
        return now.addingTimeInterval(seconds)
    }
}
