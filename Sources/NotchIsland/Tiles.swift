import SwiftUI

// MARK: - Tiles

enum TileKind: String, CaseIterable, Identifiable {
    case music, weather, calendar, timer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .music: "Music"
        case .weather: "Weather"
        case .calendar: "Calendar"
        case .timer: "Focus Timer"
        }
    }

    /// The timer is narrow, as in the mockup, but wide enough for Reset beside Start/Pause.
    var width: CGFloat { self == .timer ? 104 : 204 }
}

enum TileStyle {
    static let radius: CGFloat = 16
    static let inset: CGFloat = 12
    /// Where the first line of text sits in every tile, so the four tiles read as one row.
    static let firstLine: CGFloat = 14
}

/// The open island's row of tiles. Drag a tile sideways to move it; the new order is saved.
struct TilesRow: View {
    let model: IslandModel

    @State private var dragging: TileKind?
    @State private var dragX: CGFloat = 0
    @State private var grab: CGFloat = 0

    private var rowWidth: CGFloat { IslandLayout.rowWidth(model.tiles) }

    private func layoutX(_ kind: TileKind) -> CGFloat {
        var x: CGFloat = 0
        for k in model.tiles {
            if k == kind { return x }
            x += k.width + IslandLayout.tileGap
        }
        return x
    }

    var body: some View {
        if model.tiles.isEmpty {
            Text("All tiles are hidden. Turn them on from the menu bar.")
                .font(.system(size: 12))
                .foregroundStyle(model.palette.secondary)
                .frame(height: IslandLayout.tileHeight)
        } else {
            ZStack(alignment: .topLeading) {
                ForEach(model.tiles) { kind in
                    let isDragged = dragging == kind
                    TileView(kind: kind, model: model)
                        .frame(width: kind.width, height: IslandLayout.tileHeight)
                        .background(model.palette.tile, in: RoundedRectangle(cornerRadius: TileStyle.radius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: TileStyle.radius, style: .continuous).strokeBorder(model.palette.tileEdge))
                        // Inside the offset, so it reports where the tile is drawn, not where
                        // the stack would have put it.
                        .reportFrame("tile.\(kind.rawValue)", to: model)
                        .scaleEffect(isDragged ? 1.04 : 1)
                        .offset(x: isDragged ? dragX : layoutX(kind))
                        .animation(isDragged ? nil : .spring(response: 0.3, dampingFraction: 0.82), value: layoutX(kind))
                        .zIndex(isDragged ? 1 : 0)
                        .gesture(reorder(kind))
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(kind.title)
                }
            }
            .frame(width: rowWidth, height: IslandLayout.tileHeight, alignment: .topLeading)
            .coordinateSpace(name: "tiles")
            .onDisappear {
                // The island closed mid-drag, so no drop will come: keep what is shown and saved
                // the same.
                if dragging != nil {
                    dragging = nil
                    model.onReorder(model.tiles)
                }
            }
        }
    }

    private func reorder(_ kind: TileKind) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("tiles"))
            .onChanged { value in
                if dragging == nil {
                    grab = value.startLocation.x - layoutX(kind)
                    dragging = kind
                    model.onDragBegan()
                }
                dragX = min(max(value.location.x - grab, -8), rowWidth - kind.width + 8)

                // Swap with a neighbour once the dragged tile is past halfway between the slot
                // it has and the slot it would take. Measuring from the neighbour's centre
                // instead fails when a wide tile meets the narrow timer at the end of the row.
                var order = model.tiles
                guard let i = order.firstIndex(of: kind) else { return }
                let here = layoutX(kind)
                let hysteresis: CGFloat = 4
                if i + 1 < order.count {
                    let next = order[i + 1]
                    if dragX > here + (next.width + IslandLayout.tileGap) / 2 + hysteresis { order.swapAt(i, i + 1) }
                }
                if order == model.tiles, i > 0 {
                    let previous = order[i - 1]
                    if dragX < (here + layoutX(previous)) / 2 - hysteresis { order.swapAt(i, i - 1) }
                }
                if order != model.tiles { model.tiles = order }
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { dragging = nil }
                model.onReorder(model.tiles)
            }
    }
}

private struct TileView: View {
    let kind: TileKind
    let model: IslandModel

    var body: some View {
        switch kind {
        case .music: MusicTile(palette: model.palette, model: model)
        case .weather: WeatherTile(palette: model.palette, state: model.weather)
        case .calendar: CalendarTile(palette: model.palette, state: model.calendar, model: model)
        case .timer: TimerTile(palette: model.palette, timer: model.focusTimer, model: model)
        }
    }
}

// MARK: - Music

private struct MusicTile: View {
    let palette: Palette
    let model: IslandModel

    var body: some View {
        let now: NowPlaying? = { if case .nowPlaying(let n) = model.music { n } else { nil } }()
        HStack(alignment: .center, spacing: 12) {
            cover(now)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(now))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Text(subtitle(now))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary)
                    .lineLimit(now == nil ? 2 : 1)
                Spacer(minLength: 0)
                switch model.music {
                case .needsConsent(let player):
                    Button { model.onConnectPlayer(player) } label: {
                        Text("Connect \(player.name)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.text)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(palette.control, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .reportFrame("music.connect", to: model)
                default:
                    if let now { ProgressLine(now: now, palette: palette).padding(.bottom, 6) }
                    controls(now)
                }
            }
            .padding(.top, TileStyle.firstLine - TileStyle.inset)
        }
        .padding(TileStyle.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func title(_ now: NowPlaying?) -> String {
        switch model.music {
        case .nowPlaying(let n): n.title
        case .needsConsent(let p): "\(p.name) is open"
        case .denied(let p): "No access to \(p.name)"
        case .idle: "Not playing"
        }
    }

    private func subtitle(_ now: NowPlaying?) -> String {
        switch model.music {
        case .nowPlaying(let n): n.artist
        case .needsConsent: "Allow it to show what's playing"
        case .denied: "Allow it in System Settings, Automation"
        case .idle: "Open Music or Spotify"
        }
    }

    @ViewBuilder private func cover(_ now: NowPlaying?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if let art = now?.artwork {
            Image(nsImage: art).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                .frame(width: 68, height: 68).clipShape(shape)
        } else {
            shape.fill(palette.control).frame(width: 68, height: 68).overlay {
                if let icon = now?.player.icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 40, height: 40)
                } else {
                    Image(systemName: "music.note").font(.system(size: 24, weight: .medium)).foregroundStyle(palette.secondary)
                }
            }
        }
    }

    /// Flush with the title on the left and the tile's padding on the right.
    private func controls(_ now: NowPlaying?) -> some View {
        HStack(spacing: 0) {
            control("backward.fill", "Previous", .previous)
            Spacer(minLength: 0)
            control(now?.isPlaying == true ? "pause.fill" : "play.fill", now?.isPlaying == true ? "Pause" : "Play", .playPause)
                .reportFrame("music.playPause", to: model)
            Spacer(minLength: 0)
            control("forward.fill", "Next", .next)
        }
        .padding(.bottom, 3)
        .disabled(now == nil)
        .opacity(now == nil ? 0.3 : 1)
    }

    private func control(_ symbol: String, _ label: String, _ command: MusicCommand) -> some View {
        Button { model.onMusicCommand(command) } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.text)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// How far into the song: a thin bar, counted forward between readings while it plays.
private struct ProgressLine: View {
    let now: NowPlaying
    let palette: Palette

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let fraction = now.duration > 0 ? min(1, now.position(at: context.date) / now.duration) : 0
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.secondary.opacity(0.25))
                    Capsule().fill(palette.text).frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 3)
        }
        .accessibilityLabel("Progress")
    }
}

/// The current line of the lyrics and the next one, under the tiles, following the song.
struct LyricsRow: View {
    let model: IslandModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let (current, next) = lines(at: context.date)
            VStack(spacing: 3) {
                Text(current ?? " ")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(model.palette.text)
                    .id(current ?? "")
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                Text(next ?? " ")
                    .font(.system(size: 13))
                    .foregroundStyle(model.palette.secondary)
            }
            .lineLimit(1)
            .padding(.horizontal, IslandLayout.bodyInset)
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.25), value: current)
            .reportFrame("lyrics", to: model)
        }
    }

    private func lines(at date: Date) -> (String?, String?) {
        guard case .nowPlaying(let now) = model.music else { return (nil, nil) }
        switch model.lyrics {
        case .synced(let lines)?: return LRC.lines(at: now.position(at: date), in: lines)
        case .instrumental?: return ("♪ Instrumental", nil)
        default: return (nil, nil)   // .loading: blank until the new song's lyrics arrive
        }
    }
}

// MARK: - Weather

private struct WeatherTile: View {
    let palette: Palette
    let state: WeatherState

    var body: some View {
        let reading: WeatherReading? = { if case .ready(let r) = state { r } else { nil } }()
        let condition = reading.map { WeatherCondition.from(code: $0.code, isDay: $0.isDay) }

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(reading.map { "\(Int($0.temperature.rounded()))°" } ?? "--°")
                    .font(.system(size: 35, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(palette.text)
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
                Image(systemName: condition?.symbol ?? "cloud.sun.fill")
                    .font(.system(size: 24))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(condition?.primary ?? (reading == nil ? palette.secondary : palette.text),
                                     condition?.secondary ?? palette.text)
                    .opacity(reading == nil ? 0.5 : 1)
                    .padding(.top, 2)
                    .accessibilityLabel(condition?.label ?? "No weather")
            }
            Text(place)
                .font(.system(size: 13))
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
                .padding(.top, 2)
            Spacer(minLength: 0)
            Text(footer(reading))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(TileStyle.inset)
        .padding(.top, TileStyle.firstLine - TileStyle.inset - 6)   // the big numerals' own top space
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var place: String {
        switch state {
        case .needsSetup: "No location"
        case .loading(let place), .failed(let place, _): place
        case .ready(let r): r.place
        }
    }

    private func footer(_ reading: WeatherReading?) -> String {
        switch state {
        case .needsSetup: "Choose one in the menu bar"
        case .loading: "Updating…"
        case .failed(_, let message): message
        case .ready(let r): "H \(Int(r.high.rounded()))°  L \(Int(r.low.rounded()))°"
        }
    }
}

// MARK: - Calendar

private struct CalendarTile: View {
    let palette: Palette
    let state: CalendarState
    let model: IslandModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let event: CalendarEvent? = {
                if case .ready(let events) = state { CalendarService.next(from: events, now: context.date) } else { nil }
            }()
            // The date column shows the event's day, or today when there is no event.
            let day = event.map { max($0.start, context.date) } ?? context.date
            HStack(alignment: .top, spacing: 8) {
                // A fixed column, so the title starts at the same place whatever the date.
                VStack(alignment: .leading, spacing: 0) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.secondary)
                    Text(day.formatted(.dateTime.day()))
                        .font(.system(size: 34, weight: .light))
                        .monospacedDigit()
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(width: 40, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    switch (state, event) {
                    case (.ready, let next?):
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            if let color = next.calendarColor {
                                Circle().fill(color).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
                            }
                            Text(next.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(palette.text)
                                .lineLimit(2)
                        }
                        Text(CalendarService.timeText(for: next, now: context.date))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(palette.secondary)
                            .lineLimit(1)
                    case (.ready, nil):
                        Text("No events")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.text)
                        Text("Nothing in the next 7 days")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.secondary)
                            .lineLimit(2)
                    case (.notConnected, _):
                        Text("Your next event")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.text)
                        Button(action: model.onConnectCalendar) {
                            Text("Connect Calendar")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(palette.text)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(palette.control, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                        .reportFrame("calendar.connect", to: model)
                    case (.noAccess, _):
                        Text("No calendar access")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.text)
                        Text("Allow it in System Settings, Privacy & Security, Calendars")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.secondary)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(TileStyle.inset)
            .padding(.top, TileStyle.firstLine - TileStyle.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Focus timer

private struct TimerTile: View {
    let palette: Palette
    let timer: FocusTimer
    let model: IslandModel

    var body: some View {
        VStack(spacing: 10) {
            Text(timer.state == .finished ? "Done" : timer.display)
                .font(.system(size: 20, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(palette.text)
            // Start/Pause stays centred and never moves; Reset joins beside it once there is
            // something to reset.
            CapsuleButton(symbol: timer.state == .running ? "pause.fill" : "play.fill",
                          label: timer.state == .running ? "Pause" : "Start", palette: palette) {
                timer.state == .running ? timer.pause() : timer.start()
            }
            .reportFrame("timer.primary", to: model)
            .overlay(alignment: .trailing) {
                if timer.state != .idle {
                    RoundButton(symbol: "arrow.counterclockwise", size: 22, label: "Reset", palette: palette) {
                        timer.reset()
                    }
                    .reportFrame("timer.reset", to: model)
                    .offset(x: 22 + 6)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: timer.state == .idle)
        }
        .padding(.top, TileStyle.firstLine - 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct CapsuleButton: View {
    let symbol: String
    let label: String
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.text)
                .frame(width: 40, height: 28)
                .background(palette.control, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct RoundButton: View {
    let symbol: String
    let size: CGFloat
    let label: String
    let palette: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(palette.text)
                .frame(width: size, height: size)
                .background(palette.control, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 25 minutes, start, pause and reset. Time is measured against the clock, not by counting
/// ticks, so a busy main thread or a sleeping Mac cannot make it drift.
@MainActor
@Observable
final class FocusTimer {
    enum State { case idle, running, paused, finished }

    /// Settable so the self-test can run a session in seconds.
    @ObservationIgnored var length: TimeInterval = 25 * 60
    /// Replaceable so the self-test can pretend the Mac slept through the end.
    @ObservationIgnored var now: () -> Date = { Date() }
    private(set) var state: State = .idle
    private(set) var remaining: TimeInterval = 25 * 60

    @ObservationIgnored var onTick: (FocusTimer) -> Void = { _ in }
    /// Called with nil when the session just ended, or with the time it ended when that was a
    /// while ago (the Mac was asleep), so the message can say so instead of "time for a break".
    @ObservationIgnored var onFinish: (_ endedAt: Date?) -> Void = { _ in }
    @ObservationIgnored private var endsAt: Date?
    @ObservationIgnored private var ticker: Timer?

    var display: String {
        let seconds = Int(remaining.rounded(.up))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func start() {
        if state == .finished || state == .idle { remaining = length }
        endsAt = now().addingTimeInterval(remaining)
        state = .running
        startTicker()
        onTick(self)
    }

    func pause() {
        guard state == .running, let endsAt else { return }
        remaining = max(0, endsAt.timeIntervalSince(now()))
        state = .paused
        stopTicker()
        onTick(self)
    }

    func reset() {
        stopTicker()
        endsAt = nil
        remaining = length
        state = .idle
        onTick(self)
    }

    private func startTicker() {
        stopTicker()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard state == .running, let endsAt else { return }
        let left = max(0, endsAt.timeIntervalSince(now()))
        let shownBefore = display
        remaining = left
        if left == 0 {
            state = .finished
            stopTicker()
            onTick(self)
            let late = now().timeIntervalSince(endsAt)
            onFinish(late > 5 ? endsAt : nil)
        } else if display != shownBefore {
            onTick(self)
        }
    }
}

// MARK: - Layout reporting for the self-test

extension View {
    /// Records where this view was laid out (in the island window, top-left origin), so the
    /// self-test can click it like a person would.
    func reportFrame(_ id: String, to model: IslandModel) -> some View {
        modifier(ReportFrame(id: id, model: model))
    }
}

private struct ReportFrame: ViewModifier {
    let id: String
    let model: IslandModel
    /// This copy of the view. During a transition two copies can be on screen at once, often
    /// at the same place; the one leaving must not erase what the one staying reported.
    @State private var me = UUID()

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        model.appearances[id, default: 0] += 1
                        report(proxy.frame(in: .global))
                    }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in report(frame) }
                    .onDisappear {
                        if model.frameOwners[id] == me {
                            model.frames[id] = nil
                            model.frameOwners[id] = nil
                        }
                    }
            }
        }
    }

    private func report(_ frame: CGRect) {
        model.frameOwners[id] = me
        model.frames[id] = frame
    }
}
