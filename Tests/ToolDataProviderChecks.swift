import Foundation

/// Exercises the provider boundary with no real player, calendar, permissions,
/// city lookup or API key. The URLProtocol fixture still verifies HTTP contracts.
private actor Fixtures {
    var music = 0
    var calendar = 0
    var weather = 0
    var explicitMusic = 0
    var explicitCalendar = 0
    var failWeather = false

    func readMusic(_ command: ToolMusicCommand, permission: Bool) -> ToolMusicState {
        music += 1
        if permission { explicitMusic += 1 }
        return .track(title: "Fixture", artist: "Example", playing: true)
    }

    func readCalendar(_ permission: Bool) -> ToolCalendarState {
        calendar += 1
        if permission { explicitCalendar += 1 }
        return permission ? .empty : .notDetermined
    }

    func readWeather(in location: ToolWeatherCity) async throws -> ToolWeatherReading {
        weather += 1
        if failWeather { throw URLError(.notConnectedToInternet) }
        if location.id == 1 {
            // Simulate an in-flight request that ignores client cancellation.
            try? await Task.sleep(for: .milliseconds(120))
        }
        return .init(city: location, temperature: 19, code: 2, fetchedAt: Date())
    }

    func goOffline() { failWeather = true }
    func counts() -> [Int] { [music, calendar, weather, explicitMusic, explicitCalendar] }
}

private final class WeatherURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        let json: String
        var status = 200
        switch url.host {
        case "geocoding-api.open-meteo.com":
            if query["name"] == "network failure" {
                json = "{}"; status = 503
            } else if query["name"] == "empty city" {
                json = "{}"
            } else {
                precondition(query["name"] == "北京 & Bei+jing" && query["language"] == "zh" && url.path == "/v1/search")
                json = #"{"results":[{"id":1,"name":"北京","latitude":39.9,"longitude":116.4,"admin1":"北京","country":"中国"},{"id":0,"name":"Out of range","latitude":91,"longitude":0}]}"#
            }
        case "api.met.no":
            precondition(request.value(forHTTPHeaderField: "User-Agent")?.contains("DualDock/") == true)
            if query["lat"] == "4.1235" {
                precondition(query["lon"] == "-2.0000")
                json = #"{"properties":{"timeseries":[{"time":"2026-11-23T13:00:00Z","data":{"instant":{"details":{"air_temperature":20.2}},"next_1_hours":{"summary":{"symbol_code":"heavysleetshowers_night"}}}},{"time":"2026-11-23T14:00:00Z","data":{"instant":{"details":{"air_temperature":21.4}}}}]}}"#
            } else {
                status = 503
                json = "{}"
            }
        case "api.open-meteo.com":
            precondition(query["latitude"] == "39.9" && query["longitude"] == "116.4" && query["temperature_unit"] == "celsius")
            precondition(query["current"] == "temperature_2m,weather_code")
            precondition(query["timeformat"] == "unixtime")
            json = #"{"current":{"temperature_2m":7.1,"weather_code":3,"time":1795438800}}"#
        default: fatalError("Unexpected host")
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main private enum ToolDataProviderChecks {
    @MainActor static func main() async throws {
        precondition(CommandLine.arguments.count == 2)
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixtures = Fixtures()
        let env = ToolDataService.Environment(
            music: { await fixtures.readMusic($0, permission: $1) },
            calendar: { await fixtures.readCalendar($0) },
            conditions: { try await fixtures.readWeather(in: $0) },
            cities: { _, _ in [] })
        let service = ToolDataService(directory: dir, environment: env)
        let a = ToolWeatherCity(id: 1, name: "A", region: nil, country: nil, latitude: 0, longitude: 0)
        let b = ToolWeatherCity(id: 2, name: "B", region: nil, country: nil, latitude: 2, longitude: 3)
        var checks = 0
        func check(_ passed: Bool, _ message: String) {
            precondition(passed, message)
            checks += 1
        }
        func eventually(_ condition: () async -> Bool) async -> Bool {
            for _ in 0..<150 {
                if await condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }
        service.setWeatherCity(a)
        check(await fixtures.counts() == [0, 0, 0, 0, 0], "Cold start must not read user data or access the network")
        service.setVisible(true, for: "internal")
        check(await eventually { await fixtures.counts() == [0,1,1,0,0] }, "First visible screen should read only enabled providers without prompting")
        service.setVisible(true, for: "external")
        service.setVisible(false, for: "internal")
        service.setWeatherCity(b)
        check(await eventually {
            if case .conditions(let reading, false) = service.weather { return reading.city == b }
            return false
        }, "Retain the new location when a canceled request is still running")
        try await Task.sleep(for: .milliseconds(140))
        check(await fixtures.counts() == [0,1,2,0,0], "Adding or removing a second display must not duplicate provider work")
        service.enableMusic()
        check(await eventually { service.music == .track(title: "Fixture", artist: "Example", playing: true) && !service.musicBusy },
              "Explicit Music connection failed")
        service.authorizeCalendar()
        check(await eventually { service.calendar == .empty && !service.calendarBusy }, "Explicit calendar permission did not publish")
        let enabled = await fixtures.counts()
        check(enabled[3] == 1 && enabled[4] == 1, "User permission buttons should prompt exactly once")
        service.togglePlayback()
        check(await eventually { !service.musicBusy }, "Playback command remained busy")
        check((await fixtures.counts())[0] == enabled[0] + 1, "Playback command was duplicated")
        check((await fixtures.counts())[3] == 1, "User command implicitly requested permission again")
        service.setVisible(false, for: "external")
        let sleeping = await fixtures.counts()
        service.refreshWeather()
        try await Task.sleep(for: .milliseconds(40))
        check(await fixtures.counts() == sleeping, "Hidden shelf fetched data")
        let reload = ToolDataService(directory: dir, environment: env)
        reload.setWeatherCity(b)
        if case .conditions(let reading, false) = reload.weather { check(reading.city == b, "Wrong cached city") }
        else { check(false, "A fresh persisted forecast should be available before going online") }
        reload.setVisible(true, for: "external", music: false, calendar: false, weather: true)
        try await Task.sleep(for: .milliseconds(40))
        check(await fixtures.counts() == sleeping, "Only a weather card is visible with a fresh cache")
        await fixtures.goOffline()
        reload.refreshWeather()
        check(await eventually {
            if case .conditions(let reading, true) = reload.weather { return reading.city == b }
            return false
        }, "Network failure must preserve the last weather reading with a stale flag")
        reload.setWeatherCity(nil)
        check(reload.weather == .noCity, "Clearing city retained the wrong reading")
        reload.setWeatherCity(a)
        check(await eventually { reload.weather == .unavailable }, "An offline city without a cached forecast stayed on Loading")
        reload.setVisible(false, for: "external")

        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [WeatherURLProtocol.self]
        let sampleTime = ISO8601DateFormatter().date(from: "2026-11-23T13:30:00Z")!
        let client = ToolForecastClient(session: URLSession(configuration: conf), now: { sampleTime })
        let results = try await client.search("北京 & Bei+jing", language: "zh-Hans")
        check(results.count == 1 && results[0].name == "北京" && results[0].country == "中国", "Geocoding or coordinate validation failed")
        let reading = try await client.conditions(in: results[0])
        check(reading.temperature == 7.1 && reading.code == 3 && reading.attributionName == "Open-Meteo",
              "Open-Meteo fallback temperature, code or attribution was incorrect")
        let coast = ToolWeatherCity(id: 3, name: "Fixture", region: nil, country: nil, latitude: 4.123456, longitude: -2)
        let met = try await client.conditions(in: coast)
        check(met.temperature == 20.2 && met.code == -2 && met.source == .metNorway &&
              met.forecastAt == sampleTime.addingTimeInterval(-1800) && met.validUntil > sampleTime,
              "MET model time, coordinate rounding, source, expiration or sleet category was incorrect")
        check(ToolForecastClient.conditionCode("rainshowersandthunder_day") == 95 &&
              ToolForecastClient.conditionCode("partlycloudy_night") == 2 && ToolForecastClient.conditionCode(nil) == -1,
              "Day/night, unknown and thunder code mapping failed")
        check(try await client.search("empty city", language: "en").isEmpty, "Missing results should be an empty search")
        check(try await client.search(" ", language: "en").isEmpty, "Empty queries must stay local")
        do {
            _ = try await client.search("network failure", language: "en")
            check(false, "Non-2xx HTTP response was accepted")
        } catch { check(true, "HTTP failure reported") }
        print("Tool data providers: \(checks) checks passed. Used only isolated clients, fixture data and a temporary configuration.")
    }
}
