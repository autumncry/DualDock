import Foundation

public enum PreviewWindowPolicy {
    public static func shouldInclude(isOnScreen: Bool, title: String?, hasAccessibleWindow: Bool?) -> Bool {
        let hasTitle = !(title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        // Unknown AX coverage must not hide a potentially valid window.
        return isOnScreen || hasTitle || hasAccessibleWindow != false
    }

    public static func availablePreviewIDs(
        orderedCandidates: [UInt32],
        validSnapshotIDs: Set<UInt32>,
        currentWindowIDs: Set<UInt32>
    ) -> [UInt32] {
        var seen: Set<UInt32> = []
        return orderedCandidates.filter { id in
            validSnapshotIDs.contains(id) && currentWindowIDs.contains(id)
                && seen.insert(id).inserted
        }
    }
}
