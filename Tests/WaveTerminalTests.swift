import XCTest
@testable import Codenotch

/// Reading a Wave block out of a process environment, and the workspace names
/// the switcher groups by.
final class WaveTerminalTests: XCTestCase {
    private let jwt = "eyJhbGciOiJFZERTQSJ9.payload.signature"

    func testBothTheTokenAndTheBlockAreRequired() {
        XCTAssertNil(WaveTerminal.block(inEnvironment: ["WAVETERM_BLOCKID=block-1"]))
        XCTAssertNil(WaveTerminal.block(inEnvironment: ["WAVETERM_JWT=\(jwt)"]))
        XCTAssertEqual(
            WaveTerminal.block(inEnvironment: ["WAVETERM_BLOCKID=block-1", "WAVETERM_JWT=\(jwt)"]),
            WaveTerminal.Block(id: "block-1", tabID: nil, workspaceID: nil, jwt: jwt)
        )
    }

    /// Wave exports `WAVETERM_CONN=` empty for a local block, so a variable
    /// being present is not the same as it having a value.
    func testAnEmptyValueIsNotAValue() {
        XCTAssertNil(WaveTerminal.block(inEnvironment: [
            "WAVETERM_BLOCKID=", "WAVETERM_JWT=\(jwt)"
        ]))
        let block = WaveTerminal.block(inEnvironment: [
            "WAVETERM_BLOCKID=block-1", "WAVETERM_JWT=\(jwt)",
            "WAVETERM_CONN=", "WAVETERM_TABID="
        ])
        XCTAssertNil(block?.tabID)
    }

    func testTabAndWorkspaceAreCarriedWhenPresent() {
        let block = WaveTerminal.block(inEnvironment: [
            "PATH=/usr/bin", "TERM_PROGRAM=waveterm",
            "WAVETERM_BLOCKID=block-1", "WAVETERM_TABID=tab-1",
            "WAVETERM_WORKSPACEID=ws-1", "WAVETERM_JWT=\(jwt)"
        ])
        XCTAssertEqual(block?.tabID, "tab-1")
        XCTAssertEqual(block?.workspaceID, "ws-1")
    }

    /// The environment block also carries argv and unrelated variables; none of
    /// it may be mistaken for a block.
    func testUnrelatedEntriesAreIgnored() {
        XCTAssertNil(WaveTerminal.block(inEnvironment: [
            "/usr/local/bin/claude", "claude", "--resume",
            "PATH=/usr/bin", "WAVE_SOMETHING_ELSE=x"
        ]))
    }

    func testWorkspacesAreKeyedByTheirID() {
        let json = Data("""
            [{"windowId":"w1","workspaceId":"ws-1","name":"Agentisation","color":"#00FFDB"},
             {"windowId":"w2","workspaceId":"ws-2","name":"Calendrier","color":null}]
            """.utf8)
        let found = WaveTerminal.workspaces(fromJSON: json)
        XCTAssertEqual(found["ws-1"]?.name, "Agentisation")
        XCTAssertEqual(found["ws-1"]?.color, "#00FFDB")
        XCTAssertNil(found["ws-2"]?.color)
    }

    /// An id in a group heading would say less than nothing, so a workspace
    /// with no name of its own is left out and the heading stays the app's.
    func testAnUnnamedWorkspaceIsNotListed() {
        let json = Data(#"[{"windowId":"w1","workspaceId":"ws-1","name":""}]"#.utf8)
        XCTAssertTrue(WaveTerminal.workspaces(fromJSON: json).isEmpty)
    }

    func testUnreadableJSONIsEmptyRatherThanFatal() {
        XCTAssertTrue(WaveTerminal.workspaces(fromJSON: Data("not json".utf8)).isEmpty)
    }
}

/// Grouping a session by where it runs.
final class SessionLocationTests: XCTestCase {
    private func location(app: String, workspace: String?) -> SessionLocation {
        SessionLocation(bundleID: WaveTerminal.bundleID, appName: app,
                        wave: WaveTerminal.Block(id: "block-1", tabID: "tab-1",
                                                 workspaceID: "ws-1", jwt: "t"),
                        container: workspace)
    }

    func testTheHeadingNamesTheContainerWhenThereIsOne() {
        XCTAssertEqual(location(app: "Wave", workspace: "Agentisation").heading,
                       "Wave · Agentisation")
    }

    func testTheHeadingIsJustTheAppWithoutOne() {
        XCTAssertEqual(location(app: "Wave", workspace: nil).heading, "Wave")
        XCTAssertEqual(location(app: "Wave", workspace: "").heading, "Wave")
    }

    /// Wave lists only workspaces with a window open; one that has since been
    /// closed leaves the heading as it was rather than showing a UUID.
    func testAnUnknownWorkspaceLeavesTheContainerUnnamed() {
        let named = location(app: "Wave", workspace: nil).named(in: [:])
        XCTAssertNil(named.container)
        XCTAssertEqual(named.heading, "Wave")
    }

    func testAKnownWorkspaceNamesTheContainer() {
        let workspaces = ["ws-1": WaveTerminal.Workspace(id: "ws-1", name: "Agentisation",
                                                         color: nil)]
        XCTAssertEqual(location(app: "Wave", workspace: nil).named(in: workspaces).heading,
                       "Wave · Agentisation")
    }

    /// A session with no Wave block — every other terminal — has nothing to
    /// name and must not be given one.
    func testANonWaveSessionIsNeverNamed() {
        let terminal = SessionLocation(bundleID: "com.apple.Terminal", appName: "Terminal",
                                       wave: nil, container: nil)
        XCTAssertEqual(terminal.named(in: ["ws-1": .init(id: "ws-1", name: "x", color: nil)]),
                       terminal)
    }

    /// The runner's own tree resolves to something nameable rather than an
    /// empty heading.
    func testResolvingThisProcessNamesAnApp() {
        XCTAssertFalse(SessionLocation.resolve(pid: getpid()).appName.isEmpty)
    }
}
