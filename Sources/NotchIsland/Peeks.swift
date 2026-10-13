import AppKit
import Intents
import IOKit.ps

// MARK: - Apps opening and quitting

/// A bubble with the app's icon when an app you can see in the Dock opens or quits.
@MainActor
final class AppPeeks {
    private let island: IslandController
    private let settings: Settings
    /// Apps that start with you at login would flood the notch; wait this long after launch.
    private let quietUntil = Date().addingTimeInterval(8)

    init(island: IslandController, settings: Settings) {
        self.island = island
        self.settings = settings
        guard !Diag.selfTest else { return }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handle(note, opened: true) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handle(note, opened: false) }
        }
    }

    private func handle(_ note: Notification, opened: Bool) {
        guard settings.peekApps, Date() > quietUntil,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let peek = Self.peek(for: app, opened: opened) else { return }
        island.showPeek(peek)
    }

    /// Only apps with a Dock icon, and never this one.
    static func peek(for app: NSRunningApplication, opened: Bool) -> PeekContent? {
        guard app.activationPolicy == .regular, app.bundleIdentifier != Bundle.main.bundleIdentifier,
              let name = app.localizedName else { return nil }
        let icon: IslandIcon = app.icon.map { .image($0) } ?? .symbol("app")
        return PeekContent(icon: icon, title: opened ? "\(name) opened" : "\(name) quit", duration: 2.5)
    }
}

// MARK: - Charger and battery

struct PowerReading: Equatable {
    var onAC: Bool
    var percent: Int
}

enum PowerEvent: Equatable {
    case chargerConnected(percent: Int)
    case low(threshold: Int, percent: Int)

    var peek: PeekContent {
        switch self {
        case .chargerConnected(let percent):
            PeekContent(icon: .symbol("bolt.fill"), title: "Charging", subtitle: "\(percent)%", duration: 2.5)
        case .low(let threshold, let percent):
            PeekContent(icon: .symbol(threshold <= 10 ? "battery.0percent" : "battery.25percent"),
                        title: "Battery at \(percent)%",
                        subtitle: threshold <= 10 ? "Plug in now" : "Plug in soon", duration: 4)
        }
    }
}

/// Which bubbles a change in power should show. Each low-battery warning is for crossing its
/// level on the way down, so it re-arms only once the battery is back above it (by a margin),
/// not merely because the charger went in and out at 9%.
struct PowerRules: Equatable {
    var warned20 = false
    var warned10 = false

    mutating func events(from old: PowerReading?, to new: PowerReading) -> [PowerEvent] {
        if new.percent > 25 { warned20 = false }
        if new.percent > 15 { warned10 = false }
        guard let old else {
            // Starting up already low is not a crossing: arm the warnings without showing them.
            warned20 = new.percent <= 20
            warned10 = new.percent <= 10
            return []
        }
        var events: [PowerEvent] = []
        if new.onAC && !old.onAC { events.append(.chargerConnected(percent: new.percent)) }
        if !new.onAC {
            if new.percent <= 10 && !warned10 {
                warned10 = true
                warned20 = true   // one bubble, not two, when it drops past both at once
                events.append(.low(threshold: 10, percent: new.percent))
            } else if new.percent <= 20 && !warned20 {
                warned20 = true
                events.append(.low(threshold: 20, percent: new.percent))
            }
        }
        return events
    }
}

/// Listens to IOKit's power-source notifications (no permission needed).
@MainActor
final class PowerPeeks {
    private let island: IslandController
    private let settings: Settings
    private var rules = PowerRules()
    private var last: PowerReading?
    private var source: CFRunLoopSource?

    init(island: IslandController, settings: Settings) {
        self.island = island
        self.settings = settings
        guard !Diag.selfTest else { return }
        last = Self.read()
        _ = last.map { rules.events(from: nil, to: $0) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let me = Unmanaged<PowerPeeks>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.changed() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = source
        }
    }

    private func changed() {
        guard let now = Self.read(), now != last else { return }
        defer { last = now }
        let events = rules.events(from: last, to: now)
        guard settings.peekPower else { return }
        events.forEach { island.showPeek($0.peek) }
    }

    /// nil on a Mac without a battery.
    static func read() -> PowerReading? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let onAC = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return PowerReading(onAC: onAC, percent: Int((Double(current) / Double(max) * 100).rounded()))
        }
        return nil
    }
}

// MARK: - Focus

/// Focus on/off. macOS has no public Do Not Disturb API; the closest is INFocusStatusCenter,
/// which says only whether some Focus is on (not which one) and never announces changes, so it
/// is checked every few seconds once you allow it. It is off until you turn it on in the menu,
/// which is when macOS asks.
@MainActor
final class FocusPeeks {
    enum Availability: Equatable { case off, waiting, on, unavailable }

    private let island: IslandController
    private let settings: Settings
    private var timer: Timer?
    private var lastFocused: Bool?
    private(set) var availability: Availability = .off

    init(island: IslandController, settings: Settings) {
        self.island = island
        self.settings = settings
        guard !Diag.selfTest else { return }
        if settings.peekFocus { start(asking: false) }
    }

    /// Turned on from the menu: asks macOS the first time.
    func setEnabled(_ on: Bool) {
        settings.peekFocus = on
        if on { start(asking: true) } else { stop(); availability = .off }
    }

    private func start(asking: Bool) {
        let center = INFocusStatusCenter.default
        switch center.authorizationStatus {
        case .authorized:
            availability = .on
            beginPolling()
        case .notDetermined where asking:
            availability = .waiting
            center.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if status == .authorized {
                        self.availability = .on
                        self.beginPolling()
                    } else {
                        self.unavailable()
                    }
                }
            }
        case .notDetermined:
            availability = .off
        default:
            unavailable()
        }
    }

    private func unavailable() {
        availability = .unavailable
        island.showPeek(PeekContent(icon: .symbol("moon.fill"), title: "Focus status isn't available",
                                    subtitle: "Allow it in System Settings, or use a Shortcut", duration: 4))
    }

    private func beginPolling() {
        stop()
        // Unless allowed, isFocused reads false, which looks like "off"; only trust it now.
        lastFocused = INFocusStatusCenter.default.focusStatus.isFocused
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() { timer?.invalidate(); timer = nil }

    private func poll() {
        guard INFocusStatusCenter.default.authorizationStatus == .authorized,
              let focused = INFocusStatusCenter.default.focusStatus.isFocused else { return }
        if let lastFocused, focused != lastFocused { show(on: focused, name: nil) }
        lastFocused = focused
    }

    /// Also reached from a Shortcuts automation through notchisland://focus?on=1 (see App).
    func show(on: Bool, name: String?) {
        let what = name ?? "Focus"
        island.showPeek(PeekContent(icon: .symbol(on ? "moon.fill" : "moon"), title: on ? "\(what) on" : "\(what) off", duration: 2.5))
    }

    /// notchisland://focus?on=1&name=Do%20Not%20Disturb
    static func parse(_ url: URL) -> (on: Bool, name: String?)? {
        guard url.scheme?.lowercased() == "notchisland", url.host?.lowercased() == "focus",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let on = items.first(where: { $0.name == "on" })?.value else { return nil }
        let name = items.first(where: { $0.name == "name" })?.value.flatMap { $0.isEmpty ? nil : String($0.prefix(40)) }
        return (on == "1" || on.lowercased() == "true", name)
    }
}
