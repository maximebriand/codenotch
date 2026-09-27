import Darwin
import Foundation

/// One agent session, whichever tool it belongs to.
///
/// Deliberately a *display* model rather than a mirror of any one tool's file
/// format: Claude Code publishes a session registry, Cursor keeps composer rows
/// in SQLite, and neither shape belongs in the notch. Each monitor does its own
/// parsing and hands back this.
struct AgentSession: Identifiable, Equatable {
    /// What the session is doing right now.
    enum State: Equatable {
        case busy
        case waiting
        case success
        case idle
    }

    let id: String
    /// What to call it in the tooltip.
    let name: String
    /// The quieter second line — where it is running, or what it is doing.
    let detail: String
    let state: State
    /// Set while `waiting`: what it wants from you.
    let waitingFor: String?
    /// When it entered its current state.
    let since: Date
    /// The agent's own process, when the tool publishes one.
    ///
    /// Only used to find the window it is running in — see `SessionFocus`.
    /// Nil for the tools that report activity from a database or a log file
    /// rather than from a process, and a nil here costs nothing but the ability
    /// to jump to that session.
    let processID: pid_t?
    /// What the session is about, in the tool's own words — Claude Code's
    /// generated title, say — when it has one to give.
    ///
    /// Separate from `name` because `name` is what tells one row from the next
    /// and has to be there for every session, while a topic is only read where
    /// the question is "which conversation is this": the card that says a
    /// session is waiting on you.
    let topic: String?
    /// The start of the last thing it said, once a turn has ended — what a
    /// finished session is handing back to you.
    let lastReply: String?

    /// Written out rather than synthesised so `processID` can default to nil:
    /// four of the five monitors have no pid to give, and a memberwise
    /// initialiser would have made every one of them say so.
    init(
        id: String,
        name: String,
        detail: String,
        state: State,
        waitingFor: String?,
        since: Date,
        processID: pid_t? = nil,
        topic: String? = nil,
        lastReply: String? = nil
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.state = state
        self.waitingFor = waitingFor
        self.since = since
        self.processID = processID
        self.topic = topic
        self.lastReply = lastReply
    }
}
