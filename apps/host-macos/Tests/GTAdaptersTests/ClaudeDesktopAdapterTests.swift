import XCTest
@testable import GTAdapters
import GTProtocol

final class ClaudeDesktopAdapterTests: XCTestCase {
    // MARK: - Parser: desktop transcript semantics

    func testDesktopTranscriptDerivesStatusTitlesAndModel() {
        let jsonl = """
        {"type":"bridge-session","sessionId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","bridgeSessionId":"b1"}
        {"type":"queue-operation","operation":"enqueue","sessionId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","timestamp":"2026-09-01T10:00:00.000Z"}
        {"type":"user","entrypoint":"claude-desktop","cwd":"/Users/dev/App","sessionId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","timestamp":"2026-09-01T10:00:01.000Z","message":{"role":"user","content":"Add a settings screen"}}
        {"type":"custom-title","customTitle":"first title","sessionId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}
        {"type":"assistant","entrypoint":"claude-desktop","cwd":"/Users/dev/App","sessionId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","timestamp":"2026-09-01T10:00:05.000Z","message":{"role":"assistant","model":"claude-opus-4-8","stop_reason":"tool_use","content":[{"type":"text","text":"Looking at the app."},{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"/x"}}]}}
        {"type":"user","entrypoint":"claude-desktop","cwd":"/Users/dev/App","sessionId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","timestamp":"2026-09-01T10:00:06.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"file contents"}]}}
        {"type":"user","isSidechain":true,"entrypoint":"claude-desktop","cwd":"/Users/dev/App","sessionId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","timestamp":"2026-09-01T10:00:07.000Z","message":{"role":"user","content":"subagent prompt"}}
        {"type":"assistant","entrypoint":"claude-desktop","cwd":"/Users/dev/App","sessionId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","timestamp":"2026-09-01T10:00:09.000Z","message":{"role":"assistant","model":"claude-opus-4-8","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}
        {"type":"ai-title","aiTitle":"Settings screen","sessionId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}
        {"type":"custom-title","customTitle":"Settings work","sessionId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}
        {"type":"system","subtype":"stop_hook_summary","sessionId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","timestamp":"2026-09-01T10:00:09.500Z"}
        """

        let parsed = ClaudeCodeSessionParser.parse(jsonl: jsonl, agentID: "claude-desktop", maxMessages: 50)

        XCTAssertEqual(parsed.entrypoint, "claude-desktop")
        XCTAssertEqual(parsed.threadName, "Settings work", "The newest custom title wins over AI titles and the first prompt.")
        XCTAssertEqual(parsed.status, .done)
        XCTAssertEqual(parsed.statusDetail, "Response ready")
        XCTAssertEqual(parsed.model, "claude-opus-4-8")
        XCTAssertNil(parsed.pendingInputRequest)
        XCTAssertEqual(parsed.messages.map(\.role), [.user, .assistant, .tool, .assistant])
        XCTAssertEqual(parsed.messages[2].text, "file contents", "Tool results render as tool output, not as the user speaking.")
        XCTAssertFalse(parsed.messages.contains { $0.text == "subagent prompt" }, "Sidechain records are skipped.")
        XCTAssertEqual(parsed.lastActivityUnixMs, 1_788_256_809_500, "2026-09-01T10:00:09.500Z, the newest timestamped record")
    }

    func testDesktopTranscriptMidTurnIsWorkingAndInterruptIsStopped() {
        let working = """
        {"type":"user","entrypoint":"claude-desktop","cwd":"/Users/dev/App","sessionId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","timestamp":"2026-09-01T10:00:01.000Z","message":{"role":"user","content":"Go"}}
        {"type":"assistant","sessionId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","timestamp":"2026-09-01T10:00:02.000Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_2","name":"Bash","input":{}}]}}
        """
        let parsedWorking = ClaudeCodeSessionParser.parse(jsonl: working, agentID: "claude-desktop", maxMessages: 50)
        XCTAssertEqual(parsedWorking.status, .working)

        let interrupted = working + """

        {"type":"user","sessionId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","timestamp":"2026-09-01T10:00:03.000Z","message":{"role":"user","content":"[Request interrupted by user for tool use]"}}
        """
        let parsedInterrupted = ClaudeCodeSessionParser.parse(jsonl: interrupted, agentID: "claude-desktop", maxMessages: 50)
        XCTAssertEqual(parsedInterrupted.status, .idle)
        XCTAssertEqual(parsedInterrupted.statusDetail, "Stopped")
        XCTAssertFalse(parsedInterrupted.messages.contains { $0.text.hasPrefix("[Request interrupted") })

        // The app files the interrupted tool's result after the marker; that
        // record is not a new turn, so the card must stay "Stopped".
        let lateResult = interrupted + """

        {"type":"user","sessionId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","timestamp":"2026-09-01T10:00:04.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","content":"Command was interrupted","is_error":true}]}}
        """
        let parsedLate = ClaudeCodeSessionParser.parse(jsonl: lateResult, agentID: "claude-desktop", maxMessages: 50)
        XCTAssertEqual(parsedLate.status, .idle)
        XCTAssertEqual(parsedLate.statusDetail, "Stopped")

        // A real prompt after the interruption starts a new turn as usual.
        let nextPrompt = lateResult + """

        {"type":"user","entrypoint":"claude-desktop","cwd":"/Users/dev/App","sessionId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","timestamp":"2026-09-01T10:00:09.000Z","message":{"role":"user","content":"Try again"}}
        """
        let parsedNext = ClaudeCodeSessionParser.parse(jsonl: nextPrompt, agentID: "claude-desktop", maxMessages: 50)
        XCTAssertEqual(parsedNext.status, .working)
        XCTAssertEqual(parsedNext.statusDetail, "Claude is working")
    }

    func testAskUserQuestionBecomesPendingInputRequestUntilAnswered() {
        let asked = """
        {"type":"user","entrypoint":"claude-desktop","cwd":"/Users/dev/App","sessionId":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","timestamp":"2026-09-01T10:00:01.000Z","message":{"role":"user","content":"Build a site"}}
        {"type":"assistant","sessionId":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","timestamp":"2026-09-01T10:00:02.000Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_q","name":"AskUserQuestion","input":{"questions":[{"question":"What kind of site?","header":"Purpose","options":[{"label":"Wedding site (Recommended)","description":"Invitation style"},{"label":"Portfolio","description":"Showcase"}]}]}}]}}
        """
        let pending = ClaudeCodeSessionParser.parse(jsonl: asked, agentID: "claude-desktop", maxMessages: 50)
        let request = pending.pendingInputRequest
        XCTAssertEqual(pending.status, .waitingInput)
        XCTAssertEqual(request?.requestId, "toolu_q")
        XCTAssertEqual(request?.questions.first?.header, "Purpose")
        XCTAssertEqual(request?.questions.first?.choices.map(\.label), ["Wedding site (Recommended)", "Portfolio"])
        XCTAssertEqual(request?.questions.first?.choices.first?.recommended, true)
        XCTAssertEqual(request?.questions.first?.choices.map(\.choiceId), ["1", "2"])

        let answered = asked + """

        {"type":"user","sessionId":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","timestamp":"2026-09-01T10:00:20.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_q","content":"Wedding site"}]}}
        """
        let resolved = ClaudeCodeSessionParser.parse(jsonl: answered, agentID: "claude-desktop", maxMessages: 50)
        XCTAssertNil(resolved.pendingInputRequest)
        XCTAssertEqual(resolved.status, .working)
    }

    func testAbandonedQuestionsExpireAndLocalCommandsAreIgnored() {
        let jsonl = """
        {"type":"user","entrypoint":"claude-desktop","cwd":"/Users/dev/App","sessionId":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","timestamp":"2026-09-01T10:00:01.000Z","message":{"role":"user","content":"Build a site"}}
        {"type":"assistant","sessionId":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","timestamp":"2026-09-01T10:00:02.000Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_q","name":"AskUserQuestion","input":{"questions":[{"question":"Which?","header":"Kind","options":[{"label":"A","description":""},{"label":"B","description":""}]}]}}]}}
        {"type":"user","entrypoint":"claude-desktop","cwd":"/Users/dev/App","sessionId":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","timestamp":"2026-09-02T08:00:00.000Z","message":{"role":"user","content":"Never mind, do B"}}
        {"type":"assistant","sessionId":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","timestamp":"2026-09-02T08:00:05.000Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done with B."}]}}
        {"type":"user","isMeta":true,"sessionId":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","timestamp":"2026-09-02T08:01:00.000Z","message":{"role":"user","content":"<local-command-caveat>Caveat: local command</local-command-caveat>"}}
        {"type":"user","sessionId":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","timestamp":"2026-09-02T08:01:00.100Z","message":{"role":"user","content":"<command-name>/model</command-name>"}}
        {"type":"user","sessionId":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","timestamp":"2026-09-02T08:01:00.200Z","message":{"role":"user","content":"<local-command-stdout>Set model to opus</local-command-stdout>"}}
        """

        let parsed = ClaudeCodeSessionParser.parse(jsonl: jsonl, agentID: "claude-desktop", maxMessages: 50)

        XCTAssertNil(parsed.pendingInputRequest, "A question the conversation moved past is not pending.")
        XCTAssertEqual(parsed.status, .done, "Local slash commands never start a turn.")
        XCTAssertFalse(parsed.messages.contains { $0.text.contains("<command-name>") })
        XCTAssertEqual(parsed.messages.last?.text, "Done with B.")
    }

    func testSummaryPreviewSeesTitlesAppendedAtTheEndOfLargeTranscripts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gt-claude-desktop-summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("dddddddd-dddd-4ddd-8ddd-dddddddddddd.jsonl")

        var lines = [
            #"{"type":"user","entrypoint":"claude-desktop","cwd":"/Users/dev/App","sessionId":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","timestamp":"2026-09-01T10:00:01.000Z","message":{"role":"user","content":"Start"}}"#,
        ]
        let filler = String(repeating: "x", count: 4000)
        for index in 0..<200 {
            lines.append(#"{"type":"assistant","sessionId":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"\#(index) \#(filler)"}]}}"#)
        }
        lines.append(#"{"type":"custom-title","customTitle":"Late title","sessionId":"dddddddd-dddd-4ddd-8ddd-dddddddddddd"}"#)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertGreaterThan(size, 256 * 1024 + 64 * 1024, "Fixture must exceed the head+tail preview window.")

        let summary = ClaudeCodeSessionParser.parseSummaryPreview(at: url, path: url.path, modifiedAt: Date())

        XCTAssertEqual(summary?.threadName, "Late title")
        XCTAssertEqual(summary?.owner, .desktop)
    }

    // MARK: - Adapter behavior with a fake desktop UI

    private final class FakeHookSource: ClaudeHookEventSource, @unchecked Sendable {
        var onHook: (@Sendable (ClaudeCodeHookListener.Event) -> Void)?
        func start() throws {}
        func stop() {}
        func fire(_ kind: ClaudeCodeHookListener.HookKind, session: String, summary: String, notificationType: String = "") {
            onHook?(ClaudeCodeHookListener.Event(kind: kind, session: session, summary: summary, notificationType: notificationType))
        }
    }

    private final class FakeDesktopUI: ClaudeDesktopUIDriving, @unchecked Sendable {
        private let lock = NSLock()
        private var _delivered: [(String, Bool)] = []
        private var _pressed: [String] = []
        private var _opened: [URL] = []
        private var _interrupts = 0
        var pressableLabels: Set<String> = ["Allow once", "Deny", "Wedding site (Recommended)", "Submit", "Stop"]
        /// nil models a window whose title Accessibility cannot read.
        private var _frontTitle: String?
        /// When true, pressing a session title "navigates" the fake window to it.
        var navigatesOnPress = false

        var frontTitle: String? {
            get { lock.lock(); defer { lock.unlock() }; return _frontTitle }
            set { lock.lock(); _frontTitle = newValue; lock.unlock() }
        }

        var delivered: [(String, Bool)] { lock.lock(); defer { lock.unlock() }; return _delivered }
        var pressed: [String] { lock.lock(); defer { lock.unlock() }; return _pressed }
        var opened: [URL] { lock.lock(); defer { lock.unlock() }; return _opened }
        var interrupts: Int { lock.lock(); defer { lock.unlock() }; return _interrupts }

        func deliver(text: String, submit: Bool) throws {
            lock.lock(); _delivered.append((text, submit)); lock.unlock()
        }

        /// The fake has no panes; session-scoped presses behave like presses.
        func pressInSession(label: String, exact: Bool) throws {
            try press(label: label, exact: exact)
        }

        func press(label: String, exact: Bool) throws {
            let matches = pressableLabels.contains { exact ? $0 == label : $0.localizedCaseInsensitiveContains(label) }
            guard matches else { throw NSError(domain: "FakeDesktopUI", code: 404) }
            lock.lock()
            _pressed.append(label)
            if navigatesOnPress { _frontTitle = label }
            lock.unlock()
        }

        func interrupt() throws { lock.lock(); _interrupts += 1; lock.unlock() }
        func open(_ url: URL) -> Bool { lock.lock(); _opened.append(url); lock.unlock(); return true }
        func frontWindowTitle() -> String? { frontTitle }

        /// nil models a build that does not expose the rename control.
        private var _currentSession: String?
        var currentSession: String? {
            get { lock.lock(); defer { lock.unlock() }; return _currentSession }
            set { lock.lock(); _currentSession = newValue; lock.unlock() }
        }

        func currentSessionTitle() -> String? { currentSession }
    }

    private struct Fixture {
        let root: URL
        let projectsRoot: URL
        let source: FakeHookSource
        let ui: FakeDesktopUI
        let adapter: ClaudeDesktopAdapter
    }

    private func makeFixture(staleWorkingInterval: TimeInterval = 365 * 24 * 3_600) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gt-claude-desktop-\(UUID().uuidString)", isDirectory: true)
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectsRoot.appendingPathComponent("-Users-dev-App", isDirectory: true),
            withIntermediateDirectories: true
        )
        let source = FakeHookSource()
        let ui = FakeDesktopUI()
        let adapter = ClaudeDesktopAdapter(
            agentID: "claude-desktop-test-\(UUID().uuidString)",
            label: "Claude",
            targetPID: 1,
            ui: ui,
            projectsRoot: projectsRoot,
            hookRouter: ClaudeHookRouter(makeListener: { source }),
            hookInstaller: ClaudeCodeHookInstaller(settingsFileURL: root.appendingPathComponent("settings.json")),
            staleWorkingInterval: staleWorkingInterval
        )
        return Fixture(root: root, projectsRoot: projectsRoot, source: source, ui: ui, adapter: adapter)
    }

    @discardableResult
    private func writeSession(
        _ fixture: Fixture,
        sessionId: String,
        entrypoint: String = "claude-desktop",
        title: String? = nil,
        modifiedSecondsAgo: TimeInterval = 0,
        extraLines: [String] = []
    ) throws -> URL {
        let url = fixture.projectsRoot
            .appendingPathComponent("-Users-dev-App", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
        var lines = [
            #"{"type":"user","entrypoint":"\#(entrypoint)","cwd":"/Users/dev/App","sessionId":"\#(sessionId)","timestamp":"2026-09-01T10:00:01.000Z","message":{"role":"user","content":"Prompt \#(sessionId.prefix(4))"}}"#,
            #"{"type":"assistant","sessionId":"\#(sessionId)","timestamp":"2026-09-01T10:00:05.000Z","message":{"role":"assistant","model":"claude-opus-4-8","stop_reason":"end_turn","content":[{"type":"text","text":"Reply \#(sessionId.prefix(4))"}]}}"#,
        ]
        if let title {
            lines.append(#"{"type":"custom-title","customTitle":"\#(title)","sessionId":"\#(sessionId)"}"#)
        }
        lines += extraLines
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-modifiedSecondsAgo)],
            ofItemAtPath: url.path
        )
        return url
    }

    private func waitForSnapshot(
        _ adapter: ClaudeDesktopAdapter,
        timeout: TimeInterval = 4,
        matching predicate: @escaping (AgentStateSnapshot) -> Bool
    ) async throws -> AgentStateSnapshot {
        try await withThrowingTaskGroup(of: AgentStateSnapshot.self) { group in
            group.addTask {
                for await snapshot in adapter.observeState() where predicate(snapshot) {
                    return snapshot
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CancellationError()
            }
            let snapshot = try await group.next()
            group.cancelAll()
            if let snapshot { return snapshot }
            throw CancellationError()
        }
    }

    func testStartSelectsNewestDesktopSessionAndIgnoresCliSessions() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeSession(fixture, sessionId: "11111111-1111-4111-8111-111111111111", title: "Older desktop", modifiedSecondsAgo: 120)
        try writeSession(fixture, sessionId: "22222222-2222-4222-8222-222222222222", title: "Newest desktop", modifiedSecondsAgo: 10)
        try writeSession(fixture, sessionId: "33333333-3333-4333-8333-333333333333", entrypoint: "sdk-cli", title: "CLI session", modifiedSecondsAgo: 1)
        defer { Task { await fixture.adapter.stop() } }

        try await fixture.adapter.start()
        let snapshot = try await waitForSnapshot(fixture.adapter) { $0.status == .done }

        XCTAssertEqual(snapshot.adapterKind, .claudeDesktop)
        XCTAssertEqual(snapshot.statusDetail, "Response ready", "The parsed detail is what the phone sees after start.")
        XCTAssertEqual(snapshot.agentLabel, "Newest desktop")
        XCTAssertEqual(snapshot.recentMessages.map(\.text), ["Prompt 2222", "Reply 2222"])
        XCTAssertEqual(snapshot.availableTargets?.map(\.targetId), [
            "22222222-2222-4222-8222-222222222222",
            "11111111-1111-4111-8111-111111111111",
        ], "Only desktop-owned sessions are offered, newest first.")
        XCTAssertEqual(snapshot.availableTargets?.first?.selected, true)
        XCTAssertEqual(snapshot.runtimeControls?.modelLabel, "Opus 4.8")
        XCTAssertEqual(snapshot.runtimeControls?.editable, false)
    }

    func testHooksForTheSelectedSessionOverrideStatusUntilTranscriptChanges() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let url = try writeSession(fixture, sessionId: "44444444-4444-4444-8444-444444444444", title: "Selected")
        try writeSession(fixture, sessionId: "55555555-5555-4555-8555-555555555555", title: "Other", modifiedSecondsAgo: 60)
        defer { Task { await fixture.adapter.stop() } }
        try await fixture.adapter.start()
        _ = try await waitForSnapshot(fixture.adapter) { $0.status == .done }

        // Idle notifications carry no new state; the finished turn stands.
        fixture.source.fire(.notification, session: "44444444-4444-4444-8444-444444444444", summary: "Claude is waiting for your input", notificationType: "idle_prompt")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fixture.adapter.currentStatusForTesting(), .done)

        fixture.source.fire(.notification, session: "44444444-4444-4444-8444-444444444444", summary: "Claude needs your permission to use Bash", notificationType: "permission_prompt")
        let waiting = try await waitForSnapshot(fixture.adapter) { $0.status == .waitingInput }
        XCTAssertEqual(waiting.statusDetail, "Claude needs your permission to use Bash")
        let permission = try XCTUnwrap(waiting.pendingInputRequest)
        XCTAssertTrue(permission.requestId.hasPrefix("permission-"))
        XCTAssertEqual(permission.questions.first?.choices.map(\.label), ["Allow", "Deny"])

        // A hook from another desktop session must not move the selection.
        fixture.source.fire(.stop, session: "55555555-5555-4555-8555-555555555555", summary: "Stop")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fixture.adapter.currentSelectedSessionId(), "44444444-4444-4444-8444-444444444444")
        XCTAssertEqual(fixture.adapter.currentStatusForTesting(), .waitingInput)

        // Answering the permission prompt from the phone presses the dialog.
        try await fixture.adapter.respondToInputRequest(AgentInputRequestResponse(
            agentId: fixture.adapter.agentID,
            requestId: permission.requestId,
            answers: [AgentInputRequestAnswer(questionId: "permission", choiceIds: ["allow"])]
        ))
        XCTAssertEqual(fixture.ui.pressed, ["Allow once"])
        XCTAssertTrue(fixture.ui.delivered.isEmpty, "A permission answer must not be typed into the composer.")
        let allowed = try await waitForSnapshot(fixture.adapter) { $0.statusDetail == "Allowed" }
        XCTAssertNil(allowed.pendingInputRequest)

        // Once the transcript moves on, the transcript's own state wins again.
        let appended = try String(contentsOf: url, encoding: .utf8) + "\n" +
            #"{"type":"user","sessionId":"44444444-4444-4444-8444-444444444444","timestamp":"2026-09-01T10:01:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_p","content":"ok"}]}}"#
        try appended.write(to: url, atomically: true, encoding: .utf8)
        let working = try await waitForSnapshot(fixture.adapter, timeout: 6) { $0.status == .working && $0.statusDetail == "Claude is working" }
        XCTAssertEqual(working.recentMessages.last?.role, .tool)

        // A finished turn reads as "Response ready", never as the raw hook name.
        fixture.source.fire(.stop, session: "44444444-4444-4444-8444-444444444444", summary: "Stop")
        let finished = try await waitForSnapshot(fixture.adapter) { $0.status == .done }
        XCTAssertEqual(finished.statusDetail, "Response ready")
    }

    func testQuestionAnswersPressExactLabelsOnlyAndStayPendingWhenTheAppHidesTheQuestion() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try writeSession(fixture, sessionId: "6b6b6b6b-6b6b-4b6b-8b6b-6b6b6b6b6b6b", title: "Target session", extraLines: [
            #"{"type":"assistant","sessionId":"6b6b6b6b-6b6b-4b6b-8b6b-6b6b6b6b6b6b","timestamp":"2026-09-01T10:00:09.000Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_ab","name":"AskUserQuestion","input":{"questions":[{"question":"Which one?","header":"Pick","options":[{"label":"Alpha","description":""},{"label":"Beta","description":""}]}]}}]}}"#,
        ])
        fixture.ui.frontTitle = "Target session"
        // The app shows its tool-permission dialog first; the only control that
        // contains the option's text is an unrelated sidebar button.
        fixture.ui.pressableLabels = ["Dispatch Beta", "Allow once", "Submit"]
        defer { Task { await fixture.adapter.stop() } }
        try await fixture.adapter.start()
        let waiting = try await waitForSnapshot(fixture.adapter) { $0.status == .waitingInput }
        let request = try XCTUnwrap(waiting.pendingInputRequest)
        let beta = try XCTUnwrap(request.questions.first?.choices.first { $0.label == "Beta" })

        try await fixture.adapter.respondToInputRequest(AgentInputRequestResponse(
            agentId: fixture.adapter.agentID,
            requestId: request.requestId,
            answers: [AgentInputRequestAnswer(questionId: request.questions[0].questionId, choiceIds: [beta.choiceId])]
        ))

        XCTAssertEqual(fixture.ui.pressed, [], "A substring match must never press a look-alike control.")
        let kept = try await waitForSnapshot(fixture.adapter) { $0.statusDetail == "open the question in Claude to answer" }
        XCTAssertEqual(kept.status, .waitingInput)
        XCTAssertNotNil(kept.pendingInputRequest, "The unanswered question stays open for a retry.")
    }

    func testSubagentStopAfterAFinishedTurnKeepsResponseReady() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeSession(fixture, sessionId: "5a5a5a5a-5a5a-4a5a-8a5a-5a5a5a5a5a5a", title: "Target session")
        fixture.ui.frontTitle = "Target session"
        defer { Task { await fixture.adapter.stop() } }
        try await fixture.adapter.start()
        _ = try await waitForSnapshot(fixture.adapter) { $0.status == .done }

        fixture.source.fire(.stop, session: "5a5a5a5a-5a5a-4a5a-8a5a-5a5a5a5a5a5a", summary: "Stop")
        let finished = try await waitForSnapshot(fixture.adapter) { $0.statusDetail == "Response ready" }
        XCTAssertEqual(finished.status, .done)

        // The desktop app runs background work (title generation) after the
        // turn and reports it as a subagent finishing; the phone must keep
        // seeing a finished turn.
        fixture.source.fire(.subagentStop, session: "5a5a5a5a-5a5a-4a5a-8a5a-5a5a5a5a5a5a", summary: "SubagentStop")
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(fixture.adapter.currentStatusForTesting(), .done)
    }

    func testHousekeepingRecordsDoNotDismissAPermissionPrompt() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let url = try writeSession(fixture, sessionId: "99999999-9999-4999-8999-999999999999", title: "Busy", extraLines: [
            #"{"type":"assistant","sessionId":"99999999-9999-4999-8999-999999999999","timestamp":"2026-09-01T10:00:09.000Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_b","name":"Bash","input":{"command":"rm -rf build"}}]}}"#,
        ])
        defer { Task { await fixture.adapter.stop() } }
        try await fixture.adapter.start()
        _ = try await waitForSnapshot(fixture.adapter) { $0.status == .working }

        fixture.source.fire(.notification, session: "99999999-9999-4999-8999-999999999999", summary: "Claude needs your permission to use Bash", notificationType: "permission_prompt")
        _ = try await waitForSnapshot(fixture.adapter) { $0.pendingInputRequest != nil }

        // The desktop app appends title/queue housekeeping while the dialog is
        // still open; none of it is conversation progress.
        let appended = try String(contentsOf: url, encoding: .utf8) + "\n" +
            #"{"type":"custom-title","customTitle":"Busy again","sessionId":"99999999-9999-4999-8999-999999999999"}"# + "\n" +
            #"{"type":"queue-operation","operation":"enqueue","sessionId":"99999999-9999-4999-8999-999999999999","timestamp":"2026-09-01T10:00:12.000Z"}"#
        try appended.write(to: url, atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 2_600_000_000)

        XCTAssertEqual(fixture.adapter.currentStatusForTesting(), .waitingInput)
        let snapshot = try await waitForSnapshot(fixture.adapter) { $0.agentLabel == "Busy again" }
        XCTAssertNotNil(snapshot.pendingInputRequest, "The Allow/Deny card must survive housekeeping writes.")
    }

    func testSilentWorkingTurnEventuallyReadsAsIdle() async throws {
        let fixture = try makeFixture(staleWorkingInterval: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeSession(fixture, sessionId: "12121212-1212-4121-8121-121212121212", title: "Abandoned", extraLines: [
            #"{"type":"assistant","sessionId":"12121212-1212-4121-8121-121212121212","timestamp":"2026-09-01T10:00:09.000Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_x","name":"Bash","input":{}}]}}"#,
        ])
        defer { Task { await fixture.adapter.stop() } }
        try await fixture.adapter.start()

        let idle = try await waitForSnapshot(fixture.adapter) { $0.status == .idle }
        XCTAssertEqual(idle.statusDetail, "Idle")
    }

    func testSendInputOpensTheSelectedSessionThenTypesIntoTheComposer() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeSession(fixture, sessionId: "66666666-6666-4666-8666-666666666666", title: "Target")
        defer { Task { await fixture.adapter.stop() } }
        try await fixture.adapter.start()
        _ = try await waitForSnapshot(fixture.adapter) { $0.status == .done }

        try await fixture.adapter.sendInput("Ship it", submit: true)

        XCTAssertEqual(fixture.ui.opened.map(\.absoluteString), ["claude://code/continue?session=66666666-6666-4666-8666-666666666666"])
        XCTAssertEqual(fixture.ui.delivered.map(\.0), ["Ship it"])
        let snapshot = try await waitForSnapshot(fixture.adapter) { $0.recentMessages.last?.text == "Ship it" }
        XCTAssertEqual(snapshot.status, .working)
        XCTAssertEqual(snapshot.recentMessages.last?.role, .user)
    }

    func testRefusesToTypeIntoAWindowShowingAnotherSession() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeSession(fixture, sessionId: "abababab-abab-4bab-8bab-abababababab", title: "Target session")
        fixture.ui.frontTitle = "Some other session"
        defer { Task { await fixture.adapter.stop() } }
        try await fixture.adapter.start()
        let snapshot = try await waitForSnapshot(fixture.adapter) { $0.status == .done }
        XCTAssertEqual(snapshot.availableTargets?.first?.isActive, false, "A readable, mismatching title means the session is not active.")

        do {
            try await fixture.adapter.sendInput("Ship it", submit: true)
            XCTFail("Typing into a window that shows another session must be refused.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Target session"))
        }
        XCTAssertTrue(fixture.ui.delivered.isEmpty)
        XCTAssertEqual(fixture.ui.opened.count, 1, "The deep link is still attempted first.")
        XCTAssertEqual(fixture.ui.pressed, [], "No session row was exposed to press.")
    }

    func testFallsBackToPressingTheSessionRowWhenDeepLinksAreGated() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeSession(fixture, sessionId: "cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd", title: "Target session")
        fixture.ui.frontTitle = "Some other session"
        fixture.ui.pressableLabels.insert("Target session")
        fixture.ui.navigatesOnPress = true
        defer { Task { await fixture.adapter.stop() } }
        try await fixture.adapter.start()
        _ = try await waitForSnapshot(fixture.adapter) { $0.status == .done }

        try await fixture.adapter.sendInput("Ship it", submit: true)

        XCTAssertEqual(fixture.ui.pressed, ["Target session"], "The session row is pressed when the deep link does not switch.")
        XCTAssertEqual(fixture.ui.delivered.map(\.0), ["Ship it"])
        let active = try await waitForSnapshot(fixture.adapter, timeout: 6) { $0.availableTargets?.first?.isActive == true }
        XCTAssertEqual(active.availableTargets?.first?.isActive, true)
    }

    func testVerifiesTheFrontSessionThroughTheRenameControlWhenTheWindowTitleIsGeneric() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeSession(fixture, sessionId: "efefefef-efef-4fef-8fef-efefefefefef", title: "Target session")
        // Build 1.40609.1 titles every window "Claude"; only the rename control
        // names the session in front.
        fixture.ui.frontTitle = "Claude"
        fixture.ui.currentSession = "Target session"
        defer { Task { await fixture.adapter.stop() } }
        try await fixture.adapter.start()
        let snapshot = try await waitForSnapshot(fixture.adapter) { $0.status == .done }
        XCTAssertEqual(snapshot.availableTargets?.first?.isActive, true, "The rename control confirms the session is in front.")

        try await fixture.adapter.sendInput("Ship it", submit: true)

        XCTAssertEqual(fixture.ui.delivered.map(\.0), ["Ship it"])
        XCTAssertTrue(fixture.ui.opened.isEmpty, "No switch is attempted when the front session already matches.")
        XCTAssertTrue(fixture.ui.pressed.isEmpty)
    }

    func testRefusesWhenTheRenameControlNamesAnotherSessionDespiteAGenericWindowTitle() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeSession(fixture, sessionId: "0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f", title: "Target session")
        fixture.ui.frontTitle = "Claude"
        fixture.ui.currentSession = "Some other session"
        defer { Task { await fixture.adapter.stop() } }
        try await fixture.adapter.start()
        let snapshot = try await waitForSnapshot(fixture.adapter) { $0.status == .done }
        XCTAssertEqual(snapshot.availableTargets?.first?.isActive, false)

        do {
            try await fixture.adapter.sendInput("Ship it", submit: true)
            XCTFail("A generic window title must not hide that another session is in front.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Target session"))
        }
        XCTAssertTrue(fixture.ui.delivered.isEmpty)
    }

    func testSelectTargetOpensTheDeepLinkAndSwitchesSessions() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeSession(fixture, sessionId: "77777777-7777-4777-8777-777777777777", title: "Current")
        try writeSession(fixture, sessionId: "88888888-8888-4888-8888-888888888888", title: "Older", modifiedSecondsAgo: 90)
        defer { Task { await fixture.adapter.stop() } }
        try await fixture.adapter.start()
        _ = try await waitForSnapshot(fixture.adapter) { $0.agentLabel == "Current" }

        try await fixture.adapter.selectTarget("88888888-8888-4888-8888-888888888888")

        XCTAssertEqual(fixture.ui.opened.last?.absoluteString, "claude://code/continue?session=88888888-8888-4888-8888-888888888888")
        let switched = try await waitForSnapshot(fixture.adapter) { $0.agentLabel == "Older" && $0.status == .done }
        XCTAssertEqual(switched.recentMessages.map(\.text), ["Prompt 8888", "Reply 8888"])
        XCTAssertEqual(switched.availableTargets?.first { $0.selected }?.targetId, "88888888-8888-4888-8888-888888888888")

        await XCTAssertThrowsErrorAsync(try await fixture.adapter.selectTarget("99999999-9999-4999-8999-999999999999"))
    }

    func testAnsweringAQuestionPressesTheChoiceAndWaitsForTheTranscript() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let url = try writeSession(fixture, sessionId: "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa", title: "Asking", extraLines: [
            #"{"type":"assistant","sessionId":"aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa","timestamp":"2026-09-01T10:00:09.000Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_q","name":"AskUserQuestion","input":{"questions":[{"question":"What kind of site?","header":"Purpose","options":[{"label":"Wedding site (Recommended)","description":""},{"label":"Portfolio","description":""}]}]}}]}}"#,
        ])
        defer { Task { await fixture.adapter.stop() } }
        try await fixture.adapter.start()
        let waiting = try await waitForSnapshot(fixture.adapter) { $0.status == .waitingInput }
        let request = try XCTUnwrap(waiting.pendingInputRequest)

        try await fixture.adapter.respondToInputRequest(AgentInputRequestResponse(
            agentId: fixture.adapter.agentID,
            requestId: request.requestId,
            answers: [AgentInputRequestAnswer(questionId: "Purpose", choiceIds: ["1"])]
        ))

        XCTAssertEqual(fixture.ui.pressed, ["Wedding site (Recommended)", "Submit"])
        let sent = try await waitForSnapshot(fixture.adapter) { $0.statusDetail == "answer sent" }
        XCTAssertTrue(sent.recentMessages.last?.text.contains("Purpose: Wedding site (Recommended)") == true)
        XCTAssertNotNil(sent.pendingInputRequest, "The question stays open until the app records the answer.")
        XCTAssertEqual(sent.status, .waitingInput, "Staying in waiting keeps the phone's choices enabled for a retry.")

        let appended = try String(contentsOf: url, encoding: .utf8) + "\n" +
            #"{"type":"user","sessionId":"aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa","timestamp":"2026-09-01T10:00:30.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_q","content":"Wedding site"}]}}"#
        try appended.write(to: url, atomically: true, encoding: .utf8)
        let answered = try await waitForSnapshot(fixture.adapter, timeout: 6) { $0.pendingInputRequest == nil && $0.status == .working }
        XCTAssertEqual(answered.statusDetail, "Claude is working")
    }

    /// Opt-in audit against the real ~/.claude store on this machine:
    /// GT_CLAUDE_REAL_STATE=1 swift test --filter testRealDesktopSessionsParse
    func testRealDesktopSessionsParse() throws {
        guard ProcessInfo.processInfo.environment["GT_CLAUDE_REAL_STATE"] == "1" else {
            throw XCTSkip("Set GT_CLAUDE_REAL_STATE=1 to audit real desktop sessions.")
        }
        let desktop = ClaudeCodeSessionStore.loadSummaries(limit: 5, owner: .desktop)
        XCTAssertFalse(desktop.isEmpty, "Expected at least one desktop-owned session on this machine.")
        for summary in desktop {
            let parsed = try XCTUnwrap(ClaudeCodeSessionParser.parseRecentFile(
                at: URL(fileURLWithPath: summary.path),
                agentID: "audit",
                maxMessages: 50
            ))
            XCTAssertEqual(parsed.entrypoint, "claude-desktop")
            XCTAssertFalse(parsed.messages.isEmpty)
            print("desktop session \(summary.sessionId): title=\(summary.threadName ?? "-") status=\(parsed.status) detail=\(parsed.statusDetail) model=\(parsed.model ?? "-") messages=\(parsed.messages.count) pending=\(parsed.pendingInputRequest != nil)")
        }
    }

    func testHelpers() {
        XCTAssertEqual(ClaudeDesktopAdapter.modelLabel("claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(ClaudeDesktopAdapter.modelLabel("claude-sonnet-4-5-20250929"), "Sonnet 4.5")
        XCTAssertEqual(ClaudeDesktopAdapter.modelLabel("claude-fable-5"), "Fable 5")
        XCTAssertEqual(ClaudeDesktopAdapter.modelLabel("custom"), "custom")
        XCTAssertNil(ClaudeDesktopAdapter.continueSessionURL("not-a-uuid"))
        XCTAssertTrue(ClaudeDesktopAdapter.windowShowsSession(windowTitle: "Settings screen — Claude", sessionTitle: "settings screen"))
        XCTAssertFalse(ClaudeDesktopAdapter.windowShowsSession(windowTitle: "Claude", sessionTitle: "Settings screen"))
        XCTAssertFalse(ClaudeDesktopAdapter.windowShowsSession(windowTitle: nil, sessionTitle: "Settings screen"))
        XCTAssertFalse(ClaudeDesktopAdapter.windowShowsSession(windowTitle: "Settings screen", sessionTitle: nil))
        let permission = ClaudeDesktopAdapter.makePermissionRequest(message: "Claude needs your permission to use Bash")
        XCTAssertTrue(permission.requestId.hasPrefix(ClaudeDesktopAdapter.permissionRequestPrefix))
        XCTAssertEqual(permission.questions.first?.question, "Claude needs your permission to use Bash")
        XCTAssertEqual(permission.questions.first?.choices.map(\.choiceId), ["allow", "deny"])
        XCTAssertEqual(ClaudeCodeSessionParser.parseUTCTimestamp("2026-09-01T10:00:09.500Z"), 1_788_256_809_500)
        XCTAssertEqual(ClaudeCodeSessionParser.parseUTCTimestamp("2026-09-01T10:00:09Z"), 1_788_256_809_000)
        XCTAssertEqual(ClaudeCodeSessionParser.parseUTCTimestamp("2024-02-29T23:59:59.999Z"), 1_709_251_199_999)
        XCTAssertNil(ClaudeCodeSessionParser.parseUTCTimestamp("2026-09-01 10:00:09"))
        XCTAssertNil(ClaudeCodeSessionParser.parseUTCTimestamp("2026-13-01T10:00:09Z"))
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error to be thrown.", file: file, line: line)
    } catch {
        // expected
    }
}
