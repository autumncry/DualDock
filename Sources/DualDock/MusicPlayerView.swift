import AppKit
import SwiftUI

/// The shelf and its settings preview share a read-only face. Only the controls
/// in the expanded player send transport commands to Music.
struct MusicShelfFace: View {
    @Environment(\.dualDockLanguage) private var language
    @ObservedObject var data: ToolDataService
    let compact: Bool
    let horizontal: Bool

    var body: some View {
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(spacing: 3))
        return layout {
            MusicArtwork(bytes: data.player?.artwork, side: compact ? 25 : 28)
            if !compact {
                VStack(alignment: horizontal ? .leading : .center, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: horizontal && !compact ? .leading : .center)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if case .track(let title, _, _) = data.music { return title }
        return language("音乐", "Music")
    }

    private var subtitle: String {
        switch data.music {
        case .track(_, let artist, _): return artist
        case .disconnected: return language("连接 Apple Music", "Connect Apple Music")
        case .notRunning: return language("音乐未打开", "Music is closed")
        case .denied: return language("需要自动化权限", "Access needed")
        case .unavailable: return language("暂不可用", "Unavailable")
        case .idle: return language("暂无曲目", "No current track")
        }
    }
}

private struct MusicArtwork: View {
    let bytes: Data?
    let side: CGFloat
    @State private var cover: NSImage?

    var body: some View {
        Group {
            if let cover {
                Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.pink.opacity(0.12)
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.48, weight: .medium)).foregroundStyle(.pink)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.18, style: .continuous))
        .accessibilityHidden(true)
        .onChange(of: bytes, initial: true) { _, newValue in
            cover = newValue.flatMap(NSImage.init(data:))
        }
    }
}

struct MusicPlayerView: View {
    @Environment(\.dualDockLanguage) private var language
    @ObservedObject var data: ToolDataService
    @State private var sessionID = UUID()
    @State private var showsPlaylist = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case let .track(title, artist, playing) = data.music {
                HStack(spacing: 11) {
                    Button { _ = DockToolsStore.openApp("com.apple.Music") } label: {
                        MusicArtwork(bytes: data.player?.artwork, side: 53)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(language("在音乐 App 中打开", "Open in Music"))
                    .help(language("在音乐 App 中打开", "Open in Music"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                        if !artist.isEmpty {
                            Text(artist).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .help([title, artist, data.player?.album ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    Spacer(minLength: 0)
                    playlistButton
                }
                if let player = data.player, let duration = player.duration, duration > 0,
                   duration.isFinite, player.position != nil {
                    MusicProgressView(player: player, duration: duration, seek: data.seekMusic)
                        .id(player.trackID)
                }
                HStack(spacing: 18) {
                    transport("backward.fill", language("上一曲", "Previous Track"), id: "Previous", action: data.previousTrack)
                    transport(playing ? "pause.fill" : "play.fill",
                              playing ? language("暂停", "Pause") : language("继续播放", "Resume"),
                              id: "PlayPause", size: 25, action: data.togglePlayback)
                    transport("forward.fill", language("下一曲", "Next Track"), id: "Next", action: data.nextTrack)
                }
                .frame(maxWidth: .infinity)
                .disabled(data.musicBusy)
                if data.musicActionFailed {
                    Text(language("音乐未完成这次操作，请重试。", "Music couldn’t complete that action. Try again."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if showsPlaylist { playlist }
            } else {
                emptyPlayer
            }
        }
        .padding(16)
        .frame(width: 302)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("DualDock3.Music.Player")
        .onAppear { data.setMusicPanelVisible(true, id: sessionID) }
        .onDisappear {
            data.setMusicPlaylistVisible(false, id: sessionID)
            data.setMusicPanelVisible(false, id: sessionID)
        }
        .onChange(of: showsPlaylist) { _, open in data.setMusicPlaylistVisible(open, id: sessionID) }
        .onChange(of: data.music) { _, state in
            if case .track = state { return }
            showsPlaylist = false
        }
    }

    private var playlistButton: some View {
        let label = language("当前播放列表", "Current Playlist")
        return Button { showsPlaylist.toggle() } label: {
            Image(systemName: "list.bullet").font(.system(size: 15, weight: .medium))
                .foregroundStyle(showsPlaylist ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label).help(label)
        .accessibilityIdentifier("DualDock3.Music.Playlist")
    }

    private func transport(_ symbol: String, _ label: String, id: String,
                           size: CGFloat = 21, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .frame(width: 45, height: 35).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label).help(label)
        .accessibilityIdentifier("DualDock3.Music." + id)
    }

    @ViewBuilder private var playlist: some View {
        Divider()
        if let list = data.playlist, !list.tracks.isEmpty {
            Text(list.name.isEmpty ? language("当前播放列表", "Current Playlist") : list.name)
                .font(.headline).lineLimit(1)
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(list.tracks, id: \.index) { row in
                            let current = row.id == data.player?.trackID
                            Button { data.playMusicTrack(row) } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: current ? "speaker.wave.2.fill" : "music.note")
                                        .frame(width: 15).foregroundStyle(current ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(row.title).lineLimit(1)
                                        if !row.artist.isEmpty {
                                            Text(row.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .font(.system(size: 12)).padding(5).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(current ? Color.accentColor.opacity(0.10) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                            .disabled(data.musicBusy).id(row.index)
                        }
                    }
                }
                .frame(height: min(166, CGFloat(list.tracks.count) * 38))
                .onAppear {
                    if let current = list.tracks.first(where: { $0.id == data.player?.trackID }) {
                        scroll.scrollTo(current.index, anchor: .center)
                    }
                }
            }
            if list.totalCount > list.tracks.count {
                HStack {
                    Text("\(list.tracks.count) / \(list.totalCount)").monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button(language("载入更多", "Load More"), action: data.loadMoreMusicTracks)
                        .disabled(data.musicPlaylistLoading)
                }.font(.caption)
            }
        } else if data.musicPlaylistLoading {
            ProgressView(language("正在读取播放列表…", "Loading playlist…")).controlSize(.small)
        } else {
            Text(data.playlist == nil
                 ? language("音乐 App 没有提供当前播放列表。", "Music has no current playlist to show.")
                 : language("当前播放列表为空。", "The current playlist is empty."))
                .font(.callout).foregroundStyle(.secondary)
            Button(language("刷新列表", "Refresh Playlist"), action: data.refreshMusicPlaylist)
                .controlSize(.small)
        }
    }

    @ViewBuilder private var emptyPlayer: some View {
        HStack(spacing: 10) {
            MusicArtwork(bytes: nil, side: 45)
            VStack(alignment: .leading, spacing: 2) {
                Text(language("正在播放", "Now Playing")).font(.headline)
                Text("Apple Music").foregroundStyle(.secondary).font(.subheadline)
            }
        }
        switch data.music {
        case .disconnected:
            Text(language("连接后可以查看当前曲目和控制播放。", "Connect to see the current track and playback controls."))
                .font(.callout).foregroundStyle(.secondary)
            Button(language("连接 Apple Music", "Connect Apple Music"), action: data.enableMusic).disabled(data.musicBusy)
        case .notRunning, .idle:
            Text(data.music == .notRunning ? language("音乐 App 尚未打开。", "Music is not running.") :
                    language("当前没有播放的曲目。", "There is no current track."))
                .font(.callout).foregroundStyle(.secondary)
            Button(language("打开音乐", "Open Music")) { _ = DockToolsStore.openApp("com.apple.Music") }
        case .denied:
            Text(language("在自动化设置中允许 DualDock 控制「音乐」。", "Allow DualDock to control Music in Automation settings."))
                .font(.callout).foregroundStyle(.secondary)
            Button(language("打开自动化设置", "Open Automation Settings")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .unavailable:
            Text(language("音乐 App 暂时没有响应。", "Music is not responding.")).foregroundStyle(.secondary)
            Button(language("重新连接", "Reconnect"), action: data.enableMusic).disabled(data.musicBusy)
        case .track: EmptyView()
        }
    }
}

private struct MusicProgressView: View {
    @Environment(\.dualDockLanguage) private var language
    let player: ToolMusicPlayer
    let duration: Double
    let seek: (Double, String) -> Void
    @State private var scrubPosition: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { clock in
            let elapsed = max(0, min(duration, scrubPosition ?? player.position(at: clock.date) ?? 0))
            HStack(spacing: 6) {
                Text(Self.time(elapsed))
                Slider(value: Binding(get: { elapsed }, set: { scrubPosition = $0 }), in: 0...duration) { editing in
                    if !editing, let scrubPosition {
                        seek(scrubPosition, player.trackID)
                        self.scrubPosition = nil
                    }
                }
                .controlSize(.small).tint(.secondary)
                .accessibilityLabel(language("播放进度", "Playback position"))
                Text("−" + Self.time(duration - elapsed))
            }
            .font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private static func time(_ value: Double) -> String {
        let seconds = Int(value.rounded(.down))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
