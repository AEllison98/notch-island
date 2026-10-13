import AppKit
import ServiceManagement

@main
enum NotchIslandMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private var statusItem: NSStatusItem?
    private var island: IslandController?
    private var weather: WeatherService?
    private var calendar: CalendarService?
    private var music: MusicService?
    private var appPeeks: AppPeeks?
    private var powerPeeks: PowerPeeks?
    private var focusPeeks: FocusPeeks?
    private(set) var claude: ClaudeBridge?
    /// What the weather was last fetched for, so only a change of place refetches it.
    private var weatherPlace: (useLocation: Bool, city: String)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if quitIfAlreadyRunning() { return }
        yieldLaunchActivation()

        let island = IslandController(palette: settings.theme.palette)
        self.island = island
        applySettings()
        settings.observe { [weak self] in self?.applySettings() }
        island.model.onReorder = { [weak self] tiles in self?.settings.reorderVisible(tiles) }
        wireFocusTimer(island)
        let weather = WeatherService(model: island.model, settings: settings)
        self.weather = weather
        let calendar = CalendarService(model: island.model)
        self.calendar = calendar
        let music = MusicService(model: island.model, island: island)
        self.music = music
        appPeeks = AppPeeks(island: island, settings: settings)
        powerPeeks = PowerPeeks(island: island, settings: settings)
        focusPeeks = FocusPeeks(island: island, settings: settings)
        // The self-test and the drill listen on their own sockets, never on your real one.
        let socket = Diag.selfTest ? SelfTest.socketPath : (ClaudeDrill.socket ?? ClaudeBridge.socketPath)
        let hook = Diag.selfTest || ClaudeDrill.socket != nil ? SelfTest.hookPath : ClaudeBridge.installedHookPath
        claude = ClaudeBridge(island: island, socketPath: socket, hookPath: hook)
        if let claude, ClaudeDrill.plan != nil { ClaudeDrill.start(claude) }
        island.model.onOpened = { [weak weather, weak calendar, weak music] in
            weather?.refreshIfStale()
            calendar?.reload()
            music?.refresh()
        }
        weather.refresh()
        weatherPlace = (settings.weatherUsesLocation, settings.city)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Notch Island")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        if Diag.selfTest {
            Task { @MainActor in
                let status = await SelfTest.run(island, claude: self.claude)
                exit(status)
            }
        }
    }

    private func applySettings() {
        island?.setPalette(settings.theme.palette)
        island?.setTiles(settings.visibleTiles)
        music?.tilesChanged()
        island?.setCity(settings.city)
        if let last = weatherPlace, last != (settings.weatherUsesLocation, settings.city) {
            weatherPlace = (settings.weatherUsesLocation, settings.city)
            weather?.refresh()
        }
    }

    /// While the timer runs, the compact pill shows it; when it ends, a peek says so.
    private func wireFocusTimer(_ island: IslandController) {
        let timer = island.model.focusTimer
        timer.onTick = { [weak island] t in
            let live = t.state == .running || t.state == .paused
            island?.setActivity(
                live ? CompactActivity(leading: .symbol(t.state == .paused ? "pause.circle" : "timer"),
                                       trailing: .text(t.display)) : nil,
                from: .timer)
        }
        timer.onFinish = { [weak island] endedAt in
            if let endedAt {
                // It ended while the Mac was asleep: say when, not "time for a break".
                island?.showPeek(PeekContent(icon: .symbol("checkmark.circle"),
                                             title: "Focus session ended at \(endedAt.formatted(date: .omitted, time: .shortened))",
                                             duration: 4))
            } else {
                let minutes = Int((timer.length / 60).rounded())
                island?.showPeek(PeekContent(icon: .symbol("checkmark.circle.fill"), title: "Focus session done",
                                             subtitle: minutes > 0 ? "\(minutes) minutes. Time for a break." : nil,
                                             duration: 4))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        claude?.shutdown()
    }

    /// A second copy would draw a second island over the first one.
    private func quitIfAlreadyRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return false }
        FileHandle.standardError.write(Data("Notch Island is already running (pid \(others[0].processIdentifier)).\n".utf8))
        NSApp.terminate(nil)
        return true
    }

    /// Started from Finder or as a login item, macOS may make this app active, and whatever you
    /// were typing in would lose focus. The island never needs focus, so hand it straight back.
    private func yieldLaunchActivation() {
        launchActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { NSApp.deactivate() } }
        if NSApp.isActive { NSApp.deactivate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.stopYieldingActivation() }
    }

    private var launchActivationObserver: NSObjectProtocol?

    /// Also called before any activation you ask for, so it is never undone.
    private func stopYieldingActivation() {
        if let launchActivationObserver { NotificationCenter.default.removeObserver(launchActivationObserver) }
        launchActivationObserver = nil
    }

    // MARK: Menu

    /// Rebuilt every time it opens, so checkmarks always match the settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let header = NSMenuItem(title: "Notch Island \(version)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Tiles: click to show or hide, in the order they appear.
        menu.addItem(.sectionHeader(title: "Tiles"))
        let hidden = settings.hiddenTiles
        for kind in settings.tileOrder {
            let item = menuItem(kind.title, #selector(toggleTile(_:)))
            item.representedObject = kind.rawValue
            item.state = hidden.contains(kind) ? .off : .on
            menu.addItem(item)
        }
        let arrange = NSMenuItem(title: "Arrange Tiles", action: nil, keyEquivalent: "")
        let moves = NSMenu()
        let visible = settings.visibleTiles
        for (i, kind) in visible.enumerated() {
            if i > 0 { moves.addItem(moveItem(kind, by: -1)) }
            if i < visible.count - 1 { moves.addItem(moveItem(kind, by: 1)) }
        }
        if moves.items.isEmpty {
            let none = NSMenuItem(title: "Show two or more tiles to arrange them", action: nil, keyEquivalent: "")
            none.isEnabled = false
            moves.addItem(none)
        }
        let tip = NSMenuItem(title: "Or drag a tile in the open island", action: nil, keyEquivalent: "")
        tip.isEnabled = false
        moves.addItem(.separator())
        moves.addItem(tip)
        arrange.submenu = moves
        menu.addItem(arrange)
        menu.addItem(.separator())

        // Weather: your location, or a city you type.
        let city = settings.city
        let usesLocation = settings.weatherUsesLocation
        let place = NSMenuItem(title: "Weather: \(usesLocation ? WeatherService.myLocation : (city.isEmpty ? "Not Set" : city))",
                               action: nil, keyEquivalent: "")
        let places = NSMenu()
        let here = menuItem(WeatherService.myLocation, #selector(useMyLocation))
        here.state = usesLocation ? .on : .off
        places.addItem(here)
        if !city.isEmpty {
            let cityItem = menuItem(city, #selector(useCity))
            cityItem.state = usesLocation ? .off : .on
            places.addItem(cityItem)
        }
        places.addItem(.separator())
        places.addItem(menuItem(city.isEmpty ? "Set City…" : "Change City…", #selector(editCity)))
        place.submenu = places
        menu.addItem(place)

        let theme = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themes = NSMenu()
        for name in ThemeName.allCases {
            let item = menuItem(name.title, #selector(pickTheme(_:)))
            item.representedObject = name.rawValue
            item.state = settings.theme == name ? .on : .off
            themes.addItem(item)
        }
        theme.submenu = themes
        menu.addItem(theme)

        let login = SMAppService.mainApp.status
        let loginItem = menuItem(login == .requiresApproval ? "Launch at Login (Approve in System Settings…)" : "Launch at Login",
                                 #selector(toggleLaunchAtLogin))
        loginItem.state = login == .enabled ? .on : (login == .requiresApproval ? .mixed : .off)
        menu.addItem(loginItem)
        menu.addItem(.separator())

        let peeks = NSMenuItem(title: "Peeks", action: nil, keyEquivalent: "")
        let peekMenu = NSMenu()
        let apps = menuItem("Apps Opening and Quitting", #selector(togglePeekApps))
        apps.state = settings.peekApps ? .on : .off
        peekMenu.addItem(apps)
        let power = menuItem("Charger and Battery", #selector(togglePeekPower))
        power.state = settings.peekPower ? .on : .off
        peekMenu.addItem(power)
        let focusTitle = focusPeeks?.availability == .unavailable ? "Focus On and Off (not available)" : "Focus On and Off"
        let focus = menuItem(focusTitle, #selector(togglePeekFocus))
        focus.state = settings.peekFocus ? .on : .off
        peekMenu.addItem(focus)
        peekMenu.addItem(.separator())
        peekMenu.addItem(menuItem("Show Do Not Disturb with a Shortcut…", #selector(explainFocusShortcut)))
        peeks.submenu = peekMenu
        menu.addItem(peeks)

        let preview = NSMenuItem(title: "Preview", action: nil, keyEquivalent: "")
        let previews = NSMenu()
        previews.addItem(menuItem("Show a Peek", #selector(previewPeek)))
        previews.addItem(menuItem("Toggle the Compact Pill", #selector(previewCompact)))
        previews.addItem(menuItem("Open the Island", #selector(previewOpen)))
        preview.submenu = previews
        menu.addItem(preview)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Notch Island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func moveItem(_ kind: TileKind, by delta: Int) -> NSMenuItem {
        let item = menuItem("Move \(kind.title) \(delta < 0 ? "Left" : "Right")", #selector(moveTile(_:)))
        item.representedObject = [kind.rawValue, delta] as [Any]
        return item
    }

    @objc private func toggleTile(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = TileKind(rawValue: raw) else { return }
        settings.setVisible(kind, settings.hiddenTiles.contains(kind))
    }

    @objc private func moveTile(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Any], let raw = pair.first as? String,
              let kind = TileKind(rawValue: raw), let delta = pair.last as? Int else { return }
        settings.move(kind, by: delta)
    }

    @objc private func pickTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let name = ThemeName(rawValue: raw) else { return }
        settings.theme = name
    }

    /// Typing needs keyboard focus, so this is the one place the app activates, and only
    /// because you asked. Focus goes back where it was afterwards.
    @objc private func editCity() {
        let alert = NSAlert()
        alert.messageText = "Weather City"
        alert.informativeText = "The weather tile shows this city. Only its name is sent, to Open-Meteo, to find it."
        let field = NSTextField(string: settings.city)
        field.placeholderString = "Lisbon"
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        stopYieldingActivation()
        NSApp.activate()
        let saved = alert.runModal() == .alertFirstButtonReturn
        NSApp.deactivate()
        if saved {
            settings.city = field.stringValue
            if !settings.city.isEmpty { settings.weatherUsesLocation = false }
        }
    }

    /// The first time, macOS asks for Location permission (with the one-line reason from
    /// Info.plist). Nothing asks before you choose this.
    @objc private func useMyLocation() { settings.weatherUsesLocation = true }

    @objc private func useCity() { settings.weatherUsesLocation = false }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled: try service.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try service.register()
            }
        } catch {
            island?.showPeek(PeekContent(icon: .symbol("exclamationmark.triangle.fill"),
                                         title: "Couldn't change Launch at Login",
                                         subtitle: error.localizedDescription, duration: 4))
        }
    }

    @objc private func togglePeekApps() { settings.peekApps.toggle() }
    @objc private func togglePeekPower() { settings.peekPower.toggle() }
    /// Turning it on is the first use, so this is when macOS asks for Focus status.
    @objc private func togglePeekFocus() { focusPeeks?.setEnabled(!settings.peekFocus) }

    /// The closest thing to a Do Not Disturb API: a Shortcuts automation you make once.
    @objc private func explainFocusShortcut() {
        let alert = NSAlert()
        alert.messageText = "Show Do Not Disturb with a Shortcut"
        alert.informativeText = """
        macOS has no public way for apps to see Do Not Disturb. The Focus permission only says whether some Focus is on. For Do Not Disturb by name:

        1. Open Shortcuts and choose Automation, then New Automation.
        2. Pick Do Not Disturb, choose "Is Turned On", and Run Immediately.
        3. Add the action Open URLs with: notchisland://focus?on=1&name=Do%20Not%20Disturb
        4. Make a second automation for "Is Turned Off" with ?on=0 instead.

        No permission is needed for this.
        """
        alert.addButton(withTitle: "Copy the First URL")
        alert.addButton(withTitle: "Close")
        stopYieldingActivation()
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("notchisland://focus?on=1&name=Do%20Not%20Disturb", forType: .string)
        }
        NSApp.deactivate()
    }

    /// notchisland:// links, from a Shortcuts automation. Opening a link brings the app forward,
    /// so focus is handed straight back.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let focus = FocusPeeks.parse(url) { focusPeeks?.show(on: focus.on, name: focus.name) }
        }
        DispatchQueue.main.async { NSApp.deactivate() }
    }

    private var previewPillOn = false

    @objc private func previewPeek() {
        island?.showPeek(PeekContent(icon: .symbol("sparkles"), title: "Hello from the notch",
                                     subtitle: "A peek. It goes away by itself.", duration: 3))
    }

    @objc private func previewCompact() {
        previewPillOn.toggle()
        island?.setActivity(previewPillOn ? CompactActivity(leading: .symbol("sparkles"), trailing: .grid) : nil,
                            from: .preview)
    }

    @objc private func previewOpen() {
        island?.expand(pinned: true)
    }
}
