import XCTest
@testable import Codenotch

/// Finding a Copilot CLI session: the pid in a log file's name, the session id
/// in its head, and the fields `workspace.yaml` publishes.
final class CopilotDiscoveryTests: XCTestCase {
    func testALogNameCarriesThePidAndTheStartTime() {
        let found = CopilotActivity.process(logNamed: "process-1789715693565-80810.log")
        XCTAssertEqual(found?.pid, 80810)
        XCTAssertEqual(found?.startedAt.timeIntervalSince1970 ?? 0, 1789715693.565, accuracy: 0.001)
    }

    func testAnythingElseInTheLogsDirectoryIsNotAProcess() {
        XCTAssertNil(CopilotActivity.process(logNamed: "process-1789715693565-80810.txt"))
        XCTAssertNil(CopilotActivity.process(logNamed: "copilot.log"))
        XCTAssertNil(CopilotActivity.process(logNamed: "process-notanumber-80810.log"))
        XCTAssertNil(CopilotActivity.process(logNamed: "process-1789715693565.log"))
        XCTAssertNil(CopilotActivity.process(logNamed: "process-1789715693565-0.log"))
    }

    /// The editor-hosted server's log names many sessions; a terminal one names
    /// exactly its own. Either way the first that has state on disk is the one.
    func testTheSessionIsTheFirstOneThatExists() {
        let head = """
            2026-09-18T07:14:53.650Z [WARNING] no session host for 11111111-1111-1111-1111-111111111111
            2026-09-18T07:14:53.660Z [INFO] Workspace initialized: 6105cf47-7461-4401-acce-552bd95adf90
            """
        XCTAssertEqual(
            CopilotActivity.sessionID(inLogHead: head) { $0 == "6105cf47-7461-4401-acce-552bd95adf90" },
            "6105cf47-7461-4401-acce-552bd95adf90"
        )
    }

    func testALogNamingNoKnownSessionResolvesToNothing() {
        let head = "[INFO] Workspace initialized: 11111111-1111-1111-1111-111111111111"
        XCTAssertNil(CopilotActivity.sessionID(inLogHead: head) { _ in false })
        XCTAssertNil(CopilotActivity.sessionID(inLogHead: "no uuid here") { _ in true })
    }

    func testWorkspaceFieldsAreRead() {
        let workspace = CopilotActivity.workspace(fromYAML: """
            id: 6105cf47-7461-4401-acce-552bd95adf90
            cwd: /Users/me/IdeaProjects/supervision
            git_root: /Users/me/IdeaProjects/supervision
            branch: main
            client_name: github/cli
            name: Display Application Tags on Expand
            user_named: false
            """)
        XCTAssertEqual(workspace.cwd, "/Users/me/IdeaProjects/supervision")
        XCTAssertEqual(workspace.branch, "main")
        XCTAssertEqual(workspace.name, "Display Application Tags on Expand")
        XCTAssertTrue(workspace.isTerminalSession)
    }

    /// Only a session started at a prompt has a window to be taken to.
    func testOnlyACLISessionIsATerminalSession() {
        XCTAssertFalse(CopilotActivity.workspace(fromYAML: "client_name: github/autopilot")
            .isTerminalSession)
        XCTAssertFalse(CopilotActivity.workspace(fromYAML: "cwd: /tmp").isTerminalSession)
    }

    func testAQuotedValueLosesItsQuotes() {
        XCTAssertEqual(CopilotActivity.workspace(fromYAML: #"name: "Fix: the parser""#).name,
                       "Fix: the parser")
    }
}

/// Where a Copilot session's turn stands, from the end of its event log.
final class CopilotTurnTests: XCTestCase {
    private func event(_ type: String, _ data: String, at seconds: Int) -> String {
        let stamp = String(format: "2026-09-18T07:17:%02d.000Z", seconds)
        return #"{"type":"\#(type)","data":\#(data),"timestamp":"\#(stamp)"}"#
    }

    private func tail(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    func testAnOpenTurnIsBusy() {
        let turn = CopilotActivity.turn(inTail: tail([
            event("user.message", "{}", at: 1),
            event("assistant.turn_start", #"{"turnId":"0"}"#, at: 2),
            event("tool.execution_start", "{}", at: 3),
        ]))
        XCTAssertEqual(turn?.state, .busy)
        XCTAssertEqual(turn?.since, CopilotActivity.timestamp("2026-09-18T07:17:02.000Z"))
    }

    func testAClosedTurnIsIdle() {
        let turn = CopilotActivity.turn(inTail: tail([
            event("assistant.turn_start", #"{"turnId":"0"}"#, at: 2),
            event("assistant.turn_end", #"{"turnId":"0"}"#, at: 4),
        ]))
        XCTAssertEqual(turn?.state, .idle)
    }

    /// The one state that wants something from you, and the words Copilot used
    /// to ask for it.
    func testAnUnansweredPermissionIsWaiting() {
        let turn = CopilotActivity.turn(inTail: tail([
            event("assistant.turn_start", #"{"turnId":"0"}"#, at: 2),
            event("permission.requested",
                  #"{"requestId":"r1","permissionRequest":{"intention":"Edit file"}}"#, at: 5),
        ]))
        XCTAssertEqual(turn?.state, .waiting)
        XCTAssertEqual(turn?.waitingFor, "Edit file")
        XCTAssertEqual(turn?.since, CopilotActivity.timestamp("2026-09-18T07:17:05.000Z"))
    }

    /// A permission answered mid-turn leaves `permission.completed` as the
    /// newest event while the turn runs on — reading only the last line would
    /// call that idle.
    func testAnAnsweredPermissionLeavesTheTurnBusy() {
        let turn = CopilotActivity.turn(inTail: tail([
            event("assistant.turn_start", #"{"turnId":"0"}"#, at: 2),
            event("permission.requested",
                  #"{"requestId":"r1","permissionRequest":{"intention":"Edit file"}}"#, at: 5),
            event("permission.completed", #"{"requestId":"r1"}"#, at: 6),
        ]))
        XCTAssertEqual(turn?.state, .busy)
        XCTAssertNil(turn?.waitingFor)
    }

    func testWaitingOutranksWorking() {
        let turn = CopilotActivity.turn(inTail: tail([
            event("assistant.turn_start", #"{"turnId":"0"}"#, at: 2),
            event("permission.requested", #"{"requestId":"r1"}"#, at: 5),
        ]))
        XCTAssertEqual(turn?.state, .waiting)
        XCTAssertNil(turn?.waitingFor, "no intention published means none invented")
    }

    /// A session that has shut down is gone, not idle — its window closed with
    /// it, and a row pointing there leads nowhere.
    func testAShutDownSessionIsNotReported() {
        XCTAssertNil(CopilotActivity.turn(inTail: tail([
            event("assistant.turn_end", #"{"turnId":"0"}"#, at: 4),
            event("session.shutdown", "{}", at: 5),
        ])))
    }

    func testAnEmptyOrUnreadableTailIsNothing() {
        XCTAssertNil(CopilotActivity.turn(inTail: Data()))
        XCTAssertNil(CopilotActivity.turn(inTail: tail(["not json", "{}"])))
    }

    /// A window that did not start at byte zero cut its first line in half.
    func testATruncatedFirstLineIsDropped() {
        let lines = [
            #"turnId":"0"},"timestamp":"2026-09-18T07:17:02.000Z"}"#,
            event("assistant.turn_start", #"{"turnId":"9"}"#, at: 8),
        ]
        let turn = CopilotActivity.turn(inTail: tail(lines), truncated: true)
        XCTAssertEqual(turn?.state, .busy)
        XCTAssertEqual(turn?.since, CopilotActivity.timestamp("2026-09-18T07:17:08.000Z"))
    }

    func testTimestampsWithAndWithoutFractionalSeconds() {
        XCTAssertNotNil(CopilotActivity.timestamp("2026-09-18T07:17:11.442Z"))
        XCTAssertNotNil(CopilotActivity.timestamp("2026-09-18T07:17:11Z"))
        XCTAssertNil(CopilotActivity.timestamp("not a date"))
        XCTAssertNil(CopilotActivity.timestamp(nil))
    }
}
