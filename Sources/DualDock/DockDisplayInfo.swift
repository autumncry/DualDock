import AppKit
import CoreGraphics

/// A value snapshot; settings and presentation never retain NSScreen objects.
struct DockDisplayInfo: Identifiable, Equatable, Sendable {
    let id: String
    let runtimeID: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
    let isPrimary: Bool
    let isMirrored: Bool

    init(id: String, runtimeID: CGDirectDisplayID, name: String, frame: CGRect,
         visibleFrame: CGRect, isPrimary: Bool = false, isMirrored: Bool = false) {
        self.id = id
        self.runtimeID = runtimeID
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isPrimary = isPrimary
        self.isMirrored = isMirrored
    }

    @MainActor
    static func current() -> [DockDisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let runtimeID = number.uint32Value
            let identifier: String
            if let uuid = CGDisplayCreateUUIDFromDisplayID(runtimeID)?.takeRetainedValue() {
                identifier = CFUUIDCreateString(kCFAllocatorDefault, uuid) as String
            } else {
                identifier = "display-\(runtimeID)"
            }
            let insets = screen.safeAreaInsets
            let safe = CGRect(x: screen.frame.minX + max(0, insets.left),
                              y: screen.frame.minY + max(0, insets.bottom),
                              width: max(1, screen.frame.width - max(0, insets.left) - max(0, insets.right)),
                              height: max(1, screen.frame.height - max(0, insets.top) - max(0, insets.bottom)))
            let visible = screen.visibleFrame.intersection(safe)
            return DockDisplayInfo(id: identifier, runtimeID: runtimeID, name: screen.localizedName,
                frame: screen.frame, visibleFrame: visible.isNull || visible.isEmpty ? safe : visible,
                isPrimary: runtimeID == CGMainDisplayID(),
                isMirrored: CGDisplayMirrorsDisplay(runtimeID) != kCGNullDirectDisplay)
        }
    }
}
