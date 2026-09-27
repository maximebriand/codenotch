import Foundation

/// What a Copilot CLI session is, and what it is doing, read from the files the
/// CLI leaves under `~/.copilot`.
///
/// Copilot publishes no session registry of the kind Claude Code writes, and
/// nothing it stores carries a pid — `open-sessions-state.json` comes closest
/// and is a `working` flag that survives a crash, so a session killed mid-turn
/// stays "working" in it forever. The pieces that *are* trustworthy sit in
/// three places, and this puts them together:
///
/// * `logs/process-<epoch ms>-<pid>.log` — the only place a pid appears at all,
///   in the file name, together with when the process started. That pair is
///   exactly what `ProcessLiveness` needs to rule out a recycled pid.
/// * `session-state/<id>/workspace.yaml` — the folder, the branch, and a title
///   Copilot writes for the session. Also `client_name`, which separates a
///   terminal session (`github/cli`) from one an editor hosts; only the first
///   has a window to be taken to.
/// * `session-state/<id>/events.jsonl` — the turn, and whether the session is
///   sitting on a permission prompt.
///
/// Pure and file-driven so the whole of it can be tested on fixtures rather
/// than on whatever happens to be running.
enum CopilotActivity {
    /// The pid and start time a log file's name carries.
    ///
    /// `process-1789715693565-80810.log` is the process that started at that
    /// epoch millisecond with that pid. Nothing else in `~/.copilot` names a
    /// process, which is why a file name is being parsed at all.
    static func process(logNamed name: String) -> (pid: pid_t, startedAt: Date)? {
        guard name.hasPrefix("process-"), name.hasSuffix(".log") else { return nil }
        let middle = name.dropFirst("process-".count).dropLast(".log".count)
        let parts = middle.split(separator: "-")
        guard parts.count == 2,
              let millis = Double(parts[0]), millis > 0,
              let pid = pid_t(parts[1]), pid > 0
        else { return nil }
        return (pid, Date(timeIntervalSince1970: millis / 1000))
    }

    /// The session a process's log belongs to.
    ///
    /// Matched by looking for a session that exists rather than by the log line
    /// that announces it (`Workspace initialized: <id>`): the wording is
    /// Copilot's to change between releases, while "this uuid has a directory
    /// under `session-state`" stays true and checks itself. A log that names
    /// several — the editor-hosted server hosts many at once — yields its
    /// first, and `workspace(…)` then rejects it for not being `github/cli`.
    static func sessionID(inLogHead text: String, isKnown: (String) -> Bool) -> String? {
        for candidate in uuids(in: text) where isKnown(candidate) { return candidate }
        return nil
    }

    /// Every UUID-shaped run in the text, in the order it appears.
    static func uuids(in text: String) -> [String] {
        let pattern = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        var found: [String] = []
        var seen = Set<String>()
        for match in expression.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text) else { continue }
            let uuid = String(text[range])
            if seen.insert(uuid).inserted { found.append(uuid) }
        }
        return found
    }

    /// The handful of `workspace.yaml` fields worth showing.
    struct Workspace: Equatable {
        let name: String?
        let cwd: String?
        let branch: String?
        /// `github/cli` for a session started at a prompt, `github/autopilot`
        /// and others for the rest.
        let clientName: String?

        /// Only a session running in a terminal has a window the switcher can
        /// take you to; an editor-hosted one would be a row that goes nowhere.
        var isTerminalSession: Bool { clientName == "github/cli" }
    }

    /// `workspace.yaml` is flat `key: value` lines — no nesting, no lists — so
    /// it is read as such rather than by pulling in a YAML parser for six keys.
    /// A shape that ever grows a nested key will read as absent here, which is
    /// the same answer as a missing file and degrades to the folder name.
    static func workspace(fromYAML text: String) -> Workspace {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty, !value.isEmpty else { continue }
            values[key] = value
        }
        return Workspace(name: values["name"], cwd: values["cwd"],
                         branch: values["branch"], clientName: values["client_name"])
    }

    /// Where a session's turn stands, read from the end of its event log.
    struct Turn: Equatable {
        let state: AgentSession.State
        let since: Date
        /// Set while waiting: what Copilot asked for, in its own words
        /// ("Edit file", "Run command").
        let waitingFor: String?
    }

    /// How much of the end of `events.jsonl` is read.
    ///
    /// Generous rather than clever: a turn's events are written in a burst, and
    /// a session *waiting* on a permission writes nothing at all after asking —
    /// so the question it is blocked on is always the last thing in the file,
    /// never something an earlier window would have to be walked back to find.
    static let tailBytes: UInt64 = 256 * 1024

    static func turn(inTailOf url: URL, now: Date = Date()) -> Turn? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > tailBytes ? end - tailBytes : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd()
        else { return nil }
        return turn(inTail: data, truncated: start > 0, now: now)
    }

    /// The turn a window of events describes.
    ///
    /// `truncated` drops the first line, which a window that did not start at
    /// byte zero cut in half. Parsing it would not crash — it simply fails to
    /// decode — but dropping it says why rather than relying on that.
    static func turn(inTail data: Data, truncated: Bool = false, now: Date = Date()) -> Turn? {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if truncated, !lines.isEmpty { lines.removeFirst() }

        /// Requests and turns are closed by a later event carrying the same id,
        /// so both are tracked as "opened, not yet closed" rather than by
        /// looking only at the last line — a permission answered mid-turn leaves
        /// `permission.completed` as the newest event while the turn runs on.
        var openPermissions: [(id: String, intention: String?, at: Date)] = []
        var openTurns: [(id: String, at: Date)] = []
        var lastEventAt: Date?
        var shutdown = false

        for line in lines {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = event["type"] as? String
            else { continue }
            let data = event["data"] as? [String: Any] ?? [:]
            let at = timestamp(event["timestamp"] as? String) ?? lastEventAt ?? now
            lastEventAt = at

            switch type {
            case "permission.requested":
                guard let id = data["requestId"] as? String else { continue }
                let request = data["permissionRequest"] as? [String: Any]
                openPermissions.append((id, request?["intention"] as? String, at))
            case "permission.completed":
                guard let id = data["requestId"] as? String else { continue }
                openPermissions.removeAll { $0.id == id }
            case "assistant.turn_start":
                guard let id = data["turnId"] as? String else { continue }
                openTurns.append((id, at))
            case "assistant.turn_end":
                guard let id = data["turnId"] as? String else { continue }
                openTurns.removeAll { $0.id == id }
            case "session.shutdown":
                shutdown = true
            default:
                continue
            }
        }

        guard let lastEventAt, !shutdown else { return nil }
        // Waiting outranks working, the same way `ActivitySummary` ranks them:
        // it is the only state that wants something from the person reading it.
        if let pending = openPermissions.last {
            return Turn(state: .waiting, since: pending.at, waitingFor: pending.intention)
        }
        if let turn = openTurns.last {
            return Turn(state: .busy, since: turn.at, waitingFor: nil)
        }
        return Turn(state: .idle, since: lastEventAt, waitingFor: nil)
    }

    /// Copilot writes ISO 8601 with milliseconds and a `Z`.
    static func timestamp(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        // A release that drops the fractional part would otherwise read as no
        // timestamp at all, and every session would date from the current tick.
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
