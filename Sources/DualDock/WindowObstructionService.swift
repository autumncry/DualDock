import AppKit

/// Retains only normal-window bounds and discards other WindowServer metadata.
/// No screenshots or window contents are captured.
@MainActor
final class WindowObstructionService {
    typealias Reader = @Sendable () -> [CGRect]?
    var onUpdate: (() -> Void)?
    private(set) var frames: [CGRect] = []
    private let reader: Reader
    private let now: () -> TimeInterval
    private let maximumSnapshotAge: TimeInterval = 1
    private let queue = DispatchQueue(label: "local.ronny.DualDock.obstruction", qos: .utility)
    private var generation: UInt64 = 0
    private var reading = false
    private var pending = false
    private var stopped = false
    private var lastRead = -TimeInterval.infinity
    private var snapshotTime: TimeInterval?

    init(reader: @escaping Reader = { WindowObstructionService.readWindowBounds() },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.reader = reader
        self.now = now
    }

    func invalidate(clear: Bool = false) {
        generation &+= 1
        if clear { frames = []; snapshotTime = nil }
        lastRead = -.infinity
        pending = reading
    }

    func refresh(force: Bool = false) {
        guard !stopped else { return }
        let time = now()
        expireSnapshot(at: time)
        if reading { pending = pending || force; return }
        guard force || time - lastRead >= 0.15 else { return }
        reading = true
        lastRead = time
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
                // Age starts when the query begins: a blocked WindowServer read
                // must not bring an already-expired obstruction back to life.
                if token == self.generation, let raw, self.now() - time < self.maximumSnapshotAge {
                    let next = raw.map { CGRect(x: $0.minX, y: primaryTop - $0.maxY, width: $0.width, height: $0.height) }
                    self.snapshotTime = time
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
        snapshotTime = nil
        onUpdate = nil
    }

    private func expireSnapshot(at time: TimeInterval) {
        guard let snapshotTime, time - snapshotTime >= maximumSnapshotAge else { return }
        frames = []
        self.snapshotTime = nil
        // refresh()'s caller reads frames immediately afterward. A synchronous
        // onUpdate here would reenter that caller while it is evaluating state.
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
