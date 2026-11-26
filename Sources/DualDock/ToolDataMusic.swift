import AppKit
import Carbon

enum ToolMusicState: Equatable, Sendable {
    case disconnected, notRunning, idle, denied, unavailable
    case track(title: String, artist: String, playing: Bool)
}

enum ToolMusicCommand: Sendable { case status, toggle, next }

/// Use Music's shipped scripting dictionary and address its running PID.
/// A PID-targeted event cannot relaunch Music if it exits during a read.
final class ToolMusicClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DualDock3.Music", qos: .userInitiated)

    func perform(_ command: ToolMusicCommand, requestPermission: Bool) async -> ToolMusicState {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.send(command, requestPermission: requestPermission))
            }
        }
    }

    private func send(_ command: ToolMusicCommand, requestPermission: Bool) -> ToolMusicState {
        guard let player = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first,
              !player.isTerminated else { return .notRunning }
        let target = NSAppleEventDescriptor(processIdentifier: player.processIdentifier)
        let permission = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, requestPermission)
        switch permission {
        case noErr: break
        case OSStatus(errAEEventWouldRequireUserConsent): return .disconnected
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return player.isTerminated ? .notRunning : .unavailable
        }
        do {
            switch command {
            case .toggle: _ = try sendEvent("hook", "PlPs", to: target)
            case .next: _ = try sendEvent("hook", "Next", to: target)
            case .status: break
            }
            let state = try read(property("pPlS"), from: target)?.enumCodeValue
            if state == code("kPSS") { return .idle }
            let currentTrack = try property("pTrk")
            guard let title = try read(property("pnam", of: currentTrack), from: target)?.stringValue,
                  !title.isEmpty else { return .idle }
            let artist = try? read(property("pArt", of: currentTrack), from: target)?.stringValue
            return .track(title: title, artist: artist ?? "", playing: state == code("kPSP"))
        } catch {
            let errorCode = (error as NSError).code
            if errorCode == Int(errAEEventNotPermitted) { return .denied }
            if errorCode == Int(errAENoSuchObject) { return .idle }
            return player.isTerminated ? .notRunning : .unavailable
        }
    }

    private func read(_ object: NSAppleEventDescriptor, from target: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor? {
        try sendEvent("core", "getd", to: target, object: object)?.paramDescriptor(forKeyword: keyDirectObject)
    }

    private func sendEvent(_ eventClass: String, _ eventID: String, to target: NSAppleEventDescriptor,
                           object: NSAppleEventDescriptor? = nil) throws -> NSAppleEventDescriptor? {
        let event = NSAppleEventDescriptor(eventClass: code(eventClass), eventID: code(eventID),
            targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let object { event.setParam(object, forKeyword: keyDirectObject) }
        let reply = try event.sendEvent(options: [.waitForReply, .neverInteract, .dontRecord], timeout: 0.9)
        if let failure = reply.paramDescriptor(forKeyword: keyErrorNumber), failure.int32Value != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(failure.int32Value))
        }
        return reply
    }

    private func property(_ name: String, of container: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(.init(typeCode: typeProperty), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(.init(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(.init(typeCode: code(name)), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        guard let object = record.coerce(toDescriptorType: typeObjectSpecifier) else { throw CocoaError(.coderInvalidValue) }
        return object
    }

    private func code(_ characters: String) -> OSType {
        characters.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
