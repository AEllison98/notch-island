import AppKit
import Observation
import SwiftUI

// MARK: - State

enum IslandMode: String {
    /// Just the black notch.
    case resting
    /// A black pill grown out to the sides of the notch, while something is live.
    case compact
    /// A small bubble under the notch for 2 to 4 seconds.
    case peek
    /// Open: tiles, or a Claude permission request.
    case expanded
}

enum IslandIcon: Equatable {
    case symbol(String)
    case image(NSImage)
}

struct PeekContent: Equatable {
    var id = UUID()
    var icon: IslandIcon
    var title: String
    var subtitle: String? = nil
    /// Clamped to 2...4 seconds.
    var duration: TimeInterval = 3
}

/// What the compact pill shows either side of the notch.
struct CompactActivity: Equatable {
    var leading: IslandIcon
    var trailing: Trailing

    enum Trailing: Equatable {
        case grid
        case waveform
        case text(String)
        case none
    }
}

/// Who wants the compact pill. When several do, the highest raw value wins.
enum ActivitySource: Int, CaseIterable {
    case music = 0
    case timer = 1
    case claude = 2
    case preview = 3
}

@MainActor
@Observable
final class IslandModel {
    var mode: IslandMode = .resting
    var notch: NotchMetrics
    var palette: Palette = .darkMatte
    /// Distance from each window's centre to the notch's centre. Normally 0; window frames are
    /// rounded to whole points and the notch is not always on one.
    var centerOffsetX: CGFloat = 0
    var shadowOffsetX: CGFloat = 0
    var peek: PeekContent?
    var activity: CompactActivity?
    var pinned = false
    /// The shown tiles, in order.
    var tiles: [TileKind] = TileKind.allCases
    var city = ""
    var weather: WeatherState = .needsSetup
    var calendar: CalendarState = .notConnected
    var music: MusicState = .idle
    /// Lyrics for the track in `music`, once LRCLIB (or the cache) has answered.
    var lyrics: Lyrics?
    /// A Claude Code permission request waiting for your answer.
    var claude: ClaudeCard?
    /// The tile under the pointer, for its hover tint. Cleared when the island closes, so a tile
    /// left under the pointer is not still lit the next time it opens.
    var hoveredTile: TileKind?
    /// The player you used last, so an idle Music tile opens yours rather than always Apple Music.
    @ObservationIgnored var lastPlayer: Player?
    let focusTimer = FocusTimer()

    @ObservationIgnored var onTap: () -> Void = {}

    /// The app a click on this tile opens (nil for the timer).
    func appBundleID(for kind: TileKind) -> String? {
        IslandController.appBundleID(for: kind, music: music, running: Player.allCases.filter(\.isRunning), lastPlayer: lastPlayer)
    }

    /// What VoiceOver calls a click on the tile. An idle Music tile says "Open music player":
    /// which one it opens depends on what is running, and the island is not told when that changes.
    func openActionName(for kind: TileKind) -> String? {
        if kind == .music, case .idle = music { return "Open music player" }
        return appBundleID(for: kind).map { "Open \(IslandController.appName(forBundleID: $0))" }
    }
    @ObservationIgnored var onDragBegan: () -> Void = {}
    @ObservationIgnored var onReorder: ([TileKind]) -> Void = { _ in }
    /// Called each time the island opens, so tiles can refresh stale data.
    @ObservationIgnored var onOpened: () -> Void = {}
    @ObservationIgnored var onConnectCalendar: () -> Void = {}
    @ObservationIgnored var onOpenTile: (TileKind) -> Void = { _ in }
    @ObservationIgnored var onMusicCommand: (MusicCommand) -> Void = { _ in }
    @ObservationIgnored var onConnectPlayer: (Player) -> Void = { _ in }
    @ObservationIgnored var onClaudeDecision: (Bool) -> Void = { _ in }
    @ObservationIgnored var onClaudeSeenAll: (UUID) -> Void = { _ in }
    /// Where SwiftUI actually laid the island out, in the island window. Read by the self-test.
    @ObservationIgnored var drawnFrame: CGRect = .zero
    /// Where named controls were laid out (top-left origin), so the self-test can click them.
    @ObservationIgnored var frames: [String: CGRect] = [:]
    /// Which copy of a view last reported each frame (two copies overlap during a transition).
    @ObservationIgnored var frameOwners: [String: UUID] = [:]
    /// How many times each reported view has been created. Read by the self-test.
    @ObservationIgnored var appearances: [String: Int] = [:]

    init(notch: NotchMetrics) { self.notch = notch }

    func size(for mode: IslandMode) -> CGSize {
        IslandLayout.size(for: mode, notch: notch, tiles: tiles, lyricsRow: showsLyricsRow, claudeCard: claude != nil)
    }

    /// The two lines of lyrics under the tiles, as in the mockup: only with the Music tile shown,
    /// something loaded, and lyrics found for it.
    var showsLyricsRow: Bool { Self.showsLyricsRow(tiles: tiles, music: music, lyrics: lyrics) }

    static func showsLyricsRow(tiles: [TileKind], music: MusicState, lyrics: Lyrics?) -> Bool {
        guard tiles.contains(.music), case .nowPlaying = music else { return false }
        switch lyrics {
        case .synced?, .instrumental?, .loading?: return true
        default: return false
        }
    }
    var islandSize: CGSize { size(for: mode) }
}

// MARK: - Sizes

enum IslandLayout {
    /// How far the compact pill grows past each side of the notch.
    static let wing: CGFloat = 46
    /// The concave top corners that blend the island into the top edge of the screen.
    static let ear: CGFloat = 6
    static let peekBodyHeight: CGFloat = 46
    static let tileHeight: CGFloat = 108
    static let lyricsRowHeight: CGFloat = 46
    static let tileGap: CGFloat = 10
    /// Space between the island's edge and the row of tiles (the ears sit inside it).
    static let bodyInset: CGFloat = 20
    static let bodyTop: CGFloat = 8
    static let bodyBottom: CGFloat = 16
    static let minExpandedWidth: CGFloat = 380
    /// The widest and tallest the island can ever get (room for a long Claude command later).
    static let maxWidth: CGFloat = 800
    static let maxBodyHeight: CGFloat = 420

    /// Room around the island in its own window: only the spring's overshoot (about 2% of the
    /// change), because the shadow is drawn in a separate window that ignores the mouse. Any
    /// non-transparent pixel in the island window catches clicks, and a shadow is never
    /// fully transparent.
    static let islandMargin: CGFloat = 12
    static let shadowMargin: CGFloat = 40

    static let claudeCardWidth: CGFloat = 640
    static let claudeCardHeight: CGFloat = 300

    static func size(for mode: IslandMode, notch: NotchMetrics, tiles: [TileKind], lyricsRow: Bool = false,
                     claudeCard: Bool = false) -> CGSize {
        switch mode {
        case .resting:
            // On a real notch, stay 1 pt inside it on each side so no black edge shows next to it.
            notch.hasHardwareNotch
                ? CGSize(width: notch.width - 2, height: notch.height)
                : CGSize(width: notch.width + 2 * ear, height: notch.height)
        case .compact:
            CGSize(width: notch.width + 2 * wing + 2 * ear, height: notch.height)
        case .peek:
            CGSize(width: max(notch.width + 160, 340) + 2 * ear, height: notch.height + peekBodyHeight)
        case .expanded where claudeCard:
            CGSize(width: claudeCardWidth, height: notch.height + claudeCardHeight)
        case .expanded:
            CGSize(width: min(max(rowWidth(tiles) + 2 * bodyInset, minExpandedWidth), maxWidth),
                   height: notch.height + bodyTop + tileHeight + (lyricsRow ? lyricsRowHeight : 0) + bodyBottom)
        }
    }

    static func rowWidth(_ tiles: [TileKind]) -> CGFloat {
        tiles.reduce(0) { $0 + $1.width } + CGFloat(max(tiles.count - 1, 0)) * tileGap
    }

    static func radii(for mode: IslandMode, notch: NotchMetrics) -> (top: CGFloat, bottom: CGFloat) {
        switch mode {
        case .resting: (notch.hasHardwareNotch ? 0 : ear, 10)
        case .compact: (ear, 12)
        case .peek: (ear, 20)
        case .expanded: (ear, 28)
        }
    }

    /// A window hanging from the top of the notch's screen, centred on the notch, with an even
    /// whole-point width so its centre lands on a whole point too.
    static func windowFrame(holding size: CGSize, margin: CGFloat, notch: NotchMetrics) -> CGRect {
        let width = (ceil(size.width + 2 * margin) / 2).rounded(.up) * 2
        let height = ceil(size.height + margin)
        return CGRect(x: (notch.rect.midX - width / 2).rounded(), y: notch.screenFrame.maxY - height,
                      width: width, height: height)
    }

    /// The island's rectangle in screen coordinates for a given size.
    static func screenRect(for size: CGSize, notch: NotchMetrics) -> CGRect {
        CGRect(x: notch.rect.midX - size.width / 2, y: notch.screenFrame.maxY - size.height,
               width: size.width, height: size.height)
    }
}

// MARK: - Controller

/// Owns the two windows and every rule about when the island changes shape.
@MainActor
final class IslandController {
    /// Opening bounces a little. Closing does not, or the shape would dip smaller than the
    /// notch on its way back.
    static let springOpen = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let springClose = Animation.spring(response: 0.38, dampingFraction: 1.0)
    static let hoverDelay: TimeInterval = 0.25
    static let leaveDelay: TimeInterval = 0.15
    /// Long enough for the spring to settle before the window shrinks back.
    static let settleDelay: TimeInterval = 0.65
    /// A peek interrupted by opening the island is shown again afterwards, unless it was
    /// already up this long.
    static let peekSeenAfter: TimeInterval = 1.5

    let model: IslandModel
    let panel = IslandPanel()
    let shadowPanel = ShadowPanel()
    let container = IslandContainerView()
    let hosting: IslandHostingView<IslandRootView>

    /// Replaceable so the self-test can drive hover without a real mouse.
    var mouseLocation: () -> CGPoint = { NSEvent.mouseLocation }

    private var generation = 0
    /// The island size the window is currently big enough for.
    private var windowFit: CGSize = .zero
    private var hovering = false
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var peekWork: DispatchWorkItem?
    private var peekShownAt: Date?
    private var peekQueue: [PeekContent] = []
    private var activities: [ActivitySource: CompactActivity] = [:]
    private var outsideClickMonitor: Any?
    private var leaveWatchdog: Timer?
    private var watchdogMisses = 0

    init(palette: Palette) {
        let (_, metrics) = NotchMetrics.current()
        model = IslandModel(notch: metrics)
        model.palette = palette

        hosting = IslandHostingView(rootView: IslandRootView(model: model))
        hosting.sizingOptions = []   // the controller sizes the window, not SwiftUI
        // Never resized with the window: see placeHost().
        hosting.autoresizingMask = []
        container.addSubview(hosting)
        // The self-test drives hover itself (through the same handlers); your real pointer
        // crossing the notch while it runs must not change what it is measuring.
        container.onEnter = { [weak self] in if !Diag.selfTest { self?.mouseEntered() } }
        container.onExit = { [weak self] in if !Diag.selfTest { self?.mouseExited() } }
        panel.contentView = container
        model.onTap = { [weak self] in self?.tapped() }
        model.onDragBegan = { [weak self] in self?.pinOpen() }
        model.onOpenTile = { [weak self] in self?.openApp(for: $0) }

        let shadowHosting = NSHostingView(rootView: IslandShadowView(model: model))
        shadowHosting.sizingOptions = []
        shadowPanel.contentView = shadowHosting

        fitShadowWindow()
        placeHost()
        fitWindow(to: model.islandSize)
        orderFront()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.screensChanged() } }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.orderFront() } }

        Diag.log("notch \(metrics.rect) hardware=\(metrics.hasHardwareNotch) screen=\(metrics.screenFrame)")
    }

    // MARK: Public

    func setPalette(_ palette: Palette) {
        withAnimation(.easeInOut(duration: 0.2)) { model.palette = palette }
    }

    func showPeek(_ peek: PeekContent) {
        peekQueue.append(peek)
        if peekQueue.count > 3 { peekQueue.removeFirst(peekQueue.count - 3) }
        if model.mode == .resting || model.mode == .compact { showNextPeek() }
    }

    func setActivity(_ activity: CompactActivity?, from source: ActivitySource) {
        activities[source] = activity
        let top = activities.max { $0.key.rawValue < $1.key.rawValue }?.value
        let newBase: IslandMode = top == nil ? .resting : .compact
        if (model.mode == .resting || model.mode == .compact) && newBase != model.mode {
            // The pill's shape and what it shows move together, on one spring.
            setMode(newBase) { self.model.activity = top }
        } else if model.activity?.leading != top?.leading || (model.activity == nil) != (top == nil) {
            withAnimation(Self.springOpen) { model.activity = top }
        } else {
            model.activity = top   // only the text changed, e.g. the timer ticking
        }
    }

    /// Shown tiles changed (hidden, shown or moved from the menu). Resizes the open island.
    func setTiles(_ tiles: [TileKind]) {
        guard tiles != model.tiles else { return }
        guard model.mode == .expanded else { model.tiles = tiles; return }
        let current = model.islandSize
        let target = IslandLayout.size(for: .expanded, notch: model.notch, tiles: tiles,
                                       lyricsRow: IslandModel.showsLyricsRow(tiles: tiles, music: model.music, lyrics: model.lyrics))
        transition(to: target, shrinking: target.width < current.width) { self.model.tiles = tiles }
    }

    func setCity(_ city: String) { model.city = city }

    /// What is playing, and its lyrics. The lyrics row can appear or go, which changes the open
    /// island's height, so that goes through the same grow-then-settle as any other resize.
    func setMusic(_ music: MusicState, lyrics: Lyrics?) {
        guard music != model.music || lyrics != model.lyrics else { return }
        let rowBefore = model.showsLyricsRow
        let rowAfter = IslandModel.showsLyricsRow(tiles: model.tiles, music: music, lyrics: lyrics)
        guard model.mode == .expanded, rowBefore != rowAfter else {
            model.music = music
            model.lyrics = lyrics
            return
        }
        let target = IslandLayout.size(for: .expanded, notch: model.notch, tiles: model.tiles, lyricsRow: rowAfter)
        transition(to: target, shrinking: !rowAfter) {
            self.model.music = music
            self.model.lyrics = lyrics
        }
    }

    /// Shows a Claude Code permission request (opening the island, pinned), or takes it away.
    func setClaudeCard(_ card: ClaudeCard?) {
        if let card {
            if model.mode == .expanded && model.claude == nil {
                let target = IslandLayout.size(for: .expanded, notch: model.notch, tiles: model.tiles,
                                               lyricsRow: model.showsLyricsRow, claudeCard: true)
                transition(to: target, shrinking: false) { self.model.claude = card }
            } else {
                model.claude = card
            }
            expand(pinned: true)
        } else if model.claude != nil {
            if model.mode == .expanded {
                collapse { self.model.claude = nil }
            } else {
                model.claude = nil
            }
        }
    }

    /// A click on a tile: open the app behind it, and get out of its way.
    func openApp(for kind: TileKind) {
        guard let wanted = model.appBundleID(for: kind) else { return }
        // The player you used last may have been uninstalled since: then Apple Music.
        let installed = [wanted, kind == .music ? Player.music.rawValue : nil].compactMap { $0 }
            .first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        // The self-test records what a click would open, installed or not (Spotify need not be).
        guard let bundleID = Diag.selfTest ? wanted : installed else { NSSound.beep(); return }
        lastOpenedApp = bundleID
        collapse()
        // The self-test only records what a click would open; it never opens your apps.
        guard !Diag.selfTest, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        Self.appsOpened += 1
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Apps really opened from a tile. The self-test checks it stays at zero.
    private(set) static var appsOpened = 0

    /// The Music tile opens the player it is showing; with nothing loaded, an open player (the
    /// one you used last, if both are open), else the one you used last, else Apple Music.
    /// `running` is only asked for in that last case.
    static func appBundleID(for kind: TileKind, music: MusicState, running: @autoclosure () -> [Player],
                            lastPlayer: Player?) -> String? {
        switch kind {
        case .music:
            switch music {
            case .nowPlaying(let now): return now.player.rawValue
            case .needsConsent(let player), .denied(let player): return player.rawValue
            case .idle:
                let open = running()
                return (open.first { $0 == lastPlayer } ?? open.first ?? lastPlayer ?? .music).rawValue
            }
        case .weather: return "com.apple.weather"
        case .calendar: return "com.apple.iCal"
        case .timer: return nil
        }
    }

    /// The app's name, as VoiceOver says it in "Open …".
    static func appName(forBundleID id: String) -> String {
        if let player = Player(rawValue: id) { return player.name }
        switch id {
        case "com.apple.weather": return "Weather"
        case "com.apple.iCal": return "Calendar"
        default: return id
        }
    }

    /// Keeps the open island open while something is being done in it (a tile being dragged).
    func pinOpen() {
        if model.mode == .expanded && !model.pinned { pin() }
    }

    /// - Parameter requeuePeek: false when the open came from tapping the peek itself, which
    ///   means it has been seen.
    func expand(pinned: Bool, requeuePeek: Bool = true) {
        openWork?.cancel()
        closeWork?.cancel()
        if model.mode == .peek { interruptPeek(requeue: requeuePeek) }
        if pinned { pin() }
        setMode(.expanded)
    }

    func collapse(alongside: () -> Void = {}) {
        model.pinned = false
        model.hoveredTile = nil
        removeOutsideClickMonitor()
        guard model.mode == .expanded else { alongside(); return }
        setMode(baseMode, alongside: alongside)
        clearPeekAfterSettle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.showNextPeek() }
    }

    /// The island's current target rectangle in screen coordinates.
    var islandScreenRect: CGRect { IslandLayout.screenRect(for: model.islandSize, notch: model.notch) }

    /// Where resting the pointer opens the island: the notch itself. Not the pill's wings,
    /// which sit over menu bar items, and not the peek bubble, which hangs over app content;
    /// those open with a click. It is also the one zone that never changes shape under a
    /// pointer that has not moved.
    var openScreenRect: CGRect {
        IslandLayout.screenRect(for: model.size(for: .resting), notch: model.notch)
    }

    // MARK: Mode changes

    private var baseMode: IslandMode { model.activity == nil ? .resting : .compact }

    private func setMode(_ new: IslandMode, alongside: () -> Void = {}) {
        let old = model.mode
        guard new != old else { alongside(); updateHotRect(); return }
        let target = model.size(for: new)
        let current = model.islandSize
        transition(to: target, shrinking: target.width < current.width || target.height < current.height) {
            self.model.mode = new
            alongside()
        }
        if new == .expanded { expandCount += 1; model.onOpened() }
        Diag.log("mode \(old.rawValue) -> \(new.rawValue)")

        if new == .expanded && !model.pinned { startLeaveWatchdog() } else { stopLeaveWatchdog() }
    }

    /// Every change of the island's size goes through here: grow the window first so the spring
    /// never draws outside it, animate, and shrink the window only once the spring has settled.
    private func transition(to target: CGSize, shrinking: Bool, _ change: () -> Void) {
        generation += 1
        let gen = generation
        fitWindow(to: CGSize(width: max(windowFit.width, target.width),
                             height: max(windowFit.height, target.height)))
        withAnimation(shrinking ? Self.springClose : Self.springOpen) { change() }
        updateHotRect()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.fitWindow(to: self.model.islandSize)
        }
    }

    /// The island's SwiftUI view, in screen coordinates. It is one fixed size, big enough for
    /// the largest island, pinned over the notch. The window around it grows and shrinks (so
    /// clicks beside the island reach the menu bar), but the view does not move or resize with
    /// it: if it did, SwiftUI would re-centre the island inside the new width during the open
    /// animation, and the island would visibly slide in from the side.
    private(set) var hostScreenFrame: CGRect = .zero

    private func placeHost() {
        let n = model.notch
        let largest = CGSize(width: IslandLayout.maxWidth, height: n.height + IslandLayout.maxBodyHeight)
        hostScreenFrame = IslandLayout.windowFrame(holding: largest, margin: IslandLayout.islandMargin, notch: n)
        model.centerOffsetX = n.rect.midX - hostScreenFrame.midX
    }

    private func fitWindow(to islandSize: CGSize) {
        let frame = IslandLayout.windowFrame(holding: islandSize, margin: IslandLayout.islandMargin, notch: model.notch)
        // Window and view move in one transaction, so the view never shows at the old offset
        // inside the new window (a one-frame jump sideways).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        hosting.frame = hostScreenFrame.offsetBy(dx: -frame.minX, dy: -frame.minY)
        panel.displayIfNeeded()
        CATransaction.commit()
        windowFit = islandSize
        updateHotRect()
    }

    /// The shadow window never takes clicks, so it is simply sized for the largest island.
    private func fitShadowWindow() {
        let n = model.notch
        let largest = CGSize(width: IslandLayout.maxWidth, height: n.height + IslandLayout.maxBodyHeight)
        let frame = IslandLayout.windowFrame(holding: largest, margin: IslandLayout.shadowMargin, notch: n)
        if shadowPanel.frame != frame { shadowPanel.setFrame(frame, display: true) }
        model.shadowOffsetX = n.rect.midX - frame.midX
    }

    private func orderFront() {
        panel.orderFrontRegardless()
        shadowPanel.order(.below, relativeTo: panel.windowNumber)
    }

    /// macOS posts "screen parameters changed" for more than displays (the Dock, the menu bar);
    /// nothing to do unless the notch or its screen really moved.
    private func screensChanged(force: Bool = false) {
        let (_, metrics) = NotchMetrics.current()
        guard force || metrics != model.notch else { orderFront(); return }
        Diag.log("screens changed: notch \(metrics.rect) hardware=\(metrics.hasHardwareNotch)")
        model.notch = metrics
        fitShadowWindow()
        placeHost()
        // The shape may be mid-spring at any size up to the largest the island can ever be,
        // so make room for that, then settle to the current size like any other change.
        fitWindow(to: CGSize(width: max(IslandLayout.maxWidth, model.islandSize.width),
                             height: max(metrics.height + IslandLayout.maxBodyHeight, model.islandSize.height)))
        orderFront()
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.fitWindow(to: self.model.islandSize)
        }
    }

    // MARK: Peeks

    private func showNextPeek() {
        guard model.mode == .resting || model.mode == .compact, !peekQueue.isEmpty else { return }
        let peek = peekQueue.removeFirst()
        model.peek = peek
        peekShownAt = Date()
        setMode(.peek)
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endPeek() }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + min(max(peek.duration, 2), 4), execute: work)
    }

    private func endPeek() {
        guard model.mode == .peek else { return }
        setMode(baseMode)
        clearPeekAfterSettle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.showNextPeek() }
    }

    /// Opening the island replaces a peek. Put it back to be shown again unless it has
    /// already been on screen long enough to read, or was tapped.
    private func interruptPeek(requeue: Bool) {
        peekWork?.cancel()
        let shownFor = peekShownAt.map { Date().timeIntervalSince($0) } ?? 0
        if requeue, var peek = model.peek, shownFor < Self.peekSeenAfter {
            peek.id = UUID()
            peek.duration = max(2, peek.duration - shownFor)
            peekQueue.insert(peek, at: 0)
        }
    }

    /// Keep the bubble's text while it shrinks away, then drop it.
    private func clearPeekAfterSettle() {
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            guard let self, self.generation == gen, self.model.mode != .peek else { return }
            self.model.peek = nil
        }
    }

    // MARK: Mouse

    /// Exactly the tracking area's rectangle, so this and AppKit agree on where the zone is.
    /// No top edge: every zone hangs from the top of the screen, where the pointer stops.
    private func inZone(_ rect: CGRect) -> Bool {
        let p = mouseLocation()
        return p.x >= rect.minX && p.x < rect.maxX && p.y >= rect.minY
    }

    /// A little slack when deciding to close, so the edge of the island does not flicker.
    private func nearIsland() -> Bool {
        islandScreenRect.insetBy(dx: -2, dy: -2).contains(mouseLocation())
    }

    /// While open, leaving the open island closes it. Otherwise only the notch (or pill) counts.
    private var hotScreenRect: CGRect { model.mode == .expanded ? islandScreenRect : openScreenRect }

    private func updateHotRect() {
        let f = panel.frame
        container.hotRect = hotScreenRect.offsetBy(dx: -f.minX, dy: -f.minY)
        reconcileHover()
    }

    /// A tracking area rebuilt under a pointer that is already inside it sends no "entered",
    /// and one that shrinks away from a still pointer sends no "exited". Check directly.
    private func reconcileHover() {
        let inside = inZone(hotScreenRect)
        if inside && !hovering { mouseEntered() } else if !inside && hovering { mouseExited() }
    }

    private func mouseEntered() {
        hovering = true
        closeWork?.cancel()
        guard model.mode != .expanded else { return }
        openWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hovering, self.inZone(self.openScreenRect) else { return }
            self.expand(pinned: false)
        }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: work)
    }

    private func mouseExited() {
        hovering = false
        openWork?.cancel()
        guard model.mode == .expanded, !model.pinned else { return }
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering, !self.model.pinned, !self.nearIsland() else { return }
            self.collapse()
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.leaveDelay, execute: work)
    }

    private func tapped() {
        if model.mode == .expanded { pin() } else { expand(pinned: true, requeuePeek: false) }
    }

    /// Keeps the island open until a click lands somewhere else.
    private func pin() {
        model.pinned = true
        stopLeaveWatchdog()
        installOutsideClickMonitor()
    }

    /// A global monitor only sees clicks that go to other apps, so clicks on the island itself
    /// never reach it.
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            // Likewise, a real click in another app while the self-test runs is not part of it
            // (it calls clickedOutside() itself, as the monitor does).
            MainActor.assumeIsolated { if !Diag.selfTest { self?.clickedOutside() } }
        }
    }

    private func clickedOutside() { collapse() }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    /// Tracking areas can miss an exit (a fast flick). While open by hover, check the pointer
    /// directly a few times a second as a backstop.
    private func startLeaveWatchdog() {
        stopLeaveWatchdog()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.model.pinned || self.model.mode != .expanded { self.stopLeaveWatchdog(); return }
                self.watchdogMisses = self.nearIsland() ? 0 : self.watchdogMisses + 1
                if self.watchdogMisses >= 2 { self.collapse() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        leaveWatchdog = timer
    }

    private func stopLeaveWatchdog() {
        leaveWatchdog?.invalidate()
        leaveWatchdog = nil
        watchdogMisses = 0
    }

    // MARK: Self-test hooks

    private(set) var expandCount = 0
    /// The app a tile click last opened (or, in the self-test, would have opened).
    var lastOpenedApp: String?
    var windowFitForTest: CGSize { windowFit }
    /// A point as SwiftUI reports it in .global (the window, top-left origin), on screen.
    func screenPoint(fromWindow p: CGPoint) -> CGPoint {
        CGPoint(x: panel.frame.minX + p.x, y: panel.frame.maxY - p.y)
    }
    var hasOutsideClickMonitor: Bool { outsideClickMonitor != nil }
    var isHoveringForTest: Bool { hovering }
    var peekQueueCount: Int { peekQueue.count }
    var watchdogRunning: Bool { leaveWatchdog != nil }
    var expectedHotRectInWindow: CGRect { hotScreenRect.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY) }
    func debugMouseEntered() { mouseEntered() }
    func debugMouseExited() { mouseExited() }
    /// Runs exactly what the global click monitor runs.
    func debugClickOutside() { clickedOutside() }
    func debugScreensChanged() { screensChanged(force: true) }
}
