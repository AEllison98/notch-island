import AppKit
import CoreLocation
import SwiftUI

// MARK: - What the tile shows

struct WeatherReading: Equatable {
    var place: String
    var temperature: Double
    var high: Double
    var low: Double
    var code: Int
    var isDay: Bool
    var fetchedAt: Date
}

enum WeatherState: Equatable {
    /// No city and not using your location yet.
    case needsSetup
    case loading(place: String)
    case ready(WeatherReading)
    case failed(place: String, message: String)
}

/// WMO weather codes (what Open-Meteo returns) as an SF Symbol and its two layer colours.
struct WeatherCondition: Equatable {
    let symbol: String
    let label: String
    /// nil means the theme's text colour.
    let primary: Color?
    let secondary: Color?

    static let sun = Color(hex: 0xFFD60A)

    static func from(code: Int, isDay: Bool) -> WeatherCondition {
        switch code {
        case 0:
            isDay ? .init(symbol: "sun.max.fill", label: "Clear", primary: sun, secondary: nil)
                  : .init(symbol: "moon.stars.fill", label: "Clear", primary: sun, secondary: sun)
        case 1, 2:
            isDay ? .init(symbol: "cloud.sun.fill", label: code == 1 ? "Mostly Clear" : "Partly Cloudy", primary: nil, secondary: sun)
                  : .init(symbol: "cloud.moon.fill", label: code == 1 ? "Mostly Clear" : "Partly Cloudy", primary: nil, secondary: sun)
        case 3: .init(symbol: "cloud.fill", label: "Cloudy", primary: nil, secondary: nil)
        case 45, 48: .init(symbol: "cloud.fog.fill", label: "Fog", primary: nil, secondary: nil)
        case 51, 53, 55: .init(symbol: "cloud.drizzle.fill", label: "Drizzle", primary: nil, secondary: Palette.weatherBlue)
        case 56, 57, 66, 67: .init(symbol: "cloud.sleet.fill", label: "Freezing Rain", primary: nil, secondary: Palette.weatherBlue)
        case 61, 63: .init(symbol: "cloud.rain.fill", label: "Rain", primary: nil, secondary: Palette.weatherBlue)
        case 65: .init(symbol: "cloud.heavyrain.fill", label: "Heavy Rain", primary: nil, secondary: Palette.weatherBlue)
        case 71, 73, 75, 77, 85, 86: .init(symbol: "cloud.snow.fill", label: "Snow", primary: nil, secondary: Palette.weatherBlue)
        case 80, 81:
            isDay ? .init(symbol: "cloud.sun.rain.fill", label: "Showers", primary: nil, secondary: Palette.weatherBlue)
                  : .init(symbol: "cloud.moon.rain.fill", label: "Showers", primary: nil, secondary: Palette.weatherBlue)
        case 82: .init(symbol: "cloud.heavyrain.fill", label: "Heavy Showers", primary: nil, secondary: Palette.weatherBlue)
        case 95, 96, 99: .init(symbol: "cloud.bolt.rain.fill", label: "Thunderstorm", primary: nil, secondary: sun)
        default: .init(symbol: "cloud.fill", label: "—", primary: nil, secondary: nil)
        }
    }
}

// MARK: - Open-Meteo

enum OpenMeteo {
    struct Place: Equatable { var name: String; var latitude: Double; var longitude: Double }

    /// Rounded to one decimal, about 11 km north-south: enough for the weather, not enough to
    /// say where you are.
    static func coarse(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    static func usesFahrenheit(_ locale: Locale = .current) -> Bool { locale.measurementSystem == .us }

    static func geocodeURL(_ city: String, language: String = Locale.current.language.languageCode?.identifier ?? "en") -> URL? {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        c?.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1"),
                         .init(name: "language", value: language), .init(name: "format", value: "json")]
        return c?.url
    }

    static func forecastURL(latitude: Double, longitude: Double, fahrenheit: Bool) -> URL? {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        var items: [URLQueryItem] = [
            .init(name: "latitude", value: String(coarse(latitude))),
            .init(name: "longitude", value: String(coarse(longitude))),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "1"),
        ]
        if fahrenheit { items.append(.init(name: "temperature_unit", value: "fahrenheit")) }
        c?.queryItems = items
        return c?.url
    }

    /// nil when Open-Meteo knows no such place: it answers 200 with no "results" at all.
    static func parsePlace(_ data: Data) throws -> Place? {
        struct Response: Decodable {
            struct Result: Decodable { let name: String; let latitude: Double; let longitude: Double }
            let results: [Result]?
        }
        guard let first = try JSONDecoder().decode(Response.self, from: data).results?.first else { return nil }
        return Place(name: first.name, latitude: first.latitude, longitude: first.longitude)
    }

    static func parseForecast(_ data: Data, place: String, at date: Date = Date()) throws -> WeatherReading {
        struct Response: Decodable {
            struct Current: Decodable { let temperature_2m: Double; let weather_code: Int; let is_day: Int }
            struct Daily: Decodable { let temperature_2m_max: [Double]; let temperature_2m_min: [Double] }
            let current: Current
            let daily: Daily
        }
        let r = try JSONDecoder().decode(Response.self, from: data)
        return WeatherReading(place: place, temperature: r.current.temperature_2m,
                              high: r.daily.temperature_2m_max.first ?? r.current.temperature_2m,
                              low: r.daily.temperature_2m_min.first ?? r.current.temperature_2m,
                              code: r.current.weather_code, isDay: r.current.is_day == 1, fetchedAt: date)
    }
}

// MARK: - Your location

/// One-off, coarse locations from CoreLocation. Asks for permission the first time it is used,
/// never before.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    enum Failure: Error { case denied, unavailable }

    private let manager = CLLocationManager()
    private var waiting: [UUID: CheckedContinuation<CLLocation, Error>] = [:]
    private var last: CLLocation?
    /// Called when you allow Location, so the weather can try again straight away.
    var onAuthorized: () -> Void = {}

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    private var isAuthorized: Bool { ![.notDetermined, .denied, .restricted].contains(manager.authorizationStatus) }

    func current() async throws -> CLLocation {
        if let last, -last.timestamp.timeIntervalSinceNow < 20 * 60 { return last }
        switch manager.authorizationStatus {
        case .denied, .restricted: throw Failure.denied
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: manager.requestLocation()
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting[id] = continuation
                // The clock starts once there is permission: the prompt can stay up as long as
                // you like without the tile giving up underneath it.
                if isAuthorized { startClock(id) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.fail(id, CancellationError()) }
        }
    }

    private func startClock(_ id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.fail(id, Failure.unavailable) }
    }

    private func fail(_ id: UUID, _ error: Error) {
        waiting.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func finishAll(_ result: Result<CLLocation, Error>) {
        let all = waiting
        waiting = [:]
        if case .success(let location) = result { last = location }
        all.values.forEach { $0.resume(with: result) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            switch manager.authorizationStatus {
            case .denied, .restricted: finishAll(.failure(Failure.denied))
            case .notDetermined: break
            default:
                if !waiting.isEmpty {
                    manager.requestLocation()
                    waiting.keys.forEach(startClock)
                }
                onAuthorized()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            if let location = locations.last { finishAll(.success(location)) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            let denied = (error as? CLError)?.code == .denied
            finishAll(.failure(denied ? Failure.denied : Failure.unavailable))
        }
    }
}

// MARK: - Keeping the tile current

/// Fetches the weather for your location or your city, every 30 minutes, after the Mac wakes,
/// and when the island opens on data older than 15 minutes.
@MainActor
final class WeatherService {
    static let myLocation = "My Location"

    private let model: IslandModel
    private let settings: Settings
    private let location = LocationProvider()
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var lastAttempt: Date?

    init(model: IslandModel, settings: Settings) {
        self.model = model
        self.settings = settings
        let t = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The network is often not back the instant the lid opens.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { MainActor.assumeIsolated { self?.refresh() } }
        }
        location.onAuthorized = { [weak self] in self?.refresh() }
    }

    /// On opening the island: a reading older than 15 minutes, or none at all (a failure is
    /// retried, at most once a minute).
    func refreshIfStale() {
        if case .ready(let r) = model.weather, -r.fetchedAt.timeIntervalSinceNow < 15 * 60 { return }
        if let lastAttempt, -lastAttempt.timeIntervalSinceNow < 60 { return }
        refresh()
    }

    func refresh() {
        task?.cancel()
        lastAttempt = Date()
        task = Task { [weak self] in await self?.load() }
    }

    private func load() async {
        let useLocation = settings.weatherUsesLocation
        let city = settings.city
        let place = useLocation ? Self.myLocation : city
        guard useLocation || !city.isEmpty else { model.weather = .needsSetup; return }

        // Keep showing the last reading for the same place while refreshing it.
        var showingSamePlace = false
        if case .ready(let r) = model.weather {
            showingSamePlace = useLocation ? r.place == Self.myLocation
                                           : settings.resolvedCity?.query == city && r.place == settings.resolvedCity?.name
        }
        if !showingSamePlace { model.weather = .loading(place: place) }

        do {
            let latitude: Double, longitude: Double, name: String
            if useLocation {
                let here = try await location.current()
                (latitude, longitude, name) = (here.coordinate.latitude, here.coordinate.longitude, Self.myLocation)
            } else if let resolved = settings.resolvedCity, resolved.query == city {
                (latitude, longitude, name) = (resolved.latitude, resolved.longitude, resolved.name)
            } else {
                guard let url = OpenMeteo.geocodeURL(city) else { throw Net.Failure.offline }
                guard let found = try OpenMeteo.parsePlace(try await Net.shared.get(url)) else {
                    model.weather = .failed(place: city, message: "City not found")
                    return
                }
                settings.resolvedCity = ResolvedCity(query: city, name: found.name, latitude: found.latitude, longitude: found.longitude)
                (latitude, longitude, name) = (found.latitude, found.longitude, found.name)
            }
            guard !Task.isCancelled else { return }
            guard let url = OpenMeteo.forecastURL(latitude: latitude, longitude: longitude,
                                                  fahrenheit: OpenMeteo.usesFahrenheit()) else { throw Net.Failure.offline }
            let reading = try OpenMeteo.parseForecast(try await Net.shared.get(url), place: name)
            guard !Task.isCancelled else { return }
            model.weather = .ready(reading)
            Diag.log("weather \(name): \(reading.temperature)° code \(reading.code)")
        } catch {
            // A newer refresh has taken over (you switched place): this one must not write.
            guard !Task.isCancelled else { return }
            switch error as? LocationProvider.Failure {
            case .denied?:
                model.weather = .failed(place: place, message: "Location is off: allow it, or set a city")
            case .unavailable?:
                model.weather = .failed(place: place, message: "Can't find your location")
            case nil:
                // Offline or Open-Meteo trouble: keep a reading we already have rather than blank it.
                if case .ready = model.weather { return }
                model.weather = .failed(place: place, message: "Can't reach Open-Meteo")
            }
        }
    }
}
