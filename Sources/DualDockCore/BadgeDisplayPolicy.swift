import Foundation

public enum BadgeDisplayPolicy {
    public static func normalizedLabel(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if let number = Int(value), number == 0 { return nil }
        return value
    }

    public static func label(for entry: DockEntry, labels: [String: String], enabled: Bool) -> String? {
        guard enabled else { return nil }
        if entry.isGroup {
            return entry.apps.contains { normalizedLabel(labels[$0.id]) != nil } ? "!" : nil
        }
        return entry.apps.first.flatMap { normalizedLabel(labels[$0.id]) }
    }
}
