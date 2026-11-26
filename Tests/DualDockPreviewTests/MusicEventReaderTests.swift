import AppKit
import Carbon
import XCTest
@testable import DualDock

final class MusicEventReaderTests: XCTestCase {
    private typealias Descriptor = NSAppleEventDescriptor
    private func code(_ name: String) -> UInt32 { name.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

    private final class Catalog {
        typealias Descriptor = NSAppleEventDescriptor
        let total = 83
        var id = "song"
        var playlistID = "library"
        var sent = [UInt32]()
        var mutationObjects = [Descriptor]()
        var positions = [Double]()
        var ranges = [ClosedRange<Int>]()
        var timeout: TimeInterval = 0
        private func code(_ name: String) -> OSType { name.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
        private func texts(_ values: [String]) -> Descriptor {
            let list = Descriptor.list()
            for (index, value) in values.enumerated() { list.insert(.init(string: value), at: index + 1) }
            return list
        }

        func transport(_ event: Descriptor, _ timeout: TimeInterval) throws -> Descriptor {
            self.timeout = max(self.timeout, timeout)
            sent.append(event.eventID)
            let reply = Descriptor(eventClass: 0, eventID: 0, targetDescriptor: .null(), returnID: -1, transactionID: 0)
            let object = event.paramDescriptor(forKeyword: keyDirectObject)
            let key = AEKeyword(keyAEKeyData)
            let container = AEKeyword(keyAEContainer)
            func answer(_ value: Descriptor) { reply.setParam(value, forKeyword: keyDirectObject) }
            switch event.eventID {
            case code("cnte"):
                XCTAssertEqual(event.paramDescriptor(forKeyword: code("kocl"))?.typeCodeValue, code("cTrk"))
                answer(.init(int32: Int32(total)))
            case code("getd"):
                let prop = object?.forKeyword(key)?.typeCodeValue
                let owner = object?.forKeyword(container)
                if owner?.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue == UInt32(formRange) {
                    let range = try XCTUnwrap(owner?.forKeyword(key))
                    XCTAssertEqual(range.descriptorType, typeRangeDescriptor)
                    let first = Int(try XCTUnwrap(range.forKeyword(AEKeyword(keyAERangeStart))?.forKeyword(key)?.int32Value))
                    let last = Int(try XCTUnwrap(range.forKeyword(AEKeyword(keyAERangeStop))?.forKeyword(key)?.int32Value))
                    let indices = first...last
                    ranges.append(indices)
                    switch prop {
                    case code("pPIS"): answer(texts(indices.map { "song-\($0)" }))
                    case code("pnam"): answer(texts(indices.map { "Track \($0)" }))
                    case code("pArt"): answer(texts(indices.map { _ in "Artist" }))
                    default: XCTFail("Unexpected playlist projection")
                    }
                } else {
                    switch prop {
                    case code("pPlS"): answer(.init(enumCode: code("kPSP")))
                    case code("pTrk"), code("pPla"):
                        answer(try XCTUnwrap(object))
                    case code("pPIS"):
                        answer(.init(string: owner?.forKeyword(key)?.typeCodeValue == code("pPla") ? playlistID : id))
                    case code("pnam"): answer(.init(string: "Name"))
                    case code("pArt"): answer(.init(string: "Artist"))
                    case code("pAlb"): answer(.init(string: "Album"))
                    case code("pPos"): answer(.init(double: 24))
                    case code("pDur"): answer(.init(double: 100))
                    default:
                        XCTAssertEqual(object?.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue, code("cTrk"))
                        answer(try XCTUnwrap(object))
                    }
                }
            case code("setd"):
                XCTAssertEqual(object?.forKeyword(key)?.typeCodeValue,code("pPos"))
                positions.append(try XCTUnwrap(event.paramDescriptor(forKeyword:code("data"))?.doubleValue))
            case code("Play"): mutationObjects.append(try XCTUnwrap(object))
            case code("PlPs"), code("Next"), code("Prev"): break
            default: XCTFail("Unexpected Music command")
            }
            return reply
        }

        var reader: MusicEventReader { .init(target: .null(), transport: transport) }
    }

    func testOpeningAndSamplingOnlySendGetEvents() throws {
        let catalog = Catalog()
        let data = Data([1, 2, 3])
        let player = try catalog.reader.player { id, _ in
            XCTAssertEqual(id, "song")
            return data
        }
        XCTAssertEqual(player.title, "Name")
        XCTAssertEqual(player.artist, "Artist")
        XCTAssertEqual(player.album, "Album")
        XCTAssertEqual(player.artwork, data)
        XCTAssertEqual(player.position(at: player.sampledAt.addingTimeInterval(4)), 28)
        XCTAssertEqual(player.position(at: player.sampledAt.addingTimeInterval(100)), 100)
        XCTAssertEqual(player.position(at: player.sampledAt.addingTimeInterval(-6)), 24)
        XCTAssertTrue(catalog.sent.allSatisfy { $0 == code("getd") })
        XCTAssertLessThanOrEqual(catalog.timeout,0.9)
    }

    func testPlaylistProjectsOnlyTheRequestedPageAndDoesNotStartPlayback() throws {
        let catalog = Catalog()
        for (offset, range) in [(0,1...40), (40,41...80), (80,81...83)] {
            catalog.ranges.removeAll()
            let page = try catalog.reader.playlist(offset: offset)
            XCTAssertEqual(page.tracks.map(\.index), Array(range))
            XCTAssertEqual(page.tracks.map(\.id), range.map { "song-\($0)" })
            XCTAssertEqual(page.totalCount,83)
            XCTAssertEqual(catalog.ranges,[range,range,range])
            XCTAssertEqual(page.tracks.first?.playlistID,"library")
        }
        XCTAssertEqual(try catalog.reader.playlist(offset: 83).tracks, [])
        XCTAssertTrue(catalog.sent.allSatisfy { $0 == code("getd") || $0 == code("cnte") })
    }

    func testStaleSongOrChangedPlaylistCannotSeekOrPlayADifferentTrack() throws {
        let catalog = Catalog()
        let row = ToolMusicRow(id: "song", playlistID: "library", index: 5, title: "Name", artist: "Artist")
        try catalog.reader.perform(.seek(seconds: 130, trackID: "song"))
        try catalog.reader.perform(.seek(seconds: -12, trackID: "song"))
        XCTAssertThrowsError(try catalog.reader.perform(.seek(seconds: .infinity, trackID: "song")))
        XCTAssertThrowsError(try catalog.reader.perform(.seek(seconds: 30, trackID: "stale")))
        XCTAssertEqual(catalog.positions, [100,0])
        try catalog.reader.perform(.play(row))
        catalog.id = "other song"
        XCTAssertThrowsError(try catalog.reader.perform(.play(row)))
        catalog.id = "song"
        catalog.playlistID = "other playlist"
        XCTAssertThrowsError(try catalog.reader.perform(.play(row)))
        XCTAssertEqual(catalog.mutationObjects.count,1)
        for action in [ToolMusicCommand.previous,.toggle,.next] { try catalog.reader.perform(action) }
        XCTAssertEqual(catalog.sent.suffix(3), [code("Prev"),code("PlPs"),code("Next")])
    }

    func testArtworkRejectsInvalidOrOversizedInputAndDownsamplesValidImages() throws {
        XCTAssertNil(ToolMusicArtwork.thumbnail(Data([0, 1])))
        XCTAssertNil(ToolMusicArtwork.thumbnail(Data(repeating: 0, count: ToolMusicArtwork.maxBytes + 1)))
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 500, pixelsHigh: 300,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow:0, bitsPerPixel:0))
        let source = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        let preview = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(ToolMusicArtwork.thumbnail(source))))
        XCTAssertEqual(preview.pixelsWide,180)
        XCTAssertLessThanOrEqual(preview.pixelsHigh,180)
    }
}
