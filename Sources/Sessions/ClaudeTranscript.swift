import Foundation

/// What a Claude Code session is doing, read from its transcript.
///
/// Claude Code writes `status` into `~/.claude/sessions/<pid>.json` from one
/// place only: an effect inside the terminal interface's render loop. A session
/// hosted by the Claude desktop app runs the same binary with no terminal
/// interface, so that effect never fires and the record carries no status at
/// all — which is why every desktop session read as permanently idle, and why
/// the usage ring never polled hard while one was working.
///
/// The transcript is the other thing Claude Code writes, and the engine writes
/// it rather than the interface, so it is there for both surfaces:
/// `~/.claude/projects/<slug>/<sessionId>.jsonl`, one JSON object per line,
/// appended as the turn goes.
enum ClaudeTranscript {
    /// Whether the session is mid-turn.
    ///
    /// Two cases and not three, deliberately. Nothing in the transcript
    /// separates a tool waiting on your permission from a tool that is simply
    /// taking its time — there is no record for a permission prompt — so this
    /// never claims `waiting`. Only the terminal interface knows that, and only
    /// the terminal interface writes it to the registry.
    enum Turn: Equatable { case inFlight, finished }

    /// How much of the end of the file to look at. The last few records settle
    /// it, and these transcripts run to megabytes.
    static let tailBytes = 64 * 1024

    // MARK: - Where the file is

    /// The directory Claude Code files a working directory's transcripts under:
    /// the path with every `/` and `.` turned into `-`, so
    /// `/Users/x/app/.claude/worktrees/y` becomes
    /// `-Users-x-app--claude-worktrees-y`.
    static func projectSlug(forCWD cwd: String) -> String {
        String(cwd.map { $0 == "/" || $0 == "." ? "-" : $0 })
    }

    /// The transcript for one session, or nil if it has not been written yet.
    ///
    /// `scanning` is what makes this affordable to call on a timer: the slug is
    /// derived from the session's own `cwd` and is right almost always, so the
    /// usual cost is a single `stat`. The directory scan is the fallback for a
    /// session that has moved since it started — resumed in a worktree, say —
    /// and keeps its transcript where it was first written.
    static func transcript(
        forSessionID sessionID: String,
        cwd: String,
        in projects: URL,
        scanning: Bool,
        fileManager: FileManager = .default
    ) -> URL? {
        let file = sessionID + ".jsonl"
        let direct = projects
            .appendingPathComponent(projectSlug(forCWD: cwd))
            .appendingPathComponent(file)
        if fileManager.fileExists(atPath: direct.path) { return direct }
        guard scanning else { return nil }

        let folders = (try? fileManager.contentsOfDirectory(atPath: projects.path)) ?? []
        for folder in folders {
            let candidate = projects
                .appendingPathComponent(folder)
                .appendingPathComponent(file)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: - What it says

    static func turn(at url: URL, bytes: Int = tailBytes) -> Turn? {
        tail(of: url, bytes: bytes).flatMap(turn(inTail:))
    }

    /// The last records of the file, without reading the rest of it.
    static func tail(of url: URL, bytes: Int = tailBytes) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        return try? handle.readToEnd()
    }

    /// The state machine, kept pure so it can be tested without a file.
    ///
    /// Only `user` and `assistant` lines are allowed to decide. The transcript
    /// also carries bookkeeping — `bridge-session`, `atis-latch`, `frame-link`,
    /// `custom-title` and more — which Claude Code keeps appending while a
    /// session sits doing nothing. That is why "was the file touched recently",
    /// which is all the Codex monitor can manage, is not good enough here: on
    /// this Mac it reported a session that had been parked for an hour as
    /// working. An allow-list rather than a list of kinds to skip, because the
    /// bookkeeping kinds are added to between releases.
    ///
    /// Nil when the tail holds no conversation at all — a session that has been
    /// opened and not yet used. The caller leaves such a session as it found it
    /// rather than guessing.
    static func turn(inTail data: Data) -> Turn? {
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for line in lines.reversed() {
            // The first line of the tail is usually cut in half; it fails to
            // parse and is skipped, which is the whole handling it needs.
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line)))
                    as? [String: Any] else { continue }
            // A subagent's records are interleaved with its parent's, and the
            // parent's turn is the one being reported on.
            if json["isSidechain"] as? Bool == true { continue }

            switch json["type"] as? String {
            case "assistant":
                // `tool_use` is the only stop reason that means the turn goes
                // on; `end_turn`, `stop_sequence` and `max_tokens` all end it.
                let message = json["message"] as? [String: Any]
                return message?["stop_reason"] as? String == "tool_use" ? .inFlight : .finished
            case "user":
                return isInterruption(json) ? .finished : .inFlight
            default:
                continue
            }
        }
        return nil
    }

    /// Pressing Esc writes a user turn saying so, which is what makes "stopped"
    /// something the notch can know rather than wait out with a timeout. Two
    /// wordings exist, and both start the same way.
    private static let interruption = "[Request interrupted by user"

    static func isInterruption(_ json: [String: Any]) -> Bool {
        guard let message = json["message"] as? [String: Any] else { return false }
        switch message["content"] {
        case let text as String:
            return text.hasPrefix(interruption)
        case let blocks as [Any]:
            return blocks.contains { block in
                ((block as? [String: Any])?["text"] as? String)?.hasPrefix(interruption) == true
            }
        default:
            return false
        }
    }
}

// MARK: - What a waiting session is about

extension ClaudeTranscript {
    /// What a session that has stopped to ask something is about, and what it
    /// is asking.
    struct Prompt: Equatable {
        /// The conversation's title: the one you gave it, or else the one
        /// Claude Code generated.
        let title: String?
        /// The tool call the session is holding for you, in words.
        let ask: String?
        /// The start of the last thing it said to you.
        var reply: String? = nil
    }

    /// Read from the tail, forward, so the last word on each wins.
    ///
    /// The transcript cannot say *that* a session is waiting — see `Turn` — but
    /// once the registry has said so, it says *what for*: the tool call written
    /// last and not yet answered by a result is the one on screen. Only asked
    /// of a session the registry already reports as waiting, so a call that
    /// is merely taking its time is never described as a question.
    ///
    /// Titles are rewritten as the conversation moves on, dozens of times over
    /// a long session, so the tail almost always holds a recent one.
    static func prompt(inTail data: Data) -> Prompt {
        var custom: String?
        var generated: String?
        var calls: [(id: String, name: String, input: [String: Any])] = []
        var answered: Set<String> = []
        var reply: String?

        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let json = (try? JSONSerialization.jsonObject(with: Data(line)))
                    as? [String: Any] else { continue }
            switch json["type"] as? String {
            case "custom-title":
                custom = nonEmpty(json["customTitle"] as? String) ?? custom
            case "ai-title":
                generated = nonEmpty(json["aiTitle"] as? String) ?? generated
            case "assistant":
                // A subagent's permission prompt is shown in its parent's
                // terminal like any other, so sidechains are read here — unlike
                // `turn(inTail:)`, which is about the parent's turn alone.
                // The last words are the parent's: a subagent's text is its
                // report to the parent, never addressed to you.
                if json["isSidechain"] as? Bool != true {
                    for block in blocks(of: json) where block["type"] as? String == "text" {
                        reply = excerpt(block["text"] as? String) ?? reply
                    }
                }
                for block in blocks(of: json) where block["type"] as? String == "tool_use" {
                    guard let id = block["id"] as? String,
                          let name = block["name"] as? String else { continue }
                    calls.append((id, name, block["input"] as? [String: Any] ?? [:]))
                }
            case "user":
                for block in blocks(of: json) where block["type"] as? String == "tool_result" {
                    if let id = block["tool_use_id"] as? String { answered.insert(id) }
                }
            default:
                continue
            }
        }

        let pending = calls.last { !answered.contains($0.id) }
        return Prompt(title: custom ?? generated,
                      ask: pending.map { describe(tool: $0.name, input: $0.input) },
                      reply: reply)
    }

    /// A reply cut to what fits a few lines of a card: whitespace and markdown
    /// emphasis flattened, the rest left to the card's own truncation.
    static func excerpt(_ text: String?, limit: Int = 280) -> String? {
        guard let text = nonEmpty(text) else { return nil }
        let flat = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    /// One line a person can decide on without switching windows.
    static func describe(tool: String, input: [String: Any]) -> String {
        let text = { (key: String) in nonEmpty(input[key] as? String) }
        switch tool {
        case "AskUserQuestion":
            // The first question is the one on screen; the rest follow it.
            let questions = input["questions"] as? [[String: Any]]
            if let question = questions?.first.flatMap({ nonEmpty($0["question"] as? String) }) {
                return question
            }
            return L10n.t("Has a question for you")
        case "ExitPlanMode":
            return L10n.t("Wants you to approve its plan")
        case "Bash":
            if let command = text("description") ?? text("command") {
                return L10n.t("Run: \(command)")
            }
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            if let path = text("file_path") ?? text("notebook_path") {
                return L10n.t("Edit \((path as NSString).lastPathComponent)")
            }
        case "WebFetch":
            if let url = text("url") { return L10n.t("Fetch \(url)") }
        default:
            break
        }
        // An MCP tool's name is `mcp__server__tool`; the tool is the readable part.
        let readable = tool.components(separatedBy: "__").last ?? tool
        return L10n.t("Use \(readable)")
    }

    private static func blocks(of json: [String: Any]) -> [[String: Any]] {
        ((json["message"] as? [String: Any])?["content"] as? [Any])?
            .compactMap { $0 as? [String: Any] } ?? []
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}

/// Reads transcripts on a timer, and remembers enough not to read them twice.
///
/// One instance per monitor. A tick that finds a transcript untouched since the
/// last one costs a `stat` and nothing else — the tail is read only when the
/// file has actually grown.
final class ClaudeTranscriptReader {
    private struct Cached {
        let modified: Date
        let size: UInt64
        let turn: ClaudeTranscript.Turn?
    }

    private let projects: URL
    private let fileManager: FileManager
    /// Where each session's transcript turned out to be. Sessions come and go;
    /// this is bounded by how many have run since the app launched.
    private var paths: [String: URL] = [:]
    private var cache: [String: Cached] = [:]
    /// When each session last changed what it was doing.
    ///
    /// The transcript's timestamp is when it was last *appended to*, which
    /// moves every few seconds through a long turn. Reported as-is it would
    /// hold the tooltip's elapsed time at zero for as long as the session
    /// worked, and hand the notch a new value to animate on every tick. What
    /// the notch means by `since` is when the state was entered, so the moment
    /// of the change is kept and the appends in between are ignored.
    private var entered: [String: (turn: ClaudeTranscript.Turn, at: Date)] = [:]
    /// Sessions already looked for the hard way and not found. The directory
    /// scan is worth doing once for a session that has moved, and never worth
    /// repeating every two seconds for one that simply has no transcript.
    private var scanned: Set<String> = []

    init(projects: URL, fileManager: FileManager = .default) {
        self.projects = projects
        self.fileManager = fileManager
    }

    /// What the session is doing, and when it last moved. Nil when there is no
    /// transcript to read, or nothing said in it yet.
    func activity(sessionID: String, cwd: String) -> (turn: ClaudeTranscript.Turn, since: Date)? {
        guard let url = path(sessionID: sessionID, cwd: cwd),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0

        let turn: ClaudeTranscript.Turn?
        if let cached = cache[sessionID], cached.modified == modified, cached.size == size {
            turn = cached.turn
        } else {
            turn = ClaudeTranscript.turn(at: url)
            cache[sessionID] = Cached(modified: modified, size: size, turn: turn)
        }

        guard let turn else { return nil }
        if let previous = entered[sessionID], previous.turn == turn {
            return (turn, previous.at)
        }
        // First sight of a change, so the file's own timestamp is the closest
        // thing there is to when it happened.
        entered[sessionID] = (turn, modified)
        return (turn, modified)
    }

    /// What a waiting session is about, read again only when the file has grown.
    ///
    /// Asked only of sessions the registry reports as waiting, which are few
    /// and hold still while they wait — so this is one tail read per question
    /// asked, not one per tick.
    func prompt(sessionID: String, cwd: String) -> ClaudeTranscript.Prompt? {
        guard let url = path(sessionID: sessionID, cwd: cwd),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        if let cached = prompts[sessionID], cached.modified == modified, cached.size == size {
            return cached.prompt
        }
        guard let tail = ClaudeTranscript.tail(of: url) else { return nil }
        let prompt = ClaudeTranscript.prompt(inTail: tail)
        prompts[sessionID] = (modified, size, prompt)
        return prompt
    }

    private var prompts: [String: (modified: Date, size: UInt64, prompt: ClaudeTranscript.Prompt)] = [:]

    private func path(sessionID: String, cwd: String) -> URL? {
        if let known = paths[sessionID] { return known }
        let scanning = !scanned.contains(sessionID)
        guard let found = ClaudeTranscript.transcript(
            forSessionID: sessionID, cwd: cwd, in: projects,
            scanning: scanning, fileManager: fileManager
        ) else {
            if scanning { scanned.insert(sessionID) }
            return nil
        }
        paths[sessionID] = found
        return found
    }
}
