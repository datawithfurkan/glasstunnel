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

    func testCodexCustomToolCallsBecomeRowsWithHeadersParsed() {
        let jsonl = #"""
        {"timestamp":"2026-09-03T09:00:00.000Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"c1","name":"exec","input":"const r = await tools.exec_command({cmd:\"pnpm test --filter \\\"web\\\"\",\"workdir\":\"/x\"});\nreturn r;"}}
        {"timestamp":"2026-09-03T09:00:01.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":[{"type":"input_text","text":"Script completed\nWall time 0.1 seconds\nOutput:\n\nok 3 tests\n"}]}}
        {"timestamp":"2026-09-03T09:00:02.000Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"c2","name":"apply_patch","input":"*** Begin Patch\n*** Update File: /repo/AGENTS.md\n@@\n-old\n+new\n*** Add File: /repo/src/new.ts\n+export {}\n*** End Patch"}}
        {"timestamp":"2026-09-03T09:00:03.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c2","output":"Exit code: 1\nWall time: 0 seconds\nOutput:\nFailed to apply"}}
        {"timestamp":"2026-09-03T09:00:04.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\": \"git status\", \"workdir\": \"/repo\"}","call_id":"c3"}}
        {"timestamp":"2026-09-03T09:00:05.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"c3","output":"Chunk ID: a036bd\nWall time: 2.5000 seconds\nProcess exited with code 0\nOriginal token count: 12\nOutput:\nOn branch main"}}
        {"timestamp":"2026-09-03T09:00:06.000Z","type":"response_item","payload":{"type":"function_call","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"a\",\"status\":\"in_progress\"}]}","call_id":"c4"}}
        {"timestamp":"2026-09-03T09:00:07.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"c4","output":"Plan updated"}}
        {"timestamp":"2026-09-03T09:00:08.000Z","type":"response_item","payload":{"type":"function_call","name":"view_image","arguments":"{\"path\":\"/tmp/shots/wave1_sheet_01.jpg\",\"detail\":\"high\"}","call_id":"c5"}}
        {"timestamp":"2026-09-03T09:00:09.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"c5","output":[{"type":"input_image","image_url":"data:image/jpeg;base64,xx"}]}}
        """#
        let parsed = CodexDesktopSessionParser.parse(jsonl: jsonl, agentID: "codex-window", maxMessages: 24)
        XCTAssertEqual(parsed.messages.map(\.kind), [.toolCall, .toolResult, .toolCall, .toolResult, .toolCall, .toolResult, .toolCall, .toolResult, .toolCall, .toolResult])

        XCTAssertEqual(parsed.messages[0].toolName, "exec")
        XCTAssertEqual(parsed.messages[0].title, "pnpm test --filter \"web\"", "the command inside the exec script, unescaped")
        XCTAssertEqual(parsed.messages[0].toolCallId, "c1")
        XCTAssertEqual(parsed.messages[1].text.trimmingCharacters(in: .whitespacesAndNewlines), "ok 3 tests", "the header above Output: is gone")
        XCTAssertEqual(parsed.messages[1].durationMs, 100)
        XCTAssertFalse(parsed.messages[1].isError)
        XCTAssertEqual(parsed.messages[1].outputLineCount, 1)

        XCTAssertEqual(parsed.messages[2].title, "AGENTS.md, new.ts")
        XCTAssertTrue(parsed.messages[3].isError)
        XCTAssertEqual(parsed.messages[3].text, "Failed to apply")

        XCTAssertEqual(parsed.messages[4].title, "git status")
        XCTAssertEqual(parsed.messages[5].text, "On branch main")
        XCTAssertEqual(parsed.messages[5].durationMs, 2_500)
        XCTAssertFalse(parsed.messages[5].isError)

        XCTAssertEqual(parsed.messages[6].title, "Update plan")
        XCTAssertEqual(parsed.messages[7].text, "Plan updated")
        XCTAssertEqual(parsed.messages[8].title, "wave1_sheet_01.jpg")
        XCTAssertEqual(parsed.messages[9].text, "[image]")
    }

    func testCodexOutputHeaderParsingLeavesOrdinaryTextAlone() {
        let plain = CodexDesktopSessionParser.parseOutputHeader("Build finished.\nOutput: 3 files")
        XCTAssertEqual(plain.text, "Build finished.\nOutput: 3 files")
        XCTAssertNil(plain.durationMs)

        let failed = CodexDesktopSessionParser.parseOutputHeader("Script failed\nWall time 1.5 seconds\nOutput:\nboom")
        XCTAssertTrue(failed.isError)
        XCTAssertEqual(failed.text, "boom")
        XCTAssertEqual(failed.durationMs, 1_500)

        let stillRunning = CodexDesktopSessionParser.parseOutputHeader("Chunk ID: 74bb26\nWall time: 30.0017 seconds\nProcess running with session ID 61152\nOriginal token count: 0\nOutput:\n")
        XCTAssertEqual(stillRunning.text, "")
        XCTAssertFalse(stillRunning.isError)
        XCTAssertEqual(stillRunning.durationMs, 30_002)
    }

    func testCodexThreadRuntimeSelectionFollowsTheNewestRecord() {
        let jsonl = #"""
        {"timestamp":"2026-09-03T09:00:00.000Z","type":"session_meta","payload":{"cwd":"/repo","originator":"Codex Desktop","source":"vscode"}}
        {"timestamp":"2026-09-03T09:00:01.000Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-5.6-sol","reasoning_effort":"ultra","service_tier":"priority"}}}
        {"timestamp":"2026-09-03T09:00:02.000Z","type":"turn_context","payload":{"cwd":"/repo","model":"gpt-5.5","effort":"xhigh"}}
        """#
        let parsed = CodexDesktopSessionParser.parse(jsonl: jsonl, agentID: "codex-window", maxMessages: 24)
        XCTAssertEqual(parsed.runtimeSelection, CodexRuntimeSelection(modelId: "gpt-5.5", reasoningEffort: "xhigh", fastMode: false))

        let switched = jsonl + "\n" + #"""
        {"timestamp":"2026-09-03T09:00:03.000Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-5.6-luna","reasoning_effort":"low","service_tier":"fast"}}}
        """#
        XCTAssertEqual(
            CodexDesktopSessionParser.parse(jsonl: switched, agentID: "codex-window", maxMessages: 24).runtimeSelection,
            CodexRuntimeSelection(modelId: "gpt-5.6-luna", reasoningEffort: "low", fastMode: true),
            "a settings change after the last turn is what the thread runs next"
        )

        let noEffort = jsonl + "\n" + #"""
        {"timestamp":"2026-09-03T09:00:04.000Z","type":"turn_context","payload":{"model":"gpt-5.4-mini","effort":null}}
        """#
        XCTAssertEqual(
            CodexDesktopSessionParser.parse(jsonl: noEffort, agentID: "codex-window", maxMessages: 24).runtimeSelection,
            CodexRuntimeSelection(modelId: "gpt-5.4-mini", reasoningEffort: nil, fastMode: false)
        )

        let bare = #"{"type":"session_meta","payload":{"cwd":"/repo"}}"#
        XCTAssertNil(CodexDesktopSessionParser.parse(jsonl: bare, agentID: "codex-window", maxMessages: 24).runtimeSelection)
    }

    func testCodexInjectedContextStaysOutOfUserBubbles() {
        let jsonl = #"""
        {"timestamp":"2026-09-03T09:00:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n  <cwd>/repo</cwd>\n</environment_context>"}]}}
        {"timestamp":"2026-09-03T09:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<recommended_plugins>\n- x\n</recommended_plugins>"},{"type":"input_text","text":"fix the crash"},{"type":"input_text","text":"\n# Files mentioned by the user\n"},{"type":"input_text","text":"<image name=[Image #1] path=\"/tmp/a.png\">"},{"type":"input_image","image_url":"data:image/png;base64,xx"},{"type":"input_text","text":"</image>"}]}}
        {"timestamp":"2026-09-03T09:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<skill name=\"brainstorming\">\nlong text\n</skill>"},{"type":"input_text","text":"$brainstorming a name"}]}}
        {"timestamp":"2026-09-03T09:00:03.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<div>keep me</div>"}]}}
        {"timestamp":"2026-09-03T09:00:04.000Z","type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}
        """#
        let parsed = CodexDesktopSessionParser.parse(jsonl: jsonl, agentID: "codex-window", maxMessages: 24)
        XCTAssertEqual(parsed.messages.map(\.text), ["fix the crash\n\n[image]", "$brainstorming a name", "<div>keep me</div>", "Stopped"])
        XCTAssertEqual(parsed.messages.last?.kind, .event)
        XCTAssertEqual(parsed.messages.last?.role, .system)
        XCTAssertEqual(parsed.status, .idle)
        XCTAssertTrue(CodexDesktopSessionParser.isInjectedContext("<user_instructions>\nx\n</user_instructions>"))
        XCTAssertTrue(CodexDesktopSessionParser.isInjectedContext("<some_future_block id=\"1\">..."))
        XCTAssertFalse(CodexDesktopSessionParser.isInjectedContext("<b>bold</b> please"))
        XCTAssertFalse(CodexDesktopSessionParser.isInjectedContext(""))
    }

    func testCodexUserTextLosesTheComposersMarkdownEscapes() {
        let jsonl = #"""
        {"timestamp":"2026-09-03T09:00:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Reply with exactly GT\\_CODEX\\_APP\\_1 and \\*nothing\\* else. Path C:\\Users stays."}]}}
        {"timestamp":"2026-09-03T09:00:01.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"GT\\_CODEX\\_APP\\_1"}]}}
        """#
        let parsed = CodexDesktopSessionParser.parse(jsonl: jsonl, agentID: "codex-window", maxMessages: 24)
        XCTAssertEqual(parsed.messages[0].text, "Reply with exactly GT_CODEX_APP_1 and *nothing* else. Path C:\\Users stays.")
        XCTAssertEqual(parsed.messages[1].text, "GT\\_CODEX\\_APP\\_1", "assistant Markdown is rendered by the phone, not rewritten here")
        XCTAssertEqual(CodexDesktopSessionParser.unescapeMarkdown("no escapes"), "no escapes")
        XCTAssertEqual(CodexDesktopSessionParser.unescapeMarkdown("trailing\\"), "trailing\\")
    }
}
