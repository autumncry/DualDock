import Foundation

/// Closing a window requires stronger identity evidence than simply activating an app.
public enum WindowCloseTargetPolicy {
    public struct Candidate: Equatable, Sendable {
        public let windowID: UInt32?
        public let title: String?
        public let frame: CGRect?

        public init(windowID: UInt32?, title: String?, frame: CGRect?) {
            self.windowID = windowID
            self.title = title
            self.frame = frame
        }
    }

    public static func matchesApplication(expected: AppReference, capturedPath: String?, capturedLaunchDate: Date?,
                                           liveBundleID: String?, livePath: String?, liveLaunchDate: Date?) -> Bool {
        let expectedPath = capturedPath ?? expected.path
        guard let livePath, expectedPath.hasPrefix("/"), livePath.hasPrefix("/"),
              URL(fileURLWithPath: expectedPath).standardizedFileURL.path
                == URL(fileURLWithPath: livePath).standardizedFileURL.path else { return false }
        // References without a bundle identifier use their full path as id.
        guard expected.id == expected.path || liveBundleID == expected.id else { return false }
        if let capturedLaunchDate {
            guard liveLaunchDate == capturedLaunchDate else { return false }
        }
        return true
    }

    public static func candidateIndex(windowID: UInt32, rawTitle: String?, frame: CGRect,
                                       candidates: [Candidate]) -> Int? {
        guard windowID != 0 else { return nil }
        let exact = candidates.indices.filter { candidates[$0].windowID == windowID }
        if exact.count == 1 { return exact[0] }
        // Any resolved ID establishes that private mapping is functioning. A
        // missing target is stale, not permission to close a similarly named window.
        guard exact.isEmpty, candidates.allSatisfy({ $0.windowID == nil }),
              let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              valid(frame) else { return nil }
        let matching = candidates.indices.filter { index in
            let candidate = candidates[index]
            guard candidate.title?.trimmingCharacters(in: .whitespacesAndNewlines) == title,
                  let other = candidate.frame, valid(other) else { return false }
            // Permit one logical point of AX/SCK geometry rounding only.
            return abs(frame.minX - other.minX) <= 1 && abs(frame.minY - other.minY) <= 1
                && abs(frame.width - other.width) <= 1 && abs(frame.height - other.height) <= 1
        }
        return matching.count == 1 ? matching[0] : nil
    }

    /// Same-process WindowServer evidence required in addition to an AX fallback.
    public static func fallbackSourceIsUnique(windowID: UInt32, rawTitle: String?, frame: CGRect,
                                              windows: [Candidate]) -> Bool {
        guard windowID != 0, valid(frame),
              let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return false }
        var matches: [UInt32] = []
        for window in windows {
            // Missing geometry cannot prove that a potentially matching
            // same-process window is unrelated to the AX fallback candidate.
            guard let currentFrame = window.frame, valid(currentFrame) else { return false }
            let sameFrame = abs(frame.minX - currentFrame.minX) <= 1 && abs(frame.minY - currentFrame.minY) <= 1
                && abs(frame.width - currentFrame.width) <= 1 && abs(frame.height - currentFrame.height) <= 1
            guard sameFrame else { continue }
            guard let currentTitle = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            if currentTitle == title {
                guard let id = window.windowID else { return false }
                matches.append(id)
            }
        }
        return matches == [windowID]
    }

    private static func valid(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }
}
