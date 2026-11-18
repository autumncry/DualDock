import Combine
import Foundation
import ServiceManagement

/// ServiceManagement owns this preference. Merely opening Settings never
/// registers the app, and a failed request never becomes a saved local toggle.
@MainActor
final class LaunchAtLoginService: ObservableObject {
    enum Status: Equatable { case notRegistered, enabled, requiresApproval, notFound, unknown }

    struct Environment {
        var status: () -> Status
        var register: () throws -> Void
        var unregister: () throws -> Void
        var openSettings: () -> Void

        static func system() -> Environment {
            let service = SMAppService.mainApp
            return Environment(status: {
                switch service.status {
                case .notRegistered: return .notRegistered
                case .enabled: return .enabled
                case .requiresApproval: return .requiresApproval
                case .notFound: return .notFound
                @unknown default: return .unknown
                }
            }, register: { try service.register() },
               unregister: { try service.unregister() },
               openSettings: { SMAppService.openSystemSettingsLoginItems() })
        }
    }

    @Published private(set) var status: Status
    @Published private(set) var errorMessage: String?
    private let environment: Environment

    init(environment: Environment? = nil) {
        let environment = environment ?? .system()
        self.environment = environment
        status = environment.status()
    }

    var isEnabled: Bool { status == .enabled }
    var canChangeRegistration: Bool { status != .notFound && status != .unknown }

    func refresh() {
        let next = environment.status()
        if next != status { errorMessage = nil }
        status = next
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        refresh()
        guard canChangeRegistration else {
            errorMessage = status == .notFound
                ? "系统未找到可注册的应用，请从“应用程序”中的 DualDock 重新打开。"
                : "暂时无法读取登录启动状态，请稍后重试。"
            return
        }
        if enabled && (status == .enabled || status == .requiresApproval) { return }
        if !enabled && status == .notRegistered { return }
        do {
            if enabled { try environment.register() }
            else { try environment.unregister() }
            refresh()
            if enabled && status != .enabled && status != .requiresApproval {
                errorMessage = "系统尚未启用登录启动，请稍后重试。"
            } else if !enabled && status != .notRegistered {
                errorMessage = "系统尚未关闭登录启动，请稍后重试。"
            }
        } catch {
            refresh()
            // A concurrent system change may have completed the requested state
            // even when registration reports an already-registered error.
            if enabled && (status == .enabled || status == .requiresApproval) { return }
            if !enabled && status == .notRegistered { return }
            errorMessage = "无法\(enabled ? "开启" : "关闭")登录启动：\(error.localizedDescription)"
        }
    }

    func openSystemSettings() { environment.openSettings() }
}
