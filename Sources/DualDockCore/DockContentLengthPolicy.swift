import Foundation

/// The unmagnified row is the sole length baseline. Pointer animation and scroll
/// offsets cannot change it. A collapsed group is one item at the call site.
public enum DockContentLengthPolicy {
    public static let minimumPadding: Double = 6

    public static func contentSpan(count: Int, iconSize: Double, gap: Double,
                                   separatorLength: Double, dividerIndex: Int?) -> Double {
        let count = max(0, count)
        let icon = iconSize.isFinite ? max(1, iconSize) : 48
        let spacing = gap.isFinite ? max(0, gap) : 0
        let separator = dividerIndex.map { $0 > 0 && $0 < count } == true
            && separatorLength.isFinite ? max(0, separatorLength) : 0
        guard count > 0 else { return max(120, icon * 2) }
        return Double(count) * icon + Double(count - 1) * spacing + separator
    }

    public static func capturedPadding(length: Double, contentSpan: Double) -> Double {
        guard length.isFinite, contentSpan.isFinite else { return minimumPadding }
        return max(minimumPadding, (length - contentSpan) / 2)
    }

    public static func desiredLength(contentSpan: Double, padding: Double?) -> Double {
        let margin = padding.flatMap { $0.isFinite ? max(minimumPadding, $0) : nil } ?? minimumPadding
        return max(1, contentSpan) + 2 * margin
    }
}
