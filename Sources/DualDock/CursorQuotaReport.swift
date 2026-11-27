import Foundation
import CoreFoundation

enum CursorQuotaSource: String, Codable, CaseIterable {
    case cursorCLI, xSubscription
}

/// Interpret only account-allowance fields. Token use and paid overages have different units.
enum CursorQuotaReport {
    static func legacy(_ screen: String, now: Date) -> AIQuotaSnapshot? {
        guard screen.contains("Monthly plan and on-demand usage") else { return nil }
        let reset = capture(#"\bResets\s+([A-Za-z]{3}\s+[0-9]{1,2})\b"#, in: screen)
        let rows = [("Included", "included"), ("Auto", "auto"), ("API", "api")].compactMap { label, id -> AIQuotaWindow? in
            let pattern = #"(?m)^[\s│]*"# + label + #"(?:\s*:)?[ \t]+([\d]+(?:\.\d+)?)%[ \t]+used\b"#
            guard let used = capture(pattern, in: screen).flatMap(Double.init), (0...100).contains(used) else { return nil }
            return .init(id: "cursor-" + id, label: label, remainingPercent: 100 - used,
                         resetDescription: reset.map { $0 + " (UTC)" }, roundedByCLI: true)
        }
        guard rows.first?.id == "cursor-included" else { return nil }
        return .init(windows: rows, updated: now)
    }

    static func sharedJSON(_ data: Data, now: Date) throws -> AIQuotaSnapshot {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw AIQuotaError.invalid }
        let record = (json["usage_limit"] as? [String: Any]) ?? json
        guard let period = record["period_type"] as? String,
              ["weekly", "usage_period_type_weekly"].contains(period.lowercased()),
              let shared = record["is_unified_billing_user"] as? NSNumber,
              CFGetTypeID(shared) == CFBooleanGetTypeID(), shared.boolValue,
              let number = record["usage_pct"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              (0...100).contains(number.doubleValue) else { throw AIQuotaError.unavailable }
        let end = record["period_end_display"] as? String
        return .init(windows: [.init(id: "x-weekly", label: "Cursor / Grok", minutes: 10080,
            remainingPercent: 100 - number.doubleValue, resetDescription: end?.isEmpty == false ? end : nil)], updated: now)
    }

    static func sharedScreen(_ screen: String, now: Date) -> AIQuotaSnapshot? {
        guard screen.contains("Usage limit"),
              let percent = capture(#"(?m)^[ \t│]*Weekly limit[ \t]+\((?:The )?X(?: Subscription)?[ \t]+(?:Free|Plus|Premium|Super|Ultra|Teams?)\)[ \t│]*\n(?:[ \t│]*\n)*[ \t│]*[█░]+[ \t]+([0-9]+)%[ \t│]*$"#, in: screen).flatMap(Double.init),
              (0...100).contains(percent) else { return nil }
        let end = capture(#"(?m)^[ \t│]*Resets:[ \t]*([^\n│]+)"#, in: screen)?.trimmingCharacters(in: .whitespaces)
        return .init(windows: [.init(id: "x-weekly", label: "Cursor / Grok", minutes: 10080,
            remainingPercent: 100 - percent, resetDescription: end, roundedByCLI: true)], updated: now)
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let first = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(first.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
