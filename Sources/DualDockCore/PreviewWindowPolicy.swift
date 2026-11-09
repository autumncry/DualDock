import Foundation

public enum PreviewWindowPolicy {
    public static func shouldInclude(isOnScreen: Bool, title: String?, hasAccessibleWindow: Bool?) -> Bool {
        let hasTitle = !(title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        // Unknown AX coverage must not hide a potentially valid window.
        return isOnScreen || hasTitle || hasAccessibleWindow != false
    }
}
