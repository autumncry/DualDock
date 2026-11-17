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
    let isFrontmost: Bool
    var isFocused: Bool = false
    var isMain: Bool = false
}

struct DockWindowListSnapshot: Sendable {
    let items: [DockWindowItem]
    let selectedID: DockWindowIdentity?
}

enum DockWindowInventory: Sendable {
    case available([DockWindowItem])
    case unavailable
    case permissionDenied
}

enum WindowInteractionResult: Equatable {
    case handled
    case fallbackToApplication
    case failure(String)
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
        var invalidate: () -> Void = {}

        static func system() -> Environment {
            let backend = WindowInteractionBackend()
            return Environment(read: { app in await backend.read(for: app) },
                               perform: { item, action, app in await backend.perform(item, action: action, for: app) },
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
            guard case .available(let items) = inventory else {
                return .failure("暂时无法读取这个窗口，请稍后重试或检查辅助功能权限。")
            }
            guard let fresh = items.first(where: { $0.id == item.id }) else {
                return .failure("这个窗口已关闭或发生变化，请重新打开窗口列表。")
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
                return self.selected[self.key(app)] == nil ? .fallbackToApplication
                    : .failure("暂时无法读取已选窗口，请稍后重试。")
            }
            guard let target = self.preferred(in: items, for: app) else { return .fallbackToApplication }
            let action: DockWindowAction
            if target.isMinimized { action = .restore }
            else if target.isFullscreen || target.isMaximized || !target.isFrontmost { action = .activate }
            else { action = .minimize }
            return await self.act(target, action: action, for: app, request: request, beforePerform: beforePerform)
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
                     request: UInt64, beforePerform: @MainActor () -> Void) async -> WindowInteractionResult {
        guard generation == request, !Task.isCancelled else { return .handled }
        beforePerform()
        guard generation == request, !Task.isCancelled else { return .handled }
        let result = await environment.perform(item, action, app)
        guard generation == request, !Task.isCancelled else { return .handled }
        switch result {
        case .performed:
            selected[key(app)] = item.id
            return .handled
        case .missing: return .failure("这个窗口已关闭或发生变化，请重新选择。")
        case .unsupported: return .failure("这个窗口不支持最小化，请使用原应用的窗口控制。")
        case .failed: return .failure("应用暂未接受窗口操作，请稍后重试。")
        case .superseded: return .handled
        }
    }
}
