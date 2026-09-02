import XCTest
@testable import GTAdapters
import GTProtocol

/// Exercises the CLI adapter's session ownership: it must launch on a session
/// id it knows, react only to that session's hook events, and release the
/// shared hook socket when it fails to start or stops.
final class ClaudeCodeSessionOwnershipTests: XCTestCase {
    private final class FakeHookSource: ClaudeHookEventSource, @unchecked Sendable {
        var onHook: (@Sendable (ClaudeCodeHookListener.Event) -> Void)?
        private let lock = NSLock()
        private var _stopCount = 0

        var stopCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _stopCount
        }

        func start() throws {}

        func stop() {
            lock.lock()
            _stopCount += 1
            lock.unlock()
        }

        func fire(kind: ClaudeCodeHookListener.HookKind, session: String, summary: String) {
            onHook?(ClaudeCodeHookListener.Event(kind: kind, session: session, summary: summary))
        }
    }

    private actor HookSnapshotRecorder {
        private(set) var count = 0

        func append(_ snapshot: AgentStateSnapshot) {
            _ = snapshot
            count += 1
        }
    }

    private struct Fixture {
        let directory: URL
        let projectsRoot: URL
        let executable: URL
        let source: FakeHookSource
        let router: ClaudeHookRouter
        let installer: ClaudeCodeHookInstaller
    }

    func testFreshLaunchPinsASessionIdAndReactsOnlyToItsOwnHooks() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let adapter = makeAdapter(fixture)
        defer { Task { await adapter.stop() } }

        try await adapter.start()

        let sessionFlag = try XCTUnwrap(adapter.arguments.firstIndex(of: "--session-id"))
        let sessionId = adapter.arguments[sessionFlag + 1]
        XCTAssertNotNil(UUID(uuidString: sessionId), "Fresh launches must pin a UUID session id.")
        XCTAssertEqual(adapter.arguments.first, "initial", "Caller arguments stay ahead of the injected session id.")

        fixture.source.fire(kind: .notification, session: "someone-elses-session", summary: "needs approval")
        fixture.source.fire(kind: .stop, session: sessionId, summary: "own turn finished")

        let snapshot = try await waitForSnapshot(adapter) { $0.statusDetail == "own turn finished" }
        XCTAssertEqual(snapshot.status, .done)
        XCTAssertNotEqual(snapshot.statusDetail, "needs approval", "Foreign session hooks must never reach this adapter.")
    }

    func testResumesNewestCliOwnedSessionAndIgnoresDesktopSessions() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try writeSession(fixture, sessionId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", entrypoint: "sdk-cli", modifiedSecondsAgo: 60)
        try writeSession(fixture, sessionId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", entrypoint: "claude-desktop", modifiedSecondsAgo: 1)
        let adapter = makeAdapter(fixture)
        defer { Task { await adapter.stop() } }

        try await adapter.start()

        XCTAssertEqual(
            adapter.arguments,
            ["--resume", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"],
            "The newest CLI-owned session is resumed even when a desktop session is newer."
        )
        let targets = try XCTUnwrap(adapter.snapshotAvailableTargets())
        XCTAssertEqual(targets.map(\.targetId), ["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"])

        fixture.source.fire(kind: .stop, session: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", summary: "desktop finished")
        fixture.source.fire(kind: .stop, session: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", summary: "cli finished")

        let snapshot = try await waitForSnapshot(adapter) { $0.statusDetail == "cli finished" }
        XCTAssertEqual(snapshot.status, .done)
    }

    func testRepeatedIdenticalHooksStillPublishSnapshots() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let adapter = makeAdapter(fixture)
        defer { Task { await adapter.stop() } }

        try await adapter.start()
        let sessionId = adapter.arguments[try XCTUnwrap(adapter.arguments.firstIndex(of: "--session-id")) + 1]

        let recorder = HookSnapshotRecorder()
        let collecting = Task {
            // A Stop hook carries no message, so its summary is the raw event
            // name and the adapter publishes it as "Response ready".
            for await snapshot in adapter.observeState() where snapshot.statusDetail == "Response ready" {
                await recorder.append(snapshot)
            }
        }
        defer { collecting.cancel() }

        // Two consecutive Stop hooks carry the same status and detail; each
        // marks a finished turn whose transcript the phone must still receive.
        fixture.source.fire(kind: .stop, session: sessionId, summary: "Stop")
        try await Task.sleep(nanoseconds: 100_000_000)
        fixture.source.fire(kind: .stop, session: sessionId, summary: "Stop")

        let deadline = Date().addingTimeInterval(3)
        while await recorder.count < 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let count = await recorder.count
        XCTAssertGreaterThanOrEqual(count, 2, "An identical repeat hook must not be deduplicated away.")
    }

    func testFailedStartReleasesTheHookSubscription() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.removeItem(at: fixture.executable)
        let adapter = makeAdapter(fixture)

        do {
            try await adapter.start()
            XCTFail("Starting without an executable must throw.")
        } catch {
            XCTAssertEqual(fixture.source.stopCount, 1, "A failed start must release the shared hook socket.")
        }
    }

    func testSubagentStopAfterAFinishedTurnDoesNotReopenIt() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let adapter = makeAdapter(fixture)
        defer { Task { await adapter.stop() } }
        try await adapter.start()
        let sessionFlag = try XCTUnwrap(adapter.arguments.firstIndex(of: "--session-id"))
        let sessionId = adapter.arguments[sessionFlag + 1]

        fixture.source.fire(kind: .stop, session: sessionId, summary: "Stop")
        let finished = try await waitForSnapshot(adapter) { $0.statusDetail == "Response ready" }
        XCTAssertEqual(finished.status, .done)

        fixture.source.fire(kind: .subagentStop, session: sessionId, summary: "SubagentStop")
        do {
            let reopened = try await waitForSnapshot(adapter, timeoutSeconds: 2) { $0.status == .working }
            XCTFail("A finished turn must stay finished; got \(reopened.statusDetail)")
        } catch is CancellationError {
            // No working snapshot arrived: the background subagent was ignored.
        }
    }

    func testTrustDialogBecomesADecisionAndBlocksPromptsUntilAnswered() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        // Prints the dialog Claude Code shows for an unfamiliar folder, then
        // echoes the first byte it receives so the answering keystroke is visible.
        // The dialog as the host's PTY sees it: no numbers, and "No, exit"
        // highlighted by default. Down moves the highlight; Return confirms.
        let script = """
        import sys, time, tty
        tty.setcbreak(sys.stdin.fileno())
        def show(sel):
            print('Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open')
            print('source project, or work from your team). If not, take a moment to review what\\'s in this folder first.')
            print((' \\u276f ' if sel == 'no' else '   ') + 'No, exit')
            print((' \\u276f ' if sel == 'yes' else '   ') + 'Yes, I trust this folder')
            print('Enter to confirm \\u00b7 Esc to cancel')
            sys.stdout.flush()
        sel = 'no'
        show(sel)
        buf = b''
        while True:
            ch = sys.stdin.buffer.read(1)
            buf += ch
            if buf.endswith(b'\\x1b[B'):
                sel = 'yes'; show(sel); buf = b''
            elif buf.endswith(b'\\x1b[A'):
                sel = 'no'; show(sel); buf = b''
            elif ch in (b'\\r', b'\\n'):
                # cbreak keeps ICRNL, so the adapter's Return arrives as a newline here.
                print('GT_TRUST_CONFIRMED=' + sel)
                sys.stdout.flush()
                time.sleep(2)
                break
            elif ch.isdigit():
                print('GT_TRUST_DIGIT_IGNORED')
                sys.stdout.flush()
        """
        let adapter = ClaudeCodeAdapter(
            agentID: "claude-code-trust-\(UUID().uuidString)",
            executable: "/usr/bin/python3",
            cwd: fixture.directory.path,
            arguments: ["-c", script],
            projectsRoot: fixture.projectsRoot,
            hookRouter: fixture.router,
            hookInstaller: fixture.installer
        )
        defer { Task { await adapter.stop() } }
        try await adapter.start()

        // The decision is attached as soon as the dialog text arrives; the
        // status follows on the next idle tick.
        let waiting = try await waitForSnapshot(adapter, timeoutSeconds: 10) {
            $0.pendingInputRequest?.requestId == ClaudeCodeAdapter.trustPromptRequestId
                && $0.status == .waitingInput
        }
        XCTAssertEqual(waiting.statusDetail, "Trust this folder?")
        XCTAssertEqual(
            waiting.pendingInputRequest?.questions.first?.choices.map(\.label),
            ["Yes, I trust this folder", "No, exit"]
        )

        do {
            try await adapter.sendInput("Reply with a marker", submit: true)
            XCTFail("A prompt typed over the trust dialog would be dropped, so it must be refused.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("trust"), error.localizedDescription)
        }

        try await adapter.respondToInputRequest(AgentInputRequestResponse(
            agentId: adapter.agentID,
            requestId: ClaudeCodeAdapter.trustPromptRequestId,
            answers: [AgentInputRequestAnswer(questionId: ClaudeCodeAdapter.trustPromptQuestionId, choiceIds: [ClaudeCodeAdapter.trustChoiceId])]
        ))

        let answered: AgentStateSnapshot
        do {
            answered = try await waitForSnapshot(adapter, timeoutSeconds: 10) { snapshot in
                snapshot.recentMessages.contains { $0.text.contains("GT_TRUST_CONFIRMED=yes") }
            }
        } catch {
            XCTFail("No confirmation arrived; output tail: \(adapter.recentOutputTail(maxLength: 600))")
            throw error
        }
        XCTAssertNil(answered.pendingInputRequest, "The answered dialog must not be republished from stale output.")
        XCTAssertFalse(
            answered.recentMessages.contains { $0.text.contains("GT_TRUST_DIGIT_IGNORED") },
            "No number key is pressed; the highlight is moved and confirmed instead."
        )
    }

    func testTrustDialogSelectionIsReadFromTheNewestRendering() {
        XCTAssertEqual(ClaudeCodeAdapter.trustDialogSelection(in: " ❯ No, exit\n   Yes, I trust this folder\n"), .exit)
        XCTAssertEqual(ClaudeCodeAdapter.trustDialogSelection(in: "   No, exit\n ❯ Yes, I trust this folder\n"), .trust)
        XCTAssertEqual(ClaudeCodeAdapter.trustDialogSelection(in: " ❯ 1. Yes, I trust this folder\n   2. No, exit\n"), .trust)
        XCTAssertEqual(ClaudeCodeAdapter.trustDialogSelection(in: "   1. Yes, I trust this folder\n ❯ 2. No, exit\n"), .exit)
        // A redraw after Down leaves the older highlight earlier in the buffer.
        XCTAssertEqual(
            ClaudeCodeAdapter.trustDialogSelection(in: " ❯ No, exit\n   Yes, I trust this folder\n   No, exit\n ❯ Yes, I trust this folder\n"),
            .trust
        )
        XCTAssertNil(ClaudeCodeAdapter.trustDialogSelection(in: "❯ Try \"fix lint errors\""))
    }

    func testResumeRefusedByAnotherProcessFallsBackToAFreshSession() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        // The newest CLI-owned session gets resumed first; the fake refuses it
        // the way Claude Code does when a background agent still holds it.
        try writeSession(fixture, sessionId: "dededede-dede-4ede-8ede-dededededede", entrypoint: "cli", modifiedSecondsAgo: 30)
        let executable = fixture.directory.appendingPathComponent("bin/held-claude.sh")
        try """
        #!/bin/sh
        case "$*" in
          *--resume*)
            echo "Session dededede-dede-4ede-8ede-dededededede is currently running as a background agent (bg). Use \\`claude"
            echo "agents\\` to find and attach to it, or add --fork-session to branch off a copy."
            exit 1
            ;;
          *)
            echo "GT_FRESH_OK $*"
            sleep 5
            ;;
        esac
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = ClaudeCodeAdapter(
            agentID: "claude-code-held-\(UUID().uuidString)",
            executable: executable.path,
            cwd: fixture.directory.path,
            arguments: ["initial"],
            projectsRoot: fixture.projectsRoot,
            hookRouter: fixture.router,
            hookInstaller: fixture.installer
        )
        defer { Task { await adapter.stop() } }
        try await adapter.start()

        let fresh = try await waitForSnapshot(adapter, timeoutSeconds: 15) { snapshot in
            snapshot.recentMessages.contains { $0.text.contains("GT_FRESH_OK initial --session-id") }
        }
        XCTAssertNotEqual(fresh.status, .error, "The refused resume's exit must not be what the phone sees: \(fresh.statusDetail)")
        XCTAssertTrue(ClaudeCodeAdapter.isSessionHeldElsewhere(
            "Session x is currently running as a background agent (bg). Use `claude\nagents` to find and attach to it, or add --fork-session to branch off a copy."
        ))
        XCTAssertTrue(ClaudeCodeAdapter.isSessionHeldElsewhere(
            "Session a149ada3-b404-400c-a96b-f3a6ce31c313 is running as a background session (a149ada3). Run `claude attach a149ada3`\nto open it."
        ))
        XCTAssertFalse(ClaudeCodeAdapter.isSessionHeldElsewhere("process exited (1)"))
    }

    func testResumeThatDiesBeforeTheComposerFallsBackEvenWithoutTheKnownMessage() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try writeSession(fixture, sessionId: "fafafafa-fafa-4afa-8afa-fafafafafafa", entrypoint: "cli", modifiedSecondsAgo: 30)
        let executable = fixture.directory.appendingPathComponent("bin/broken-resume.sh")
        try """
        #!/bin/sh
        case "$*" in
          *--resume*) echo "Could not read that conversation"; exit 2 ;;
          *) echo "GT_FRESH_OK $*"; sleep 5 ;;
        esac
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = ClaudeCodeAdapter(
            agentID: "claude-code-broken-resume-\(UUID().uuidString)",
            executable: executable.path,
            cwd: fixture.directory.path,
            arguments: ["initial"],
            projectsRoot: fixture.projectsRoot,
            hookRouter: fixture.router,
            hookInstaller: fixture.installer
        )
        defer { Task { await adapter.stop() } }
        try await adapter.start()

        let fresh = try await waitForSnapshot(adapter, timeoutSeconds: 15) { snapshot in
            snapshot.recentMessages.contains { $0.text.contains("GT_FRESH_OK initial --session-id") }
        }
        XCTAssertNotEqual(fresh.status, .error, fresh.statusDetail)
    }

    func testSilenceBeforeTheComposerHintIsStartingNotReady() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        // Claude Code prints its banner, goes quiet while it loads, then draws
        // the composer with its hint line.
        let script = """
        import sys, time
        print('Claude Code v2.1.226')
        sys.stdout.flush()
        time.sleep(4.5)
        print('\\u276f Try "fix lint errors"')
        print('  \\u23f8 manual mode on \\u00b7 ? for shortcuts')
        sys.stdout.flush()
        time.sleep(6)
        """
        let adapter = ClaudeCodeAdapter(
            agentID: "claude-code-startup-\(UUID().uuidString)",
            executable: "/usr/bin/python3",
            cwd: fixture.directory.path,
            arguments: ["-c", script],
            projectsRoot: fixture.projectsRoot,
            hookRouter: fixture.router,
            hookInstaller: fixture.installer
        )
        defer { Task { await adapter.stop() } }
        try await adapter.start()

        let starting = try await waitForSnapshot(adapter, timeoutSeconds: 12) { $0.statusDetail == "Starting Claude Code" }
        XCTAssertEqual(starting.status, .working)

        let ready = try await waitForSnapshot(adapter, timeoutSeconds: 16) { $0.status == .done }
        XCTAssertTrue(ready.statusDetail.hasPrefix("idle for"), ready.statusDetail)
        XCTAssertTrue(ClaudeCodeAdapter.showsComposer("  ⏸ manual mode on · ? for shortcuts · ← for agents"))
        XCTAssertFalse(ClaudeCodeAdapter.showsComposer("❯ 1. Yes, I trust this folder"))
    }

    func testPromptKeptInTheComposerIsResubmittedUntilTheTranscriptRecordsIt() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        // A fake Claude Code that shows its composer, swallows the first Return
        // (the way a paste-detected burst does), and records the prompt in its
        // transcript only on the second Return.
        let script = """
        import sys, os, tty, time, json
        tty.setcbreak(sys.stdin.fileno())
        args = sys.argv
        root = args[1]
        # Spelled apart: the adapter treats a literal session flag in its arguments as caller-provided.
        sid = args[args.index('--session' + '-id') + 1]
        print('\\u276f Try "fix lint errors"')
        print('  ? for shortcuts')
        sys.stdout.flush()
        buf = b''
        returns = 0
        typed = ''
        while True:
            ch = sys.stdin.buffer.read(1)
            if ch in (b'\\r', b'\\n'):
                returns += 1
                if buf:
                    typed = buf.decode('utf-8', 'replace')
                buf = b''
                if returns == 1:
                    print('(kept in composer)')
                    sys.stdout.flush()
                    continue
                path = os.path.join(root, '-Users-developer-Example', sid + '.jsonl')
                with open(path, 'a') as f:
                    f.write(json.dumps({'type': 'user', 'entrypoint': 'cli', 'cwd': '/tmp', 'sessionId': sid, 'timestamp': '2026-09-02T10:00:00.000Z', 'message': {'role': 'user', 'content': typed}}) + '\\n')
                print('GT_ACCEPTED returns=' + str(returns))
                sys.stdout.flush()
                time.sleep(3)
                break
            else:
                buf += ch
        """
        // Passed as a file: a `-c` argument reads as Claude Code's own
        // `--continue` short flag and suppresses the fresh session id.
        let scriptURL = fixture.directory.appendingPathComponent("bin/fake-resubmit.py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let adapter = ClaudeCodeAdapter(
            agentID: "claude-code-resubmit-\(UUID().uuidString)",
            executable: "/usr/bin/python3",
            cwd: fixture.directory.path,
            arguments: [scriptURL.path, fixture.projectsRoot.path],
            projectsRoot: fixture.projectsRoot,
            hookRouter: fixture.router,
            hookInstaller: fixture.installer
        )
        defer { Task { await adapter.stop() } }
        try await adapter.start()
        _ = try await waitForSnapshot(adapter, timeoutSeconds: 12) { $0.status == .done }

        try await adapter.sendInput("Reply with the marker GT_RESUBMIT", submit: true)

        let recorded = try await waitForSnapshot(adapter, timeoutSeconds: 10) { snapshot in
            snapshot.recentMessages.contains { $0.role == .user && $0.text.contains("GT_RESUBMIT") }
        }
        XCTAssertNotNil(recorded)
        XCTAssertTrue(adapter.recentOutputTail(maxLength: 2000).contains("GT_ACCEPTED returns=2"),
                      "The second Return, not a retyped prompt, is what got it accepted: \(adapter.recentOutputTail(maxLength: 300))")
    }

    func testTrustPromptDetectionSurvivesTerminalWrapping() {
        let wrapped = """
         Quick safety check: Is this a project you created or one you
         trust? (Like your own code, a well-known open source project)
         ❯ 1. Yes, I trust this folder
           2. No, exit
        """
        XCTAssertTrue(ClaudeCodeAdapter.isTrustPrompt(wrapped))
        XCTAssertFalse(ClaudeCodeAdapter.isTrustPrompt("❯ Reply with a marker\n"))
        XCTAssertFalse(ClaudeCodeAdapter.isTrustPrompt("Do you trust the tests in this repository?"))

        let request = ClaudeCodeAdapter.trustPromptInputRequest(cwd: NSHomeDirectory() + "/Projects/demo")
        XCTAssertEqual(request.questions.first?.question, "Claude Code asks whether to trust ~/Projects/demo before it runs there.")
        XCTAssertEqual(request.questions.first?.choices.map(\.choiceId), ["trust", "exit"])
    }

    func testExplicitSessionArgumentsAreLeftAlone() {
        XCTAssertTrue(ClaudeCodeAdapter.hasExplicitSessionArgument(["--resume", "abc"]))
        XCTAssertTrue(ClaudeCodeAdapter.hasExplicitSessionArgument(["-c"]))
        XCTAssertTrue(ClaudeCodeAdapter.hasExplicitSessionArgument(["--session-id=abc"]))
        XCTAssertFalse(ClaudeCodeAdapter.hasExplicitSessionArgument(["--model", "claude-opus-4-8"]))
        XCTAssertFalse(ClaudeCodeAdapter.hasExplicitSessionArgument([]))
    }

    func testExplicitSessionIdIsExtractedFromArguments() {
        XCTAssertEqual(ClaudeCodeAdapter.explicitSessionId(in: ["--resume", "abc"]), "abc")
        XCTAssertEqual(ClaudeCodeAdapter.explicitSessionId(in: ["-r", "abc", "--model", "x"]), "abc")
        XCTAssertEqual(ClaudeCodeAdapter.explicitSessionId(in: ["--session-id=def"]), "def")
        XCTAssertNil(ClaudeCodeAdapter.explicitSessionId(in: ["--continue"]), "--continue names no id.")
        XCTAssertNil(ClaudeCodeAdapter.explicitSessionId(in: ["--resume", "--model"]), "A flag is not an id.")
        XCTAssertNil(ClaudeCodeAdapter.explicitSessionId(in: ["--resume"]))
        XCTAssertNil(ClaudeCodeAdapter.explicitSessionId(in: []))
    }

    func testExplicitResumeArgumentBecomesTheOwnedSession() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let adapter = ClaudeCodeAdapter(
            agentID: "claude-code-ownership-explicit-\(UUID().uuidString)",
            executable: fixture.executable.path,
            cwd: fixture.directory.path,
            arguments: ["--resume", "cccccccc-cccc-4ccc-8ccc-cccccccccccc"],
            projectsRoot: fixture.projectsRoot,
            hookRouter: fixture.router,
            hookInstaller: fixture.installer
        )
        defer { Task { await adapter.stop() } }

        try await adapter.start()

        XCTAssertEqual(adapter.arguments, ["--resume", "cccccccc-cccc-4ccc-8ccc-cccccccccccc"], "Caller-pinned sessions are launched as given.")
        fixture.source.fire(kind: .stop, session: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", summary: "explicit finished")
        let snapshot = try await waitForSnapshot(adapter) { $0.statusDetail == "explicit finished" }
        XCTAssertEqual(snapshot.status, .done)
    }

    // MARK: - Helpers

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-claude-ownership-\(UUID().uuidString)",
            isDirectory: true
        )
        let projectsRoot = directory.appendingPathComponent("projects", isDirectory: true)
        let binDirectory = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectsRoot.appendingPathComponent("-Users-developer-Example", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        let executable = binDirectory.appendingPathComponent("fake-claude.sh")
        try "#!/bin/sh\nsleep 5\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let source = FakeHookSource()
        return Fixture(
            directory: directory,
            projectsRoot: projectsRoot,
            executable: executable,
            source: source,
            router: ClaudeHookRouter(makeListener: { source }),
            installer: ClaudeCodeHookInstaller(settingsFileURL: directory.appendingPathComponent("settings.json"))
        )
    }

    private func makeAdapter(_ fixture: Fixture) -> ClaudeCodeAdapter {
        ClaudeCodeAdapter(
            agentID: "claude-code-ownership-\(UUID().uuidString)",
            executable: fixture.executable.path,
            cwd: fixture.directory.path,
            arguments: ["initial"],
            projectsRoot: fixture.projectsRoot,
            hookRouter: fixture.router,
            hookInstaller: fixture.installer
        )
    }

    private func writeSession(_ fixture: Fixture, sessionId: String, entrypoint: String, modifiedSecondsAgo: TimeInterval) throws {
        let url = fixture.projectsRoot
            .appendingPathComponent("-Users-developer-Example", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
        // The workspace root becomes the PTY's cwd on resume, so it must exist.
        let jsonl = """
        {"type":"user","entrypoint":"\(entrypoint)","cwd":"\(fixture.directory.path)","sessionId":"\(sessionId)","timestamp":"2026-05-17T10:00:00.000Z","message":{"role":"user","content":"Task \(sessionId.prefix(4))"}}
        """
        try jsonl.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-modifiedSecondsAgo)],
            ofItemAtPath: url.path
        )
    }

    private func waitForSnapshot(
        _ adapter: ClaudeCodeAdapter,
        timeoutSeconds: UInt64 = 4,
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
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw CancellationError()
            }
            let snapshot = try await group.next()
            group.cancelAll()
            if let snapshot { return snapshot }
            throw CancellationError()
        }
    }
}
