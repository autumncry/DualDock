import AppKit
import Carbon

enum ToolMusicState: Equatable, Sendable {
    case disconnected, notRunning, idle, denied, unavailable
    case track(title: String, artist: String, playing: Bool)
}

enum ToolMusicCommand: Equatable, Sendable {
    case status, toggle, previous, next
    case seek(seconds: Double, trackID: String)
    case play(ToolMusicRow)
}

/// All Apple events address an already-running PID. Reads never open Music or
/// ask for permission. Explicit connection is the only operation that may prompt.
final class ToolMusicClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DualDock3.Music", qos: .userInitiated)
    // Accessed only on queue. The current artwork is never written to disk.
    private var lastArt: (id: String, data: Data?, checkedAt: Date)?

    func perform(_ command: ToolMusicCommand, requestPermission: Bool) async -> ToolMusicState {
        await onQueue(cancelled: .unavailable) {
            do {
                let reader = try self.reader(allowPrompt: requestPermission)
                try reader.perform(command)
                return try reader.state()
            } catch { return Self.failure(error) }
        }
    }

    func player() async -> ToolMusicPlayerRead {
        await onQueue(cancelled: .unavailable(.unavailable)) {
            do {
                let reader = try self.reader(allowPrompt: false)
                let result = try reader.player { id, track in
                    if let cached = self.lastArt, cached.id == id,
                       cached.data != nil || Date().timeIntervalSince(cached.checkedAt) < 45 {
                        return cached.data
                    }
                    let art = try? reader.artwork(of: track)
                    self.lastArt = (id, art, Date())
                    return art
                }
                return .player(result)
            } catch {
                self.lastArt = nil
                return .unavailable(Self.failure(error))
            }
        }
    }

    func playlist(offset: Int) async -> ToolMusicPlaylist? {
        await onQueue(cancelled: nil) { try? self.reader(allowPrompt: false).playlist(offset: offset) }
    }

    private func onQueue<T: Sendable>(cancelled fallback: T, _ operation: @escaping @Sendable () -> T) async -> T {
        let ticket = Progress(totalUnitCount: 1)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: ticket.isCancelled ? fallback : operation())
                }
            }
        } onCancel: { ticket.cancel() }
    }

    private func reader(allowPrompt: Bool) throws -> MusicEventReader {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first,
              !app.isTerminated else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(procNotFound)) }
        let target = NSAppleEventDescriptor(processIdentifier: app.processIdentifier)
        let permission = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, allowPrompt)
        guard permission == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(permission)) }
        return MusicEventReader(target: target)
    }

    private static func failure(_ error: Error) -> ToolMusicState {
        switch (error as NSError).code {
        case Int(errAEEventWouldRequireUserConsent): return .disconnected
        case Int(errAEEventNotPermitted): return .denied
        case Int(procNotFound), Int(connectionInvalid): return .notRunning
        case Int(errAENoSuchObject): return .idle
        default: return .unavailable
        }
    }
}

/// Property and command codes come from com.apple.Music.sdef in Music.app.
/// A sequence of optional properties shares one deadline, even if Music hangs.
struct MusicEventReader {
    typealias Descriptor = NSAppleEventDescriptor
    typealias Transport = (Descriptor, TimeInterval) throws -> Descriptor
    private let target: Descriptor
    private let transport: Transport
    private let deadline = ProcessInfo.processInfo.systemUptime + 2.7
    static let pageSize = 40

    init(target: Descriptor, transport: @escaping Transport = { event, timeout in
        try event.sendEvent(options: [.waitForReply, .neverInteract, .dontRecord], timeout: timeout)
    }) {
        self.target = target
        self.transport = transport
    }

    func perform(_ command: ToolMusicCommand) throws {
        switch command {
        case .status: break
        case .toggle: _ = try event("hook", "PlPs")
        case .previous: _ = try event("hook", "Prev")
        case .next: _ = try event("hook", "Next")
        case .seek(let seconds, let expected):
            let track = try reference("pTrk")
            guard seconds.isFinite, !expected.isEmpty, try text("pPIS", of: track) == expected,
                  let duration = try number("pDur", of: track), duration > 0 else { throw CocoaError(.userCancelled) }
            let position = Descriptor(double: max(0, min(seconds, duration)))
            _ = try event("core", "setd", object: property("pPos"), parameter: ("data", position))
        case .play(let row):
            let playlist = try reference("pPla")
            guard row.index >= 1, row.index <= Int(Int32.max), !row.id.isEmpty,
                  try text("pPIS", of: playlist) == row.playlistID else { throw CocoaError(.userCancelled) }
            let track = try element("cTrk", index: row.index, of: playlist)
            // Resolve the indexed slot to its stable Music object before playback;
            // an old row must never start a different track after a playlist edit.
            guard let resolved = try read(track), resolved.descriptorType == typeObjectSpecifier,
                  try text("pPIS", of: resolved) == row.id else { throw CocoaError(.userCancelled) }
            _ = try event("hook", "Play", object: resolved)
        }
    }

    func state() throws -> ToolMusicState {
        let playing = try playingState()
        let track = try property("pTrk")
        let title = try requiredTitle(track)
        return .track(title: title, artist: (try? text("pArt", of: track)) ?? "", playing: playing)
    }

    func player(art: (String, Descriptor) -> Data?) throws -> ToolMusicPlayer {
        let playing = try playingState()
        let track = try reference("pTrk")
        let title = try requiredTitle(track)
        let artist = (try? text("pArt", of: track)) ?? ""
        let album = (try? text("pAlb", of: track)) ?? ""
        // Some radio streams have no library identifier. They can still display
        // metadata, but Music cannot reliably target them for a seek.
        let persistent = (try? text("pPIS", of: track)).flatMap { $0.isEmpty ? nil : $0 }
        let id = persistent ?? [title, artist, album].joined(separator: "\u{1f}")
        let duration = (try? number("pDur", of: track)).flatMap { $0 > 0 ? $0 : nil }
        let position = persistent == nil ? nil : try? number("pPos")
        let time = Date()
        return ToolMusicPlayer(trackID: id, title: title, artist: artist, album: album, playing: playing,
                               position: position, duration: duration, sampledAt: time, artwork: art(id, track))
    }

    func artwork(of track: Descriptor) throws -> Data? {
        let item = try element("cArt", index: 1, of: track)
        guard let raw = try read(property("pRaw", of: item)), AEGetDescDataSize(raw.aeDesc) <= ToolMusicArtwork.maxBytes else { return nil }
        return ToolMusicArtwork.thumbnail(raw.data)
    }

    func playlist(offset: Int) throws -> ToolMusicPlaylist {
        guard (0..<Int(Int32.max)).contains(offset) else { throw CocoaError(.validationNumberTooLarge) }
        let list = try reference("pPla")
        guard let id = try text("pPIS", of: list), !id.isEmpty else { throw statusError(errAENoSuchObject) }
        let name = (try? text("pnam", of: list)) ?? ""
        let reply = try event("core", "cnte", object: list, parameter: ("kocl", .init(typeCode: code("cTrk"))))
        guard let count = reply.paramDescriptor(forKeyword: keyDirectObject)?.coerce(toDescriptorType: typeSInt32),
              count.int32Value >= 0 else { throw CocoaError(.coderInvalidValue) }
        let total = Int(count.int32Value)
        guard offset < total else {
            return ToolMusicPlaylist(id: id, name: name, tracks: [], totalCount: total)
        }
        let last = min(total, offset + Self.pageSize)
        // Use three bounded projection requests, irrespective of playlist size.
        let range = try trackRange(offset + 1, last, in: list)
        let ids = try strings("pPIS", of: range, count: last - offset)
        let titles = try strings("pnam", of: range, count: last - offset)
        let artists = (try? strings("pArt", of: range, count: last - offset)) ?? []
        let rows = try ids.enumerated().map { index, trackID in
            guard !trackID.isEmpty, !titles[index].isEmpty else { throw CocoaError(.coderInvalidValue) }
            return ToolMusicRow(id: trackID, playlistID: id, index: offset + index + 1,
                                title: titles[index], artist: artists.isEmpty ? "" : artists[index])
        }
        return ToolMusicPlaylist(id: id, name: name, tracks: rows, totalCount: total)
    }

    private func playingState() throws -> Bool {
        guard let value = try read(property("pPlS")) else { throw CocoaError(.coderInvalidValue) }
        if value.enumCodeValue == code("kPSS") { throw statusError(errAENoSuchObject) }
        return value.enumCodeValue == code("kPSP")
    }

    private func requiredTitle(_ track: Descriptor) throws -> String {
        guard let title = try text("pnam", of: track), !title.isEmpty else { throw statusError(errAENoSuchObject) }
        return title
    }

    private func reference(_ name: String) throws -> Descriptor {
        guard let reference = try read(property(name)), reference.descriptorType == typeObjectSpecifier else {
            throw statusError(errAENoSuchObject)
        }
        return reference
    }

    private func text(_ name: String, of object: Descriptor) throws -> String? {
        try read(property(name, of: object))?.stringValue
    }

    private func number(_ name: String, of object: Descriptor = .null()) throws -> Double? {
        guard let value = try read(property(name, of: object))?.coerce(toDescriptorType: typeIEEE64BitFloatingPoint) else { return nil }
        return value.doubleValue.isFinite && value.doubleValue >= 0 ? value.doubleValue : nil
    }

    private func strings(_ name: String, of object: Descriptor, count: Int) throws -> [String] {
        guard let value = try read(property(name, of: object)) else { throw CocoaError(.coderInvalidValue) }
        if value.descriptorType != typeAEList, count == 1, let text = value.stringValue { return [text] }
        guard value.descriptorType == typeAEList, value.numberOfItems == count else { throw CocoaError(.coderInvalidValue) }
        return (1...count).map { value.atIndex($0)?.stringValue ?? "" }
    }

    private func read(_ object: Descriptor) throws -> Descriptor? {
        try event("core", "getd", object: object).paramDescriptor(forKeyword: keyDirectObject)
    }

    private func event(_ suite: String, _ verb: String, object: Descriptor? = nil,
                       parameter: (String, Descriptor)? = nil) throws -> Descriptor {
        let time = deadline - ProcessInfo.processInfo.systemUptime
        guard time > 0 else { throw statusError(errAETimeout) }
        let event = Descriptor(eventClass: code(suite), eventID: code(verb), targetDescriptor: target,
                               returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let object { event.setParam(object, forKeyword: keyDirectObject) }
        if let (key, value) = parameter { event.setParam(value, forKeyword: code(key)) }
        let reply = try transport(event, min(time, 0.9))
        if let error = reply.paramDescriptor(forKeyword: keyErrorNumber), error.int32Value != 0 { throw statusError(Int(error.int32Value)) }
        return reply
    }

    private func trackRange(_ start: Int, _ end: Int, in playlist: Descriptor) throws -> Descriptor {
        let range = Descriptor.record()
        guard let container = Descriptor(descriptorType: typeCurrentContainer, data: Data()) else { throw CocoaError(.coderInvalidValue) }
        range.setDescriptor(try element("cTrk", index: start, of: container), forKeyword: AEKeyword(keyAERangeStart))
        range.setDescriptor(try element("cTrk", index: end, of: container), forKeyword: AEKeyword(keyAERangeStop))
        guard let data = range.coerce(toDescriptorType: typeRangeDescriptor) else { throw CocoaError(.coderInvalidValue) }
        return try specifier(want: code("cTrk"), form: formRange, data: data, container: playlist)
    }

    private func element(_ name: String, index: Int, of container: Descriptor) throws -> Descriptor {
        try specifier(want: code(name), form: formAbsolutePosition, data: .init(int32: Int32(index)), container: container)
    }

    private func property(_ name: String, of container: Descriptor = .null()) throws -> Descriptor {
        try specifier(want: typeProperty, form: formPropertyID, data: .init(typeCode: code(name)), container: container)
    }

    private func specifier(want: OSType, form: Int, data: Descriptor, container: Descriptor) throws -> Descriptor {
        let record = Descriptor.record()
        record.setDescriptor(.init(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(.init(enumCode: OSType(form)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(data, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        guard let result = record.coerce(toDescriptorType: typeObjectSpecifier) else { throw CocoaError(.coderInvalidValue) }
        return result
    }

    private func code(_ chars: String) -> OSType { chars.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    private func statusError(_ value: Int) -> NSError { NSError(domain: NSOSStatusErrorDomain, code: value) }
}
