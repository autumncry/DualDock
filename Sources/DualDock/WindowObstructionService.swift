import AppKit

/// Retains only normal-window bounds and discards other WindowServer metadata.
/// No screenshots or window contents are captured.
@MainActor
final class WindowObstructionService {
    typealias Reader = @Sendable () -> [CGRect]?
    var onUpdate: (() -> Void)?
    private(set) var frames: [CGRect] = []
    private let reader: Reader
    private let queue = DispatchQueue(label: "local.ronny.DualDock.obstruction", qos: .utility)
    private var generation: UInt64 = 0
    private var reading = false
    private var pending = false
    private var stopped = false
    private var lastRead = -TimeInterval.infinity

    init(reader: @escaping Reader = { WindowObstructionService.readWindowBounds() }) { self.reader = reader }

    func invalidate(clear: Bool = false) {
        generation &+= 1
        if clear { frames = [] }
        lastRead = -.infinity
        pending = reading
    }

    func refresh(force: Bool = false) {
        guard !stopped else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if reading { pending = pending || force; return }
        guard force || now - lastRead >= 0.15 else { return }
        reading = true
        lastRead = now
        let token = generation, read = reader
        let primaryTop = NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        })?.frame.maxY ?? 0
        queue.async { [weak self] in
            let raw = autoreleasepool { read() }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reading = false
                guard !self.stopped else { return }
                if token == self.generation, let raw {
                    let next = raw.map { CGRect(x: $0.minX, y: primaryTop - $0.maxY, width: $0.width, height: $0.height) }
                    if next != self.frames { self.frames = next; self.onUpdate?() }
                }
                if self.pending {
                    self.pending = false
                    self.refresh(force: true)
                }
            }
        }
    }

    func stop() {
        stopped = true
        generation &+= 1
        pending = false
        frames = []
        onUpdate = nil
    }

    nonisolated private static func readWindowBounds() -> [CGRect]? {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.05,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
                  frame.width >= 40, frame.height >= 40 else { return nil }
            return frame
        }
    }
}
