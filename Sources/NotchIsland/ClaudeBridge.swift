import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - What the island shows

/// A permission request from Claude Code, as the island shows it.
struct ClaudeCard: Equatable {
    var id: UUID
    var title: String
    /// The whole command (or the tool's whole input). Never shortened: you cannot allow what
    /// you cannot see.
    var detail: String
    var caption: String?
    var project: String
    var position: Int
    var count: Int
    /// Allow (button and shortcut) works only once the whole of `detail` has been on screen.
    var unlocked: Bool
    /// Too long to show here at all: answer it in the terminal.
    var tooLong: Bool

    /// Longer than this is not shown in the notch (and so cannot be allowed from it).
    static let maxDetail = 200_000
}

/// What Claude is doing right now, for the compact pill.
enum ClaudeStep: Equatable {
    case thinking, reading, searching, editing, running, web, agents, planning, tool, waiting

    init(tool: String) {
        switch tool {
        case "Read", "NotebookRead": self = .reading
        case "Glob", "Grep", "LS", "ToolSearch": self = .searching
        case "Edit", "MultiEdit", "Write", "NotebookEdit": self = .editing
        case "Bash", "BashOutput", "KillShell", "KillBash": self = .running
        case "WebFetch", "WebSearch": self = .web
        case "Task", "Agent": self = .agents
        case "TodoWrite": self = .planning
        default: self = tool.hasPrefix("mcp__") ? .tool : .thinking
        }
    }

    var symbol: String {
        switch self {
        case .thinking: "sparkle"
        case .reading: "doc.text"
        case .searching: "magnifyingglass"
        case .editing: "pencil"
        case .running: "terminal"
        case .web: "globe"
        case .agents: "person.2"
        case .planning: "checklist"
        case .tool: "puzzlepiece.extension"
        case .waiting: "hand.raised.fill"
        }
    }
}

// MARK: - The card

private struct BottomOfRequest: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The permission request in the open island: the whole request in a box you can scroll, Deny
/// and Allow. Allow stays dimmed until the end of the request has been on screen.
struct ClaudeCardView: View {
    let model: IslandModel
    let card: ClaudeCard
    @State private var needsScrolling = false

    private static let boxHeight: CGFloat = 176

    var body: some View {
        let palette = model.palette
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.text)
                    Text([card.project, card.caption].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if card.count > 1 {
                    Text("1 of \(card.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(palette.secondary)
                }
            }

            ScrollView(.vertical) {
                Text(card.tooLong ? "This request is too long to show here. Answer it in the terminal." : card.detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: BottomOfRequest.self,
                                                   value: proxy.frame(in: .named("request")).maxY)
                        }
                    }
            }
            .coordinateSpace(name: "request")
            .frame(height: Self.boxHeight)
            .background(palette.tile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.tileEdge))
            .onPreferenceChange(BottomOfRequest.self) { bottom in
                needsScrolling = bottom > Self.boxHeight + 1 && !card.unlocked
                if bottom <= Self.boxHeight + 1 { model.onClaudeSeenAll(card.id) }
            }
            .reportFrame("claude.request", to: model)

            HStack(spacing: 10) {
                Text(card.tooLong ? "Answer this one in the terminal" : (needsScrolling ? "Scroll to the end to allow" : ""))
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondary)
                Spacer(minLength: 0)
                decision("Deny", shortcut: "⌃⌥⌘N", primary: false, enabled: true) { model.onClaudeDecision(false) }
                    .reportFrame("claude.deny", to: model)
                decision("Allow", shortcut: "⌃⌥⌘Y", primary: true, enabled: card.unlocked) { model.onClaudeDecision(true) }
                    .reportFrame("claude.allow", to: model)
            }
        }
        .padding(.horizontal, IslandLayout.bodyInset)
        .padding(.top, 4)
    }

    private func decision(_ title: String, shortcut: String, primary: Bool, enabled: Bool,
                          action: @escaping () -> Void) -> some View {
        let palette = model.palette
        return Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(shortcut).font(.system(size: 11)).opacity(0.7)
            }
            .foregroundStyle(primary ? palette.background : palette.text)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(primary ? palette.accent : palette.control, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel("\(title), \(shortcut)")
    }
}

// MARK: - The bridge

/// Turns Claude Code hook events into what the island shows, and answers permission requests
/// with your Allow or Deny.
@MainActor
final class ClaudeBridge {
    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NotchIsland")
    }

    static var socketPath: String { supportDirectory.appendingPathComponent("claude.sock").path }

    /// Where Claude Code's settings point: a copy of the hook that stays put wherever the app is
    /// (Downloads, /Applications, ~/Applications), refreshed from the app on every launch.
    static var installedHookPath: String { supportDirectory.appendingPathComponent("notch-island-hook").path }

    /// Copies the bundled hook to `path` if it is missing or different. Returns whether the copy
    /// there now matches the app's.
    @discardableResult
    static func installHook(at path: String) -> Bool {
        guard let bundled = Bundle.main.url(forResource: "notch-island-hook", withExtension: nil),
              let script = try? Data(contentsOf: bundled) else { return false }
        let fm = FileManager.default
        if fm.contents(atPath: path) != script {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let temporary = path + ".new"
            guard fm.createFile(atPath: temporary, contents: script, attributes: [.posixPermissions: 0o755]),
                  rename(temporary, path) == 0 else { return false }
        }
        return fm.contents(atPath: path) == script && fm.isExecutableFile(atPath: path)
    }

    private struct Session {
        var startedAt: Date?
        /// False when the turn's start was not seen (the app started mid-turn): then "Done" leaves
        /// out a time it would only be guessing.
        var startKnown = false
        var project: String
        var step: ClaudeStep
        var lastEvent: Date
    }

    /// Subagents share their parent's session id; each one is its own conversation with you.
    private struct Asker: Hashable {
        var session: String
        var agent: String
    }

    private struct Pending {
        var id: UUID
        var asker: Asker
        var session: String { asker.session }
        var tool: String
        var input: NSDictionary
        var card: ClaudeCard
        var connection: SocketServer.Connection
        var receivedAt: Date
    }

    private let island: IslandController
    private let server: SocketServer
    private let hotkeys = Hotkeys()
    private var sessions: [String: Session] = [:]
    private var queue: [Pending] = []
    private var shownAt: Date?
    private var seenAll = false
    private var ticker: Timer?

    init(island: IslandController, socketPath: String, hookPath: String) {
        self.island = island
        Self.installHook(at: hookPath)
        server = SocketServer(path: socketPath)
        server.onMessage = { [weak self] data, connection in self?.handle(data, connection) }
        do { try server.start() } catch { Diag.log("claude socket failed: \(error)") }

        island.model.onClaudeDecision = { [weak self] allow in self?.decide(allow) }
        island.model.onClaudeSeenAll = { [weak self] id in
            if self?.queue.first?.id == id { self?.seenAll = true }
        }
        hotkeys.onAllow = { [weak self] in self?.decide(true) }
        hotkeys.onDeny = { [weak self] in self?.decide(false) }

        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    // MARK: Events

    private func handle(_ data: Data, _ connection: SocketServer.Connection) {
        guard let event = (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary,
              let name = event["hook_event_name"] as? String else { connection.close(); return }
        let sessionID = event["session_id"] as? String ?? "unknown"
        let asker = Asker(session: sessionID, agent: event["agent_id"] as? String ?? "main")
        let project = (event["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Claude Code"
        let tool = event["tool_name"] as? String ?? ""
        let input = event["tool_input"] as? NSDictionary ?? [:]
        Diag.log("claude \(name) \(tool) session \(sessionID.prefix(8)) agent \(asker.agent.prefix(8))")

        var session = sessions[sessionID] ?? Session(startedAt: nil, project: project, step: .thinking, lastEvent: Date())
        session.lastEvent = Date()
        session.project = project
        func markBusy() {
            if session.startedAt == nil { session.startedAt = Date(); session.startKnown = false }
        }
        func endSession() {
            dismiss { $0.session == sessionID }
            sessions[sessionID] = nil
            updatePill()
            connection.close()
        }

        switch name {
        case "PermissionRequest":
            // Claude Code asks one thing at a time per conversation, so an older card from the
            // same agent has been answered (in the terminal).
            dismiss { $0.asker == asker }
            markBusy()
            let card = Self.card(tool: tool, input: input, project: project)
            enqueue(Pending(id: card.id, asker: asker, tool: tool, input: input, card: card,
                            connection: connection, receivedAt: Date()))
            sessions[sessionID] = session
            return   // the connection stays open until you decide
        case "UserPromptSubmit":
            session.startedAt = Date()
            session.startKnown = true
            session.step = .thinking
            dismiss { $0.session == sessionID }
        case "PreToolUse":
            markBusy()
            session.step = ClaudeStep(tool: tool)
            // The same call's PreToolUse can arrive after its PermissionRequest (both hooks run
            // at once); a different call from the same agent a moment later means the request
            // was answered. Other agents carry on independently.
            dismiss("a later step started") { $0.asker == asker && !($0.tool == tool && $0.input == input)
                && -$0.receivedAt.timeIntervalSinceNow > 1 }
        case "PostToolUse", "PostToolUseFailure":
            // It ran (or tried to), so it was allowed in the terminal.
            dismiss("it ran") { $0.asker == asker && $0.tool == tool && $0.input == input }
        case "SubagentStop":
            dismiss { $0.asker == asker }
        case "Notification":
            let kind = event["notification_type"] as? String ?? ""
            if kind == "idle_prompt" {
                // Waiting for you: nothing is still asking (a "No" in the terminal ends a turn
                // without a Stop), and the session is not busy.
                dismiss { $0.session == sessionID }
                session.startedAt = nil
                island.showPeek(PeekContent(icon: .symbol("bubble.left.fill"), title: "Claude is waiting for you",
                                            subtitle: project, duration: 3))
            } else if kind != "permission_prompt", let message = event["message"] as? String, !message.isEmpty {
                island.showPeek(PeekContent(icon: .symbol("sparkle"), title: message, subtitle: project, duration: 3))
            }
        case "Stop":
            let took = session.startKnown ? session.startedAt.map { Self.duration(Date().timeIntervalSince($0)) } : nil
            island.showPeek(PeekContent(icon: .symbol("checkmark.circle.fill"), title: "Done",
                                        subtitle: [took.map { "in \($0)" }, project].compactMap { $0 }.joined(separator: " · "),
                                        duration: 4))
            endSession()
            return
        case "StopFailure":
            let error = (event["error"] as? String).map { $0.replacingOccurrences(of: "_", with: " ") } ?? "an error"
            island.showPeek(PeekContent(icon: .symbol("exclamationmark.triangle.fill"), title: "Claude stopped: \(error)",
                                        subtitle: project, duration: 4))
            endSession()
            return
        case "SessionEnd":
            endSession()
            return
        default:
            break
        }
        sessions[sessionID] = session
        updatePill()
        connection.close()
    }

    // MARK: Requests

    private func enqueue(_ request: Pending) {
        queue.append(request)
        if queue.count == 1 { showCurrent() } else { refreshCard() }
    }

    private func showCurrent() {
        shownAt = nil
        seenAll = false
        hotkeys.unregister()
        island.setClaudeCard(currentCard())
        updatePill()
    }

    private func currentCard() -> ClaudeCard? {
        guard var card = queue.first?.card else { return nil }
        card.count = queue.count
        return card
    }

    /// Same request, new state (unlocked, or another request queued behind it).
    private func refreshCard() {
        if island.model.claude != nil { island.model.claude = currentCard() }
    }

    /// Allow unlocks once the whole request has been on screen for a moment. Leaving and coming
    /// back starts that over, and the shortcuts only exist while it is unlocked.
    private var lastProbe = Date.distantPast

    private func tick() {
        if -lastProbe.timeIntervalSinceNow >= 2 {
            lastProbe = Date()
            // A hook Claude Code has stopped waiting for (you answered in the terminal) is
            // killed; the probe notices, and its card goes.
            dismiss("the hook is gone") { !$0.connection.isAlive() }
            // A turn interrupted with Esc sends nothing at all. Stop calling a session busy once
            // it has been silent a long while (long commands are silent too, so not too soon).
            let stale = sessions.filter { -$0.value.lastEvent.timeIntervalSinceNow > 10 * 60 }.map(\.key)
            if !stale.isEmpty {
                stale.forEach { sessions[$0] = nil }
                updatePill()
            }
        }
        guard var current = queue.first else { return }
        let visible = island.model.mode == .expanded && island.model.claude?.id == current.id
        if !visible {
            if current.card.unlocked || shownAt != nil {
                current.card.unlocked = false
                queue[0] = current
                shownAt = nil
                seenAll = false
                refreshCard()
                hotkeys.unregister()
            }
            return
        }
        if shownAt == nil { shownAt = Date() }
        let ready = seenAll && !current.card.tooLong && -(shownAt ?? Date()).timeIntervalSinceNow >= 0.6
        if ready != current.card.unlocked {
            current.card.unlocked = ready
            queue[0] = current
            refreshCard()
            if ready { hotkeys.register() } else { hotkeys.unregister() }
        }
        // Claude Code stops waiting for a hook after 10 minutes; give the card up just before.
        if -current.receivedAt.timeIntervalSinceNow > 590 { dismiss("hook time limit") { $0.id == current.id } }
    }

    /// Your answer, from a button or a shortcut, while the card is on screen. Allow needs the card
    /// unlocked (the whole request seen); Deny is always safe.
    func decide(_ allow: Bool) {
        guard let current = queue.first, island.model.mode == .expanded, island.model.claude?.id == current.id,
              current.card.unlocked || !allow else { return }
        current.connection.reply(Self.decisionJSON(allow: allow))
        Diag.log("claude decision \(allow ? "allow" : "deny")")
        queue.removeFirst()
        hotkeys.unregister()
        showCurrent()
    }

    /// Removes requests that no longer need an answer, closing their hook without a reply (so
    /// Claude Code just uses whatever you answered in the terminal).
    private func dismiss(_ why: String = "", where match: (Pending) -> Bool) {
        for request in queue where match(request) { Diag.log("claude dismissed (\(why)): \(request.card.detail.prefix(40))") }
        let wasFirst = queue.first.map(match) ?? false
        for request in queue where match(request) { request.connection.close() }
        queue.removeAll(where: match)
        if wasFirst { showCurrent() } else if !queue.isEmpty { refreshCard() }
    }

    private func updatePill() {
        if !queue.isEmpty {
            island.setActivity(CompactActivity(leading: .symbol(ClaudeStep.waiting.symbol), trailing: .text("Allow?")), from: .claude)
        } else if let busy = sessions.values.filter({ $0.startedAt != nil }).max(by: { $0.lastEvent < $1.lastEvent }) {
            island.setActivity(CompactActivity(leading: .symbol(busy.step.symbol), trailing: .grid), from: .claude)
        } else {
            island.setActivity(nil, from: .claude)
        }
    }

    // MARK: Formatting

    static func decisionJSON(allow: Bool) -> String {
        allow
            ? #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
            : #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Notch Island"}}}"#
    }

    static func card(tool: String, input: NSDictionary, project: String) -> ClaudeCard {
        let title: String
        var caption: String?
        var shown: Set<String> = []
        var body = ""
        func text(_ key: String) -> String {
            shown.insert(key)
            return input[key] as? String ?? ""
        }
        switch tool {
        case "Bash":
            title = "Claude wants to run a command"
            body = text("command")
            caption = input["description"] as? String
            shown.insert("description")
        case "Write":
            title = "Claude wants to write a file"
            body = "\(text("file_path"))\n\n\(text("content"))"
        case "Edit":
            title = "Claude wants to edit a file"
            body = "\(text("file_path"))\n\n" + Self.replacement(text("old_string"), text("new_string"))
        case "MultiEdit":
            title = "Claude wants to edit a file"
            shown.insert("edits")
            let edits = (input["edits"] as? [NSDictionary] ?? []).map {
                Self.replacement($0["old_string"] as? String ?? "", $0["new_string"] as? String ?? "")
                    + (($0["replace_all"] as? Bool) == true ? "\n(every occurrence)" : "")
            }
            body = "\(text("file_path"))\n\n" + edits.joined(separator: "\n\n")
        case "WebFetch":
            title = "Claude wants to open a web page"
            body = "\(text("url"))\n\n\(text("prompt"))"
        default:
            title = "Claude wants to use \(tool.isEmpty ? "a tool" : tool)"
            body = Self.prettyJSON(input)
            shown = Set(input.allKeys.compactMap { $0 as? String })
        }
        // Everything else in the request is shown too. Settings that widen what Allow allows go
        // first, where they cannot be missed; routine ones (Claude's own timeout) go after.
        let risky: Set<String> = ["dangerouslyDisableSandbox", "replace_all", "run_in_background"]
        let extras = input.allKeys.compactMap { $0 as? String }.filter { !shown.contains($0) }.sorted()
        func lines(_ keys: [String]) -> String {
            keys.map { "Also: \($0): \(Self.prettyJSON(input[$0] ?? NSNull()))" }.joined(separator: "\n")
        }
        let first = extras.filter(risky.contains), after = extras.filter { !risky.contains($0) }
        if !first.isEmpty { body = lines(first) + "\n\n" + body }
        if !after.isEmpty { body += "\n\n" + lines(after) }
        let (visible, hidden) = Self.revealHidden(body)
        let detail = hidden ? "Contains hidden characters, shown as ⟦U+…⟧.\n\n" + visible : visible
        return ClaudeCard(id: UUID(), title: title, detail: detail, caption: caption.map { Self.revealHidden($0).0 },
                          project: project, position: 1, count: 1, unlocked: false,
                          tooLong: detail.count > ClaudeCard.maxDetail)
    }

    /// Two labelled blocks with every line marked, so no line of one can pass for the other.
    static func replacement(_ old: String, _ new: String) -> String {
        func marked(_ text: String, _ mark: String) -> String {
            text.split(separator: "\n", omittingEmptySubsequences: false).map { mark + $0 }.joined(separator: "\n")
        }
        return "Replace:\n" + marked(old, "- ") + "\nWith:\n" + marked(new, "+ ")
    }

    /// Invisible and direction-changing characters (bidi overrides, zero-width spaces, control
    /// codes) would let the text on screen differ from what runs; they are shown as ⟦U+202E⟧.
    static func revealHidden(_ text: String) -> (String, Bool) {
        var found = false
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let category = scalar.properties.generalCategory
            if (category == .format || category == .control) && scalar != "\n" && scalar != "\t" {
                found = true
                out.append(contentsOf: String(format: "⟦U+%04X⟧", scalar.value).unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return (String(out), found)
    }

    /// JSON for any value, including a bare true or 12 (which would otherwise print as 1).
    static func prettyJSON(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return "\(object)" }
        return String(decoding: data, as: UTF8.self)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \(s % 3600 / 60) min"
    }

    func shutdown() { server.stop() }

    // MARK: Self-test hooks

    var hotkeysRegistered: Bool { hotkeys.isRegistered }
    /// Runs exactly what the Carbon hot-key handler runs.
    func debugPressShortcut(allow: Bool) { allow ? hotkeys.onAllow() : hotkeys.onDeny() }
    var pendingCount: Int { queue.count }
    var firstPendingCard: ClaudeCard? { queue.first?.card }
    /// The card as the island shows it (with its unlocked state).
    var shownCard: ClaudeCard? { island.model.mode == .expanded ? island.model.claude : nil }
}

// MARK: - The socket

/// A Unix domain socket in your Application Support folder, readable and writable only by you;
/// connections from any other user are refused. One JSON event per connection.
final class SocketServer: @unchecked Sendable {
    final class Connection: @unchecked Sendable {
        fileprivate let fd: Int32
        private var closed = false
        private let lock = NSLock()

        fileprivate init(fd: Int32) { self.fd = fd }

        /// Writes the answer and closes. Safe to call after the other end has gone.
        func reply(_ text: String) {
            lock.withLock {
                guard !closed else { return }
                let bytes = Array(text.utf8)
                var sent = 0
                while sent < bytes.count {
                    let n = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                    if n <= 0 { break }
                    sent += n
                }
                shutClosed()
            }
        }

        func close() { lock.withLock { shutClosed() } }

        /// Writes an empty line, which Claude Code ignores (it only reads lines starting with
        /// "{"). Fails once the hook has been killed: nothing else can tell that apart from a
        /// hook that is still waiting, because nc half-closes its side as soon as it has sent.
        func isAlive() -> Bool {
            lock.withLock {
                guard !closed else { return false }
                var newline: UInt8 = 0x0A
                return write(fd, &newline, 1) == 1
            }
        }

        private func shutClosed() {
            guard !closed else { return }
            closed = true
            Darwin.close(fd)
        }
    }

    let path: String
    var onMessage: @MainActor (Data, Connection) -> Void = { _, _ in }
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "NotchIsland.claude-socket", attributes: .concurrent)

    init(path: String) { self.path = path }

    /// On quit: without the file, the hook sees no app and does nothing.
    func stop() {
        acceptSource?.cancel()
        if listener >= 0 { Darwin.close(listener) }
        unlink(path)
    }

    func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)
        unlink(path)

        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8) + [0])
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
        chmod(path, 0o600)
        guard listen(listener, 16) == 0 else { throw POSIXError(.EIO) }
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.resume()
        acceptSource = source
    }

    private func acceptAll() {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            queue.async { [weak self] in self?.serve(fd) }
        }
    }

    private func serve(_ fd: Int32) {
        // Only your own processes.
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { Darwin.close(fd); return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))   // a gone hook must not kill the app
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Read until the JSON is complete (the hook cannot signal the end any other way).
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count < 4_000_000 {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if (try? JSONSerialization.jsonObject(with: data)) != nil { break }
        }
        // There is no telling from here whether the hook is still waiting: nc half-closes its side
        // as soon as it has sent the event, then waits for the answer. So a held request is let
        // go on Claude Code's own events instead (see ClaudeBridge.handle).
        let connection = Connection(fd: fd)
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onMessage(data, connection) } }
    }
}

// MARK: - Shortcuts

/// ⌃⌥⌘Y Allow and ⌃⌥⌘N Deny, through Carbon's hot keys: no Accessibility or Input Monitoring
/// permission, and they exist only while an unlocked request is on screen.
@MainActor
final class Hotkeys {
    var onAllow: () -> Void = {}
    var onDeny: () -> Void = {}
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private(set) var isRegistered = false

    static let modifiers = UInt32(cmdKey | optionKey | controlKey)
    static let allowKey = UInt32(kVK_ANSI_Y)
    static let denyKey = UInt32(kVK_ANSI_N)

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let me = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { id.id == 1 ? me.onAllow() : me.onDeny() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register() {
        guard !isRegistered else { return }
        let signature = OSType(0x4E49_736C)   // "NIsl"
        for (key, id) in [(Self.allowKey, UInt32(1)), (Self.denyKey, UInt32(2))] {
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(key, Self.modifiers, EventHotKeyID(signature: signature, id: id),
                                   GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            }
        }
        isRegistered = refs.count == 2
    }

    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        isRegistered = false
    }
}
