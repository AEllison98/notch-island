import SwiftUI

// MARK: - Themes

enum ThemeName: String, CaseIterable {
    case darkMatte, whiteMatte

    var title: String {
        switch self {
        case .darkMatte: "Dark Matte"
        case .whiteMatte: "White Matte"
        }
    }

    var palette: Palette {
        switch self {
        case .darkMatte: .darkMatte
        case .whiteMatte: .whiteMatte
        }
    }
}

/// The open island's body and tiles: flat colours, no gradients. (The strip level with the
/// notch is glass; see BandStrip.)
struct Palette: Equatable {
    let background: Color
    let tile: Color
    let text: Color
    let secondary: Color
    let accent: Color
    /// Round buttons on a tile.
    let control: Color
    /// A hairline around tiles. On White Matte the tile (#FBFBFC) and the background (#F7F8FA)
    /// are too close to tell apart without it.
    let tileEdge: Color

    /// Apple's own dark surfaces (the grouped greys its widgets use), with the text, secondary
    /// and accent colours as specified.
    static let darkMatte = Palette(
        background: Color(hex: 0x1C1C1E), tile: Color(hex: 0x2C2C2E),
        text: Color(hex: 0xE3E7EF), secondary: Color(hex: 0xA4ABBA), accent: Color(hex: 0x8FC7FF),
        control: Color(hex: 0x3A3A3C), tileEdge: .clear)

    static let whiteMatte = Palette(
        background: Color(hex: 0xF7F8FA), tile: Color(hex: 0xFBFBFC),
        text: Color(hex: 0x1E2129), secondary: Color(hex: 0x545A69), accent: Color(hex: 0x3B82D0),
        control: Color(hex: 0x1E2129).opacity(0.07), tileEdge: Color(hex: 0x1E2129).opacity(0.08))

    /// A weather-symbol blue that reads on both themes' tiles.
    static let weatherBlue = Color(hex: 0x5AC8FA)

    /// The notch-shaped core of the strip. Black in every theme: it sits under the hardware
    /// notch, or stands in for one.
    static let band = Color.black
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

// MARK: - Settings

/// Everything the user can change, stored in UserDefaults (local.NotchIsland.plist).
@MainActor
final class Settings {
    static let shared = Settings()

    /// The self-test works in its own throwaway domain, so it never touches your settings.
    static let selfTestSuite = "local.NotchIsland.selftest"

    private let defaults: UserDefaults
    private var observers: [() -> Void] = []

    private init() {
        if Diag.selfTest, let suite = UserDefaults(suiteName: Self.selfTestSuite) {
            suite.removePersistentDomain(forName: Self.selfTestSuite)
            defaults = suite
        } else {
            defaults = .standard
        }
    }

    func observe(_ block: @escaping () -> Void) { observers.append(block) }
    private func changed() { observers.forEach { $0() } }

    var theme: ThemeName {
        get { ThemeName(rawValue: defaults.string(forKey: "theme") ?? "") ?? .darkMatte }
        set { defaults.set(newValue.rawValue, forKey: "theme"); changed() }
    }

    /// Every tile, shown or not, in display order. Unknown or missing names are repaired.
    var tileOrder: [TileKind] {
        get {
            var order: [TileKind] = []
            for raw in defaults.stringArray(forKey: "tileOrder") ?? [] {
                if let kind = TileKind(rawValue: raw), !order.contains(kind) { order.append(kind) }
            }
            for kind in TileKind.allCases where !order.contains(kind) { order.append(kind) }
            return order
        }
        set { defaults.set(newValue.map(\.rawValue), forKey: "tileOrder"); changed() }
    }

    var hiddenTiles: Set<TileKind> {
        get { Set((defaults.stringArray(forKey: "hiddenTiles") ?? []).compactMap(TileKind.init(rawValue:))) }
        set { defaults.set(newValue.map(\.rawValue).sorted(), forKey: "hiddenTiles"); changed() }
    }

    var visibleTiles: [TileKind] { tileOrder.filter { !hiddenTiles.contains($0) } }

    func setVisible(_ kind: TileKind, _ visible: Bool) {
        var hidden = hiddenTiles
        if visible { hidden.remove(kind) } else { hidden.insert(kind) }
        hiddenTiles = hidden
    }

    /// Moves a shown tile one place left (-1) or right (+1) among the shown tiles.
    func move(_ kind: TileKind, by delta: Int) {
        var visible = visibleTiles
        guard let i = visible.firstIndex(of: kind), visible.indices.contains(i + delta) else { return }
        visible.swapAt(i, i + delta)
        reorderVisible(visible)
    }

    /// Saves a new order for the shown tiles; hidden ones keep their order after them.
    func reorderVisible(_ visible: [TileKind]) {
        tileOrder = visible + tileOrder.filter { !visible.contains($0) }
    }

    var city: String {
        get { defaults.string(forKey: "city") ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "city"); changed() }
    }

    /// Peeks, each on or off. Focus is off until you turn it on, because that asks macOS.
    var peekApps: Bool {
        get { defaults.object(forKey: "peekApps") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "peekApps"); changed() }
    }
    var peekPower: Bool {
        get { defaults.object(forKey: "peekPower") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "peekPower"); changed() }
    }
    var peekFocus: Bool {
        get { defaults.bool(forKey: "peekFocus") }
        set { defaults.set(newValue, forKey: "peekFocus"); changed() }
    }

    /// Weather for where you are (CoreLocation) instead of for the city.
    var weatherUsesLocation: Bool {
        get { defaults.bool(forKey: "weatherUsesLocation") }
        set { defaults.set(newValue, forKey: "weatherUsesLocation"); changed() }
    }

    /// The city as Open-Meteo found it, so it is looked up once, not on every refresh.
    var resolvedCity: ResolvedCity? {
        get {
            guard let d = defaults.dictionary(forKey: "resolvedCity"), let query = d["query"] as? String,
                  let name = d["name"] as? String, let lat = d["latitude"] as? Double, let lon = d["longitude"] as? Double
            else { return nil }
            return ResolvedCity(query: query, name: name, latitude: lat, longitude: lon)
        }
        set {
            // Not a user-facing change, so no observers: nothing else depends on it.
            if let c = newValue {
                defaults.set(["query": c.query, "name": c.name, "latitude": c.latitude, "longitude": c.longitude], forKey: "resolvedCity")
            } else {
                defaults.removeObject(forKey: "resolvedCity")
            }
        }
    }
}

struct ResolvedCity: Equatable {
    var query: String
    var name: String
    var latitude: Double
    var longitude: Double
}
