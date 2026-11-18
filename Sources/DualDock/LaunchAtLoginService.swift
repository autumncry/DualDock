import Combine
import Foundation
import ServiceManagement

/// ServiceManagement owns this preference. Merely opening Settings never
/// registers the app, and a failed request never becomes a saved local toggle.
@MainActor
final class LaunchAtLoginService: ObservableObject {
    enum Status: String, Equatable { case notRegistered, enabled, requiresApproval, notFound, unknown }

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
    @Published private var failure: Failure?
    private enum Failure {
        case statusUnavailable, enablePending, disablePending
        case rejected(enabling: Bool, details: String)
    }

    var errorMessage: String? {
        switch failure {
        case nil: return nil
        case .statusUnavailable: return L("暂时无法读取登录启动状态，请稍后重试。", "The login item status is unavailable. Try again later.")
        case .enablePending: return L("系统尚未启用登录启动，请稍后重试。", "macOS has not enabled launch at login. Try again later.")
        case .disablePending: return L("系统尚未关闭登录启动，请稍后重试。", "macOS still lists the login item. Try again later.")
        case .rejected(let enabling, let details):
            return (enabling ? L("无法开启登录启动", "Could not enable launch at login")
                             : L("无法关闭登录启动", "Could not disable launch at login")) + " · " + details
        }
    }
    private let environment: Environment

    init(environment: Environment? = nil) {
        let environment = environment ?? .system()
        self.environment = environment
        status = environment.status()
    }

    var isEnabled: Bool { status == .enabled }
    var canChangeRegistration: Bool { status != .unknown }

    func refresh() {
        let next = environment.status()
        if next != status { failure = nil }
        status = next
    }

    func setEnabled(_ enabled: Bool) {
        failure = nil
        refresh()
        guard canChangeRegistration else {
            failure = .statusUnavailable
            return
        }
        if enabled && (status == .enabled || status == .requiresApproval) { return }
        if !enabled && (status == .notRegistered || status == .notFound) { return }
        do {
            if enabled { try environment.register() }
            else { try environment.unregister() }
            refresh()
            if enabled && status != .enabled && status != .requiresApproval {
                failure = .enablePending
            } else if !enabled && status != .notRegistered && status != .notFound {
                failure = .disablePending
            }
        } catch {
            refresh()
            // A concurrent system change may have completed the requested state
            // even when registration reports an already-registered error.
            if enabled && (status == .enabled || status == .requiresApproval) { return }
            if !enabled && (status == .notRegistered || status == .notFound) { return }
            failure = .rejected(enabling: enabled, details: error.localizedDescription)
        }
    }

    func openSystemSettings() { environment.openSettings() }
}
