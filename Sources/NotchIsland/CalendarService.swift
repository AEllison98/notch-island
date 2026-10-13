import AppKit
import EventKit
import SwiftUI

struct CalendarEvent: Equatable {
    var title: String
    var start: Date
    var end: Date
    var calendarColor: Color?
}

enum CalendarState: Equatable {
    /// Not asked yet: the tile offers a button, and only that button asks.
    case notConnected
    /// Refused, or only "add events" access: the tile says where to change it.
    case noAccess
    /// Upcoming events; the tile picks which one to show each time it redraws, so an event
    /// that has just ended gives way at once.
    case ready(events: [CalendarEvent])
}

/// Your next event, read on this Mac with EventKit. Nothing about your calendars leaves it.
@MainActor
final class CalendarService {
    /// How far ahead "next event" looks.
    static let horizon: TimeInterval = 7 * 24 * 3600

    private let model: IslandModel
    private let store = EKEventStore()
    private var timer: Timer?

    init(model: IslandModel) {
        self.model = model
        model.onConnectCalendar = { [weak self] in self?.connect() }
        // The self-test never reads your calendars.
        guard !Diag.selfTest else { return }
        let center = NotificationCenter.default
        center.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
        // Often enough that an event that just ended gives way to the next one.
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        reload()
    }

    /// Reading the status never prompts; only connect() can.
    func reload() {
        guard !Diag.selfTest else { return }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            model.calendar = .notConnected
        case .fullAccess:
            model.calendar = .ready(events: upcoming())
        default:
            model.calendar = .noAccess
        }
    }

    /// Asks macOS for Calendar access. Only called from the tile's Connect button.
    func connect() {
        // The self-test never asks for your calendars.
        guard !Diag.selfTest else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.store.requestFullAccessToEvents()
            self.reload()
        }
    }

    private func upcoming() -> [CalendarEvent] {
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600),
                                                 end: now.addingTimeInterval(Self.horizon), calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled && !Self.declined($0) }
            .map { CalendarEvent(title: $0.title ?? "Untitled", start: $0.startDate, end: $0.endDate,
                                 calendarColor: $0.calendar.map { Color(nsColor: $0.color) }) }
    }

    /// Meetings you said no to are not your next event.
    static func declined(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }

    /// The event happening now, or else the next one to start. All-day events are left out,
    /// and so is anything running longer than 12 hours while there is something shorter: either
    /// would sit in the tile for days and hide the meeting that is about to begin.
    static func next(from events: [CalendarEvent], now: Date) -> CalendarEvent? {
        let upcoming = events.filter { $0.end > now }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        return upcoming.first { $0.end.timeIntervalSince($0.start) <= 12 * 3600 } ?? upcoming.first
    }

    /// "15:00 – 15:30", or "Now until 15:30" while it is on, in this Mac's time format; with the
    /// day added to any time that is not today.
    static func timeText(for event: CalendarEvent, now: Date) -> String {
        func time(_ d: Date) -> String {
            let t = d.formatted(date: .omitted, time: .shortened)
            return Calendar.current.isDate(d, inSameDayAs: now) ? t : "\(d.formatted(.dateTime.weekday(.abbreviated))) \(t)"
        }
        if event.start <= now { return "Now until \(time(event.end))" }
        let end = Calendar.current.isDate(event.end, inSameDayAs: event.start)
            ? event.end.formatted(date: .omitted, time: .shortened) : time(event.end)
        return "\(event.start.formatted(date: .omitted, time: .shortened)) – \(end)"
    }
}
