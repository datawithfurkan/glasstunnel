import XCTest
@testable import GTAdapters
import GTProtocol

final class ClaudeCodeSessionParserTests: XCTestCase {
    func testParsesClaudeMessagesAndSummary() {
        let jsonl = """
        {"type":"user","cwd":"/Users/developer/Documents/GitHub/example","sessionId":"11111111-1111-1111-1111-111111111111","timestamp":"2026-05-17T10:00:00.000Z","message":{"role":"user","content":"Build the settings screen"}}
        {"type":"assistant","cwd":"/Users/developer/Documents/GitHub/example","sessionId":"11111111-1111-1111-1111-111111111111","timestamp":"2026-05-17T10:00:03.000Z","message":{"role":"assistant","content":[{"type":"text","text":"I will inspect the app first."},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}
        """

        let parsed = ClaudeCodeSessionParser.parse(jsonl: jsonl, agentID: "claude-code", maxMessages: 24)

        XCTAssertEqual(parsed.sessionId, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(parsed.workspaceRoot, "/Users/developer/Documents/GitHub/example")
        XCTAssertEqual(parsed.threadName, "Build the settings screen")
        XCTAssertEqual(parsed.messages.count, 2)
        XCTAssertEqual(parsed.messages[0].role, .user)
        XCTAssertEqual(parsed.messages[0].text, "Build the settings screen")
        XCTAssertEqual(parsed.messages[1].role, .assistant)
        XCTAssertEqual(parsed.messages[1].text, "I will inspect the app first.")
        XCTAssertEqual(parsed.messages[1].pendingToolCalls.first?.toolName, "Bash")
    }

    func testSessionStoreSkipsSubagentTranscripts() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = root.appendingPathComponent("-Users-developer-Example", isDirectory: true)
        let subagents = project
            .appendingPathComponent("22222222-2222-2222-2222-222222222222", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let main = project.appendingPathComponent("22222222-2222-2222-2222-222222222222.jsonl")
        let subagent = subagents.appendingPathComponent("agent-1.jsonl")
        let mainJsonl = """
        {"type":"user","cwd":"/Users/developer/Example","sessionId":"22222222-2222-2222-2222-222222222222","timestamp":"2026-05-17T10:00:00.000Z","message":{"role":"user","content":"Main task"}}
        """
        let subagentJsonl = """
        {"type":"user","cwd":"/Users/developer/Example","sessionId":"33333333-3333-3333-3333-333333333333","timestamp":"2026-05-17T10:00:00.000Z","message":{"role":"user","content":"Subagent task"}}
        """
        try mainJsonl.write(to: main, atomically: true, encoding: .utf8)
        try subagentJsonl.write(to: subagent, atomically: true, encoding: .utf8)

        let summaries = ClaudeCodeSessionStore.loadSummaries(projectsRoot: root)

        XCTAssertEqual(summaries.map(\.sessionId), ["22222222-2222-2222-2222-222222222222"])
        XCTAssertEqual(summaries.first?.threadName, "Main task")
    }
}
