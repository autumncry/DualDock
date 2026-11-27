import Foundation

struct ToolWeatherCity: Identifiable, Codable, Hashable, Sendable {
    let id: Int
    let name: String
    let region: String?
    let country: String?
    let latitude: Double
    let longitude: Double
}

struct ToolWeatherReading: Codable, Equatable, Sendable {
    let city: ToolWeatherCity
    let temperature: Double
    let code: Int
    let fetchedAt: Date
    var forecastAt: Date?
    var expiresAt: Date?
    var source: Source?

    enum Source: String, Codable, Sendable { case openMeteo, metNorway }

    var attributionName: String { source == .metNorway ? "MET Norway" : "Open-Meteo" }
    var attributionURL: URL {
        source == .metNorway ? URL(string: "https://www.met.no/en")! : URL(string: "https://open-meteo.com/")!
    }
    var validUntil: Date { expiresAt ?? fetchedAt.addingTimeInterval(20 * 60) }
}

enum ToolWeatherState: Equatable {
    case noCity, loading, unavailable
    case conditions(ToolWeatherReading, stale: Bool)
}

/// Coordinates are supplied by the user's choice in the city picker. A search
/// never queries Core Location or sends the Mac's current location.
struct ToolForecastClient {
    private let session: URLSession

    private let now: @Sendable () -> Date

    init(session: URLSession = URLSession(configuration: .ephemeral), now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.now = now
    }

    func search(_ query: String, language: String) async throws -> [ToolWeatherCity] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...120).contains(term.count) else { return [] }
        struct Response: Decodable {
            struct Place: Decodable {
                let id: Int
                let name: String
                let admin1: String?
                let country: String?
                let latitude: Double
                let longitude: Double
            }
            let results: [Place]?
        }
        let (result, _): (Response, HTTPURLResponse) = try await request(host: "geocoding-api.open-meteo.com", path: "/v1/search", items: [
            URLQueryItem(name: "name", value: term), URLQueryItem(name: "count", value: "8"),
            URLQueryItem(name: "language", value: language == "en" ? "en" : "zh")
        ])
        return (result.results ?? []).compactMap { place in
            guard !place.name.isEmpty, Self.validCoordinates(place.latitude, place.longitude) else { return nil }
            return ToolWeatherCity(id: place.id, name: place.name, region: place.admin1,
                                   country: place.country, latitude: place.latitude, longitude: place.longitude)
        }
    }

    func conditions(in city: ToolWeatherCity) async throws -> ToolWeatherReading {
        guard Self.validCoordinates(city.latitude, city.longitude) else { throw URLError(.badURL) }
        do { return try await norwegianForecast(city) }
        catch {
            try Task.checkCancellation()
            return try await openMeteoForecast(city)
        }
    }

    private func norwegianForecast(_ city: ToolWeatherCity) async throws -> ToolWeatherReading {
        struct Response: Decodable {
            struct Properties: Decodable {
                struct Step: Decodable {
                    struct DataPoint: Decodable {
                        struct Instant: Decodable {
                            struct Details: Decodable { let air_temperature: Double }
                            let details: Details
                        }
                        struct Period: Decodable {
                            struct Summary: Decodable { let symbol_code: String }
                            let summary: Summary
                        }
                        let instant: Instant
                        let next_1_hours: Period?
                        let next_6_hours: Period?
                    }
                    let time: Date
                    let data: DataPoint
                }
                let timeseries: [Step]
            }
            let properties: Properties
        }
        func coordinate(_ value: Double) -> String {
            String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        let (payload, response): (Response, HTTPURLResponse) = try await request(host: "api.met.no", path: "/weatherapi/locationforecast/2.0/compact", items: [
            .init(name: "lat", value: coordinate(city.latitude)), .init(name: "lon", value: coordinate(city.longitude))
        ])
        let date = now()
        let series = payload.properties.timeseries
        // Prefer the current model hour, falling back to the nearest future
        // hour for a newly generated run. Reject outdated forecast series.
        guard let step = series.last(where: { $0.time <= date }) ?? series.first,
              abs(step.time.timeIntervalSince(date)) < 6 * 3600 else { throw URLError(.cannotDecodeContentData) }
        let symbol = step.data.next_1_hours?.summary.symbol_code ?? step.data.next_6_hours?.summary.symbol_code
        let httpDate = DateFormatter()
        httpDate.locale = Locale(identifier: "en_US_POSIX")
        httpDate.timeZone = TimeZone(secondsFromGMT: 0)
        httpDate.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        let expires = response.value(forHTTPHeaderField: "Expires").flatMap(httpDate.date)
        return ToolWeatherReading(city: city, temperature: step.data.instant.details.air_temperature,
                                  code: Self.conditionCode(symbol), fetchedAt: date, forecastAt: step.time,
                                  expiresAt: max(expires ?? date.addingTimeInterval(3600), date.addingTimeInterval(1200)),
                                  source: .metNorway)
    }

    /// Map MET's symbol names to the same broad categories the shelf uses for
    /// WMO codes. Mixed precipitation uses a separate internal sleet category.
    static func conditionCode(_ symbol: String?) -> Int {
        guard let key = symbol?.split(separator: "_").first else { return -1 }
        if key.contains("thunder") { return 95 }
        if key.contains("sleet") { return -2 }
        if key.contains("snow") { return key.contains("showers") ? 85 : 73 }
        if key.contains("rain") { return key.contains("showers") ? 80 : 63 }
        switch key {
        case "clearsky": return 0
        case "fair": return 1
        case "partlycloudy": return 2
        case "cloudy": return 3
        case "fog": return 45
        default: return -1
        }
    }

    private func openMeteoForecast(_ city: ToolWeatherCity) async throws -> ToolWeatherReading {
        struct Response: Decodable {
            struct Current: Decodable {
                let temperature_2m: Double
                let weather_code: Int
                let time: TimeInterval
            }
            let current: Current
        }
        let (result, _): (Response, HTTPURLResponse) = try await request(host: "api.open-meteo.com", path: "/v1/forecast", items: [
            URLQueryItem(name: "latitude", value: String(city.latitude)),
            URLQueryItem(name: "longitude", value: String(city.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "temperature_unit", value: "celsius"),
            URLQueryItem(name: "timeformat", value: "unixtime")
        ])
        let date = now()
        let validAt = Date(timeIntervalSince1970: result.current.time)
        guard abs(validAt.timeIntervalSince(date)) < 6 * 3600 else { throw URLError(.cannotDecodeContentData) }
        return ToolWeatherReading(city: city, temperature: result.current.temperature_2m,
                                  code: result.current.weather_code, fetchedAt: date, forecastAt: validAt,
                                  source: .openMeteo)
    }

    private static func validCoordinates(_ latitude: Double, _ longitude: Double) -> Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    private func request<T: Decodable>(host: String, path: String, items: [URLQueryItem]) async throws -> (T, HTTPURLResponse) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = items
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if host == "api.met.no" {
            request.setValue("DualDock/3.0 (https://github.com/autumncry/DualDock)", forHTTPHeaderField: "User-Agent")
        }
        let (bytes, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              bytes.count <= 512 * 1024 else { throw URLError(.badServerResponse) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try decoder.decode(T.self, from: bytes), http)
    }
}
