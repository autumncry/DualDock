import AppKit
import Darwin
import DualDockCore

/// Some WeChat versions put a regular Dock icon in a nested application while
/// the browser's real NSWindow and native minimize button belong to WeChat.
/// Learn that window from an observed reveal; never pick a host window by name,
/// size, or simply because it happens to have keyboard focus.
@MainActor
final class WeChatBrowserWindowRouter {
    struct Instance: Equatable, Sendable {
        let pid: pid_t
        let launched: Date
        let path: String
    }

    struct Pair: Equatable, Sendable {
        let icon: Instance
        let host: Instance
        let hostApp: AppReference

        func owns(_ window: DockWindowItem) -> Bool {
            window.id.pid == host.pid && window.id.processLaunchDate == host.launched &&
                window.id.applicationPath == host.path
        }
    }

    struct Observation {
        let windows: [DockWindowItem]
        let visibleIDs: Set<CGWindowID>
        let exposedIDs: Set<CGWindowID>
        let companionIDs: Set<CGWindowID>
        let frontPID: pid_t?
    }

    enum Resolution {
        case ordinary
        case activationRequested
        case target(DockWindowItem, Pair)
        case reveal(DockWindowItem, Pair)
    }

    struct Environment {
        var pair: (AppReference) -> Pair?
        var observe: (Pair) async -> Observation?
        var activate: (Pair) -> Bool
        var pause: () async -> Void = { try? await Task.sleep(nanoseconds: 40_000_000) }
    }

    private let environment: Environment
    private var binding: (pair: Pair, window: DockWindowIdentity)?

    init(environment: Environment) { self.environment = environment }

    convenience init(backend: WindowInteractionBackend) {
        self.init(environment: .init(pair: Self.livePair, observe: { pair in
            guard case .available(let all) = await backend.read(for: pair.hostApp) else { return nil }
            let rows = VerifiedWindowActivation.orderedOnscreenRows()
            guard !ApplicationActivationService.hasVisibleContentWindow(processID:pair.icon.pid, windows:rows) else { return nil }
            let owned = all.filter(pair.owns)
            let visible = rows.compactMap { row -> CGWindowID? in
                guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pair.host.pid,
                      (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
                return (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            }
            let exposed = owned.filter { VerifiedWindowActivation.isExposed(windowID:$0.id.windowID, pid:pair.host.pid, in:rows) }
            return Observation(windows: owned, visibleIDs: Set(visible), exposedIDs: Set(exposed.map { $0.id.windowID }),
                               companionIDs: Self.companionIDs(pair: pair, windows: owned),
                               frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        }, activate: { pair in
            guard let icon = NSRunningApplication(processIdentifier: pair.icon.pid),
                  Self.iconBirth(icon) == pair.icon.launched, !icon.isTerminated,
                  icon.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == pair.icon.path,
                  icon.activationPolicy == .regular else { return false }
            icon.unhide()
            return icon.activate(options: [.activateAllWindows])
        }))
    }

    nonisolated static func hostURL(for app: AppReference) -> URL? {
        let iconName: String
        switch app.id {
        case "com.tencent.xinWeChat.WeChatHelper": iconName = "WeChatHelper.app"
        case "com.tencent.flue.WeChatAppEx": iconName = "WeChatAppEx.app"
        default: return nil
        }
        let icon = URL(fileURLWithPath: app.path).standardizedFileURL.resolvingSymlinksInPath()
        guard icon.lastPathComponent == iconName else { return nil }
        let macOS = icon.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let host = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", host.pathExtension == "app" else { return nil }
        return host
    }

    // DockIconService sometimes has no LaunchServices launchDate. A kernel
    // process birth time survives app focus changes and distinguishes recycled PIDs.
    nonisolated private static func iconBirth(_ app: NSRunningApplication) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(app.processIdentifier, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(app.processIdentifier), info.pbi_start_tvsec > 0 else { return app.launchDate }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    nonisolated static func isCurrentProxy(_ expected: Instance, host: AppReference) -> Bool {
        guard host.id == "com.tencent.xinWeChat", let current = NSRunningApplication(processIdentifier: expected.pid),
              !current.isTerminated, current.activationPolicy == .regular, current.processIdentifier == expected.pid,
              let id = current.bundleIdentifier, let path = current.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path,
              path == expected.path, iconBirth(current) == expected.launched else { return false }
        return hostURL(for: AppReference(id:id, name:"", path:path))?.path == host.path
    }

    nonisolated static func frontProxy(_ expected: Instance, host: AppReference) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == expected.pid && isCurrentProxy(expected, host: host)
    }

    /// The webpage renderer can have an offscreen companion surface in an
    /// accessory process of the same embedded bundle, even though its regular
    /// Dock process has no windows. This is only corroborating evidence when
    /// the actual proxy holds foreground and the host window is visibly exposed.
    private static func companionIDs(pair: Pair, windows: [DockWindowItem]) -> Set<CGWindowID> {
        guard !windows.isEmpty, let iconID = NSRunningApplication(processIdentifier:pair.icon.pid)?.bundleIdentifier else { return [] }
        let peers = Set(NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.bundleIdentifier == iconID && $0.activationPolicy == .accessory &&
                $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == pair.icon.path
        }.map(\.processIdentifier))
        guard !peers.isEmpty, let rows = CGWindowListCopyWindowInfo([.optionAll,.excludeDesktopElements], kCGNullWindowID)
            as? [[String:Any]] else { return [] }
        var hosts: [(id: CGWindowID, frame: CGRect)] = []
        var surfaces: [(id: CGWindowID, frame: CGRect)] = []
        for row in rows {
            guard let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid == pair.host.pid || peers.contains(pid),
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.05,
                  let dict = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation:dict as CFDictionary),
                  frame.width >= 80, frame.height >= 50 else { continue }
            if pid == pair.host.pid, let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value {
                hosts.append((id,frame))
            } else if peers.contains(pid), (row[kCGWindowIsOnscreen as String] as? Bool) != true,
                      let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value {
                surfaces.append((id, frame))
            }
        }
        return Set(windows.compactMap { window in
            guard let target = hosts.first(where: { $0.id == window.id.windowID }),
                  hosts.filter({ $0.frame == target.frame }).count == 1 else { return nil }
            let matches = surfaces.filter { $0.frame == target.frame }
            // These paired surfaces are allocated consecutively. If a future
            // build differs, use an observed reveal or an explicit user choice.
            guard matches.count == 1, let peer = matches.first, UInt64(peer.id) + 1 == UInt64(target.id) else { return nil }
            return window.id.windowID
        })
    }

    private static func livePair(_ app: AppReference) -> Pair? {
        guard let host = hostURL(for: app) else { return nil }
        func instance(id: String, url: URL, isIcon: Bool = false) -> Instance? {
            let expected = url.standardizedFileURL.resolvingSymlinksInPath().path
            let matches = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter {
                !$0.isTerminated && $0.activationPolicy == .regular &&
                    $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == expected
            }
            guard matches.count == 1, let process = matches.first, let date = isIcon ? iconBirth(process) : process.launchDate else { return nil }
            return Instance(pid: process.processIdentifier, launched: date, path: expected)
        }
        guard let icon = instance(id: app.id, url: URL(fileURLWithPath: app.path), isIcon: true),
              let owner = instance(id: "com.tencent.xinWeChat", url: host) else { return nil }
        return Pair(icon: icon, host: owner, hostApp: AppReference(id:"com.tencent.xinWeChat", name:"WeChat", path:owner.path))
    }

    func resolve(_ app: AppReference) async -> Resolution {
        guard let pair = environment.pair(app) else { return .ordinary }
        if binding?.pair != pair { binding = nil }
        guard !Task.isCancelled, let before = await environment.observe(pair),
              !Task.isCancelled, environment.pair(app) == pair else { return .ordinary }
        if let id = binding?.window {
            if let current = before.windows.first(where: { $0.id == id && pair.owns($0) }) {
                return .target(Self.forProxy(current, pair: pair, observation:before), pair)
            }
            binding = nil
        }
        guard environment.activate(pair) else { return .ordinary }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        var pending: DockWindowIdentity?
        for _ in 0..<18 {
            await environment.pause()
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline,
                  environment.pair(app) == pair else { break }
            guard let after = await environment.observe(pair) else { pending = nil; continue }
            guard !Task.isCancelled, environment.pair(app) == pair else { break }
            // Stop attributing focus to this click if the user switched away.
            guard after.frontPID == before.frontPID || after.frontPID == pair.icon.pid || after.frontPID == pair.host.pid else { break }
            if let restored = Self.newlyRestored(before:before, after:after, pair:pair), Self.mayLearn(restored, in:pair) {
                binding = (pair,restored.id)
                return .reveal(Self.forProxy(restored, pair:pair, observation:after),pair)
            }
            let revealed = Self.revealedWindow(before: before, after: after, pair: pair)
            let cold = Self.corroboratedFrontWindow(after, pair:pair)
            guard let candidate = revealed ?? cold, Self.mayLearn(candidate, in:pair) else {
                pending = nil
                continue
            }
            if pending == candidate.id {
                binding = (pair, candidate.id)
                // If the very first click already began on this foreground page,
                // a corroborated match can honor that click as a minimize.
                if revealed == nil, before.exposedIDs.contains(candidate.id.windowID),
                   before.companionIDs.contains(candidate.id.windowID),
                   before.frontPID == pair.icon.pid || (before.frontPID == pair.host.pid &&
                       before.windows.first(where: { $0.id == candidate.id })?.isFrontmost == true) {
                    return .target(Self.forProxy(candidate, pair:pair, observation:after), pair)
                }
                return .reveal(Self.forProxy(candidate,pair:pair,observation:after),pair)
            }
            pending = candidate.id
        }
        return .activationRequested
    }

    func choices(for app: AppReference) async -> (Pair, [DockWindowItem], DockWindowIdentity?)? {
        guard let pair = environment.pair(app), let snapshot = await environment.observe(pair),
              !Task.isCancelled, environment.pair(app) == pair else { return nil }
        let items = snapshot.windows.filter(pair.owns).map { Self.forProxy($0, pair: pair, observation:snapshot) }
        return (pair, items, binding?.pair == pair ? binding?.window : nil)
    }

    func remember(_ id: DockWindowIdentity, in pair: Pair) { binding = (pair,id) }

    private static func forProxy(_ item: DockWindowItem, pair: Pair, observation: Observation) -> DockWindowItem {
        var result = item
        result.foregroundProxy = pair.icon
        if observation.frontPID == pair.icon.pid && !item.isMinimized && observation.exposedIDs.contains(item.id.windowID) &&
            !observation.windows.contains(where: { $0.isFocused && $0.id != item.id }) {
            result.isFrontmost = true
        }
        return result
    }

    private static func mayLearn(_ window: DockWindowItem, in pair: Pair) -> Bool {
        // The main chat window commonly has the app's own title. A title can
        // disqualify a window but can never prove that it belongs to the browser.
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !["微信", "wechat", "weixin", pair.hostApp.name.lowercased()].contains(title)
    }

    private static func corroboratedFrontWindow(_ state: Observation, pair: Pair) -> DockWindowItem? {
        guard state.exposedIDs.count == 1, state.companionIDs.count == 1,
              let id = state.exposedIDs.first, state.companionIDs.contains(id),
              let target = state.windows.first(where: { pair.owns($0) && $0.id.windowID == id && !$0.isMinimized }),
              !state.windows.contains(where: { $0.isFocused && $0.id != target.id }) else { return nil }
        guard state.frontPID == pair.icon.pid ||
              (state.frontPID == pair.host.pid && target.isFrontmost && target.isFocused && target.isMain) else { return nil }
        return target
    }

    // The proxy can restore the browser and then immediately activate WeChat's
    // chat window. AX may still focus that chat, or nothing, when we sample.
    // A single exact host window making a real minimized -> onscreen transition
    // identifies what the targeted activation restored, even if it needs raising.
    private static func newlyRestored(before: Observation, after: Observation, pair: Pair) -> DockWindowItem? {
        guard after.frontPID == pair.icon.pid || after.frontPID == pair.host.pid else { return nil }
        let changes = after.windows.filter { item in
            pair.owns(item) && !item.isMinimized && after.visibleIDs.contains(item.id.windowID) &&
                !before.visibleIDs.contains(item.id.windowID)
        }
        guard changes.count == 1, let target = changes.first,
              before.windows.contains(where: { $0.id == target.id && $0.isMinimized }) else { return nil }
        return target
    }

    private static func revealedWindow(before: Observation, after: Observation, pair: Pair) -> DockWindowItem? {
        guard after.frontPID == pair.host.pid || after.frontPID == pair.icon.pid else { return nil }
        let candidates = after.windows.filter {
            pair.owns($0) && !$0.isMinimized && after.exposedIDs.contains($0.id.windowID) &&
                (after.frontPID == pair.icon.pid || ($0.isFrontmost && $0.isFocused))
        }
        guard candidates.count == 1, let target = candidates.first,
              !after.windows.contains(where: { $0.isFocused && $0.id != target.id }) else { return nil }
        let prior = before.windows.first { $0.id == target.id }
        guard prior?.isFrontmost != true else { return nil }
        let hadOtherFocus = before.windows.contains { pair.owns($0) && $0.isFocused && $0.id != target.id }
        let uncoveredByProxy = after.frontPID == pair.icon.pid && !before.exposedIDs.contains(target.id.windowID)
        guard !before.visibleIDs.contains(target.id.windowID) || prior?.isMinimized == true ||
              hadOtherFocus || uncoveredByProxy else { return nil }
        return target
    }
}
