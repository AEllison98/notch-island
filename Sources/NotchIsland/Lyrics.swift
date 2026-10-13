import CryptoKit
import Foundation

/// One timed line of synced lyrics.
struct LyricLine: Equatable {
    var time: TimeInterval
    var text: String
}

enum Lyrics: Equatable {
    /// Being looked up; the row stays (blank) so the island does not shrink and grow again.
    case loading
    case synced([LyricLine])
    case instrumental
    /// LRCLIB has none for this track (or only unsynced text, which cannot follow the song).
    case notFound
}

// MARK: - LRC

enum LRC {
    /// Parses "[mm:ss.xx] text" lines. A line may carry several timestamps; tags like [ar:...]
    /// and lines without a timestamp are skipped.
    static func parse(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw).drop { $0 == "\u{FEFF}" }
            var times: [TimeInterval] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let t = timestamp(tag) { times.append(t) }
                rest = rest[rest.index(after: close)...]
            }
            let words = rest.trimmingCharacters(in: .whitespaces)
            for t in times { lines.append(LyricLine(time: t, text: words)) }
        }
        return lines.sorted { $0.time < $1.time }
    }

    /// "mm:ss", "mm:ss.xx", "mm:ss.xxx" or "mm:ss:xx"; nil for anything else (metadata tags).
    static func timestamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, let minutes = Double(parts[0]), let seconds = Double(parts[1]),
              minutes >= 0, seconds >= 0, seconds < 60 else { return nil }
        var total = minutes * 60 + seconds
        if parts.count == 3 {
            guard !parts[2].isEmpty, let hundredths = Double(parts[2]), hundredths >= 0 else { return nil }
            total += hundredths / pow(10, Double(parts[2].count))
        }
        return total
    }

    /// The line being sung at `position`, and the one after it. Before the first line there is
    /// no current line; a blank line in the file is a pause and shows as nothing.
    static func lines(at position: TimeInterval, in lines: [LyricLine]) -> (current: String?, next: String?) {
        guard let index = lines.lastIndex(where: { $0.time <= position + 0.15 }) else {
            return (nil, lines.first?.text)
        }
        let current = lines[index].text
        let next = lines[(index + 1)...].first { !$0.text.isEmpty }?.text
        return (current.isEmpty ? nil : current, next)
    }
}

// MARK: - LRCLIB, with a cache on disk

/// Synced lyrics from lrclib.net (free, no key). Sends artist, title, album and duration, and
/// nothing else. Every answer, including "none", is cached in ~/Library/Caches, so a song is
/// asked about once.
actor LyricsService {
    struct Track: Hashable {
        var title: String
        var artist: String
        var album: String
        /// Seconds.
        var duration: TimeInterval
    }

    private let cacheDirectory: URL
    /// "None" answers are asked again after this long: lyrics get added to LRCLIB over time.
    static let retryNoneAfter: TimeInterval = 7 * 24 * 3600

    init(cacheDirectory: URL? = nil) {
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.NotchIsland/lyrics", isDirectory: true)
    }

    func lyrics(for track: Track) async -> Lyrics {
        // LRCLIB refuses these (ads, radio streams, live inputs), so do not even ask.
        guard (1...3600).contains(track.duration),
              !track.title.trimmingCharacters(in: .whitespaces).isEmpty,
              !track.artist.trimmingCharacters(in: .whitespaces).isEmpty else { return .notFound }
        if let cached = readCache(track) { return cached }
        let found = await fetch(track)
        if let found { writeCache(track, found) }
        return found ?? .notFound
    }

    // MARK: Network

    static func getURL(_ t: Track) -> URL? {
        var c = URLComponents(string: "https://lrclib.net/api/get")
        c?.queryItems = [.init(name: "track_name", value: t.title), .init(name: "artist_name", value: t.artist),
                         .init(name: "album_name", value: t.album),
                         .init(name: "duration", value: String(Int(t.duration.rounded())))]
        return c?.url
    }

    static func searchURL(_ t: Track) -> URL? {
        var c = URLComponents(string: "https://lrclib.net/api/search")
        c?.queryItems = [.init(name: "track_name", value: t.title), .init(name: "artist_name", value: t.artist)]
        return c?.url
    }

    struct Record: Decodable {
        let duration: Double?
        let instrumental: Bool?
        let syncedLyrics: String?
    }

    static func lyrics(from record: Record) -> Lyrics {
        if record.instrumental == true { return .instrumental }
        if let synced = record.syncedLyrics, !synced.isEmpty {
            let lines = LRC.parse(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        return .notFound
    }

    /// nil means "could not find out" (offline, server busy): not cached, asked again later.
    private func fetch(_ track: Track) async -> Lyrics? {
        guard track.duration > 0, let url = Self.getURL(track) else { return nil }
        do {
            let data = try await getWithOneRetry(url)
            let found = Self.lyrics(from: try JSONDecoder().decode(Record.self, from: data))
            if found != .notFound { return found }
        } catch Net.Failure.status(404, _) {
            // Not under that exact album and duration; try a looser search below.
        } catch {
            return nil
        }
        // The search matches title and artist only, so check the length is the same song (LRCLIB
        // itself matches durations within 2 seconds).
        guard let url = Self.searchURL(track), let data = try? await getWithOneRetry(url),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return nil }
        let sameSong = records.filter { abs(($0.duration ?? -100) - track.duration) <= 2 }
        return sameSong.lazy.map(Self.lyrics(from:)).first { $0 != .notFound } ?? .notFound
    }

    /// LRCLIB answers a never-seen song with 503 "busy, retry" before it answers properly.
    private func getWithOneRetry(_ url: URL) async throws -> Data {
        do {
            return try await Net.shared.get(url)
        } catch Net.Failure.status(503, let retryAfter) {
            try await Task.sleep(for: .seconds(min(max(retryAfter ?? 1, 1), 5)))
            return try await Net.shared.get(url)
        }
    }

    // MARK: Cache

    static func cacheKey(_ t: Track) -> String {
        let id = [t.artist, t.title, t.album, String(Int(t.duration.rounded()))]
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private struct Entry: Codable {
        var kind: String          // "synced", "instrumental", "none"
        var lines: [[String]]?    // [time, text]
        var savedAt: Date
    }

    private func file(_ t: Track) -> URL { cacheDirectory.appendingPathComponent(Self.cacheKey(t) + ".json") }

    private func readCache(_ t: Track) -> Lyrics? {
        guard let data = try? Data(contentsOf: file(t)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        switch entry.kind {
        case "synced":
            let lines = (entry.lines ?? []).compactMap { pair -> LyricLine? in
                guard pair.count == 2, let time = Double(pair[0]) else { return nil }
                return LyricLine(time: time, text: pair[1])
            }
            return lines.isEmpty ? nil : .synced(lines)
        case "instrumental":
            return .instrumental
        default:
            return -entry.savedAt.timeIntervalSinceNow < Self.retryNoneAfter ? Lyrics.notFound : nil
        }
    }

    private func writeCache(_ t: Track, _ lyrics: Lyrics) {
        let entry: Entry
        switch lyrics {
        case .synced(let lines): entry = Entry(kind: "synced", lines: lines.map { [String($0.time), $0.text] }, savedAt: Date())
        case .instrumental: entry = Entry(kind: "instrumental", lines: nil, savedAt: Date())
        case .notFound, .loading: entry = Entry(kind: "none", lines: nil, savedAt: Date())
        }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entry) { try? data.write(to: file(t), options: .atomic) }
    }
}
