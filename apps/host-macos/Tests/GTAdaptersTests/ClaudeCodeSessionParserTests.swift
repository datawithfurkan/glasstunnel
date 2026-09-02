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

    func testTitleRecordsOutrankTheFirstPromptForCliSessions() {
        let jsonl = """
        {"type":"user","entrypoint":"sdk-cli","cwd":"/Users/developer/Example","sessionId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","timestamp":"2026-05-17T10:00:00.000Z","message":{"role":"user","content":"First prompt text"}}
        {"type":"ai-title","aiTitle":"Generated title","sessionId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}
        {"type":"custom-title","customTitle":"My title","sessionId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}
        {"type":"ai-title","aiTitle":"Regenerated title","sessionId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}
        """

        let parsed = ClaudeCodeSessionParser.parse(jsonl: jsonl, agentID: "claude-code", maxMessages: 24)

        XCTAssertEqual(parsed.threadName, "My title", "A user-set title outranks AI titles, even newer ones.")
        XCTAssertTrue(parsed.titleIsExplicit)

        let withoutTitles = ClaudeCodeSessionParser.parse(
            jsonl: String(jsonl.split(separator: "\n").first!),
            agentID: "claude-code",
            maxMessages: 24
        )
        XCTAssertEqual(withoutTitles.threadName, "First prompt text")
        XCTAssertFalse(withoutTitles.titleIsExplicit)
    }

    func testInterruptedTurnsRenderAsStoppedAndToolResultsAsToolOutput() {
        let jsonl = """
        {"type":"user","cwd":"/Users/developer/Example","sessionId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","timestamp":"2026-05-17T10:00:00.000Z","message":{"role":"user","content":"Run the tests"}}
        {"type":"assistant","sessionId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","timestamp":"2026-05-17T10:00:01.000Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"swift test"}}]}}
        {"type":"user","cwd":"/Users/developer/Example","sessionId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","timestamp":"2026-05-17T10:00:02.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"All tests passed"}]},{"type":"text","text":"<system-reminder>injected context</system-reminder>"}]}}
        {"type":"user","cwd":"/Users/developer/Example","sessionId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","timestamp":"2026-05-17T10:00:03.000Z","message":{"role":"user","content":"[Request interrupted by user]"}}
        """

        let parsed = ClaudeCodeSessionParser.parse(jsonl: jsonl, agentID: "claude-code", maxMessages: 24)

        XCTAssertEqual(parsed.messages.map(\.role), [.user, .tool, .tool, .system])
        XCTAssertEqual(parsed.messages[2].text, "All tests passed", "Injected context blocks are not the user's words.")
        XCTAssertEqual(parsed.messages[3].text, "Stopped")
        XCTAssertEqual(parsed.status, .idle)
        XCTAssertEqual(parsed.statusDetail, "Stopped")
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

    func testClassifiesSessionOwnerByEntrypoint() throws {
        let root = try makeProjectsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(root: root, sessionId: "44444444-4444-4444-4444-444444444444", entrypoint: "claude-desktop")
        try writeSession(root: root, sessionId: "55555555-5555-5555-5555-555555555555", entrypoint: "sdk-cli")
        try writeSession(root: root, sessionId: "66666666-6666-6666-6666-666666666666", entrypoint: nil)

        let all = ClaudeCodeSessionStore.loadSummaries(projectsRoot: root)
        let cliOnly = ClaudeCodeSessionStore.loadSummaries(projectsRoot: root, owner: .cli)
        let desktopOnly = ClaudeCodeSessionStore.loadSummaries(projectsRoot: root, owner: .desktop)

        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(
            Set(cliOnly.map(\.sessionId)),
            ["55555555-5555-5555-5555-555555555555", "66666666-6666-6666-6666-666666666666"],
            "CLI-owned listings must include CLI sessions and legacy transcripts without an entrypoint."
        )
        XCTAssertEqual(desktopOnly.map(\.sessionId), ["44444444-4444-4444-4444-444444444444"])
    }

    func testOwnerLookupBySessionId() throws {
        let root = try makeProjectsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(root: root, sessionId: "44444444-4444-4444-4444-444444444444", entrypoint: "claude-desktop")
        try writeSession(root: root, sessionId: "55555555-5555-5555-5555-555555555555", entrypoint: "sdk-cli")

        XCTAssertEqual(
            ClaudeCodeSessionStore.owner(ofSessionId: "44444444-4444-4444-4444-444444444444", projectsRoot: root),
            .desktop
        )
        XCTAssertEqual(
            ClaudeCodeSessionStore.owner(ofSessionId: "55555555-5555-5555-5555-555555555555", projectsRoot: root),
            .cli
        )
        XCTAssertNil(
            ClaudeCodeSessionStore.owner(ofSessionId: "99999999-9999-9999-9999-999999999999", projectsRoot: root),
            "A session without a transcript yet has no known owner."
        )
        XCTAssertNil(ClaudeCodeSessionStore.owner(ofSessionId: "", projectsRoot: root))
    }

    func testSummaryCacheReparsesOnlyWhenTranscriptChanges() throws {
        let root = try makeProjectsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(root: root, sessionId: "77777777-7777-7777-7777-777777777777", entrypoint: "sdk-cli")
        let url = root
            .appendingPathComponent("-Users-developer-Example", isDirectory: true)
            .appendingPathComponent("77777777-7777-7777-7777-777777777777.jsonl")
        let cache = ClaudeCodeSessionSummaryCache()
        var parseCount = 0
        let parse = {
            parseCount += 1
            return ClaudeCodeSessionParser.parseSummaryPreview(at: url, path: url.path, modifiedAt: Date(timeIntervalSince1970: 100))
        }

        let first = cache.summary(for: url, modifiedAt: Date(timeIntervalSince1970: 100), parse: parse)
        let second = cache.summary(for: url, modifiedAt: Date(timeIntervalSince1970: 100), parse: parse)
        XCTAssertEqual(parseCount, 1, "An unchanged transcript must be served from the cache.")
        XCTAssertEqual(first, second)

        _ = cache.summary(for: url, modifiedAt: Date(timeIntervalSince1970: 200), parse: parse)
        XCTAssertEqual(parseCount, 2, "A changed modification date must re-parse.")

        cache.retain(onlyPaths: [])
        _ = cache.summary(for: url, modifiedAt: Date(timeIntervalSince1970: 200), parse: parse)
        XCTAssertEqual(parseCount, 3, "Entries dropped by retain(onlyPaths:) must re-parse.")
    }

    func testLoadSummariesUsesTheCacheAcrossScans() throws {
        let root = try makeProjectsRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(root: root, sessionId: "88888888-8888-8888-8888-888888888888", entrypoint: "sdk-cli")
        let cache = ClaudeCodeSessionSummaryCache()

        let first = ClaudeCodeSessionStore.loadSummaries(projectsRoot: root, cache: cache)
        let second = ClaudeCodeSessionStore.loadSummaries(projectsRoot: root, cache: cache)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.sessionId), ["88888888-8888-8888-8888-888888888888"])
    }

    /// Opt-in audit against the real ~/.claude store on this machine, mirroring
    /// the Codex GT_CODEX_DESKTOP_REAL_STATE pattern. Run with:
    /// GT_CLAUDE_REAL_STATE=1 swift test --filter testRealClaudeStoreOwnerAudit
    func testRealClaudeStoreOwnerAudit() throws {
        guard ProcessInfo.processInfo.environment["GT_CLAUDE_REAL_STATE"] == "1" else {
            throw XCTSkip("Set GT_CLAUDE_REAL_STATE=1 to audit the real ~/.claude store.")
        }
        let cli = ClaudeCodeSessionStore.loadSummaries(owner: .cli)
        let desktop = ClaudeCodeSessionStore.loadSummaries(owner: .desktop)

        XCTAssertTrue(
            Set(cli.map(\.sessionId)).isDisjoint(with: Set(desktop.map(\.sessionId))),
            "A session must classify as exactly one owner."
        )
        print("GT_CLAUDE_REAL_STATE: cli=\(cli.count) desktop=\(desktop.count)")
        for summary in desktop.prefix(5) {
            print("desktop-owned: \(summary.sessionId) \(summary.workspaceRoot) [\(summary.threadName ?? "untitled")]")
        }
        for summary in cli.prefix(5) {
            print("cli-owned: \(summary.sessionId) \(summary.workspaceRoot)")
        }
    }

    private func makeProjectsRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("-Users-developer-Example", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    private func writeSession(root: URL, sessionId: String, entrypoint: String?) throws {
        let project = root.appendingPathComponent("-Users-developer-Example", isDirectory: true)
        let entrypointField = entrypoint.map { "\"entrypoint\":\"\($0)\"," } ?? ""
        let jsonl = """
        {"type":"user",\(entrypointField)"cwd":"/Users/developer/Example","sessionId":"\(sessionId)","timestamp":"2026-05-17T10:00:00.000Z","message":{"role":"user","content":"Task for \(sessionId.prefix(4))"}}
        """
        try jsonl.write(
            to: project.appendingPathComponent("\(sessionId).jsonl"),
            atomically: true,
            encoding: .utf8
        )
    }
}
