import Foundation

enum AIQuotaClaudeParser {
    private struct CommandResult: Decodable {
        struct Usage: Decodable { let input_tokens: Int; let output_tokens: Int }
        let type: String
        let local_command: String?
        let num_turns: Int
        let total_cost_usd: Double
        let usage: Usage
        let is_error: Bool
        let result: String?
    }

    static func parse(_ data: Data, now: Date) throws -> AIQuotaSnapshot {
        guard let envelope = try? JSONDecoder().decode(CommandResult.self, from: data),
              envelope.type == "result", envelope.local_command == "usage", envelope.num_turns == 0,
              envelope.total_cost_usd == 0, envelope.usage.input_tokens == 0, envelope.usage.output_tokens == 0 else {
            throw AIQuotaError.invalid
        }
        guard !envelope.is_error, let report = envelope.result else { throw AIQuotaError.unavailable }
        let row = try NSRegularExpression(pattern:
            #"^Current (session|week \(([^)]+)\)):\s*([0-9]+(?:\.[0-9]+)?)% used(?:\s*·\s*resets (.+))?\s*$"#)
        var windows: [AIQuotaWindow] = []
        for line in report.components(separatedBy: .newlines) {
            guard let match = row.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
            func value(_ index: Int) -> String? { Range(match.range(at: index), in: line).map { String(line[$0]) } }
            guard let percentage = value(3).flatMap(Double.init), (0...100).contains(percentage) else { continue }
            let weekly = value(1) != "session"
            let source = value(2) ?? ""
            let model = source.hasSuffix(" only") ? String(source.dropLast(5)) : source
            let label = source == "all models" ? "" : model
            let id = weekly ? (label.isEmpty ? "seven_day" : "seven_day/" + label.lowercased()) : "five_hour"
            guard !windows.contains(where: { $0.id == id }) else { continue }
            let minutes = weekly ? 10080 : 300
            windows.append(AIQuotaWindow(id: id, label: label, minutes: minutes,
                                         remainingPercent: 100 - percentage,
                                         reset: value(4).flatMap { resetDate($0, now: now, minutes: minutes) },
                                         roundedByCLI: true))
        }
        guard !windows.isEmpty else { throw AIQuotaError.unavailable }
        // An unmarked response can also be cached internally by Claude Code.
        let cached = report.localizedCaseInsensitiveContains("last-known usage") ||
                     report.localizedCaseInsensitiveContains("cached usage")
        return AIQuotaSnapshot(windows: windows, updated: now, sourceIsCached: cached ? true : nil)
    }

    // The CLI prints in the TZ/locale requested by the caller. Honor the printed
    // zone, preserve minute precision and handle December/January rollover.
    private static func resetDate(_ text: String, now: Date, minutes: Int) -> Date? {
        let pattern = #"^(?:([A-Za-z]{3}) (\d{1,2}) at )?(\d{1,2})(?::(\d{2}))?\s*(am|pm) \(([^()]+)\)$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func value(_ i: Int) -> String? { Range(m.range(at: i), in: text).map { String(text[$0]) } }
        guard let zone = value(6).flatMap(TimeZone.init(identifier:)),
              let hour = value(3).flatMap(Int.init), (1...12).contains(hour) else { return nil }
        let minute = value(4).flatMap(Int.init) ?? 0
        guard (0..<60).contains(minute) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        cal.locale = Locale(identifier: "en_US_POSIX")
        var target = DateComponents(hour: hour % 12 + (value(5)?.lowercased() == "pm" ? 12 : 0), minute: minute, second: 0)
        if let month = value(1), let day = value(2).flatMap(Int.init) {
            guard let index = cal.shortMonthSymbols.firstIndex(of: month), (1...31).contains(day) else { return nil }
            target.month = index + 1
            target.day = day
        }
        // A rate-limited query can legitimately return a cached reset in the past hour.
        let earliest = now.addingTimeInterval(-3660)
        guard let date = cal.nextDate(after: earliest, matching: target, matchingPolicy: .strict),
              date <= now.addingTimeInterval(Double(minutes) * 60 + 60) else { return nil }
        return date
    }
}
