import AppKit
import DualDockCore

private final class RecoveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var completed: [pid_t] = []
    private var mainThread = false
    private var attemptCount = 0
    private var liveActive: Bool
    private let visible: Bool
    let started = DispatchSemaphore(value: 0)
    let gate: DispatchSemaphore?
    init(block: Bool = false, liveActive: Bool = true, visible: Bool = false) {
        gate = block ? DispatchSemaphore(value: 0) : nil
        self.liveActive = liveActive
        self.visible = visible
    }
    func setLiveActive(_ value: Bool) { lock.lock(); liveActive = value; lock.unlock() }
    func run(_ process: ApplicationActivationService.Process, _ cancellation: ActivationRecoveryCancellation) {
        lock.lock(); mainThread = mainThread || Thread.isMainThread; attemptCount += 1; lock.unlock()
        started.signal()
        gate?.wait()
        if !cancellation.isCancelled {
            lock.lock()
            if liveActive && !visible { completed.append(process.pid) }
            lock.unlock()
        }
    }
    var results: [pid_t] { lock.lock(); defer { lock.unlock() }; return completed }
    var usedMain: Bool { lock.lock(); defer { lock.unlock() }; return mainThread }
    var attempts: Int { lock.lock(); defer { lock.unlock() }; return attemptCount }
}

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
            openApplication: { url, done in opened.append(url); done(nil, nil) })
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
                openApplication: { url, done in opened.append(url); done(nil, nil) })
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
        let recovery = recoveryChecks()
        checks += recovery.checks
        errors += recovery.errors
        print("\(checks) application activation checks, \(errors) failures; injected operations only")
        exit(errors == 0 ? 0 : 1)
    }

    @MainActor private static func recoveryChecks() -> (checks: Int, errors: Int) {
        typealias Process = ApplicationActivationService.Process
        let app = AppReference(id: "example.editor", name: "Editor", path: "/Applications/Editor.app")
        let other = AppReference(id: "example.other", name: "Other", path: "/Applications/Other.app")
        func process(_ pid: pid_t = 42, app: AppReference = app, active: Bool = true,
                     regular: Bool = true, terminated: Bool = false, path: String? = nil) -> Process {
            Process(pid: pid, bundleIdentifier: app.id, bundlePath: path ?? app.path,
                    launchDate: Date(timeIntervalSince1970: Double(pid)), regular: regular,
                    active: active, terminated: terminated)
        }
        var checks = 0, errors = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { errors += 1; print("FAIL: \(message)") }
        }
        func wait(_ predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(1)
            while !predicate(), Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        func window(pid: pid_t = 42, frame: CGRect = CGRect(x: 0, y: 39, width: 1800, height: 1130),
                    layer: Int = 0, alpha: Double = 1, onscreen: Bool = true) -> [String: Any] {
            [kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowLayer as String: layer,
             kCGWindowAlpha as String: alpha, kCGWindowIsOnscreen as String: onscreen,
             kCGWindowBounds as String: frame.dictionaryRepresentation]
        }
        check(ApplicationActivationService.hasVisibleContentWindow(processID: 42, windows: [window()]),
              "A normal visible content window must skip further AX work")
        for row in [window(pid: 99), window(layer: 3), window(alpha: 0), window(onscreen: false),
                    window(frame: CGRect(x: 0, y: 0, width: 1800, height: 39)), window(frame: .infinite)] {
            check(!ApplicationActivationService.hasVisibleContentWindow(processID: 42, windows: [row]),
                  "A titlebar, hidden/foreign surface or invalid bound must not count as a visible editor")
        }
        func environment(_ recorder: RecoveryRecorder,
                         open: @escaping (URL, @escaping ApplicationActivationService.OpenCompletion) -> Void)
            -> ApplicationActivationService.Environment {
            .init(processes: { [process(99)] }, windowOrder: { [] }, activate: { _ in false },
                  restoreWindow: { _ in .unavailable }, fileExists: { _ in true },
                  openApplication: open, recoverAfterOpen: { recorder.run($0, $1) })
        }
        do {
            let recorder = RecoveryRecorder()
            var nativeCalls = 0
            let service = ApplicationActivationService(environment: environment(recorder) { _, done in
                nativeCalls += 1
                done(process(), nil)
            })
            service.open(app, at: URL(fileURLWithPath: app.path)) { _ in }
            wait { recorder.results == [42] }
            check(nativeCalls == 1, "Native reopen must remain first and unconditional")
            check(recorder.results == [42], "Accepted native reopen must recover its exact returned offscreen instance")
            check(!recorder.usedMain, "Post-open recovery must not block the visibility main actor")
        }
        for returned in [process(regular: false), process(terminated: true),
                         process(path: "/Other/Editor.app"), process(app: other)] {
            let recorder = RecoveryRecorder()
            var nativeCalls = 0
            let service = ApplicationActivationService(environment: environment(recorder) { _, done in
                nativeCalls += 1; done(returned, nil)
            })
            service.open(app, at: URL(fileURLWithPath: app.path)) { _ in }
            Thread.sleep(forTimeInterval: 0.15)
            check(nativeCalls == 1 && recorder.results.isEmpty,
                  "Stale, background, or substituted returned process must not trigger recovery")
        }
        do {
            let recorder = RecoveryRecorder(liveActive: false)
            let service = ApplicationActivationService(environment: environment(recorder) { _, done in
                done(process(active: false), nil)
            })
            let start = ProcessInfo.processInfo.systemUptime
            service.open(app, at: URL(fileURLWithPath: app.path)) { _ in }
            check(ProcessInfo.processInfo.systemUptime - start < 0.025, "Activation grace must not block native reopen")
            let timer = Timer(timeInterval: 0.02, repeats: false) { _ in recorder.setLiveActive(true) }
            RunLoop.main.add(timer, forMode: .common)
            wait { recorder.results == [42] }
            check(recorder.results == [42] && !recorder.usedMain,
                  "An inactive completion snapshot must not discard recovery after live activation catches up")
            timer.invalidate()
        }
        do {
            let recorder = RecoveryRecorder(liveActive: false)
            let service = ApplicationActivationService(environment: environment(recorder) { _, done in
                done(process(active: false), nil)
            })
            service.open(app, at: URL(fileURLWithPath: app.path)) { _ in }
            wait { recorder.attempts == 1 }
            check(recorder.attempts == 1 && recorder.results.isEmpty,
                  "An inactive callback must reach the delayed live check without acting while still inactive")
        }
        do {
            let recorder = RecoveryRecorder()
            let service = ApplicationActivationService(environment: environment(recorder) { _, done in done(process(), nil) })
            service.open(app, at: URL(fileURLWithPath: app.path)) { _ in }
            recorder.setLiveActive(false)
            wait { recorder.attempts == 1 }
            check(recorder.results.isEmpty, "A user focus change during the grace interval must win")
        }
        do {
            let recorder = RecoveryRecorder(visible: true)
            let service = ApplicationActivationService(environment: environment(recorder) { _, done in done(process(), nil) })
            service.open(app, at: URL(fileURLWithPath: app.path)) { _ in }
            wait { recorder.attempts == 1 }
            check(recorder.results.isEmpty, "An already-visible native success must not receive another window action")
        }
        do {
            let recorder = RecoveryRecorder()
            var calls = 0, failures = 0
            let service = ApplicationActivationService(environment: environment(recorder) { _, done in
                calls += 1; done(nil, nil)
            })
            service.open(app, at: URL(fileURLWithPath: app.path)) { _ in failures += 1 }
            Thread.sleep(forTimeInterval: 0.015)
            check(calls == 1 && failures == 0 && recorder.results.isEmpty,
                  "Missing process/AX data must never prevent a successful native reopen")
        }
        do {
            let recorder = RecoveryRecorder()
            var failures = 0
            let service = ApplicationActivationService(environment: environment(recorder) { _, done in
                done(process(), "native open failed")
            })
            service.open(app, at: URL(fileURLWithPath: app.path)) { _ in failures += 1 }
            check(failures == 1 && recorder.results.isEmpty, "Native errors must not schedule recovery")
        }
        do {
            let recorder = RecoveryRecorder()
            var completions: [ApplicationActivationService.OpenCompletion] = []
            let service = ApplicationActivationService(environment: environment(recorder) { _, done in completions.append(done) })
            service.open(app, at: URL(fileURLWithPath: app.path)) { _ in }
            service.open(other, at: URL(fileURLWithPath: other.path)) { _ in }
            completions[0](process(), nil)
            completions[1](process(43, app: other), nil)
            wait { recorder.results == [43] }
            check(recorder.results == [43], "An older native completion must not raise the previous application")
        }
        do {
            let recorder = RecoveryRecorder(block: true)
            var calls = 0
            let service = ApplicationActivationService(environment: environment(recorder) { _, done in
                calls += 1; done(process(pid_t(41 + calls)), nil)
            })
            service.open(app, at: URL(fileURLWithPath: app.path)) { _ in }
            check(recorder.started.wait(timeout: .now() + 1) == .success, "Recovery reader did not start")
            let start = ProcessInfo.processInfo.systemUptime
            service.open(app, at: URL(fileURLWithPath: app.path)) { _ in }
            check(ProcessInfo.processInfo.systemUptime - start < 0.025, "A blocked recovery delayed the next native open")
            recorder.gate?.signal()
            check(recorder.started.wait(timeout: .now() + 1) == .success, "Replacement recovery did not start")
            recorder.gate?.signal()
            wait { recorder.results == [43] }
            check(recorder.results == [43] && !recorder.usedMain,
                  "A later click must cancel an in-flight restore before any window action")
        }
        do {
            let recorder = RecoveryRecorder()
            var completion: ApplicationActivationService.OpenCompletion?
            let service = ApplicationActivationService(environment: environment(recorder) { _, done in completion = done })
            service.open(app, at: URL(fileURLWithPath: app.path)) { _ in }
            service.cancelPendingRecovery()
            completion?(process(), nil)
            Thread.sleep(forTimeInterval: 0.015)
            check(recorder.results.isEmpty, "Stopping the owner must suppress a late recovery")
        }
        do {
            let recorder = RecoveryRecorder(block: true)
            var service: ApplicationActivationService? = ApplicationActivationService(environment: environment(recorder) { _, done in done(process(), nil) })
            service?.open(app, at: URL(fileURLWithPath: app.path)) { _ in }
            check(recorder.started.wait(timeout: .now() + 1) == .success, "Lifetime recovery did not start")
            service = nil
            recorder.gate?.signal()
            Thread.sleep(forTimeInterval: 0.02)
            check(recorder.results.isEmpty, "A released activation owner must cancel outstanding window work")
        }
        return (checks, errors)
    }
}
