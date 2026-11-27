import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ToolMusicPlayer: Equatable, Sendable {
    let trackID: String
    let title: String
    let artist: String
    let album: String
    let playing: Bool
    let position: Double?
    let duration: Double?
    let sampledAt: Date
    let artwork: Data?

    func position(at date: Date) -> Double? {
        guard let position, position.isFinite, position >= 0 else { return nil }
        let elapsed = playing ? max(0, date.timeIntervalSince(sampledAt)) : 0
        let value = position + elapsed
        return min(value, duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? value)
    }

    var state: ToolMusicState { .track(title: title, artist: artist, playing: playing) }
}

enum ToolMusicPlayerRead: Equatable, Sendable {
    case player(ToolMusicPlayer)
    case unavailable(ToolMusicState)
}

struct ToolMusicRow: Equatable, Sendable, Identifiable {
    let id: String
    let playlistID: String
    let index: Int   // One-based, matching Music's object model.
    let title: String
    let artist: String
}

struct ToolMusicPlaylist: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let tracks: [ToolMusicRow]
    let totalCount: Int
}

enum ToolMusicArtwork {
    static let maxBytes = 8 * 1024 * 1024

    /// Decode at display scale on the Music worker queue. Do not load an entire
    /// full-resolution album image into AppKit on every SwiftUI update.
    static func thumbnail(_ bytes: Data) -> Data? {
        guard !bytes.isEmpty, bytes.count <= maxBytes,
              let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 180
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
