import XCTest
@testable import GTAdapters
import GTProtocol

/// The structured transcript rows both parsers send for phones that render
/// transcripts for reading: titles, previews, pairing ids, timing, errors.
final class TranscriptStructureTests: XCTestCase {
    private let session = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

    func testClaudeToolCallsBecomeTitledRowsAndResultsCarryPreviews() {
        // JSON-escaped newlines inside the JSON string value.
        let output = (1...30).map { "line \($0)" }.joined(separator: "\\n")
        let jsonl = #"""
        {"type":"user","entrypoint":"claude-desktop","cwd":"/Users/dev/App","sessionId":"\#(session)","timestamp":"2026-09-01T10:00:00.000Z","message":{"role":"user","content":"Check the repo"}}
        {"type":"assistant","sessionId":"\#(session)","timestamp":"2026-09-01T10:00:01.000Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"text","text":"Looking."},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"git status --short\n"}},{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file_path":"/Users/dev/App/Package.swift"}}]}}
        {"type":"user","sessionId":"\#(session)","timestamp":"2026-09-01T10:00:03.500Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","content":"// swift-tools-version"},{"type":"tool_result","tool_use_id":"toolu_1","content":"\#(output)","is_error":true}]}}
        """#
        let parsed = ClaudeCodeSessionParser.parse(jsonl: jsonl, agentID: "claude-desktop", maxMessages: 50)
        XCTAssertEqual(parsed.messages.map(\.kind), [.text, .text, .toolCall, .toolCall, .toolResult, .toolResult])

        let assistant = parsed.messages[1]
        XCTAssertEqual(assistant.text, "Looking.")
        XCTAssertTrue(assistant.pendingToolCalls.isEmpty, "the text message no longer carries the calls; the rows do")

        let bashCall = parsed.messages[2]
        XCTAssertEqual(bashCall.role, .tool)
        XCTAssertEqual(bashCall.toolName, "Bash")
        XCTAssertEqual(bashCall.toolCallId, "toolu_1")
        XCTAssertEqual(bashCall.title, "git status --short")
        XCTAssertEqual(bashCall.text, "Using Bash", "older phones still get the old wording")
        XCTAssertEqual(bashCall.pendingToolCalls.map(\.toolCallId), ["toolu_1"])
        XCTAssertEqual(parsed.messages[3].title, "Package.swift")

        let readResult = parsed.messages[4]
        XCTAssertEqual(readResult.toolCallId, "toolu_2")
        XCTAssertEqual(readResult.toolName, "Read")
        XCTAssertEqual(readResult.outputLineCount, 1)
        XCTAssertFalse(readResult.truncated)
        XCTAssertEqual(readResult.durationMs, 2_500)
        XCTAssertNil(parsed.messageDetails[readResult.messageId])

        let bashResult = parsed.messages[5]
        XCTAssertEqual(bashResult.toolCallId, "toolu_1")
        XCTAssertTrue(bashResult.isError)
        XCTAssertEqual(bashResult.outputLineCount, 30)
        XCTAssertTrue(bashResult.truncated)
        XCTAssertEqual(bashResult.text.split(separator: "\n").count, 12, "the snapshot carries a preview")
        XCTAssertEqual(parsed.messageDetails[bashResult.messageId]?.split(separator: "\n").count, 30, "the full text waits on the Mac")
        XCTAssertEqual(parsed.status, .working)
    }

    func testClaudeInterruptIsAnEventAndTitlesCoverTheCommonTools() {
        let jsonl = #"""
        {"type":"user","sessionId":"\#(session)","timestamp":"2026-09-01T10:00:03.000Z","message":{"role":"user","content":"[Request interrupted by user for tool use]"}}
        """#
        let parsed = ClaudeCodeSessionParser.parse(jsonl: jsonl, agentID: "claude-desktop", maxMessages: 50)
        XCTAssertEqual(parsed.messages.map(\.kind), [.event])
        XCTAssertEqual(parsed.messages.first?.text, "Stopped")

        XCTAssertEqual(ClaudeCodeSessionParser.toolTitle(name: "Grep", input: ["pattern": "TODO", "path": "/Users/dev/App/Sources"]), "TODO in Sources")
        XCTAssertEqual(ClaudeCodeSessionParser.toolTitle(name: "Glob", input: ["pattern": "**/*.swift"]), "**/*.swift")
        XCTAssertEqual(ClaudeCodeSessionParser.toolTitle(name: "Edit", input: ["file_path": "/Users/dev/App/Sources/App/RootTabView.swift"]), "RootTabView.swift")
        XCTAssertEqual(ClaudeCodeSessionParser.toolTitle(name: "WebFetch", input: ["url": "https://example.com/docs/api?x=1"]), "example.com/docs/api")
        XCTAssertEqual(ClaudeCodeSessionParser.toolTitle(name: "Task", input: ["description": "Explore the transport layer"]), "Explore the transport layer")
        XCTAssertEqual(ClaudeCodeSessionParser.toolTitle(name: "TodoWrite", input: [:]), "Update todos")
        XCTAssertEqual(ClaudeCodeSessionParser.toolTitle(name: "AskUserQuestion", input: ["questions": []]), "")
        XCTAssertEqual(ClaudeCodeSessionParser.toolTitle(name: "Bash", input: ["command": String(repeating: "x", count: 300)]).count, 120)
    }

    func testCodexShellCallsBecomeRowsWithExitCodesAndDurations() {
        let jsonl = #"""
        {"timestamp":"2026-05-11T11:47:00.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"git status\"]}","call_id":"call-1"}}
        {"timestamp":"2026-05-11T11:47:02.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-1","output":"{\"output\":\"On branch main\\nnothing to commit\",\"metadata\":{\"exit_code\":1,\"duration_seconds\":0.5}}"}}
        {"timestamp":"2026-05-11T11:47:05.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"pnpm test\"}","call_id":"call-2"}}
        {"timestamp":"2026-05-11T11:47:09.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-2","output":"all green"}}
        """#
        let parsed = CodexDesktopSessionParser.parse(jsonl: jsonl, agentID: "codex-window", maxMessages: 24)
        XCTAssertEqual(parsed.messages.map(\.kind), [.toolCall, .toolResult, .toolCall, .toolResult])
        XCTAssertEqual(parsed.messages[0].title, "git status")
        XCTAssertEqual(parsed.messages[0].toolName, "shell")
        XCTAssertEqual(parsed.messages[1].toolCallId, "call-1")
        XCTAssertEqual(parsed.messages[1].text, "On branch main\nnothing to commit")
        XCTAssertTrue(parsed.messages[1].isError)
        XCTAssertEqual(parsed.messages[1].durationMs, 500, "metadata beats the timestamp gap")
        XCTAssertEqual(parsed.messages[1].outputLineCount, 2)
        XCTAssertEqual(parsed.messages[2].title, "pnpm test")
        XCTAssertEqual(parsed.messages[3].text, "all green")
        XCTAssertFalse(parsed.messages[3].isError)
        XCTAssertEqual(parsed.messages[3].durationMs, 4_000, "plain-text output falls back to the timestamps")
    }

    func testPreviewKeepsTwelveLinesAndTheFullTextForDetails() {
        let text = (1...20).map { "row \($0)" }.joined(separator: "\n") + "\n\n"
        let preview = TranscriptPreview.make(text)
        XCTAssertEqual(preview.lineCount, 20)
        XCTAssertTrue(preview.truncated)
        XCTAssertEqual(preview.text.split(separator: "\n").count, 12)
        XCTAssertEqual(preview.detail.split(separator: "\n").count, 20)
        XCTAssertFalse(preview.detailTruncated)

        let short = TranscriptPreview.make("one\ntwo")
        XCTAssertFalse(short.truncated)
        XCTAssertEqual(short.lineCount, 2)
        XCTAssertEqual(TranscriptPreview.make("").lineCount, 0)

        let wide = TranscriptPreview.make(String(repeating: "y", count: 5_000))
        XCTAssertTrue(wide.truncated)
        XCTAssertLessThanOrEqual(wide.text.utf8.count, TranscriptPreview.previewByteCount)

        let huge = TranscriptPreview.make(String(repeating: "z\n", count: 40_000))
        XCTAssertTrue(huge.detailTruncated)
        XCTAssertLessThanOrEqual(huge.detail.utf8.count, TranscriptPreview.detailByteCount)
        XCTAssertEqual(TranscriptPreview.singleLine("  git   status\n--short "), "git status --short")
    }
}
