import Foundation

/// Exercises the production service against injected system state. These checks
/// never register/unregister the actual app or open System Settings.
@main
struct LaunchAtLoginChecks {
    @MainActor static func main() {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        enum Failure: LocalizedError {
            case rejected
            var errorDescription: String? { "Fixture request rejected" }
        }
        var systemState: LaunchAtLoginService.Status = .notRegistered
        var registers = 0, unregisters = 0, settingsOpens = 0
        var registerResult: LaunchAtLoginService.Status = .enabled
        var unregisterResult: LaunchAtLoginService.Status = .notRegistered
        var registerFails = false, unregisterFails = false
        var stateBeforeRegisterError: LaunchAtLoginService.Status?
        let service = LaunchAtLoginService(environment: .init(
            status: { systemState },
            register: {
                registers += 1
                if registerFails {
                    if let stateBeforeRegisterError { systemState = stateBeforeRegisterError }
                    throw Failure.rejected
                }
                systemState = registerResult
            },
            unregister: {
                unregisters += 1
                if unregisterFails { throw Failure.rejected }
                systemState = unregisterResult
            },
            openSettings: { settingsOpens += 1 }))

        check(service.status == .notRegistered && !service.isEnabled, "Fresh service did not show disabled state")
        check(registers == 0 && unregisters == 0, "Initialization changed login registration")
        service.refresh()
        check(registers == 0 && unregisters == 0, "Refreshing changed login registration")
        service.setEnabled(false)
        check(unregisters == 0, "Disabling an unregistered service made a needless request")
        service.setEnabled(true)
        check(registers == 1 && service.isEnabled && service.errorMessage == nil, "Enable did not follow system registration")
        service.setEnabled(true)
        check(registers == 1, "Already enabled service registered again")
        service.setEnabled(false)
        check(unregisters == 1 && !service.isEnabled && service.errorMessage == nil, "Disable did not follow system state")

        registerFails = true
        service.setEnabled(true)
        check(!service.isEnabled && service.errorMessage?.contains("Fixture request rejected") == true,
              "Registration error was hidden or optimistically enabled the toggle")
        systemState = .enabled
        service.refresh()
        check(service.isEnabled && service.errorMessage == nil, "External enable did not refresh or clear stale failure")
        unregisterFails = true
        service.setEnabled(false)
        check(service.isEnabled && service.errorMessage?.contains("Fixture request rejected") == true,
              "Unregister error incorrectly disabled the toggle")
        systemState = .notRegistered
        service.refresh()
        check(!service.isEnabled && service.errorMessage == nil, "External disable left stale status or error")

        registerFails = false; unregisterFails = false
        registerResult = .requiresApproval
        service.setEnabled(true)
        check(service.status == .requiresApproval && !service.isEnabled && service.errorMessage == nil,
              "Pending approval was reported as active or failed")
        let beforePendingRetry = registers
        service.setEnabled(true)
        check(registers == beforePendingRetry, "Pending service was repeatedly registered")
        service.openSystemSettings()
        check(settingsOpens == 1 && service.status == .requiresApproval, "System settings request mutated registration")
        service.setEnabled(false)
        check(service.status == .notRegistered && service.errorMessage == nil,
              "Pending registration could not be cancelled")

        // The API may report denied/already-registered while the status query
        // already reflects approval pending or an external successful change.
        registerFails = true
        for observed in [LaunchAtLoginService.Status.requiresApproval, .enabled] {
            stateBeforeRegisterError = observed
            service.setEnabled(true)
            check(service.status == observed && service.isEnabled == (observed == .enabled)
                    && service.errorMessage == nil, "Actual registration state was replaced by an obsolete request error")
            service.setEnabled(false)
            check(service.status == .notRegistered, "Status-after-error fixture failed to reset")
        }
        registerFails = false
        stateBeforeRegisterError = nil

        registerResult = .notRegistered
        service.setEnabled(true)
        check(!service.isEnabled && service.errorMessage != nil,
              "Successful call with unchanged system status was reported as enabled")
        systemState = .enabled; service.refresh()
        unregisterResult = .enabled
        service.setEnabled(false)
        check(service.isEnabled && service.errorMessage != nil,
              "Successful unregister call with still-enabled status was reported as disabled")

        for unavailable in [LaunchAtLoginService.Status.notFound, .unknown] {
            systemState = unavailable; service.refresh()
            let before = (registers, unregisters)
            check(!service.canChangeRegistration && !service.isEnabled, "Unavailable system service stayed editable")
            service.setEnabled(true)
            check(registers == before.0 && unregisters == before.1 && service.errorMessage != nil,
                  "Unavailable service attempted registration or swallowed its condition")
        }
        check(settingsOpens == 1, "A state refresh or mutation opened System Settings unexpectedly")
        failures.forEach { print("FAIL: \($0)") }
        print("Login startup checks: \(checks), failures: \(failures.count); injected state only")
        exit(failures.isEmpty ? 0 : 1)
    }
}
