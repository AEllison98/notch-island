import AppKit
import CoreServices

// MARK: - Players

enum Player: String, CaseIterable {
    case music = "com.apple.Music"
    case spotify = "com.spotify.client"

    var name: String { self == .music ? "Music" : "Spotify" }

    /// Never launches anything: only asks what is already running (and not on its way out).
    var isRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).contains { !$0.isTerminated }
    }

    /// The app's own icon, from disk. Stands in for Spotify's cover, which only exists as a
    /// link on Spotify's image server (fetching it would send your listening to a third host).
    /// Loaded once: a new image every time would look like a change to the pill on every poll.
    @MainActor var icon: NSImage? {
        if let cached = Self.icons[self] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue).map { NSWorkspace.shared.icon(forFile: $0.path) }
        Self.icons[self] = icon
        return icon
    }
    @MainActor private static var icons: [Player: NSImage] = [:]

    /// Music reports seconds; Spotify milliseconds (whatever its dictionary says).
    func seconds(fromDuration value: Double) -> TimeInterval { self == .spotify ? value / 1000 : value }

    /// Each player announces track and play/pause changes, so there is no need to poll for them.
    var changeNotification: Notification.Name {
        Notification.Name(self == .music ? "com.apple.Music.playerInfo" : "com.spotify.client.PlaybackStateChanged")
    }
}

struct NowPlaying: Equatable {
    var player: Player
    var title: String
    var artist: String
    var album: String
    /// Seconds.
    var duration: TimeInterval
    var position: TimeInterval
    var positionAt: Date
    var isPlaying: Bool
    var trackID: String
    var artwork: NSImage?

    /// Where the song is now, counted forward from the last reading while it plays.
    func position(at date: Date) -> TimeInterval {
        guard isPlaying else { return position }
        return min(duration, position + max(0, date.timeIntervalSince(positionAt)))
    }
}

enum MusicState: Equatable {
    /// No player open, or nothing loaded in it.
    case idle
    /// A player is open, but Notch Island has not been allowed to talk to it yet.
    case needsConsent(Player)
    /// You said no; the tile says where to change it.
    case denied(Player)
    case nowPlaying(NowPlaying)
}

enum MusicCommand { case playPause, next, previous }

// MARK: - AppleScript

/// Every script starts with "if application id ... is running": a plain "tell application"
/// would launch a closed player just to ask what it is playing.
enum PlayerScripts {
    static func state(_ p: Player) -> String {
        let id = p == .music ? "persistent ID of t" : "id of t"
        return """
        if application id "\(p.rawValue)" is running then
            tell application id "\(p.rawValue)"
                with timeout of 2 seconds
                    set s to player state as text
                    if s is "stopped" then return {"stopped"}
                    try
                        set t to current track
                        return {s, name of t, artist of t, album of t, duration of t, player position, \(id)}
                    on error
                        return {"stopped"}
                    end try
                end timeout
            end tell
        end if
        return {"closed"}
        """
    }

    static func artwork(_ p: Player) -> String? {
        guard p == .music else { return nil }
        return """
        if application id "\(p.rawValue)" is running then
            tell application id "\(p.rawValue)"
                with timeout of 3 seconds
                    try
                        if (count of artworks of current track) > 0 then return raw data of artwork 1 of current track
                    end try
                end timeout
            end tell
        end if
        return ""
        """
    }

    static func command(_ c: MusicCommand, _ p: Player) -> String {
        let verb = switch c {
        case .playPause: "playpause"
        case .next: "next track"
        case .previous: "previous track"
        }
        return """
        if application id "\(p.rawValue)" is running then
            tell application id "\(p.rawValue)"
                with timeout of 2 seconds
                    \(verb)
                end timeout
            end tell
        end if
        """
    }
}

/// All AppleScript runs on this one thread. NSAppleScript must not be used from two threads
/// at once, and on the main thread a frozen player would freeze the island with it (every
/// script also gives up after 2 or 3 seconds).
final class ScriptThread: NSObject, @unchecked Sendable {
    static let shared = ScriptThread()

    private var thread: Thread?
    /// Touched only on `thread`.
    private var compiled: [String: NSAppleScript] = [:]

    private final class Job: NSObject {
        let source: String
        let done: (NSAppleEventDescriptor?, Int?) -> Void
        init(_ source: String, _ done: @escaping (NSAppleEventDescriptor?, Int?) -> Void) {
            self.source = source
            self.done = done
        }
    }

    override init() {
        super.init()
        let started = DispatchSemaphore(value: 0)
        let t = Thread {
            RunLoop.current.add(NSMachPort(), forMode: .default)
            started.signal()
            while true { RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
        t.name = "NotchIsland.AppleScript"
        t.qualityOfService = .userInitiated
        t.start()
        started.wait()
        thread = t
    }

    /// The result (or the AppleScript error number) comes back on the main thread.
    func run(_ source: String) async -> (NSAppleEventDescriptor?, Int?) {
        await withCheckedContinuation { continuation in
            let job = Job(source) { result, error in continuation.resume(returning: (result, error)) }
            perform(#selector(execute(_:)), on: thread!, with: job, waitUntilDone: false)
        }
    }

    @objc private func execute(_ job: Job) {
        let script = compiled[job.source] ?? {
            let s = NSAppleScript(source: job.source)
            compiled[job.source] = s
            return s
        }()
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        let code = error?[NSAppleScript.errorNumber] as? Int
        DispatchQueue.main.async { job.done(code == nil && error == nil ? result : nil, code) }
    }
}

/// Whether macOS lets this app send Apple Events to a player, asking only when `ask` is true.
enum Automation {
    enum Consent { case allowed, notAsked, denied, notRunning }

    /// With ask: true this shows the system prompt and waits for the answer: never call it on
    /// the main thread with ask: true.
    nonisolated static func consent(_ p: Player, ask: Bool) -> Consent {
        let target = NSAppleEventDescriptor(bundleIdentifier: p.rawValue)
        guard let desc = target.aeDesc else { return .notRunning }
        switch AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask) {
        case noErr: return .allowed
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .notRunning
        }
    }
}

// MARK: - Keeping the tile current

@MainActor
final class MusicService {
    private let model: IslandModel
    private weak var island: IslandController?
    private let lyricsService = LyricsService()
    /// The player whose change notification came last: the one you are using.
    private var lastActive: Player?
    /// Players that just announced "Stopped". Sent when playback stops, but also as a player
    /// quits; asking a quitting player anything can relaunch it, so it is left alone briefly.
    private var stopping: Set<Player> = []
    /// The track the shown lyrics (or the lookup in flight) belong to.
    private var lyricsTrack: String?
    private var artworkAttempts: [String: Int] = [:]
    private var poll: Timer?
    private var lastRead = Date.distantPast
    private var refreshing = false
    private var refreshAgain = false
    private var pending: DispatchWorkItem?

    /// Counted so the self-test can prove it never talked to a player.
    private(set) static var scriptsRun = 0

    init(model: IslandModel, island: IslandController) {
        self.model = model
        self.island = island
        model.onMusicCommand = { [weak self] in self?.send($0) }
        model.onConnectPlayer = { [weak self] in self?.connect($0) }
        // The self-test never talks to your players: no prompts, nothing launched.
        guard !Diag.selfTest else { return }

        let distributed = DistributedNotificationCenter.default()
        for player in Player.allCases {
            distributed.addObserver(forName: player.changeNotification, object: nil, queue: .main) { [weak self] note in
                let state = note.userInfo?["Player State"] as? String
                MainActor.assumeIsolated { self?.changed(player, state: state) }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let id = app?.bundleIdentifier, let player = Player(rawValue: id) else { return }
                MainActor.assumeIsolated {
                    if name == NSWorkspace.didTerminateApplicationNotification { self?.stopping.remove(player) }
                    self?.refresh()
                }
            }
        }
        // Position is only needed while you can see it: the open island, music playing.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        poll = t
        refresh()
    }

    private func changed(_ player: Player, state: String?) {
        lastActive = player
        if state == "Stopped" {
            stopping.insert(player)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.stopping.remove(player)
                self?.refresh()
            }
        }
        // Players often send several notifications for one change.
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func tick() {
        guard model.mode == .expanded, case .nowPlaying(let now) = model.music, now.isPlaying else { return }
        if -lastRead.timeIntervalSinceNow >= 2 { refresh() }
    }

    /// The tiles changed: lyrics are only looked up while the Music tile is shown.
    func tilesChanged() {
        if model.tiles.contains(.music), lyricsTrack == nil, case .nowPlaying = model.music { apply(model.music) }
        if !model.tiles.contains(.music) { lyricsTrack = nil }
    }

    func refresh() {
        guard !Diag.selfTest else { return }
        if refreshing { refreshAgain = true; return }
        refreshing = true
        Task { [weak self] in
            guard let self else { return }
            await self.performRefresh()
            self.refreshing = false
            if self.refreshAgain {
                self.refreshAgain = false
                self.refresh()
            }
        }
    }

    private func performRefresh() async {
        lastRead = Date()
        let running = Player.allCases.filter { $0.isRunning && !stopping.contains($0) }
        var waitingForConsent: Player?
        var refused: Player?
        var readings: [NowPlaying] = []
        for player in running {
            switch Automation.consent(player, ask: false) {
            case .allowed:
                if let reading = await read(player) { readings.append(reading) }
            case .notAsked: waitingForConsent = waitingForConsent ?? player
            case .denied: refused = refused ?? player
            case .notRunning: break
            }
        }

        let playing = readings.first { $0.isPlaying }
        let state: MusicState
        if let playing {
            state = .nowPlaying(await withArtwork(playing))
        } else if let player = waitingForConsent, lastActive == player || readings.isEmpty {
            // The player you just used has not been allowed yet: offer Connect rather than
            // showing another player's paused song.
            state = .needsConsent(player)
        } else if let paused = readings.first(where: { $0.player == lastActive }) ?? readings.first {
            state = .nowPlaying(await withArtwork(paused))
        } else if let player = waitingForConsent {
            state = .needsConsent(player)
        } else if let player = refused {
            state = .denied(player)
        } else {
            state = .idle
        }
        apply(state)
    }

    /// Keeps the cover across refreshes of the same track; asks again (a few times) when there
    /// was none, because Music often has not loaded it yet when a track starts.
    private func withArtwork(_ reading: NowPlaying) async -> NowPlaying {
        var now = reading
        let key = "\(now.player.rawValue)|\(now.trackID)"
        if case .nowPlaying(let old) = model.music, old.player == now.player, old.trackID == now.trackID, let art = old.artwork {
            now.artwork = art
            return now
        }
        let tries = artworkAttempts[key, default: 0]
        guard tries < 3, let source = PlayerScripts.artwork(now.player), now.player.isRunning else { return now }
        artworkAttempts[key] = tries + 1
        Self.scriptsRun += 1
        let (result, _) = await ScriptThread.shared.run(source)
        if let data = result?.data, !data.isEmpty { now.artwork = NSImage(data: data) }
        return now
    }

    private func apply(_ state: MusicState) {
        guard let island else { return }
        let key: String? = { if case .nowPlaying(let n) = state { "\(n.player.rawValue)|\(n.trackID)" } else { nil } }()
        let musicShown = model.tiles.contains(.music)
        if musicShown, let key, key != lyricsTrack, case .nowPlaying(let now) = state {
            lyricsTrack = key
            // Keep the row (blank) while the new song's lyrics load, rather than shrinking the
            // island and growing it again a moment later.
            island.setMusic(state, lyrics: model.showsLyricsRow ? .loading : nil)
            loadLyrics(now, key: key)
        } else if key == nil || !musicShown {
            lyricsTrack = nil
            island.setMusic(state, lyrics: nil)
        } else {
            island.setMusic(state, lyrics: model.lyrics)
        }
        // The pill shows while something plays and nothing more important wants it.
        if case .nowPlaying(let now) = state, now.isPlaying {
            let cover: IslandIcon = now.artwork.map { .image($0) } ?? now.player.icon.map { .image($0) } ?? .symbol("music.note")
            island.setActivity(CompactActivity(leading: cover, trailing: .waveform), from: .music)
        } else {
            island.setActivity(nil, from: .music)
        }
    }

    private func loadLyrics(_ now: NowPlaying, key: String) {
        let track = LyricsService.Track(title: now.title, artist: now.artist, album: now.album, duration: now.duration)
        Task { [weak self, lyricsService] in
            let found = await lyricsService.lyrics(for: track)
            guard let self, self.lyricsTrack == key else { return }
            self.island?.setMusic(self.model.music, lyrics: found)
        }
    }

    // MARK: Apple Events

    private func read(_ player: Player) async -> NowPlaying? {
        guard player.isRunning else { return nil }
        Self.scriptsRun += 1
        let (result, _) = await ScriptThread.shared.run(PlayerScripts.state(player))
        guard let r = result, r.numberOfItems >= 7,
              let state = r.atIndex(1)?.stringValue, state == "playing" || state == "paused" else { return nil }
        func text(_ i: Int) -> String { r.atIndex(i)?.stringValue ?? "" }
        func number(_ i: Int) -> Double { Double(r.atIndex(i)?.stringValue ?? "") ?? r.atIndex(i)?.doubleValue ?? 0 }
        return NowPlaying(player: player, title: text(2), artist: text(3), album: text(4),
                          duration: player.seconds(fromDuration: number(5)), position: number(6),
                          positionAt: Date(), isPlaying: state == "playing", trackID: text(7), artwork: nil)
    }

    private func send(_ command: MusicCommand) {
        guard case .nowPlaying(let now) = model.music, now.player.isRunning, !stopping.contains(now.player) else { return }
        Self.scriptsRun += 1
        Task { [weak self] in
            _ = await ScriptThread.shared.run(PlayerScripts.command(command, now.player))
            try? await Task.sleep(for: .seconds(0.3))
            self?.refresh()
        }
    }

    /// The Connect button: macOS shows its Automation prompt for this one player.
    private func connect(_ player: Player) {
        guard player.isRunning else { refresh(); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = Automation.consent(player, ask: true)
            DispatchQueue.main.async { self?.refresh() }
        }
    }
}
