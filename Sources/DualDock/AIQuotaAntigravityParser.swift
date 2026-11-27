import CoreFoundation
import Foundation

enum AIQuotaAntigravityParser {
    /// Decode only the structured result of agy's read-only /usage command.
    /// Other fields in the envelope can describe a conversation or account.
    static func parse(_ data: Data, now: Date) throws -> AIQuotaSnapshot {
        guard data.count <= 1_048_576,
              let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AIQuotaError.invalid
        }
        if let status = report["status"] as? String, status != "SUCCESS" { throw AIQuotaError.unavailable }
        guard let command = report["command"] as? [String: Any], command["name"] as? String == "usage",
              let payload = command["data"] as? [String: Any],
              let groups = payload["groups"] as? [[String: Any]] else {
            throw AIQuotaError.invalid
        }

        var windows: [AIQuotaWindow] = []
        var seenIDs: Set<String> = []
        for group in groups {
            guard let groupName = group["name"] as? String else { continue }
            let names = Set(groupName.lowercased().split { !$0.isLetter })
            guard names.contains("gemini"), names.isDisjoint(with: ["claude", "gpt", "credit", "credits"]),
                  let buckets = group["buckets"] as? [[String: Any]] else { continue }
            for bucket in buckets {
                guard let window = window(from: bucket), seenIDs.insert(window.id).inserted else { continue }
                windows.append(window)
            }
        }
        guard !windows.isEmpty else { throw AIQuotaError.unavailable }
        windows.sort {
            let first = $0.minutes ?? Int.max, second = $1.minutes ?? Int.max
            return first == second ? $0.id < $1.id : first < second
        }
        return AIQuotaSnapshot(windows: windows, updated: now)
    }

    private static func window(from bucket: [String: Any]) -> AIQuotaWindow? {
        // The CLI identifies the shared Gemini limits with the gemini- prefix;
        // it also returns 3p-* limits for Claude/GPT in this same report.
        guard let id = bucket["id"] as? String, id.hasPrefix("gemini-"),
              let period = bucket["window"] as? String, !period.isEmpty,
              bucket["disabled"] as? Bool != true else { return nil }

        let fraction = number(bucket["remaining_fraction"])?.doubleValue
        let percent = fraction.flatMap { (0...1).contains($0) ? $0 * 100 : nil }
        let count = number(bucket["remaining_amount"]).flatMap { Int(exactly: $0) }.flatMap { $0 >= 0 ? $0 : nil }
        guard percent != nil || count != nil else { return nil }

        let minutes: Int?
        switch period.lowercased() {
        case "5h": minutes = 300
        case "weekly": minutes = 10080
        default: minutes = nil
        }
        // Known durations localize through AIQuotaWindow.title. For a new
        // duration preserve the service's label without inventing a period.
        let label = minutes == nil ? (bucket["name"] as? String ?? period) : ""
        return AIQuotaWindow(id: id, label: label, minutes: minutes, remainingPercent: percent,
                             remainingCount: count, unit: bucket["unit"] as? String,
                             reset: resetDate(bucket["reset_time"] as? String))
    }

    private static func number(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number
    }

    private static func resetDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let format = ISO8601DateFormatter()
        if text.contains(".") { format.formatOptions.insert(.withFractionalSeconds) }
        // Some windows with no active reset carry Unix epoch as a placeholder.
        guard let date = format.date(from: text), date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }
}
