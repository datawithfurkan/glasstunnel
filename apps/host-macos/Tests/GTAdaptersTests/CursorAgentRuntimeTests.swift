import XCTest
@testable import GTAdapters
import GTProtocol

/// The Cursor Agent CLI card: local commands, model handling, the stream-json
/// parser, and the adapter driving a fake `cursor-agent` through a turn, an
/// interrupt, and a rejected login.
final class CursorAgentRuntimeTests: XCTestCase {
    // MARK: - Runtime values

    func testModelNormalizationAcceptsAnyTokenButRejectsUnsafeValues() throws {
        XCTAssertEqual(try CursorAgentAdapter.normalizedModel("  gpt-5.4-nano  "), "gpt-5.4-nano")
        XCTAssertEqual(try CursorAgentAdapter.normalizedModel("composer-2.5-fast"), "composer-2.5-fast")
        XCTAssertEqual(try CursorAgentAdapter.normalizedModel("claude-opus-4-8[context=1m]"), "claude-opus-4-8[context=1m]")
        XCTAssertThrowsError(try CursorAgentAdapter.normalizedModel(""))
        XCTAssertThrowsError(try CursorAgentAdapter.normalizedModel("gpt-5.4 nano"))
        XCTAssertThrowsError(try CursorAgentAdapter.normalizedModel("gpt-5.4-nano\""))
    }

    func testLocalCommandsAreRecognised() {
        XCTAssertEqual(CursorAgentAdapter.localCommand(in: "/mode plan"), .mode("plan"))
        XCTAssertEqual(CursorAgentAdapter.localCommand(in: "  /MODE Ask "), .mode("ask"))
        XCTAssertEqual(CursorAgentAdapter.localCommand(in: "/model gpt-5.4-nano"), .model("gpt-5.4-nano"))
        XCTAssertEqual(CursorAgentAdapter.localCommand(in: "/new"), .newChat)
        XCTAssertNil(CursorAgentAdapter.localCommand(in: "explain /mode plan to me"))
        XCTAssertNil(CursorAgentAdapter.localCommand(in: "/unknown"))
    }

    func testModelListParsingKeepsIdsAndLabels() {
        let output = """
        Available models:
          gpt-5.4-nano - GPT-5.4 Nano
          composer-2.5-fast Composer 2.5 Fast
        * auto
        sonnet-4-thinking
        Use --model <id> to select one.
        """
        let options = CursorAgentAdapter.parseModelList(output)
        XCTAssertEqual(options.map(\.id), ["gpt-5.4-nano", "composer-2.5-fast", "auto", "sonnet-4-thinking"])
        XCTAssertEqual(options[0].label, "GPT-5.4 Nano")
        XCTAssertEqual(options[1].label, "Composer 2.5 Fast")
        XCTAssertEqual(options[3].label, "sonnet-4-thinking")
        XCTAssertTrue(CursorAgentAdapter.isAuthenticationFailure("Error: Authentication required. Please run 'agent login' first, or set CURSOR_API_KEY environment variable."))
        XCTAssertFalse(CursorAgentAdapter.isAuthenticationFailure("all good"))
    }

    func testRuntimeControlsExposeAnEditableModelAndTheModeNote() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gt-cursor-none-\(UUID().uuidString)", isDirectory: true)
        let adapter = CursorAgentAdapter(executable: "/usr/bin/true", cwd: NSTemporaryDirectory(), cursorRoot: root)
        let controls = adapter.runtimeControls()
        XCTAssertEqual(controls?.modelId, CursorAgentAdapter.defaultModel)
        XCTAssertEqual(controls?.modelLabel, "GPT-5.4 Nano")
        XCTAssertEqual(controls?.modelOptions.map(\.id), [CursorAgentAdapter.defaultModel])
        XCTAssertEqual(controls?.supportsModelSelection, true)
        XCTAssertEqual(controls?.editable, true)
        XCTAssertEqual(controls?.appliesOn, .immediate)
        XCTAssertEqual(controls?.note, CursorAgentAdapter.askModeNote)
        XCTAssertEqual(adapter.workspaceForTesting(), NSTemporaryDirectory())
    }

    // MARK: - Stream parser

    func testStreamParserBuildsRowsFromDocumentedEvents() throws {
        var clock: Int64 = 1_000
        let parser = CursorAgentStreamParser(agentID: "cursor-agent", turnId: "t1", now: { clock })
        XCTAssertTrue(parser.feed(#"{"type":"system","subtype":"init","session_id":"abc","model":"gpt-5.4-nano","cwd":"/tmp"}"# + "\n"))
        XCTAssertEqual(parser.sessionId, "abc")
        XCTAssertEqual(parser.model, "gpt-5.4-nano")
        XCTAssertTrue(parser.feed(#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Read README"}]}}"# + "\n"))
        XCTAssertTrue(parser.promptEchoed)
        XCTAssertTrue(parser.feed(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Read"}]}}"# + "\n"))
        XCTAssertTrue(parser.feed(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ing."}]}}"# + "\n"))
        XCTAssertEqual(parser.assistantText, "Reading.")
        XCTAssertTrue(parser.feed(#"{"type":"tool_call","subtype":"started","call_id":"c1","tool_call":{"readToolCall":{"args":{"path":"/tmp/App/README.md"}}}}"# + "\n"))
        XCTAssertTrue(parser.hasPendingRows)
        clock = 3_500
        // The completed event arrives split across two chunks.
        let completed = ##"{"type":"tool_call","subtype":"completed","call_id":"c1","tool_call":{"readToolCall":{"args":{"path":"/tmp/App/README.md"},"result":{"success":{"content":"# App\nline 2","totalLines":2}}}}}"## + "\n"
        let cut = completed.index(completed.startIndex, offsetBy: 40)
        XCTAssertFalse(parser.feed(String(completed[..<cut])))
        XCTAssertTrue(parser.feed(String(completed[cut...])))
        XCTAssertFalse(parser.hasPendingRows)
        XCTAssertTrue(parser.feed(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":" Done."}]}}"# + "\n"))
        XCTAssertFalse(parser.feed(#"{"type":"result","subtype":"success","duration_ms":2600,"is_error":false,"result":"Reading. Done.","session_id":"abc"}"#))
        XCTAssertTrue(parser.finish(), "a last line without a newline is flushed at the end")
        XCTAssertEqual(parser.outcome, CursorAgentStreamParser.Outcome(isError: false, text: "Reading. Done.", durationMs: 2_600))
        XCTAssertEqual(parser.assistantText, "Reading. Done.")

        let built = parser.messages(startedAtUnixMs: 900)
        XCTAssertEqual(built.messages.map(\.kind), [.toolCall, .toolResult, .text])
        let call = built.messages[0]
        XCTAssertEqual(call.messageId, "cursor-agent-t1-c0")
        XCTAssertEqual(call.toolName, "Read")
        XCTAssertEqual(call.toolCallId, "c1")
        XCTAssertEqual(call.title, "README.md")
        XCTAssertEqual(call.atUnixMs, 1_000)
        let result = built.messages[1]
        XCTAssertEqual(result.toolCallId, "c1")
        XCTAssertEqual(result.text, "# App\nline 2")
        XCTAssertEqual(result.outputLineCount, 2)
        XCTAssertEqual(result.durationMs, 2_500)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(built.messages[2].text, "Reading. Done.")
        XCTAssertEqual(built.messages[2].role, .assistant)
        XCTAssertTrue(built.details.isEmpty)
    }

    func testStreamParserHandlesFailuresPartialArgumentsAndStrayLines() {
        let parser = CursorAgentStreamParser(agentID: "cursor-agent", turnId: "t2", now: { 5_000 })
        parser.feed("Warning: something on stdout\n")
        XCTAssertEqual(parser.stray, ["Warning: something on stdout"])
        parser.feed(#"{"type":"tool_call","subtype":"started","call_id":"s1","tool_call":{"partialToolCall":{}}}"# + "\n")
        XCTAssertEqual(parser.rows.first?.name, "Partial")
        parser.feed(#"{"type":"tool_call","subtype":"completed","call_id":"s1","tool_call":{"shellToolCall":{"args":{"command":"pnpm test"},"result":{"error":{"message":"exit 1"}}}}}"# + "\n")
        XCTAssertEqual(parser.rows.count, 1, "the completed event updates the started row by call id")
        XCTAssertEqual(parser.rows[0].title, "pnpm test", "a title learned late still labels the row")
        XCTAssertTrue(parser.rows[0].isError)
        XCTAssertEqual(parser.rows[0].resultText, "exit 1")
        parser.feed(##"{"type":"tool_call","subtype":"completed","call_id":"m1","tool_call":{"mcpToolCall":{"name":"browser_click","args":{"selector":"#go"},"result":{"success":{"text":"clicked"}}}}}"## + "\n")
        XCTAssertEqual(parser.rows[1].name, "browser_click")
        XCTAssertEqual(parser.rows[1].resultText, "clicked")
        parser.feed(#"{"type":"result","subtype":"error","is_error":true,"result":"Model unavailable"}"# + "\n")
        XCTAssertEqual(parser.outcome?.isError, true)
        XCTAssertEqual(parser.outcome?.text, "Model unavailable")
        XCTAssertEqual(parser.assistantText, "", "an error result is not a reply")

        XCTAssertEqual(CursorAgentStreamParser.toolName(fromCaseKey: "semSearchToolCall", payload: [:], fallback: ""), "SemSearch")
        XCTAssertEqual(CursorAgentStreamParser.toolName(fromCaseKey: "", payload: [:], fallback: "Grep"), "Grep")
        let long = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let summary = CursorAgentStreamParser.resultSummary(["success": ["stdout": long]], subtype: "completed")
        XCTAssertEqual(summary.0, long)
        XCTAssertFalse(summary.1)
        let listed = CursorAgentStreamParser.resultSummary(["success": ["files": [["path": "/a"], ["path": "/b"]]]], subtype: "completed")
        XCTAssertEqual(listed.0, "/a\n/b")
        let fullReply = CursorAgentStreamParser(agentID: "x", turnId: "t3")
        fullReply.feed(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello"}]}}"# + "\n")
        fullReply.feed(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello world"}]}}"# + "\n")
        XCTAssertEqual(fullReply.assistantText, "Hello world", "a growing full text replaces rather than repeats")

        // The real CLI: timestamped deltas, then the whole reply once more without a timestamp.
        let real = CursorAgentStreamParser(agentID: "x", turnId: "t4")
        real.feed(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"GT"}]},"session_id":"s","timestamp_ms":1788437377768}"# + "\n")
        real.feed(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"_OK"}]},"session_id":"s","timestamp_ms":1788437377833}"# + "\n")
        real.feed(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"GT_OK"}]},"session_id":"s"}"# + "\n")
        XCTAssertEqual(real.assistantText, "GT_OK", "the final repeat replaces the deltas instead of doubling the reply")
        real.feed(#"{"type":"result","subtype":"success","duration_ms":9772,"is_error":false,"result":"GT_OK","session_id":"s","request_id":"r","usage":{"inputTokens":19481,"outputTokens":9}}"# + "\n")
        XCTAssertEqual(real.outcome?.text, "GT_OK")
        XCTAssertEqual(real.outcome?.durationMs, 9_772)
    }

    // MARK: - Adapter with a fake CLI

    func testAdapterCreatesAChatStreamsATurnAndReportsDone() async throws {
        let fixture = try FakeCursorAgent.make(prefix: "gt-cursor-agent-turn", behavior: "turn")
        defer { fixture.cleanUp() }
        let adapter = fixture.adapter()
        let snapshots = SnapshotCollector(adapter.observeState())

        try await adapter.start()
        let ready = try await snapshots.wait(timeout: 5) { $0.status == .idle && $0.statusDetail == "ready" }
        XCTAssertEqual(ready.availableTargets?.last?.targetId, CursorAgentAdapter.newChatTargetId, "a new chat can always be started from the phone")
        XCTAssertEqual(ready.availableTargets?.last?.threadLabel, "New chat")

        try await adapter.sendInput("Read the README", submit: true)
        let done = try await snapshots.wait(timeout: 10) { $0.status == .done }
        XCTAssertEqual(done.statusDetail, CursorConversationBuilder.doneDetail)
        XCTAssertEqual(done.recentMessages.map(\.kind), [.text, .toolCall, .toolResult, .text])
        XCTAssertEqual(done.recentMessages[0].role, .user)
        XCTAssertEqual(done.recentMessages[0].text, "Read the README")
        XCTAssertEqual(done.recentMessages[1].toolName, "Read")
        XCTAssertEqual(done.recentMessages[1].title, "README.md")
        XCTAssertEqual(done.recentMessages[2].text, "# App")
        XCTAssertEqual(done.recentMessages[3].text, "The README says App.")
        XCTAssertEqual(adapter.selectedChatIdForTesting(), FakeCursorAgent.chatId, "the chat created by create-chat is the one resumed")
        XCTAssertTrue(snapshots.all.contains { $0.status == .working && $0.recentMessages.contains { $0.kind == .toolCall } }, "the tool row was published while the turn ran")

        let arguments = try fixture.recordedArguments()
        XCTAssertEqual(arguments.first, "--print")
        XCTAssertTrue(arguments.contains("--stream-partial-output"))
        XCTAssertEqual(arguments.last, "Read the README")
        XCTAssertEqual(value(after: "--resume", in: arguments), FakeCursorAgent.chatId)
        XCTAssertEqual(value(after: "--workspace", in: arguments), fixture.workspace.path)
        XCTAssertEqual(value(after: "--mode", in: arguments), "ask")
        XCTAssertEqual(value(after: "--model", in: arguments), CursorAgentAdapter.defaultModel)
        XCTAssertNil(adapter.messageDetail("nope"))
        await adapter.stop()
    }

    func testLocalCommandsSwitchModeAndModelAndAgentModeStaysOff() async throws {
        let fixture = try FakeCursorAgent.make(prefix: "gt-cursor-agent-mode", behavior: "turn")
        defer { fixture.cleanUp() }
        let adapter = fixture.adapter()
        let snapshots = SnapshotCollector(adapter.observeState())
        try await adapter.start()
        _ = try await snapshots.wait(timeout: 5) { $0.statusDetail == "ready" }

        try await adapter.sendInput("/mode plan", submit: true)
        let planned = try await snapshots.wait(timeout: 5) { $0.statusDetail == "settings updated" }
        XCTAssertEqual(planned.runtimeControls?.note, CursorAgentAdapter.planModeNote)
        XCTAssertEqual(adapter.modeForTesting(), "plan")
        XCTAssertEqual(planned.recentMessages.last?.kind, .event)
        XCTAssertEqual(planned.recentMessages.last?.text, "Mode: plan")

        do {
            try await adapter.sendInput("/mode agent", submit: true)
            XCTFail("agent mode must stay off until permissions can reach the phone")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not enabled"))
        }
        XCTAssertEqual(adapter.modeForTesting(), "plan")

        try await adapter.sendInput("/model composer-2.5-fast", submit: true)
        XCTAssertEqual(adapter.runtimeControls()?.modelId, "composer-2.5-fast")
        XCTAssertTrue(adapter.runtimeControls()?.modelOptions.contains { $0.id == "composer-2.5-fast" } ?? false)

        try await adapter.sendInput("Plan the change", submit: true)
        _ = try await snapshots.wait(timeout: 10) { $0.status == .done }
        let arguments = try fixture.recordedArguments()
        XCTAssertEqual(value(after: "--mode", in: arguments), "plan")
        XCTAssertEqual(value(after: "--model", in: arguments), "composer-2.5-fast")

        try await adapter.updateRuntimeSettings(AgentRuntimeSettingsUpdate(agentId: adapter.agentID, modelId: " gpt-5.4-nano "))
        XCTAssertEqual(adapter.runtimeControls()?.modelId, "gpt-5.4-nano")
        await adapter.stop()
    }

    func testInterruptEndsTheTurnAsStopped() async throws {
        let fixture = try FakeCursorAgent.make(prefix: "gt-cursor-agent-stop", behavior: "slow")
        defer { fixture.cleanUp() }
        let adapter = fixture.adapter()
        let snapshots = SnapshotCollector(adapter.observeState())
        try await adapter.start()
        _ = try await snapshots.wait(timeout: 5) { $0.statusDetail == "ready" }

        let turn = Task { try await adapter.sendInput("Count forever", submit: true) }
        _ = try await snapshots.wait(timeout: 10) { snapshot in
            snapshot.status == .working && snapshot.recentMessages.contains { $0.kind == .toolCall && $0.toolName == "Shell" }
        }
        try await adapter.interrupt()
        _ = try await turn.value
        let stopped = try await snapshots.wait(timeout: 10) { $0.status == .idle && $0.statusDetail == CursorConversationBuilder.stoppedDetail }
        XCTAssertEqual(stopped.recentMessages.last?.kind, .event)
        XCTAssertEqual(stopped.recentMessages.last?.text, "Stopped")
        XCTAssertTrue(stopped.recentMessages.contains { $0.kind == .toolCall }, "the interrupted row stays in the transcript")

        // The card recovers for the next prompt.
        fixture.setBehavior("turn")
        try await adapter.sendInput("Read the README", submit: true)
        _ = try await snapshots.wait(timeout: 10) { $0.status == .done }
        await adapter.stop()
    }

    func testRejectedLoginIsReportedAsAnErrorWithTheRemedy() async throws {
        let fixture = try FakeCursorAgent.make(prefix: "gt-cursor-agent-auth", behavior: "auth")
        defer { fixture.cleanUp() }
        let adapter = fixture.adapter()
        let snapshots = SnapshotCollector(adapter.observeState())
        try await adapter.start()
        _ = try await snapshots.wait(timeout: 5) { $0.statusDetail == "ready" }

        do {
            try await adapter.sendInput("Hello", submit: true)
            XCTFail("a rejected login must surface")
        } catch {
            XCTAssertEqual(error.localizedDescription, CursorAgentAdapter.loginDetail)
        }
        let failed = try await snapshots.wait(timeout: 5) { $0.status == .error }
        XCTAssertEqual(failed.statusDetail, CursorAgentAdapter.loginDetail)
        await adapter.stop()
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

// MARK: - Fixtures

/// A `cursor-agent` stand-in: `create-chat` prints a fixed id; a prompt run
/// records its arguments and prints stream-json events according to the
/// behavior file (`turn`, `slow`, or `auth`).
private struct FakeCursorAgent {
    static let chatId = "11111111-2222-4333-8444-555555555555"

    let directory: URL
    let executable: URL
    let workspace: URL
    let cursorRoot: URL
    let argumentsFile: URL
    let behaviorFile: URL
    let hooksFile: URL

    static func make(prefix: String, behavior: String) throws -> FakeCursorAgent {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        let cursorRoot = directory.appendingPathComponent("cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cursorRoot.appendingPathComponent("chats"), withIntermediateDirectories: true)
        let argumentsFile = directory.appendingPathComponent("arguments.txt")
        let behaviorFile = directory.appendingPathComponent("behavior.txt")
        try behavior.write(to: behaviorFile, atomically: true, encoding: .utf8)
        let executable = bin.appendingPathComponent("cursor-agent")
        let script = """
        #!/bin/sh
        if [ "$1" = "create-chat" ]; then
          echo "\(chatId)"
          exit 0
        fi
        : > "\(argumentsFile.path)"
        for arg in "$@"; do
          printf '%s\\n' "$arg" >> "\(argumentsFile.path)"
        done
        behavior="$(cat "\(behaviorFile.path)")"
        case "$behavior" in
          auth)
            echo "Error: Authentication required. Please run 'agent login' first, or set CURSOR_API_KEY environment variable." >&2
            exit 1
            ;;
          slow)
            echo '{"type":"system","subtype":"init","session_id":"\(chatId)","model":"gpt-5.4-nano"}'
            echo '{"type":"tool_call","subtype":"started","call_id":"s1","tool_call":{"shellToolCall":{"args":{"command":"sleep 30"}}}}'
            exec sleep 30
            ;;
          *)
            echo '{"type":"system","subtype":"init","session_id":"\(chatId)","model":"gpt-5.4-nano"}'
            echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"prompt"}]}}'
            echo '{"type":"tool_call","subtype":"started","call_id":"c1","tool_call":{"readToolCall":{"args":{"path":"\(workspace.path)/README.md"}}}}'
            sleep 0.3
            echo '{"type":"tool_call","subtype":"completed","call_id":"c1","tool_call":{"readToolCall":{"args":{"path":"\(workspace.path)/README.md"},"result":{"success":{"content":"# App","totalLines":1}}}}}'
            echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"The README "}]}}'
            echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"says App."}]}}'
            echo '{"type":"result","subtype":"success","duration_ms":400,"is_error":false,"result":"The README says App."}'
            exit 0
            ;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return FakeCursorAgent(
            directory: directory,
            executable: executable,
            workspace: workspace,
            cursorRoot: cursorRoot,
            argumentsFile: argumentsFile,
            behaviorFile: behaviorFile,
            hooksFile: directory.appendingPathComponent("hooks.json")
        )
    }

    func adapter() -> CursorAgentAdapter {
        CursorAgentAdapter(
            agentID: "cursor-agent-test-\(UUID().uuidString.prefix(8))",
            executable: executable.path,
            cwd: workspace.path,
            cursorRoot: cursorRoot,
            hookRouter: CursorHookRouter(makeListener: { NoopHookLineSource() }),
            hookInstaller: CursorHookInstaller(hooksFileURL: hooksFile)
        )
    }

    func setBehavior(_ behavior: String) {
        try? behavior.write(to: behaviorFile, atomically: true, encoding: .utf8)
    }

    func recordedArguments() throws -> [String] {
        try String(contentsOf: argumentsFile, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .dropLast()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class NoopHookLineSource: HookLineSource, @unchecked Sendable {
    var onLine: (@Sendable (String) -> Void)?
    func start() throws {}
    func stop() {}
}

/// Collects every snapshot an adapter publishes so tests can wait for a state
/// without racing the stream.
private final class SnapshotCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [AgentStateSnapshot] = []
    /// Snapshots before this index were consumed by earlier waits.
    private var cursor = 0
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<AgentStateSnapshot>) {
        task = Task { [weak self] in
            for await snapshot in stream {
                guard let self else { return }
                self.lock.withLock { self.snapshots.append(snapshot) }
            }
        }
    }

    deinit {
        task?.cancel()
    }

    var all: [AgentStateSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return snapshots
    }

    /// The first snapshot (from the moment of the call) matching `predicate`.
    func wait(timeout: TimeInterval, where predicate: @escaping (AgentStateSnapshot) -> Bool) async throws -> AgentStateSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let match: AgentStateSnapshot? = lock.withLock {
                let start = cursor
                let pending = Array(snapshots[start...])
                if let index = pending.firstIndex(where: predicate) {
                    cursor = start + index + 1
                    return pending[index]
                }
                cursor = snapshots.count
                return nil
            }
            if let match { return match }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        let summary = all.suffix(6).map { "\($0.status)/\($0.statusDetail)" }.joined(separator: " → ")
        throw NSError(domain: "SnapshotCollector", code: 1, userInfo: [NSLocalizedDescriptionKey: "timed out; last snapshots: \(summary)"])
    }
}
