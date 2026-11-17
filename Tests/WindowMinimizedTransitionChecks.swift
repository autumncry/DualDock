import AppKit
import ApplicationServices
import DualDockCore

/// The actual transition policy with a virtual clock and native-state sequence.
/// No Accessibility calls, application launches or real window actions occur.
@main
struct WindowMinimizedTransitionChecks {
    static func main() {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        final class Fixture {
            var time: TimeInterval = 0
            var current = true
            var exists = true
            var pressCount = 0
            var capabilityCount = 0
            var setCount = 0
            var reads = 0
            var states: [Bool?] = []
            var afterRead: (() -> Void)?

            func validate() -> DockWindowActionOutcome? {
                !current ? .superseded : (!exists ? .missing : nil)
            }

            func confirm(_ desired: Bool) -> DockWindowActionOutcome {
                WindowMinimizedTransition.confirm(desired, deadline: 1,
                    isCurrent: { self.current }, exists: { self.exists }, read: {
                        self.reads += 1
                        let value = self.states.isEmpty ? nil : self.states.removeFirst()
                        self.afterRead?()
                        return value
                    }, now: { self.time }, pause: { self.time += 0.1 })
            }

            func run(desired: Bool = true, press: AXError? = .cannotComplete,
                     setter: AXError = .cannotComplete) -> DockWindowActionOutcome {
                let nativePress: (() -> AXError)? = press.map { result in
                    { self.pressCount += 1; return result }
                }
                return WindowMinimizedTransition.perform(press: nativePress, canSet: {
                    self.capabilityCount += 1
                    return .success
                }, set: {
                    self.setCount += 1
                    return setter
                }, validate: validate, confirm: { self.confirm(desired) })
            }
        }

        let delayedPress = Fixture()
        delayedPress.states = [false, nil, nil, true]
        check(delayedPress.run() == .performed, "timed-out press did not confirm later native minimized state")
        check(delayedPress.pressCount == 1 && delayedPress.capabilityCount == 0 && delayedPress.setCount == 0,
              "uncertain press dispatched a redundant capability query or attribute mutation")
        check(delayedPress.reads == 4 && delayedPress.time >= 0.3,
              "press timeout was reported successful without waiting for native state")

        let noCompletion = Fixture()
        check(noCompletion.run() == .failed, "unconfirmed press timeout was reported successful")
        check(noCompletion.time >= 1 && noCompletion.time < 1.2, "uncertain request did not use a bounded confirmation deadline")
        check(noCompletion.setCount == 0, "unconfirmed press timeout retried the mutation")

        let unsupportedPress = Fixture()
        unsupportedPress.states = [false, nil, true]
        check(unsupportedPress.run(press: .actionUnsupported) == .performed,
              "definitely unsupported press did not confirm uncertain attribute fallback")
        check(unsupportedPress.pressCount == 1 && unsupportedPress.setCount == 1,
              "unsupported press did not issue exactly one attribute fallback")

        let restore = Fixture()
        restore.states = [true, nil, false]
        check(restore.run(desired: false, press: nil) == .performed, "restore setter timeout did not confirm restored state")
        check(restore.pressCount == 0 && restore.setCount == 1 && restore.reads == 3,
              "restore confirmation repeated or omitted its native mutation")

        let cancelled = Fixture()
        cancelled.states = [false]
        cancelled.afterRead = { cancelled.current = false }
        check(cancelled.run() == .superseded, "cancellation during uncertain state confirmation was not respected")
        check(cancelled.setCount == 0 && cancelled.reads == 1, "canceled confirmation dispatched another mutation or read")

        let cancelledDuringFinalRead = Fixture()
        cancelledDuringFinalRead.states = [true]
        cancelledDuringFinalRead.afterRead = { cancelledDuringFinalRead.current = false }
        check(cancelledDuringFinalRead.run(press: .success) == .superseded,
              "cancellation during the final native read was reported as performed")

        let closed = Fixture()
        closed.states = [false]
        closed.afterRead = { closed.exists = false }
        check(closed.run() == .missing, "lost process/window identity did not abort uncertain confirmation")
        check(closed.setCount == 0 && closed.reads == 1, "closed target caused a fallback or another read")

        let closedDuringFinalRead = Fixture()
        closedDuringFinalRead.states = [true]
        closedDuringFinalRead.afterRead = { closedDuringFinalRead.exists = false }
        check(closedDuringFinalRead.run(press: .success) == .missing,
              "identity loss during the final native read was reported as performed")

        let invalidElement = Fixture()
        check(invalidElement.run(press: .invalidUIElement) == .missing, "invalid AX element was treated as an unsupported action")
        check(invalidElement.setCount == 0 && invalidElement.reads == 0, "invalid AX element was mutated again")

        let accepted = Fixture()
        accepted.states = [false, true]
        check(accepted.run(press: .success) == .performed, "successful press no longer confirms native state")
        check(accepted.setCount == 0 && accepted.reads == 2, "successful press used redundant attribute fallback")

        let stoppedBeforeWrite = Fixture()
        var staleWrites = 0
        let stoppedResult = WindowMinimizedTransition.perform(canSet: {
            stoppedBeforeWrite.exists = false
            return .success
        }, set: { staleWrites += 1; return .success }, validate: stoppedBeforeWrite.validate,
            confirm: { stoppedBeforeWrite.confirm(true) })
        check(stoppedResult == .missing && staleWrites == 0,
              "target disappearance during capability query still dispatched attribute mutation")

        let unsupportedAttribute = Fixture()
        check(unsupportedAttribute.run(press: nil, setter: .attributeUnsupported) == .unsupported,
              "definitively unsupported attribute was not reported accurately")

        print("Window minimized transition: \(checks) checks, \(failures.count) failures; injected native results and virtual time only")
        failures.forEach { print("FAIL: \($0)") }
        if !failures.isEmpty { exit(1) }
    }
}
