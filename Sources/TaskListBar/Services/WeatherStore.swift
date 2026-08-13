import CoreLocation
import Foundation
import SwiftUI

enum WeatherKind: String, Hashable {
    case sunny
    case partlyCloudy
    case cloudy
    case fog
    case drizzle
    case rain
    case snow
    case storm

    static func from(code: Int) -> WeatherKind {
        switch code {
        case 0, 1: return .sunny
        case 2: return .partlyCloudy
        case 3: return .cloudy
        case 45, 48: return .fog
        case 51, 53, 55, 56, 57: return .drizzle
        case 61, 63, 65, 66, 67, 80, 81, 82: return .rain
        case 71, 73, 75, 77, 85, 86: return .snow
        case 95, 96, 99: return .storm
        default: return .cloudy
        }
    }

    var label: String {
        switch self {
        case .sunny: return "晴"
        case .partlyCloudy: return "晴间多云"
        case .cloudy: return "多云"
        case .fog: return "雾"
        case .drizzle: return "毛毛雨"
        case .rain: return "雨"
        case .snow: return "雪"
        case .storm: return "雷雨"
        }
    }

    func symbolName(night: Bool) -> String {
        switch self {
        case .sunny: return night ? "moon.stars.fill" : "sun.max.fill"
        case .partlyCloudy: return night ? "cloud.moon.fill" : "cloud.sun.fill"
        case .cloudy: return "cloud.fill"
        case .fog: return "cloud.fog.fill"
        case .drizzle: return "cloud.drizzle.fill"
        case .rain: return "cloud.rain.fill"
        case .snow: return "cloud.snow.fill"
        case .storm: return "cloud.bolt.rain.fill"
        }
    }

    var isDarkSky: Bool {
        switch self {
        case .rain, .storm, .drizzle: return true
        default: return false
        }
    }

    /// iPhone 天气式天空渐变。
    func palette(night: Bool) -> WeatherPalette {
        if night {
            switch self {
            case .sunny:
                return WeatherPalette(
                    top: Color(red: 0.07, green: 0.12, blue: 0.32),
                    bottom: Color(red: 0.02, green: 0.04, blue: 0.14)
                )
            case .partlyCloudy, .cloudy:
                return WeatherPalette(
                    top: Color(red: 0.14, green: 0.18, blue: 0.28),
                    bottom: Color(red: 0.06, green: 0.08, blue: 0.14)
                )
            case .fog:
                return WeatherPalette(
                    top: Color(red: 0.22, green: 0.23, blue: 0.26),
                    bottom: Color(red: 0.10, green: 0.11, blue: 0.13)
                )
            case .drizzle, .rain:
                return WeatherPalette(
                    top: Color(red: 0.16, green: 0.20, blue: 0.28),
                    bottom: Color(red: 0.08, green: 0.10, blue: 0.16)
                )
            case .snow:
                return WeatherPalette(
                    top: Color(red: 0.22, green: 0.28, blue: 0.38),
                    bottom: Color(red: 0.10, green: 0.14, blue: 0.22)
                )
            case .storm:
                return WeatherPalette(
                    top: Color(red: 0.16, green: 0.12, blue: 0.30),
                    bottom: Color(red: 0.06, green: 0.05, blue: 0.14)
                )
            }
        }

        switch self {
        case .sunny:
            return WeatherPalette(
                top: Color(red: 0.28, green: 0.67, blue: 0.93),
                bottom: Color(red: 0.10, green: 0.42, blue: 0.78)
            )
        case .partlyCloudy:
            return WeatherPalette(
                top: Color(red: 0.36, green: 0.62, blue: 0.84),
                bottom: Color(red: 0.18, green: 0.40, blue: 0.64)
            )
        case .cloudy:
            return WeatherPalette(
                top: Color(red: 0.42, green: 0.54, blue: 0.64),
                bottom: Color(red: 0.26, green: 0.36, blue: 0.44)
            )
        case .fog:
            return WeatherPalette(
                top: Color(red: 0.58, green: 0.60, blue: 0.63),
                bottom: Color(red: 0.40, green: 0.42, blue: 0.46)
            )
        case .drizzle:
            return WeatherPalette(
                top: Color(red: 0.38, green: 0.50, blue: 0.62),
                bottom: Color(red: 0.22, green: 0.32, blue: 0.42)
            )
        case .rain:
            return WeatherPalette(
                top: Color(red: 0.29, green: 0.40, blue: 0.52),
                bottom: Color(red: 0.16, green: 0.24, blue: 0.32)
            )
        case .snow:
            return WeatherPalette(
                top: Color(red: 0.55, green: 0.66, blue: 0.76),
                bottom: Color(red: 0.34, green: 0.46, blue: 0.58)
            )
        case .storm:
            return WeatherPalette(
                top: Color(red: 0.24, green: 0.22, blue: 0.42),
                bottom: Color(red: 0.10, green: 0.10, blue: 0.22)
            )
        }
    }

    func iconPrimary(night: Bool) -> Color {
        switch self {
        case .sunny:
            return night
                ? Color(red: 0.90, green: 0.92, blue: 1.00)
                : Color(red: 1.00, green: 0.84, blue: 0.22)
        default:
            return .white
        }
    }

    func iconSecondary(night: Bool) -> Color {
        switch self {
        case .sunny:
            return iconPrimary(night: night)
        case .partlyCloudy:
            return night
                ? Color(red: 0.90, green: 0.92, blue: 1.00)
                : Color(red: 1.00, green: 0.84, blue: 0.22)
        case .rain, .drizzle:
            return Color(red: 0.70, green: 0.86, blue: 1.00)
        case .snow:
            return Color(red: 0.86, green: 0.94, blue: 1.00)
        case .storm:
            return Color(red: 0.90, green: 0.82, blue: 1.00)
        default:
            return Color.white.opacity(0.92)
        }
    }
}

struct WeatherPalette {
    let top: Color
    let bottom: Color
}

struct DayWeather: Hashable {
    let day: Date
    let code: Int
    let high: Int
    let low: Int

    var kind: WeatherKind { WeatherKind.from(code: code) }
    var label: String { kind.label }
    var symbolName: String { kind.symbolName(night: false) }
    var symbolColor: Color { kind.iconPrimary(night: false) }
}

@MainActor
final class WeatherStore: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var byDay: [Date: DayWeather] = [:]
    @Published private(set) var placeName: String?
    @Published private(set) var currentTemp: Int?
    @Published private(set) var currentKind: WeatherKind?

    private let calendar = Calendar(identifier: .gregorian)
    private let locationManager = CLLocationManager()
    private static let requestedKey = "didRequestLocationAuth"
    private var lastFetch: Date?
    private var fetching = false
    private var didRequestLocationAuth = UserDefaults.standard.bool(forKey: WeatherStore.requestedKey)

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func start() {}

    func weather(on date: Date) -> DayWeather? {
        byDay[calendar.startOfDay(for: date)]
    }

    func refreshIfNeeded() {
        if let lastFetch, lastFetch.timeIntervalSinceNow > -30 * 60, !byDay.isEmpty {
            return
        }
        resolveLocationAndFetch()
    }

    private func resolveLocationAndFetch() {
        guard !fetching else { return }
        fetching = true
        Task { [weak self] in
            if let geo = await Self.fetchGeoIP() {
                await self?.applyLocation(latitude: geo.lat, longitude: geo.lon, name: geo.name)
                return
            }
            await MainActor.run {
                self?.requestDeviceLocation()
            }
        }
    }

    private func requestDeviceLocation() {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.requestLocation()
        case .notDetermined:
            guard !didRequestLocationAuth else {
                fetching = false
                return
            }
            didRequestLocationAuth = true
            UserDefaults.standard.set(true, forKey: Self.requestedKey)
            locationManager.requestWhenInUseAuthorization()
        default:
            fetching = false
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                self.locationManager.requestLocation()
            case .denied, .restricted:
                self.fetching = false
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            await applyLocation(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                name: nil
            )
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.fetching = false
        }
    }

    private func applyLocation(latitude: Double, longitude: Double, name: String?) async {
        if let name, placeName == nil {
            placeName = name
        }
        do {
            let snapshot = try await Self.fetchForecast(latitude: latitude, longitude: longitude)
            byDay = Dictionary(uniqueKeysWithValues: snapshot.days.map { (calendar.startOfDay(for: $0.day), $0) })
            currentTemp = snapshot.currentTemp
            currentKind = snapshot.currentKind
            lastFetch = Date()
            if placeName == nil {
                placeName = name
            }
        } catch {
            AppLog.error("天气刷新失败: \(error.localizedDescription)", category: "weather")
        }
        fetching = false
    }

    private struct GeoIP {
        let lat: Double
        let lon: Double
        let name: String?
    }

    private static func fetchGeoIP() async -> GeoIP? {
        guard let url = URL(string: "https://get.geojs.io/v1/ip/geo.json") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let lat = doubleValue(json["latitude"])
        let lon = doubleValue(json["longitude"])
        guard let lat, let lon else { return nil }
        let city = json["city"] as? String
        let region = json["region"] as? String
        let name = [city, region].compactMap { $0 }.first { !$0.isEmpty }
        return GeoIP(lat: lat, lon: lon, name: name)
    }

    private static func fetchForecast(latitude: Double, longitude: Double) async throws -> WeatherSnapshot {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "past_days", value: "6"),
            URLQueryItem(name: "forecast_days", value: "16"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return parseForecast(data)
    }

    private struct WeatherSnapshot {
        let currentTemp: Int?
        let currentKind: WeatherKind?
        let days: [DayWeather]
    }

    private static func parseForecast(_ data: Data) -> WeatherSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return WeatherSnapshot(currentTemp: nil, currentKind: nil, days: [])
        }

        var currentTemp: Int?
        var currentKind: WeatherKind?
        if let current = root["current"] as? [String: Any] {
            currentTemp = intValue(current["temperature_2m"])
            if let code = intValue(current["weather_code"]) {
                currentKind = WeatherKind.from(code: code)
            }
        }

        guard let daily = root["daily"] as? [String: Any],
              let times = daily["time"] as? [String],
              let codes = daily["weather_code"] as? [Any],
              let highs = daily["temperature_2m_max"] as? [Any],
              let lows = daily["temperature_2m_min"] as? [Any]
        else {
            return WeatherSnapshot(currentTemp: currentTemp, currentKind: currentKind, days: [])
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar(identifier: .gregorian)

        let days = times.enumerated().compactMap { index, raw -> DayWeather? in
            guard let date = formatter.date(from: raw) else { return nil }
            return DayWeather(
                day: calendar.startOfDay(for: date),
                code: intValue(codes, index) ?? 3,
                high: intValue(highs, index) ?? 0,
                low: intValue(lows, index) ?? 0
            )
        }
        return WeatherSnapshot(currentTemp: currentTemp, currentKind: currentKind, days: days)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        if let number = value as? Double { return number }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return Int(number.doubleValue.rounded()) }
        if let number = value as? Double { return Int(number.rounded()) }
        if let number = value as? Int { return number }
        if let text = value as? String, let number = Double(text) { return Int(number.rounded()) }
        return nil
    }

    private static func intValue(_ array: [Any], _ index: Int) -> Int? {
        guard index < array.count else { return nil }
        return intValue(array[index])
    }
}
