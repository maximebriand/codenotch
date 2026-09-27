import Foundation

/// Every live agent session in one list, grouped by the window it runs in.
///
/// The notch shows sessions one provider at a time, in a tooltip, on hover —
/// which is the right shape for "is this ring still working". It is the wrong
/// shape for "which of these nine windows is waiting on me", and that is the
/// question this answers.
///
/// A session with no pid is left out. Four of the monitors report activity from
/// a database or a log file and never learn which process it belongs to; there
/// is no window to take you to, and a row that goes nowhere is worse than no
/// row. They stay visible in the notch, where they are not offering a jump.
struct SessionFleet: Equatable {
    struct Row: Identifiable, Equatable {
        let session: AgentSession
        /// Which ring it belongs to — the switcher shows the provider's glyph,
        /// and a jump has to say what it jumped to.
        let providerID: String
        let location: SessionLocation

        /// Unique across providers: two tools can both call a session by the
        /// folder it runs in.
        var id: String { "\(providerID)\u{1}\(session.id)" }
    }

    struct Group: Identifiable, Equatable {
        let heading: String
        let rows: [Row]
        var id: String { heading }
    }

    let groups: [Group]
    /// The same rows, flattened in display order — what the keyboard walks.
    let rows: [Row]

    static let empty = SessionFleet(groups: [], rows: [])

    /// Build from what the monitors currently publish.
    ///
    /// `locate` is passed in rather than called directly because resolving one
    /// costs a walk up the process tree and, in Wave, a subprocess: the caller
    /// resolves off the main actor and caches, and a test hands over a table.
    static func build(sessions: [String: [AgentSession]],
                      locate: (pid_t) -> SessionLocation?) -> SessionFleet {
        var byHeading: [String: [Row]] = [:]
        for (providerID, live) in sessions {
            for session in live {
                guard let pid = session.processID, let location = locate(pid) else { continue }
                byHeading[location.heading, default: []]
                    .append(Row(session: session, providerID: providerID, location: location))
            }
        }

        let groups = byHeading
            .map { Group(heading: $0.key, rows: $0.value.sorted(by: precedes)) }
            // A group is as urgent as its most urgent row, so the window that
            // is waiting on you is the one at the top of the panel. Heading
            // breaks the tie, so two calm groups cannot swap places between
            // one keystroke and the next.
            .sorted { a, b in
                let left = a.rows.first.map { rank($0.session.state) } ?? Int.max
                let right = b.rows.first.map { rank($0.session.state) } ?? Int.max
                return left == right ? a.heading < b.heading : left < right
            }
        return SessionFleet(groups: groups, rows: groups.flatMap(\.rows))
    }

    /// Waiting first — it is the only state asking for something — then work in
    /// progress, then what has just finished, then the idle windows.
    static func rank(_ state: AgentSession.State) -> Int {
        switch state {
        case .waiting: return 0
        case .busy:    return 1
        case .success: return 2
        case .idle:    return 3
        }
    }

    /// Within a group: by urgency, then newest first, then by id so the order
    /// cannot flicker between two ticks that read the same thing.
    static func precedes(_ a: Row, _ b: Row) -> Bool {
        let left = rank(a.session.state), right = rank(b.session.state)
        if left != right { return left < right }
        if a.session.since != b.session.since { return a.session.since > b.session.since }
        return a.id < b.id
    }

    /// The row a selection lands on after the list has been rebuilt.
    ///
    /// Held by id rather than by index: the list re-sorts under the selection
    /// whenever a session changes state, and an index would quietly move the
    /// highlight onto a different window between the keystroke and the return.
    /// A row that has gone leaves the selection where it was in the order,
    /// which is the nearest thing to staying put.
    func selection(keeping id: String?, previousIndex: Int) -> Int? {
        guard !rows.isEmpty else { return nil }
        if let id, let found = rows.firstIndex(where: { $0.id == id }) { return found }
        return min(max(0, previousIndex), rows.count - 1)
    }
}
