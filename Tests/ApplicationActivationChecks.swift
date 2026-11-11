import AppKit
import DualDockCore

/// Application click routing with injected OS operations; no real app is activated.
@main
struct ApplicationActivationChecks {
    @MainActor
    static func main() {
        let path = "/Applications/Host.app/Contents/MacOS/Browser.app"
        let reference = AppReference(id: "example.browser", name: "Browser", path: path)
        let background = ApplicationActivationService.Process(pid: 10, bundleIdentifier: reference.id,
            bundlePath: path, launchDate: Date(timeIntervalSince1970: 10), regular: false,
            active: false, terminated: false)
        let browser = ApplicationActivationService.Process(pid: 20, bundleIdentifier: reference.id,
            bundlePath: path, launchDate: Date(timeIntervalSince1970: 20), regular: true,
            active: false, terminated: false)
        var activated: [pid_t] = [], restored: [pid_t] = [], opened: [URL] = [], failures: [String] = []
        let environment = ApplicationActivationService.Environment(
            processes: { [background, browser] }, windowOrder: { [20] },
            activate: { activated.append($0.pid); return true },
            restoreWindow: { restored.append($0.pid); return .raised }, fileExists: { _ in true },
            openApplication: { url, done in opened.append(url); done(nil) })
        ApplicationActivationService(environment: environment).open(reference, at: URL(fileURLWithPath: path)) {
            failures.append($0)
        }
        var checks = 0
        var errors = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { errors += 1; print("FAIL: \(message)") }
        }
        check(activated == [20], "The displayed browser's regular PID must activate, not its accessory twin")
        check(restored == [20], "Restore must target the same existing PID")
        check(opened.isEmpty, "Clicking an existing embedded helper must not reopen its bundle")
        check(failures.isEmpty, "A valid existing helper must not report a launch failure")

        typealias Process = ApplicationActivationService.Process
        func process(_ pid: pid_t, path: String = path, regular: Bool = true,
                     active: Bool = false, terminated: Bool = false, identifier: String = reference.id) -> Process {
            Process(pid: pid, bundleIdentifier: identifier, bundlePath: path,
                    launchDate: Date(timeIntervalSince1970: Double(pid)), regular: regular,
                    active: active, terminated: terminated)
        }
        func route(_ processes: [Process], order: [pid_t] = [], app: AppReference = reference,
                   fileExists: Bool = true, activatedResult: Bool = true,
                   windowResult: ApplicationActivationService.WindowRestoreResult = .raised) {
            activated = []; restored = []; opened = []; failures = []
            let environment = ApplicationActivationService.Environment(
                processes: { processes }, windowOrder: { order },
                activate: { activated.append($0.pid); return activatedResult },
                restoreWindow: { restored.append($0.pid); return windowResult },
                fileExists: { _ in fileExists },
                openApplication: { url, done in opened.append(url); done(nil) })
            ApplicationActivationService(environment: environment).open(app, at: URL(fileURLWithPath: app.path)) {
                failures.append($0)
            }
        }
        route([browser, background])
        check(activated == [20] && opened.isEmpty, "Process enumeration order changed the chosen helper")
        route([process(10, regular: false, active: true), browser])
        check(activated == [20], "Active accessory twin displaced the displayed regular process")
        route([process(30, path: "/Other/Browser.app", active: true), browser])
        check(activated == [20], "Same bundle ID at another path displaced the requested application")
        route([process(30, active: true), browser])
        check(activated == [30], "Exact active regular instance should win")
        route([process(30), browser], order: [99, 20, 30])
        check(activated == [20], "Frontmost owning-window process should resolve duplicate regular instances")
        route([process(30), browser])
        check(activated.isEmpty && restored.isEmpty && opened.isEmpty && failures.count == 1,
              "Ambiguous duplicate instances must not activate or reopen an arbitrary target")
        route([process(20, terminated: true), background])
        check(activated.isEmpty && opened.isEmpty && failures.count == 1, "Terminated helper must not relaunch")
        route([background])
        check(activated.isEmpty && opened.isEmpty && failures.count == 1, "Accessory-only embedded helper must not reopen")
        route([])
        check(activated.isEmpty && opened.isEmpty && failures.count == 1, "Missing embedded helper requires its host")
        route([process(20, identifier: "example.other")])
        check(activated.isEmpty && opened.isEmpty, "Path match with wrong bundle ID must not activate")
        route([browser], fileExists: false)
        check(activated == [20] && failures.isEmpty, "A live process must activate before checking its bundle on disk")
        route([browser], activatedResult: false, windowResult: .raised)
        check(failures.isEmpty && restored == [20] && opened.isEmpty, "A successful exact window raise is sufficient")
        route([browser], activatedResult: false, windowResult: .unavailable)
        check(failures.count == 1 && opened.isEmpty, "Failed helper activation must not launch a replacement instance")
        route([browser], windowResult: .noWindow)
        check(opened.isEmpty, "Windowless embedded helper must never be launched directly")

        let ordinary = AppReference(id: "example.editor", name: "Editor", path: "/Applications/Editor.app")
        route([], app: ordinary)
        check(opened == [URL(fileURLWithPath: ordinary.path)] && activated.isEmpty, "Nonrunning ordinary app must launch normally")
        route([], app: ordinary, fileExists: false)
        check(opened.isEmpty && failures.count == 1, "Missing ordinary app must show an error")
        route([process(40, path: ordinary.path, identifier: ordinary.id)], app: ordinary, windowResult: .noWindow)
        check(activated.isEmpty && restored.isEmpty && opened.count == 1,
              "Ordinary app without windows should use its native reopen action directly")
        route([process(40, path: ordinary.path, identifier: ordinary.id)], app: ordinary, windowResult: .unavailable)
        check(activated.isEmpty && restored.isEmpty && opened.count == 1,
              "Ordinary running app must receive native reopen even when AX is unavailable")
        route([process(40, path: ordinary.path, identifier: ordinary.id)], app: ordinary, windowResult: .raised)
        check(activated.isEmpty && restored.isEmpty && opened.count == 1,
              "Ordinary apps must not depend on AX window selection for Dock clicks")
        route([process(40, path: ordinary.path, identifier: ordinary.id),
               process(41, path: ordinary.path, identifier: ordinary.id)], app: ordinary, windowResult: .unavailable)
        check(opened.count == 1 && failures.isEmpty,
              "Multiple ordinary app instances/minimized windows must retain the system's reopen routing")
        route([browser], windowResult: .unavailable)
        check(activated == [20] && opened.isEmpty,
              "Unavailable AX data must not relaunch an embedded helper")

        typealias Window = ApplicationActivationService.WindowCandidate
        let visible = Window(token: 1, minimized: false)
        let minimized = Window(token: 2, minimized: true)
        func target(_ windows: [Window], focused: Int? = nil, main: Int? = nil) -> Int? {
            ApplicationActivationService.windowTarget(candidates: windows, focused: focused, main: main)
        }
        check(target([visible, minimized], focused: 2, main: 1) == 2, "Focused minimized window must be restored, not another visible window")
        check(target([visible, minimized], main: 2) == 2, "Known main minimized window must be restored")
        check(target([minimized]) == 2, "Unique minimized window must remain restorable")
        check(target([visible, minimized]) == 1, "Unique visible window should win when main/focused information is unavailable")
        check(target([visible], focused: 99) == nil, "Stale focused window must not fall through to another window")
        check(target([visible], main: 99) == nil, "Stale main window must not fall through to another window")
        check(target([minimized, Window(token: 3, minimized: true)]) == nil, "Multiple minimized windows are ambiguous")
        check(target([visible, Window(token: 3, minimized: false)]) == nil, "Multiple visible windows without focus/main are ambiguous")
        check(target([]) == nil, "Empty window list cannot yield a target")
        print("\(checks) application activation checks, \(errors) failures; injected operations only")
        exit(errors == 0 ? 0 : 1)
    }
}
