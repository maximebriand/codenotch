import Foundation

/// A session that is waiting on you, as the notch offers it.
///
/// The chime says *that* something happened and the Wave badge says *where*;
/// this is the half that says *what*, early enough to decide whether it is worth
/// leaving what you are doing for. It stays offered until you answer it — go
/// there, or not now — or the session moves on by itself, because a card that
/// disappears after five seconds is one you can miss by looking away.
///
/// Two ways for a session to be waiting on you, and both count: it has stopped
/// mid-turn to ask something (a permission, a question), or it has finished its
/// turn and handed the conversation back.
struct SessionPrompt: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Stopped mid-turn on a question or a permission.
        case blocked
        /// Its turn is over; the next move is yours.
        case finished
    }

    let providerID: String
    let session: AgentSession
    let kind: Kind
    /// How many other sessions are waiting behind this one.
    let others: Int

    /// One wait, not one session: the same session stopping again after being
    /// answered is a new question, and `since` is when this wait began.
    var id: String { Self.key(providerID: providerID, session: session) }

    static func key(providerID: String, session: AgentSession) -> String {
        "\(providerID)\u{1}\(session.id)\u{1}\(session.since.timeIntervalSince1970)"
    }

    /// The conversation's own title where the tool gives one, its name otherwise.
    var title: String { session.topic ?? session.name }

    /// What it is asking, or what it said last.
    var message: String {
        switch kind {
        case .blocked:  return session.waitingFor ?? L10n.t("Waiting for your answer")
        case .finished: return session.lastReply ?? L10n.t("Finished — your turn")
        }
    }

    /// Every wait not yet cleared, newest first — the notch's to-do list.
    ///
    /// A blocked session is listed on its state alone. A finished one only
    /// when its turn was seen ending (`finished`, keyed like `id`): every idle
    /// session is technically waiting on you, and the nine that were sitting
    /// there before Codenotch started are not news.
    ///
    /// Newest first because it is the one you most likely just left. Only
    /// sessions with a process are listed — "go there" is what a row is for,
    /// and a session with no window has nowhere to go.
    static func open(sessions: [String: [AgentSession]],
                     finished: Set<String> = [],
                     dismissed: Set<String>) -> [SessionPrompt] {
        var open: [(providerID: String, session: AgentSession, kind: Kind, key: String)] = []
        for (providerID, live) in sessions {
            for session in live where session.processID != nil {
                let key = key(providerID: providerID, session: session)
                guard !dismissed.contains(key) else { continue }
                if session.state == .waiting {
                    open.append((providerID, session, .blocked, key))
                } else if session.state != .busy, finished.contains(key) {
                    open.append((providerID, session, .finished, key))
                }
            }
        }
        // The key breaks ties so two waits that began together cannot swap
        // places between one reading and the next.
        open.sort { a, b in
            if a.session.since != b.session.since { return a.session.since > b.session.since }
            return a.key < b.key
        }
        return open.enumerated().map { index, entry in
            SessionPrompt(providerID: entry.providerID, session: entry.session,
                          kind: entry.kind, others: open.count - 1 - index)
        }
    }

    /// The newest open wait, or nil.
    static func current(sessions: [String: [AgentSession]],
                        finished: Set<String> = [],
                        dismissed: Set<String>) -> SessionPrompt? {
        open(sessions: sessions, finished: finished, dismissed: dismissed).first
    }

    /// The keys still worth remembering: those of sessions still at rest in the
    /// same wait.
    ///
    /// A wait that has ended can never come back under the same key, so
    /// holding on to it would only grow the set for as long as the app runs.
    static func pruned(_ keys: Set<String>,
                       sessions: [String: [AgentSession]]) -> Set<String> {
        var live: Set<String> = []
        for (providerID, list) in sessions {
            for session in list where session.state != .busy {
                live.insert(key(providerID: providerID, session: session))
            }
        }
        return keys.intersection(live)
    }
}
