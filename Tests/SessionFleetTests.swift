import XCTest
@testable import Codenotch

/// One list of every running session, grouped by the window it runs in.
final class SessionFleetTests: XCTestCase {
    private func session(_ id: String, _ state: AgentSession.State,
                         pid: pid_t?, since: TimeInterval = 0) -> AgentSession {
        AgentSession(id: id, name: id, detail: "", state: state, waitingFor: nil,
                     since: Date(timeIntervalSince1970: since), processID: pid)
    }

    private func location(_ app: String, _ container: String? = nil) -> SessionLocation {
        SessionLocation(bundleID: nil, appName: app, wave: nil, container: container)
    }

    /// pid 1 is in Wave's first workspace, 2 in its second, 3 in Terminal.
    private func locate(_ pid: pid_t) -> SessionLocation? {
        switch pid {
        case 1: return location("Wave", "Agentisation")
        case 2: return location("Wave", "Calendrier")
        case 3: return location("Terminal")
        default: return nil
        }
    }

    func testSessionsAreGroupedByWhereTheyRun() {
        let fleet = SessionFleet.build(sessions: [
            "claude": [session("a", .idle, pid: 1), session("b", .idle, pid: 3)],
            "copilot": [session("c", .idle, pid: 1)],
        ], locate: locate)
        XCTAssertEqual(fleet.groups.map(\.heading), ["Terminal", "Wave · Agentisation"])
        XCTAssertEqual(fleet.groups.first { $0.heading == "Wave · Agentisation" }?.rows.count, 2)
    }

    /// The window waiting on you is the one a single keystroke should reach.
    func testTheWaitingGroupComesFirst() {
        let fleet = SessionFleet.build(sessions: [
            "claude": [session("calm", .idle, pid: 1), session("blocked", .waiting, pid: 2)],
        ], locate: locate)
        XCTAssertEqual(fleet.groups.first?.heading, "Wave · Calendrier")
        XCTAssertEqual(fleet.rows.first?.session.id, "blocked")
    }

    func testWithinAGroupWaitingOutranksBusyOutranksIdle() {
        let fleet = SessionFleet.build(sessions: [
            "claude": [
                session("idle", .idle, pid: 1),
                session("busy", .busy, pid: 1),
                session("waiting", .waiting, pid: 1),
                session("done", .success, pid: 1),
            ],
        ], locate: locate)
        XCTAssertEqual(fleet.rows.map(\.session.id), ["waiting", "busy", "done", "idle"])
    }

    func testEqualStatesAreNewestFirst() {
        let fleet = SessionFleet.build(sessions: [
            "claude": [session("older", .busy, pid: 1, since: 10),
                       session("newer", .busy, pid: 1, since: 20)],
        ], locate: locate)
        XCTAssertEqual(fleet.rows.map(\.session.id), ["newer", "older"])
    }

    /// Four monitors report activity without ever learning the process, and a
    /// row that cannot be jumped to is worse than no row.
    func testASessionWithNoProcessIsLeftOut() {
        let fleet = SessionFleet.build(sessions: [
            "cursor": [session("nowhere", .busy, pid: nil)],
            "claude": [session("somewhere", .busy, pid: 1)],
        ], locate: locate)
        XCTAssertEqual(fleet.rows.map(\.session.id), ["somewhere"])
    }

    /// A pid whose tree runs out before an application — launchd, or ssh.
    func testASessionWithNoLocatableWindowIsLeftOut() {
        let fleet = SessionFleet.build(sessions: [
            "claude": [session("orphan", .busy, pid: 99)],
        ], locate: locate)
        XCTAssertTrue(fleet.rows.isEmpty)
        XCTAssertTrue(fleet.groups.isEmpty)
    }

    /// Two tools can both name a session after the folder it runs in.
    func testRowIdentityIsUniqueAcrossProviders() {
        let fleet = SessionFleet.build(sessions: [
            "claude": [session("same", .busy, pid: 1)],
            "copilot": [session("same", .busy, pid: 1)],
        ], locate: locate)
        XCTAssertEqual(Set(fleet.rows.map(\.id)).count, 2)
    }
}

/// The highlight, while the list re-sorts underneath it.
final class SessionFleetSelectionTests: XCTestCase {
    private func fleet(_ ids: [String]) -> SessionFleet {
        SessionFleet.build(sessions: ["claude": ids.map {
            AgentSession(id: $0, name: $0, detail: "", state: .idle, waitingFor: nil,
                         since: .distantPast, processID: 1)
        }], locate: { _ in
            SessionLocation(bundleID: nil, appName: "Wave", wave: nil, container: nil)
        })
    }

    private func rowID(_ id: String) -> String { "claude\u{1}\(id)" }

    func testAnEmptyListHasNoSelection() {
        XCTAssertNil(fleet([]).selection(keeping: nil, previousIndex: 0))
    }

    /// The whole reason selection is held by id: a session changing state
    /// re-sorts the list, and an index would move the highlight onto a
    /// different window between the keystroke and the return.
    func testTheSameRowKeepsTheSelectionWhereverItMoved() {
        let after = fleet(["c", "b", "a"])
        let index = after.selection(keeping: rowID("a"), previousIndex: 0)
        XCTAssertEqual(index.map { after.rows[$0].session.id }, "a")
    }

    func testARowThatHasGoneLeavesTheSelectionInPlace() {
        let after = fleet(["a", "b"])
        XCTAssertEqual(after.selection(keeping: rowID("gone"), previousIndex: 1), 1)
    }

    /// The list can shrink under a selection near its end.
    func testTheFallbackIndexIsClampedToTheList() {
        let after = fleet(["a"])
        XCTAssertEqual(after.selection(keeping: nil, previousIndex: 7), 0)
        XCTAssertEqual(after.selection(keeping: nil, previousIndex: -3), 0)
    }
}
