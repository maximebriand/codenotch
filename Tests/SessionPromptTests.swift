import XCTest
@testable import Codenotch

/// The notch's card for a session waiting on you: what it is about, what it is
/// asking, and which wait gets offered.
final class SessionPromptTests: XCTestCase {
    // MARK: - Reading the transcript

    private func tail(_ records: [[String: Any]]) -> Data {
        let lines = records.map { record -> String in
            let data = try! JSONSerialization.data(withJSONObject: record)
            return String(data: data, encoding: .utf8)!
        }
        // A tail starts mid-record; the half line must be skipped, not fatal.
        return Data(("{\"type\":\"assist" + "\n" + lines.joined(separator: "\n") + "\n").utf8)
    }

    private func call(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
        ["type": "assistant",
         "message": ["stop_reason": "tool_use",
                     "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]]
    }

    private func result(_ id: String) -> [String: Any] {
        ["type": "user",
         "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]]]
    }

    func testTheUnansweredCallIsTheQuestion() {
        let prompt = ClaudeTranscript.prompt(inTail: tail([
            call("a", "Bash", ["command": "ls"]),
            result("a"),
            call("b", "Bash", ["command": "git push --force", "description": "Force-push the branch"]),
        ]))
        XCTAssertEqual(prompt.ask, "Run: Force-push the branch")
    }

    func testAnAnsweredCallIsNotAQuestion() {
        let prompt = ClaudeTranscript.prompt(inTail: tail([
            call("a", "Bash", ["command": "ls"]),
            result("a"),
        ]))
        XCTAssertNil(prompt.ask)
    }

    func testAQuestionIsQuotedInItsOwnWords() {
        let prompt = ClaudeTranscript.prompt(inTail: tail([
            call("q", "AskUserQuestion", ["questions": [["question": "Which database should we use?"]]]),
        ]))
        XCTAssertEqual(prompt.ask, "Which database should we use?")
    }

    func testAnMCPToolIsNamedByItsReadablePart() {
        XCTAssertEqual(ClaudeTranscript.describe(tool: "mcp__github__create_pull_request", input: [:]),
                       "Use create_pull_request")
    }

    func testTheLatestTitleWinsAndYoursBeatsTheGeneratedOne() {
        let generated = ClaudeTranscript.prompt(inTail: tail([
            ["type": "ai-title", "aiTitle": "First idea"],
            ["type": "ai-title", "aiTitle": "Trending videos extraction"],
        ]))
        XCTAssertEqual(generated.title, "Trending videos extraction")

        let named = ClaudeTranscript.prompt(inTail: tail([
            ["type": "custom-title", "customTitle": "Release prep"],
            ["type": "ai-title", "aiTitle": "Something else"],
        ]))
        XCTAssertEqual(named.title, "Release prep")
    }

    // MARK: - Which wait is offered

    private func session(_ id: String, _ state: AgentSession.State, since: TimeInterval,
                         pid: pid_t? = 1) -> AgentSession {
        AgentSession(id: id, name: id, detail: "", state: state, waitingFor: nil,
                     since: Date(timeIntervalSince1970: since), processID: pid)
    }

    func testTheNewestWaitIsOfferedWithACountOfTheRest() {
        let sessions = ["claude": [session("old", .waiting, since: 1),
                                   session("new", .waiting, since: 2),
                                   session("busy", .busy, since: 3)]]
        let prompt = SessionPrompt.current(sessions: sessions, dismissed: [])
        XCTAssertEqual(prompt?.session.id, "new")
        XCTAssertEqual(prompt?.others, 1)
    }

    func testAnAnsweredWaitGivesWayToTheNext() {
        let sessions = ["claude": [session("old", .waiting, since: 1),
                                   session("new", .waiting, since: 2)]]
        let first = SessionPrompt.current(sessions: sessions, dismissed: [])!
        let next = SessionPrompt.current(sessions: sessions, dismissed: [first.id])
        XCTAssertEqual(next?.session.id, "old")
        XCTAssertEqual(next?.others, 0)
    }

    func testTheSameSessionBlockingAgainIsANewQuestion() {
        let before = SessionPrompt.current(sessions: ["claude": [session("a", .waiting, since: 1)]],
                                           dismissed: [])!
        let again = SessionPrompt.current(sessions: ["claude": [session("a", .waiting, since: 5)]],
                                          dismissed: [before.id])
        XCTAssertEqual(again?.session.id, "a")
    }

    func testASessionWithNoWindowIsNotOffered() {
        let prompt = SessionPrompt.current(
            sessions: ["cursor": [session("c", .waiting, since: 1, pid: nil)]], dismissed: [])
        XCTAssertNil(prompt)
    }

    func testATurnSeenEndingIsOfferedWithWhatItSaid() {
        let done = AgentSession(id: "t", name: "treg-58", detail: "", state: .idle, waitingFor: nil,
                                since: Date(timeIntervalSince1970: 3), processID: 1,
                                topic: "Brief", lastReply: "Here is the plan")
        let sessions = ["claude": [done, session("quiet", .idle, since: 4)]]
        let prompt = SessionPrompt.current(
            sessions: sessions,
            finished: [SessionPrompt.key(providerID: "claude", session: done)],
            dismissed: [])
        XCTAssertEqual(prompt?.session.id, "t", "an idle session nobody saw finish is not news")
        XCTAssertEqual(prompt?.kind, .finished)
        XCTAssertEqual(prompt?.title, "Brief")
        XCTAssertEqual(prompt?.message, "Here is the plan")
        XCTAssertEqual(prompt?.others, 0)
    }

    func testTheLastThingItSaidIsTheReply() {
        let prompt = ClaudeTranscript.prompt(inTail: tail([
            ["type": "assistant", "message": ["stop_reason": "end_turn",
                                              "content": [["type": "text", "text": "First **draft**"]]]],
            ["type": "assistant", "isSidechain": true,
             "message": ["content": [["type": "text", "text": "subagent report"]]]],
            ["type": "assistant", "message": ["stop_reason": "end_turn",
                                              "content": [["type": "text", "text": "Final\n\n  answer"]]]],
        ]))
        XCTAssertEqual(prompt.reply, "Final answer")
    }

    func testFinishedWaitsAreForgotten() {
        let waiting = session("a", .waiting, since: 1)
        let answered: Set<String> = [SessionPrompt.key(providerID: "claude", session: waiting), "gone"]
        let kept = SessionPrompt.pruned(answered, sessions: ["claude": [waiting]])
        XCTAssertEqual(kept, [SessionPrompt.key(providerID: "claude", session: waiting)])
    }
}
