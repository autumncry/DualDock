import Combine
import Foundation

/// One service per trial configuration, shared by all Dock windows. Poll each
/// source only while a visible tools page includes a card that uses that source.
@MainActor
final class ToolDataService: ObservableObject {
    struct Environment {
        var music: @Sendable (ToolMusicCommand, Bool) async -> ToolMusicState
        var calendar: @Sendable (Bool) async -> ToolCalendarState
        var conditions: @Sendable (ToolWeatherCity) async throws -> ToolWeatherReading
        var cities: @Sendable (String, String) async throws -> [ToolWeatherCity]
        var musicPlayer: @Sendable () async -> ToolMusicPlayerRead = { .unavailable(.unavailable) }
        var musicPlaylist: @Sendable (Int) async -> ToolMusicPlaylist? = { _ in nil }
        var now: () -> Date = Date.init

        static func system() -> Self {
            let music = ToolMusicClient()
            let calendar = ToolCalendarClient()
            let weather = ToolForecastClient()
            return Self(music: { await music.perform($0, requestPermission: $1) },
                        calendar: { await calendar.load(requestPermission: $0) },
                        conditions: { try await weather.conditions(in: $0) },
                        cities: { try await weather.search($0, language: $1) },
                        musicPlayer: { await music.player() },
                        musicPlaylist: { await music.playlist(offset: $0) })
        }
    }

    private struct Demand: OptionSet {
        let rawValue: Int
        static let music = Self(rawValue: 1)
        static let calendar = Self(rawValue: 2)
        static let weather = Self(rawValue: 4)
    }

    private struct Saved: Codable {
        var musicEnabled = false
        var lastWeather: ToolWeatherReading?
    }

    @Published private(set) var music: ToolMusicState = .disconnected
    @Published private(set) var player: ToolMusicPlayer?
    @Published private(set) var playlist: ToolMusicPlaylist?
    @Published private(set) var musicPlaylistLoading = false
    @Published private(set) var musicActionFailed = false
    @Published private(set) var calendar: ToolCalendarState = .notDetermined
    @Published private(set) var weather: ToolWeatherState = .noCity
    @Published private(set) var musicBusy = false
    @Published private(set) var calendarBusy = false

    private let environment: Environment
    private let stateFile: URL
    private var state: Saved
    private var displays: [String: Demand] = [:]
    private var demand: Demand = []
    private var city: ToolWeatherCity?
    private var musicLoop: Task<Void, Never>?
    private var calendarLoop: Task<Void, Never>?
    private var weatherLoop: Task<Void, Never>?
    private var musicAction: Task<Void, Never>?
    private var calendarAuthorization: Task<Void, Never>?
    private var musicPanels = Set<UUID>()
    private var playlistPanels = Set<UUID>()
    private var playlistRequest: Task<Void, Never>?
    private var musicRevision = 0
    private var calendarRevision = 0

    init(directory: URL, environment: Environment? = nil) {
        self.environment = environment ?? .system()
        stateFile = directory.appendingPathComponent("tool-provider-state.json")
        state = (try? JSONDecoder().decode(Saved.self, from: Data(contentsOf: stateFile))) ?? Saved()
    }

    deinit {
        musicLoop?.cancel()
        calendarLoop?.cancel()
        weatherLoop?.cancel()
        musicAction?.cancel()
        playlistRequest?.cancel()
        calendarAuthorization?.cancel()
    }

    func setVisible(_ visible: Bool, for displayID: String,
                    music: Bool = true, calendar: Bool = true, weather: Bool = true) {
        var requests: Demand = []
        if visible {
            if music { requests.insert(.music) }
            if calendar { requests.insert(.calendar) }
            if weather { requests.insert(.weather) }
        }
        displays[displayID] = requests.isEmpty ? nil : requests
        let next = displays.values.reduce(into: Demand()) { $0.formUnion($1) }
        let previous = demand
        demand = next
        for source in [Demand.music, .calendar, .weather] where previous.contains(source) != next.contains(source) {
            switch source {
            case .music: if musicPanels.isEmpty { updateMusicLoop() }
            case .calendar: updateCalendarLoop()
            default: updateWeatherLoop()
            }
        }
    }

    func enableMusic() {
        if !state.musicEnabled {
            state.musicEnabled = true
            save()
        }
        runMusic(.status, requestPermission: true)
        if musicLoop == nil { updateMusicLoop() }
    }

    func togglePlayback() { runMusic(.toggle) }
    func previousTrack() { runMusic(.previous) }
    func nextTrack() { runMusic(.next) }

    func seekMusic(to seconds: Double, trackID: String) {
        guard seconds.isFinite, let player, player.trackID == trackID,
              let duration = player.duration, duration.isFinite, duration > 0 else { return }
        runMusic(.seek(seconds: max(0, min(duration, seconds)), trackID: trackID))
    }

    func playMusicTrack(_ row: ToolMusicRow) {
        guard playlist?.id == row.playlistID, playlist?.tracks.contains(row) == true else { return }
        runMusic(.play(row))
    }

    func setMusicPanelVisible(_ visible: Bool, id: UUID) {
        let hadPanel = !musicPanels.isEmpty
        if visible { musicPanels.insert(id) } else {
            musicPanels.remove(id)
            setMusicPlaylistVisible(false, id: id)
        }
        if hadPanel != !musicPanels.isEmpty {
            musicActionFailed = false
            updateMusicLoop()
        }
    }

    func setMusicPlaylistVisible(_ visible: Bool, id: UUID) {
        let wasOpen = !playlistPanels.isEmpty
        if visible && musicPanels.contains(id) { playlistPanels.insert(id) } else { playlistPanels.remove(id) }
        if !wasOpen && !playlistPanels.isEmpty { refreshMusicPlaylist() }
        if wasOpen && playlistPanels.isEmpty { clearPlaylist() }
    }

    func refreshMusicPlaylist() {
        guard state.musicEnabled, !playlistPanels.isEmpty else { return }
        requestPlaylist(offset: 0)
    }

    func loadMoreMusicTracks() {
        guard !playlistPanels.isEmpty, !musicPlaylistLoading, let playlist,
              playlist.tracks.count < playlist.totalCount else { return }
        requestPlaylist(offset: playlist.tracks.count)
    }

    private func clearPlaylist() {
        playlistRequest?.cancel()
        playlistRequest = nil
        musicPlaylistLoading = false
        playlist = nil
    }

    private func requestPlaylist(offset: Int) {
        playlistRequest?.cancel()
        let fetch = environment.musicPlaylist
        musicPlaylistLoading = true
        playlistRequest = Task { [weak self] in
            let page = await fetch(offset)
            guard let self, !Task.isCancelled else { return }
            self.musicPlaylistLoading = false
            self.playlistRequest = nil
            guard let page else {
                if offset == 0 { self.playlist = nil }
                else { self.musicActionFailed = true }
                return
            }
            if offset == 0 {
                self.playlist = page
            } else if let previous = self.playlist,
                      previous.id == page.id, previous.tracks.count == offset, previous.totalCount == page.totalCount,
                      !page.tracks.isEmpty {
                self.playlist = ToolMusicPlaylist(id: page.id, name: page.name,
                    tracks: previous.tracks + page.tracks, totalCount: page.totalCount)
            } else {
                // The library changed while a page was in flight; start again
                // against the actual current playlist rather than mixing rows.
                self.requestPlaylist(offset: 0)
            }
        }
    }

    private func runMusic(_ command: ToolMusicCommand, requestPermission: Bool = false) {
        guard state.musicEnabled, !musicBusy else { return }
        musicBusy = true
        musicActionFailed = false
        musicRevision &+= 1
        let fetch = environment.music
        musicAction = Task { [weak self] in
            let result = await fetch(command, requestPermission)
            guard let self, !Task.isCancelled else { return }
            if command != .status && result == .unavailable {
                self.musicActionFailed = true
            } else {
                self.applyMusicState(result)
            }
            self.musicBusy = false
            self.musicAction = nil
            if !self.musicPanels.isEmpty { self.updateMusicLoop() }
        }
    }

    private func applyMusicState(_ state: ToolMusicState) {
        if let current = player {
            if case let .track(title, artist, _) = state, title == current.title, artist == current.artist {
                // Keep matching artwork while the next playback sample is pending.
            } else { player = nil }
        }
        if music != state { music = state }
        if case .track = state { return }
        if playlist != nil || playlistRequest != nil { clearPlaylist() }
    }

    private func updateMusicLoop() {
        musicLoop?.cancel()
        musicLoop = nil
        guard state.musicEnabled, demand.contains(.music) || !musicPanels.isEmpty else { return }
        let details = !musicPanels.isEmpty
        let fetch = environment.music
        let fetchPlayer = environment.musicPlayer
        musicLoop = Task { [weak self] in
            while !Task.isCancelled {
                if let revision = self?.musicRevision, self?.musicBusy == false {
                    if details {
                        let result = await fetchPlayer()
                        guard !Task.isCancelled else { return }
                        if let self, self.musicRevision == revision {
                            switch result {
                            case .player(let sample):
                                let changedTrack = self.player?.trackID != sample.trackID
                                self.player = sample
                                self.applyMusicState(sample.state)
                                if changedTrack && !self.playlistPanels.isEmpty && self.playlistRequest == nil {
                                    self.refreshMusicPlaylist()
                                }
                            case .unavailable(let state): self.applyMusicState(state)
                            }
                        }
                    } else {
                        let result = await fetch(.status, false)
                        guard !Task.isCancelled else { return }
                        if self?.musicRevision == revision { self?.applyMusicState(result) }
                    }
                }
                try? await Task.sleep(for: .seconds(details ? 3 : 6))
            }
        }
    }

    func authorizeCalendar() {
        guard !calendarBusy else { return }
        calendarBusy = true
        calendarRevision &+= 1
        let fetch = environment.calendar
        calendarAuthorization = Task { [weak self] in
            let result = await fetch(true)
            guard let self, !Task.isCancelled else { return }
            self.calendar = result
            self.calendarBusy = false
            self.calendarAuthorization = nil
        }
    }

    private func updateCalendarLoop() {
        calendarLoop?.cancel()
        calendarLoop = nil
        guard demand.contains(.calendar) else { return }
        let fetch = environment.calendar
        calendarLoop = Task { [weak self] in
            while !Task.isCancelled {
                if let revision = self?.calendarRevision, self?.calendarBusy == false {
                    let result = await fetch(false)
                    guard !Task.isCancelled else { return }
                    if self?.calendarRevision == revision && self?.calendar != result { self?.calendar = result }
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func searchCities(_ query: String) async throws -> [ToolWeatherCity] {
        try await environment.cities(query, AppLanguage.current.rawValue)
    }

    func setWeatherCity(_ city: ToolWeatherCity?) {
        guard self.city != city else { return }
        self.city = city
        if let previous = state.lastWeather, previous.city.id != city?.id {
            state.lastWeather = nil
            save()
        }
        if let reading = state.lastWeather {
            weather = .conditions(reading, stale: isStale(reading))
        } else {
            weather = city == nil ? .noCity : .loading
        }
        updateWeatherLoop()
    }

    func refreshWeather() {
        updateWeatherLoop(forceRefresh: true)
    }

    private func isStale(_ reading: ToolWeatherReading) -> Bool {
        let age = environment.now().timeIntervalSince(reading.fetchedAt)
        return age < 0 || environment.now() >= reading.validUntil
    }

    private func updateWeatherLoop(forceRefresh: Bool = false) {
        weatherLoop?.cancel()
        weatherLoop = nil
        guard let city, demand.contains(.weather) else { return }
        let fetch = environment.conditions
        weatherLoop = Task { [weak self] in
            var force = forceRefresh
            while !Task.isCancelled {
                var nextDelay: TimeInterval = 180
                var retryAfterFailure = false
                if let cached = self?.state.lastWeather, self?.isStale(cached) == false, !force || cached.source == .metNorway {
                    self?.weather = .conditions(cached, stale: false)
                    nextDelay = max(1, cached.validUntil.timeIntervalSince(self?.environment.now() ?? cached.fetchedAt))
                } else {
                    if let cached = self?.state.lastWeather, self?.isStale(cached) == true {
                        self?.weather = .conditions(cached, stale: true)
                    }
                    do {
                        let reading = try await fetch(city)
                        guard !Task.isCancelled, self?.city?.id == reading.city.id else { return }
                        self?.state.lastWeather = reading
                        self?.save()
                        self?.weather = .conditions(reading, stale: false)
                        nextDelay = max(1, reading.validUntil.timeIntervalSince(self?.environment.now() ?? reading.fetchedAt))
                    } catch {
                        guard !Task.isCancelled else { return }
                        retryAfterFailure = true
                        if let cached = self?.state.lastWeather { self?.weather = .conditions(cached, stale: true) }
                        else { self?.weather = .unavailable }
                    }
                }
                force = retryAfterFailure
                try? await Task.sleep(for: .seconds(nextDelay))
            }
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
        } catch {
            // State remains usable in memory if the configuration directory
            // becomes read-only. The next explicit change retries the write.
        }
    }
}
