import AppKit
import DualDockCore

struct DockWindowIdentity: Hashable, Sendable {
    let pid: pid_t
    let processLaunchDate: Date
    let applicationPath: String
    let windowID: CGWindowID
}

struct DockWindowItem: Identifiable, Equatable, Sendable {
    let id: DockWindowIdentity
    let title: String
    let frame: CGRect
    let isMinimized: Bool
    let isFullscreen: Bool
    let isMaximized: Bool
    var isFrontmost: Bool
    var isFocused: Bool = false
    var isMain: Bool = false
    // A regular nested Dock icon may be frontmost on behalf of this exact window.
    var foregroundProxy: WeChatBrowserWindowRouter.Instance?
}

struct DockWindowListSnapshot: Sendable {
    let items: [DockWindowItem]
    let selectedID: DockWindowIdentity?
    var isHostedChoice = false
}

enum DockWindowInventory: Sendable {
    case available([DockWindowItem])
    case unavailable
    case permissionDenied
}

enum WindowInteractionResult: Equatable {
    case handled
    case fallbackToApplication
    /// The exact target cannot currently be resolved. Do not reopen a different
    /// window or leave an unrelated, persistent warning in Settings.
    case targetUnavailable
    case failure(LocalizedNotice)
}

enum DockWindowAction: Equatable, Sendable { case activate, restore, minimize }
enum DockWindowActionOutcome: Equatable, Sendable { case performed, missing, unsupported, failed, superseded }

/// Selection is session-local and tied to an exact process incarnation/window.
/// Fresh reads decide every click; requested operations are serialized so an
/// in-flight native minimize cannot turn two clicks into duplicate minimizes.
@MainActor
final class WindowInteractionService {
    @MainActor struct Environment {
        var read: (AppReference) async -> DockWindowInventory
        var perform: (DockWindowItem, DockWindowAction, AppReference) async -> DockWindowActionOutcome
        var recover: (DockWindowIdentity, AppReference) async -> Bool = { _, _ in false }
        var browser: WeChatBrowserWindowRouter?
        var invalidate: () -> Void = {}

        static func system() -> Environment {
            let backend = WindowInteractionBackend()
            let browser = WeChatBrowserWindowRouter(backend: backend)
            return Environment(read: { app in await backend.read(for: app) },
                               perform: { item, action, app in await backend.perform(item, action: action, for: app) },
                               recover: { identity, app in await backend.recover(identity, for: app) },
                               browser: browser,
                               invalidate: { backend.cancel() })
        }
    }

    private let environment: Environment
    private var selected: [String: DockWindowIdentity] = [:]
    private var generation: UInt64 = 0
    private var operationID: UInt64 = 0
    private var pending: Task<WindowInteractionResult, Never>?

    init(environment: Environment? = nil) { self.environment = environment ?? .system() }

    func list(for app: AppReference) async -> DockWindowListSnapshot {
        let request = generation
        if let pending { _ = await pending.value }
        guard request == generation, !Task.isCancelled else { return .init(items: [], selectedID: nil) }
        let inventory = await environment.read(app)
        guard request == generation, !Task.isCancelled else { return .init(items: [], selectedID: nil) }
        guard case .available(let items) = inventory else { return .init(items: [], selectedID: nil) }
        if items.isEmpty, WeChatBrowserWindowRouter.hostURL(for: app) != nil,
           let (_, choices, id) = await environment.browser?.choices(for: app),
           request == generation, !Task.isCancelled {
            return .init(items: choices, selectedID: id, isHostedChoice: true)
        }
        let target = preferred(in: items, for: app)
        return .init(items: items, selectedID: target?.id)
    }

    func select(_ item: DockWindowItem, for app: AppReference,
                beforePerform: @escaping @MainActor () -> Void = {}) async -> WindowInteractionResult {
        cancel()
        return await enqueue { [weak self] in
            guard let self else { return .handled }
            let request = self.generation
            let inventory = await self.environment.read(app)
            guard request == self.generation, !Task.isCancelled else { return .handled }
            let items: [DockWindowItem]
            switch inventory {
            case .available(let available): items = available
            case .unavailable: return .targetUnavailable
            case .permissionDenied:
                return .failure(LocalizedNotice("暂时无法读取这个窗口，请稍后重试或检查辅助功能权限。", "Couldn’t read this window. Try again or check Accessibility permission."))
            }
            if items.isEmpty, WeChatBrowserWindowRouter.hostURL(for: app) != nil, let browser = self.environment.browser,
               let (pair, choices, _) = await browser.choices(for: app), item.foregroundProxy == pair.icon,
               let fresh = choices.first(where: { $0.id == item.id }) {
                return await self.act(fresh, action: fresh.isMinimized ? .restore : .activate,
                                      for: app, owner:pair.hostApp, request:request, beforePerform:beforePerform,
                                      onPerformed: { browser.remember(fresh.id,in:pair) })
            }
            guard let fresh = items.first(where: { $0.id == item.id }) else {
                return .targetUnavailable
            }
            return await self.act(fresh, action: fresh.isMinimized ? .restore : .activate,
                                  for: app, request: request, beforePerform: beforePerform)
        }
    }

    func toggle(for app: AppReference,
                beforePerform: @escaping @MainActor () -> Void = {}) async -> WindowInteractionResult {
        await enqueue { [weak self] in
            guard let self else { return .handled }
            let request = self.generation
            let inventory = await self.environment.read(app)
            guard request == self.generation, !Task.isCancelled else { return .handled }
            let items: [DockWindowItem]
            switch inventory {
            case .available(let available): items = available
            case .permissionDenied: return .fallbackToApplication
            case .unavailable:
                guard let retained = self.selected[self.key(app)] else { return .fallbackToApplication }
                beforePerform()
                let recovered = await self.environment.recover(retained, app)
                guard request == self.generation, !Task.isCancelled else { return .handled }
                return recovered ? .handled : .targetUnavailable
            }
            let target: DockWindowItem
            let owner: AppReference
            var forceActivation = false
            if let direct = self.preferred(in: items, for: app) {
                target = direct
                owner = app
            } else if WeChatBrowserWindowRouter.hostURL(for: app) != nil, let browser = self.environment.browser {
                beforePerform()
                let route = await browser.resolve(app)
                guard request == self.generation, !Task.isCancelled else { return .handled }
                switch route {
                case .ordinary: return .fallbackToApplication
                case .activationRequested: return .handled
                case .target(let window, let pair): target = window; owner = pair.hostApp
                case .reveal(let window, let pair):
                    target = window
                    owner = pair.hostApp
                    forceActivation = true
                }
            } else {
                return .fallbackToApplication
            }
            let action: DockWindowAction
            if target.isMinimized { action = .restore }
            else if forceActivation || target.isFullscreen || target.isMaximized || !target.isFrontmost { action = .activate }
            else { action = .minimize }
            return await self.act(target, action: action, for: app, owner: owner, request: request,
                                  beforePerform: owner == app ? beforePerform : {})
        }
    }

    func remember(_ preview: WindowPreview, for app: AppReference) {
        guard let date = preview.processLaunchDate, let path = preview.applicationPath, preview.windowID != 0 else { return }
        cancel()
        selected[key(app)] = .init(pid: preview.pid, processLaunchDate: date,
                                  applicationPath: URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path,
                                  windowID: preview.windowID)
    }

    func cancel() {
        generation &+= 1
        environment.invalidate()
        pending?.cancel()
        pending = nil
        operationID &+= 1
    }

    private func key(_ app: AppReference) -> String { app.id + "\n" + URL(fileURLWithPath: app.path).standardizedFileURL.path }

    private func preferred(in items: [DockWindowItem], for app: AppReference) -> DockWindowItem? {
        // Only a complete inventory can prove that the remembered window closed.
        if let id = selected[key(app)], let retained = items.first(where: { $0.id == id }) { return retained }
        selected.removeValue(forKey: key(app))
        return items.first(where: \.isFrontmost) ?? items.first(where: \.isFocused)
            ?? items.first(where: \.isMain) ?? items.first
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> WindowInteractionResult) async -> WindowInteractionResult {
        let previous = pending
        let request = generation
        operationID &+= 1
        let id = operationID
        let next = Task { @MainActor [weak self] in
            if let previous { _ = await previous.value }
            guard let self, self.generation == request, !Task.isCancelled else { return WindowInteractionResult.handled }
            return await operation()
        }
        pending = next
        let result = await next.value
        if operationID == id { pending = nil }
        return result
    }

    private func act(_ item: DockWindowItem, action: DockWindowAction, for app: AppReference,
                     owner: AppReference? = nil, request: UInt64, beforePerform: @MainActor () -> Void,
                     onPerformed: () -> Void = {}) async -> WindowInteractionResult {
        guard generation == request, !Task.isCancelled else { return .handled }
        beforePerform()
        guard generation == request, !Task.isCancelled else { return .handled }
        let result = await environment.perform(item, action, owner ?? app)
        guard generation == request, !Task.isCancelled else { return .handled }
        switch result {
        case .performed:
            onPerformed()
            selected[key(app)] = item.id
            return .handled
        case .missing: return .targetUnavailable
        case .unsupported: return .failure(LocalizedNotice("这个窗口不支持最小化，请使用原应用的窗口控制。", "This window does not support minimizing. Use its app’s window controls."))
        case .failed: return .failure(LocalizedNotice("应用暂未接受窗口操作，请稍后重试。", "The app didn’t accept the window action. Try again."))
        case .superseded: return .handled
        }
    }
}
