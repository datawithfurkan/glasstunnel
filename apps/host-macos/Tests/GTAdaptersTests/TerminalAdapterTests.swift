import XCTest
@testable import GTAdapters
import GTProtocol
import GTSecurity

final class TerminalAdapterTests: XCTestCase {
    func testDefaultLaunchUsesSharedScreenSessionWhenAvailable() {
        let launch = TerminalSessionConfiguration.defaultLaunch(
            shell: "/bin/zsh",
            sessionName: "glasstunnel-terminal",
            executableExists: { $0 == "/usr/bin/screen" }
        )

        XCTAssertEqual(launch.executable, "/usr/bin/screen")
        XCTAssertEqual(launch.arguments, ["-xRR", "-S", "glasstunnel-terminal"])
    }

    func testDefaultLaunchFallsBackToLoginShellWhenScreenIsMissing() {
        let launch = TerminalSessionConfiguration.defaultLaunch(
            shell: "/bin/zsh",
            sessionName: "glasstunnel-terminal",
            executableExists: { _ in false }
        )

        XCTAssertEqual(launch.executable, "/bin/zsh")
        XCTAssertEqual(launch.arguments, ["-l"])
    }

    func testVisibleTerminalCommandAttachesToSharedScreenSession() {
        XCTAssertEqual(
            TerminalSessionConfiguration.visibleTerminalCommand(sessionName: "glasstunnel-terminal"),
            "exec /usr/bin/screen -xRR -S glasstunnel-terminal"
        )
    }

    func testScreenSessionCleanupParsesAndSelectsOnlyDetachedGeneratedSessions() {
        let output = """
        There are screens on:
            62311.glasstunnel-terminal-1781597997067-089C045E (Attached)
            52191.glasstunnel-terminal-1781532428 (Detached)
            7271.glasstunnel-terminal (Detached)
            14627.glasstunnel-terminal-same-2 (Detached)
            70356.glasstunnel-terminal-two (Detached)
        5 Sockets in /var/folders/test.
        """

        let sessions = TerminalScreenSessionCleanup.parseScreenList(output)
        let candidates = TerminalScreenSessionCleanup.cleanupCandidates(from: sessions)

        XCTAssertEqual(sessions.map(\.name), [
            "glasstunnel-terminal-1781597997067-089C045E",
            "glasstunnel-terminal-1781532428",
            "glasstunnel-terminal",
            "glasstunnel-terminal-same-2",
            "glasstunnel-terminal-two",
        ])
        XCTAssertEqual(candidates, [
            .init(
                identifier: "52191",
                name: "glasstunnel-terminal-1781532428",
                state: .detached
            ),
        ])
    }

    func testGeneratedSessionNameClassifierRejectsManualSessionNames() {
        XCTAssertTrue(TerminalScreenSessionCleanup.isGeneratedGlasstunnelSessionName("glasstunnel-terminal-1781532428"))
        XCTAssertTrue(TerminalScreenSessionCleanup.isGeneratedGlasstunnelSessionName("glasstunnel-terminal-1781597997067-089C045E"))
        XCTAssertFalse(TerminalScreenSessionCleanup.isGeneratedGlasstunnelSessionName("glasstunnel-terminal"))
        XCTAssertFalse(TerminalScreenSessionCleanup.isGeneratedGlasstunnelSessionName("glasstunnel-terminal-two"))
        XCTAssertFalse(TerminalScreenSessionCleanup.isGeneratedGlasstunnelSessionName("glasstunnel-terminal-same-2"))
        XCTAssertFalse(TerminalScreenSessionCleanup.isGeneratedGlasstunnelSessionName("glasstunnel-terminal-abc"))
    }

    func testSubmittedInputSplitsMultilineCommands() {
        XCTAssertEqual(
            TerminalAdapter.commandLines(from: "echo one\npython3 --version"),
            ["echo one", "python3 --version"]
        )
        XCTAssertEqual(
            TerminalAdapter.commandLines(from: "pwd\r\nls"),
            ["pwd", "ls"]
        )
    }

    func testDetectsZshContinuationPrompts() {
        XCTAssertTrue(TerminalAdapter.isContinuationPromptTail("""
        %
        developer@Test-Mac / % echo "Hello
        dquote>
        """))
        XCTAssertTrue(TerminalAdapter.isContinuationPromptTail("quote>"))
        XCTAssertTrue(TerminalAdapter.isContinuationPromptTail("cmdsubst> "))
    }

    func testDoesNotTreatNormalPromptAsContinuation() {
        XCTAssertFalse(TerminalAdapter.isContinuationPromptTail("developer@Test-Mac / %"))
        XCTAssertFalse(TerminalAdapter.isContinuationPromptTail("Python 3.12.0\n%"))
    }

    func testDetectsReadyPromptTail() {
        XCTAssertTrue(TerminalAdapter.isReadyPromptTail("developer@Test-Mac / %"))
        XCTAssertTrue(TerminalAdapter.isReadyPromptTail("Python 3.12.0\n%"))
        XCTAssertTrue(TerminalAdapter.isReadyPromptTail("devbox ~/repo $"))
        XCTAssertTrue(TerminalAdapter.isReadyPromptTail("GT_TEST%"))
        XCTAssertFalse(TerminalAdapter.isReadyPromptTail("developer@Test-Mac / % sleep 20"))
        XCTAssertFalse(TerminalAdapter.isReadyPromptTail("running command"))
    }

    func testTerminalReturnsToIdleAfterNormalOutputSilence() {
        let adapter = TerminalAdapter()

        let transition = adapter.statusAfterOutputSilence(
            buffer: "developer@Test-Mac / % python3 --version\nPython 3.12.0\n%",
            silenceDuration: 2
        )

        XCTAssertEqual(transition.status, .idle)
        XCTAssertEqual(transition.detail, "ready")
    }

    func testTerminalStaysWorkingWhileSubmittedCommandIsSilent() {
        let adapter = TerminalAdapter()

        let transition = adapter.statusAfterOutputSilence(
            buffer: "developer@Test-Mac / % sleep 20",
            silenceDuration: 2
        )

        XCTAssertEqual(transition.status, .working)
        XCTAssertEqual(transition.detail, "running command")
    }

    func testTerminalStaysWorkingForContinuationPrompt() {
        let adapter = TerminalAdapter()

        let transition = adapter.statusAfterOutputSilence(
            buffer: "developer@Test-Mac / % echo \"Hello\ndquote>",
            silenceDuration: 2
        )

        XCTAssertEqual(transition.status, .working)
        XCTAssertEqual(transition.detail, "waiting for closing quote")
    }

    func testTerminalInterruptRemainsWorkingUntilPromptReturns() {
        let adapter = TerminalAdapter()

        let transition = adapter.statusAfterInterrupt()

        XCTAssertEqual(transition.status, .working)
        XCTAssertEqual(transition.detail, "interrupt sent")
    }

    func testTerminalPublishesNamedSharedSessionTarget() throws {
        let adapter = TerminalAdapter(screenSessionName: "glasstunnel-terminal-test")

        let target = try XCTUnwrap(adapter.snapshotAvailableTargets()?.first)

        XCTAssertEqual(target.targetId, "terminal-session:glasstunnel-terminal-test")
        XCTAssertEqual(target.label, "Default Terminal")
        XCTAssertEqual(target.subtitle, "Current session")
        XCTAssertTrue(target.selected)
        XCTAssertEqual(target.threadId, "terminal-session:glasstunnel-terminal-test")
        XCTAssertEqual(target.threadLabel, "Default Terminal")
        XCTAssertEqual(target.targetKind, "session")
        XCTAssertEqual(target.isActive, true)
        XCTAssertEqual(target.supportsNewThread, true)
    }

    func testTerminalPublishesRenamedSharedSessionTarget() throws {
        let adapter = TerminalAdapter(
            screenSessionName: "glasstunnel-terminal-test",
            sessionLabel: "Release console"
        )

        var target = try XCTUnwrap(adapter.snapshotAvailableTargets()?.first)
        XCTAssertEqual(target.label, "Release console")
        XCTAssertEqual(target.threadLabel, "Release console")

        adapter.setSessionLabel("Debug console")
        target = try XCTUnwrap(adapter.snapshotAvailableTargets()?.first)
        XCTAssertEqual(target.label, "Debug console")
        XCTAssertEqual(target.threadLabel, "Debug console")
    }

    func testTerminalPublishesMultipleSessionTargetsWithSelectedSession() throws {
        let adapter = TerminalAdapter(
            screenSessionName: "glasstunnel-terminal-two",
            sessionLabel: "Second console",
            sessionOptions: [
                .init(sessionName: "glasstunnel-terminal", label: "Default Terminal"),
                .init(sessionName: "glasstunnel-terminal-two", label: "Second console"),
            ]
        )

        let targets = try XCTUnwrap(adapter.snapshotAvailableTargets())

        XCTAssertEqual(targets.map(\.targetId), [
            "terminal-session:glasstunnel-terminal",
            "terminal-session:glasstunnel-terminal-two",
        ])
        XCTAssertEqual(targets.map(\.label), ["Default Terminal", "Second console"])
        XCTAssertEqual(targets.map(\.selected), [false, true])
        XCTAssertEqual(targets.map(\.subtitle), ["Switch session", "Current session"])
    }

    func testTerminalSessionNameParsesFromTargetId() {
        XCTAssertEqual(
            TerminalAdapter.sessionName(fromTargetId: "terminal-session:glasstunnel-terminal-two"),
            "glasstunnel-terminal-two"
        )
        XCTAssertNil(TerminalAdapter.sessionName(fromTargetId: "codex:one"))
        XCTAssertNil(TerminalAdapter.sessionName(fromTargetId: "terminal-session:"))
    }

    func testTerminalHidesLegacyAmbiguousScreenAttachOutput() {
        let buffer = """
        There are several suitable screens on:
            7271.glasstunnel-terminal
            (Detached)
            70356.glasstunnel-terminal-two
            (Detached)
        developer@test-mac host-macos %
        """

        let visible = TerminalAdapter.userVisibleBuffer(from: buffer)

        XCTAssertFalse(visible.contains("There are several suitable screens on:"))
        XCTAssertFalse(visible.contains("glasstunnel-terminal-two"))
        XCTAssertEqual(visible, "developer@test-mac host-macos %")
    }

    func testSharedPtyFallbackTailIsRedactedBeforeSnapshots() {
        let secret = "GTSECRET_12345"
        let adapter = RedactionProbePTYAdapter(
            agentID: "pty-tail-redaction-test-\(UUID().uuidString)",
            redactor: SecretRedactor(patterns: [
                SecretRedactor.Pattern(name: "test_secret", regex: #"GTSECRET_[0-9]+"#),
            ])
        )

        let messages = adapter.snapshotMessages(from: "provider auth failed for token \(secret)")
        let text = messages.map(\.text).joined(separator: "\n")

        XCTAssertFalse(text.contains(secret))
        XCTAssertTrue(text.contains("<redacted:test_secret>"))
        XCTAssertTrue(messages.contains { message in
            message.redacted && message.redactionReasons.contains("test_secret")
        })
    }

    func testTerminalRunsSubmittedCommandThroughPTY() async throws {
        let adapter = testTerminalAdapter()

        try await withRunningAdapter(adapter) { adapter in
            let output = expectation(description: "terminal command output")
            let ready = expectation(description: "terminal returns to ready status")
            let observer = observeSnapshots(from: adapter, fulfilling: output) { snapshot in
                snapshot.recentMessages.contains { message in
                    message.text.contains("GT_TERMINAL_OK")
                }
            }
            let readyObserver = observeSnapshots(from: adapter, fulfilling: ready) { snapshot in
                snapshot.status == .idle &&
                    snapshot.statusDetail == "ready" &&
                    snapshot.recentMessages.contains { message in
                        message.text.contains("GT_TERMINAL_OK")
                    }
            }
            defer {
                observer.cancel()
                readyObserver.cancel()
            }

            try await adapter.sendInput("printf 'GT_TERMINAL_OK\\n'", submit: true)

            await fulfillment(of: [output, ready], timeout: 8)
        }
    }

    func testTerminalDefaultsToUsableTermWhenHostEnvironmentIsDumb() async throws {
        let adapter = TerminalAdapter(
            agentID: "terminal-term-test-\(UUID().uuidString)",
            executable: "/bin/zsh",
            arguments: ["-f", "-i"],
            environment: [
                "PS1": "GT_TEST%% ",
            ],
            cwd: FileManager.default.temporaryDirectory.path
        )

        try await withRunningAdapter(adapter) { adapter in
            let output = expectation(description: "terminal TERM output")
            let observer = observeSnapshots(from: adapter, fulfilling: output) { snapshot in
                snapshot.recentMessages.contains { message in
                    message.text.contains("GT_TERM=xterm-256color")
                }
            }
            defer { observer.cancel() }

            try await adapter.sendInput("printf 'GT_TERM=%s\\n' \"$TERM\"", submit: true)

            await fulfillment(of: [output], timeout: 8)
        }
    }

    func testDefaultTerminalRunsSubmittedCommandThroughSharedScreenSession() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: TerminalSessionConfiguration.screenExecutable),
            "screen is not installed"
        )
        let sessionName = "glasstunnel-terminal-test-\(UUID().uuidString)"
        let adapter = TerminalAdapter(
            agentID: "terminal-screen-test-\(UUID().uuidString)",
            environment: [
                "PS1": "GT_TEST%% ",
            ],
            cwd: FileManager.default.temporaryDirectory.path,
            screenSessionName: sessionName
        )
        defer { terminateScreenSession(named: sessionName) }

        try await withRunningAdapter(adapter) { adapter in
            let output = expectation(description: "screen-backed terminal command output")
            let observer = observeSnapshots(from: adapter, fulfilling: output) { snapshot in
                snapshot.recentMessages.contains { message in
                    message.text.contains("GT_SCREEN_SESSION_OK")
                }
            }
            defer { observer.cancel() }

            try await adapter.sendInput("printf 'GT_SCREEN_SESSION_OK\\n'", submit: true)

            await fulfillment(of: [output], timeout: 8)
        }
    }

    func testTerminalInterruptsLongRunningProcessAndAcceptsNextCommand() async throws {
        let adapter = testTerminalAdapter()

        try await withRunningAdapter(adapter) { adapter in
            let interrupted = expectation(description: "terminal publishes interrupt status")
            let recovered = expectation(description: "terminal accepts command after interrupt")
            let interruptObserver = observeSnapshots(from: adapter, fulfilling: interrupted) { snapshot in
                snapshot.status == .working && snapshot.statusDetail == "interrupt sent"
            }
            let observer = observeSnapshots(from: adapter, fulfilling: recovered) { snapshot in
                snapshot.recentMessages.contains { message in
                    message.text.contains("GT_AFTER_INTERRUPT")
                }
            }
            defer {
                interruptObserver.cancel()
                observer.cancel()
            }

            try await adapter.sendInput("sleep 20", submit: true)
            try await Task.sleep(nanoseconds: 250_000_000)
            try await adapter.interrupt()
            try await Task.sleep(nanoseconds: 250_000_000)
            try await adapter.sendInput("printf 'GT_AFTER_INTERRUPT\\n'", submit: true)

            await fulfillment(of: [interrupted, recovered], timeout: 8)
        }
    }

    private func testTerminalAdapter() -> TerminalAdapter {
        TerminalAdapter(
            agentID: "terminal-test-\(UUID().uuidString)",
            executable: "/bin/zsh",
            arguments: ["-f", "-i"],
            environment: [
                "TERM": "xterm-256color",
                "PS1": "GT_TEST%% ",
            ],
            cwd: FileManager.default.temporaryDirectory.path
        )
    }

    private func withRunningAdapter(
        _ adapter: TerminalAdapter,
        body: (TerminalAdapter) async throws -> Void
    ) async throws {
        try await adapter.start()
        do {
            try await body(adapter)
        } catch {
            await adapter.stop()
            throw error
        }
        await adapter.stop()
    }

    private func observeSnapshots(
        from adapter: TerminalAdapter,
        fulfilling expectation: XCTestExpectation,
        when predicate: @escaping @Sendable (AgentStateSnapshot) -> Bool
    ) -> Task<Void, Never> {
        Task {
            for await snapshot in adapter.observeState() {
                if predicate(snapshot) {
                    expectation.fulfill()
                    break
                }
            }
        }
    }

    private func terminateScreenSession(named name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: TerminalSessionConfiguration.screenExecutable)
        process.arguments = ["-S", name, "-X", "quit"]
        try? process.run()
        process.waitUntilExit()
    }
}

private final class RedactionProbePTYAdapter: PTYAdapterBase, @unchecked Sendable {
    init(agentID: AgentID, redactor: SecretRedactor) {
        super.init(
            agentID: agentID,
            kind: .terminal,
            label: "Redaction probe",
            executable: "/bin/cat",
            redactor: redactor
        )
    }
}
