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
        var now: () -> Date = Date.init

        static func system() -> Self {
            let music = ToolMusicClient()
            let calendar = ToolCalendarClient()
            let weather = ToolForecastClient()
            return Self(music: { await music.perform($0, requestPermission: $1) },
                        calendar: { await calendar.load(requestPermission: $0) },
                        conditions: { try await weather.conditions(in: $0) },
                        cities: { try await weather.search($0, language: $1) })
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
            case .music: updateMusicLoop()
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
    func nextTrack() { runMusic(.next) }

    private func runMusic(_ command: ToolMusicCommand, requestPermission: Bool = false) {
        guard state.musicEnabled, !musicBusy else { return }
        musicBusy = true
        musicRevision &+= 1
        let fetch = environment.music
        musicAction = Task { [weak self] in
            let result = await fetch(command, requestPermission)
            guard let self, !Task.isCancelled else { return }
            self.music = result
            self.musicBusy = false
            self.musicAction = nil
        }
    }

    private func updateMusicLoop() {
        musicLoop?.cancel()
        musicLoop = nil
        guard state.musicEnabled, demand.contains(.music) else { return }
        let fetch = environment.music
        musicLoop = Task { [weak self] in
            while !Task.isCancelled {
                if let revision = self?.musicRevision, self?.musicBusy == false {
                    let result = await fetch(.status, false)
                    guard !Task.isCancelled else { return }
                    if self?.musicRevision == revision && self?.music != result { self?.music = result }
                }
                try? await Task.sleep(for: .seconds(6))
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
