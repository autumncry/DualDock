import Foundation

public enum PreviewWindowPolicy {
    public struct AccessibilityWindow: Equatable, Sendable {
        public let windowID: UInt32
        public let frame: CGRect?
        public let role: String?
        public let subrole: String?
        public let isMain: Bool?
        public let isFocused: Bool?
        public let isModal: Bool?
        public let isMinimized: Bool?
        public let hasWindowControls: Bool?

        public init(windowID: UInt32, frame: CGRect?, role: String?, subrole: String?,
                    isMain: Bool?, isFocused: Bool?, isModal: Bool?, isMinimized: Bool?,
                    hasWindowControls: Bool?) {
            self.windowID = windowID
            self.frame = frame
            self.role = role
            self.subrole = subrole
            self.isMain = isMain
            self.isFocused = isFocused
            self.isModal = isModal
            self.isMinimized = isMinimized
            self.hasWindowControls = hasWindowControls
        }
    }

    /// The input is restricted to one process; titles and captured pixels are not identities.
    public static func companionOverlayIDs(in windows: [AccessibilityWindow]) -> Set<UInt32> {
        let candidates = possibleCompanionOverlayIDs(in: windows)
        return Set(windows.filter {
            candidates.contains($0.windowID) && $0.isMain == false && $0.isFocused == false
                && $0.isModal == false && $0.isMinimized == false && $0.hasWindowControls == false
        }.map(\.windowID))
    }

    /// Cheap structural pass, so native callers only inspect capabilities for a
    /// possible helper layer, not every normal application window.
    public static func possibleCompanionOverlayIDs(in windows: [AccessibilityWindow]) -> Set<UInt32> {
        let standard = windows.filter { $0.role == "AXWindow" && $0.subrole == "AXStandardWindow" }
        return Set(windows.filter { candidate in
            guard candidate.role == "AXWindow", candidate.subrole == "AXUnknown",
                  let frame = candidate.frame, valid(frame) else { return false }
            return standard.contains { sibling in
                guard sibling.windowID != candidate.windowID, let other = sibling.frame, valid(other) else { return false }
                return abs(frame.minX - other.minX) <= 1 && abs(frame.minY - other.minY) <= 1
                    && abs(frame.width - other.width) <= 1 && abs(frame.height - other.height) <= 1
            }
        }.map(\.windowID))
    }

    private static func valid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }

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
