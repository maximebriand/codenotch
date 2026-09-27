import Combine
import Foundation

/// Publishes the Copilot CLI sessions that are actually running.
///
/// Polled rather than watched. Every other monitor here can watch one directory
/// because the tool writes its session state into it; Copilot writes each
/// session's events inside `session-state/<id>/`, a directory per session that
/// does not exist yet when the session starts, and a watch on the parent never
/// sees an append two levels down. A timer is the honest answer, and the two
/// caches below are what keep it from costing anything: a pid's session id is
/// resolved once, and a session's events are re-read only when the file has
/// been written to.
///
/// See `CopilotActivity` for what is read and why those files.
@MainActor
final class CopilotActivityMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let root: URL
    private let interval: TimeInterval
    private var timer: Timer?

    /// pid → the session its log names. A process keeps the same session for
    /// its whole life, so this is resolved once and dropped when the pid goes.
    private var resolved: [pid_t: String] = [:]
    /// sessionID → the last turn read, and the modification date it was read
    /// at. A session blocked on a permission writes nothing while it waits, so
    /// holding the answer is not staleness — it is the answer.
    private var turns: [String: (modified: Date, turn: CopilotActivity.Turn?)] = [:]

    /// Copilot keeps every log it has ever written; only the newest few belong
    /// to processes that could still be alive, and walking the rest on every
    /// tick would be work that can only ever come back empty.
    private static let logsExamined = 50

    init(root: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".copilot"),
         interval: TimeInterval = 2) {
        self.root = root
        self.interval = interval
    }

    func start() {
        // Same reason as `ClaudeSessionMonitor`: not idempotent by
        // construction, so a second start would stack a second timer.
        stop()
        rescan()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func rescan() {
        let found = read()
        guard found != sessions else { return }   // don't churn SwiftUI for nothing
        let summary = found.map { "\($0.name)=\($0.state)" }.joined(separator: " ")
        Log.sessions.debug("copilot: \(summary, privacy: .public)")
        sessions = found
    }

    private func read() -> [AgentSession] {
        let manager = FileManager.default
        let logs = root.appendingPathComponent("logs")
        let names = (try? manager.contentsOfDirectory(atPath: logs.path)) ?? []

        let candidates = names
            .compactMap { name -> (pid: pid_t, startedAt: Date)? in
                CopilotActivity.process(logNamed: name)
            }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(Self.logsExamined)
            .filter { ProcessLiveness.isAlive(pid: $0.pid, startedAt: $0.startedAt) }

        // Everything the dead left behind, so a long-lived Codenotch does not
        // accumulate a cache entry per Copilot run of the week.
        let alive = Set(candidates.map(\.pid))
        resolved = resolved.filter { alive.contains($0.key) }

        var built: [AgentSession] = []
        var live = Set<String>()
        for candidate in candidates {
            guard let sessionID = sessionID(of: candidate.pid, startedAt: candidate.startedAt),
                  let session = session(id: sessionID, pid: candidate.pid)
            else { continue }
            live.insert(sessionID)
            built.append(session)
        }
        turns = turns.filter { live.contains($0.key) }
        // Newest first, with the id breaking ties so two sessions started in
        // the same millisecond cannot swap places between ticks.
        return built.sorted { $0.since == $1.since ? $0.id < $1.id : $0.since > $1.since }
    }

    /// The session a live process belongs to, resolved from the head of its log
    /// and then remembered.
    private func sessionID(of pid: pid_t, startedAt: Date) -> String? {
        if let known = resolved[pid] { return known }
        let name = "process-\(Int(startedAt.timeIntervalSince1970 * 1000))-\(pid).log"
        let url = root.appendingPathComponent("logs").appendingPathComponent(name)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // The head only. The session is announced in the first few kilobytes,
        // and the editor-hosted server's log runs to hundreds of megabytes.
        guard let data = try? handle.read(upToCount: 64 * 1024),
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        let sessions = root.appendingPathComponent("session-state")
        let found = CopilotActivity.sessionID(inLogHead: text) { candidate in
            FileManager.default.fileExists(
                atPath: sessions.appendingPathComponent(candidate).path
            )
        }
        if let found { resolved[pid] = found }
        return found
    }

    private func session(id: String, pid: pid_t) -> AgentSession? {
        let directory = root.appendingPathComponent("session-state").appendingPathComponent(id)
        let yaml = (try? String(contentsOf: directory.appendingPathComponent("workspace.yaml"),
                                encoding: .utf8)) ?? ""
        let workspace = CopilotActivity.workspace(fromYAML: yaml)
        // An editor-hosted session has no terminal window to be taken to, and a
        // row that goes nowhere is worse than no row.
        guard workspace.isTerminalSession else { return nil }

        let events = directory.appendingPathComponent("events.jsonl")
        guard let turn = turn(for: id, at: events) else { return nil }

        let folder = workspace.cwd.map { ($0 as NSString).lastPathComponent } ?? id
        return AgentSession(
            id: "copilot.\(id)",
            name: workspace.name ?? folder,
            // Spelled the way `ClaudeSessionRecord` spells it, so two rows from
            // two tools read as the same kind of thing in one list.
            detail: "\(L10n.t("Terminal")) · \(folder)",
            state: turn.state,
            waitingFor: turn.waitingFor,
            since: turn.since,
            processID: pid
        )
    }

    /// The turn, re-read only when the event log has been written to since.
    private func turn(for id: String, at events: URL) -> CopilotActivity.Turn? {
        let modified = (try? events.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        if let modified, let cached = turns[id], cached.modified == modified {
            return cached.turn
        }
        let turn = CopilotActivity.turn(inTailOf: events)
        if let modified { turns[id] = (modified, turn) }
        return turn
    }
}
