import XCTest
@testable import GTAdapters
import GTProtocol
import GTSecurity

final class CodexRuntimeCatalogTests: XCTestCase {
    func testCodexCliStartStaysBusyUntilTheInteractivePromptIsReady() async throws {
        let adapter = CodexAdapter(
            agentID: "codex-cli-starting-test-\(UUID().uuidString)",
            executable: "/bin/sleep",
            arguments: ["30"],
            cwd: FileManager.default.temporaryDirectory.path
        )

        try await withRunningAdapter(adapter) { adapter in
            let snapshot = try await waitForSnapshot(adapter) { snapshot in
                snapshot.status == .working && snapshot.statusDetail == "starting Codex"
            }

            XCTAssertEqual(snapshot.status, .working)
        }
    }

    func testCodexCliDefaultsToHomeInsteadOfHostWorkingDirectory() {
        let adapter = CodexAdapter(executable: "/usr/bin/true")

        XCTAssertEqual(adapter.cwd, FileManager.default.homeDirectoryForCurrentUser.path)
    }

    func testLaunchArgumentsMatchCurrentCodexCliFlags() {
        let arguments = CodexRuntimeCatalog.launchArguments(
            selection: CodexRuntimeSelection(
                modelId: "gpt-5.5",
                reasoningEffort: "xhigh",
                fastMode: true
            )
        )

        XCTAssertEqual(arguments, [
            "--no-alt-screen",
            "--disable", "plugins",
            "--disable", "apps",
            "-c", "mcp_servers.node_repl.enabled=false",
            "--model", "gpt-5.5",
            "-c", "model_reasoning_effort=\"xhigh\"",
            "-c", "check_for_update_on_startup=false",
            "-c", "service_tier=\"fast\"",
        ])
    }

    func testLaunchArgumentsUseDefaultServiceTierWhenFastModeIsOff() {
        let arguments = CodexRuntimeCatalog.launchArguments(
            selection: CodexRuntimeSelection(
                modelId: nil,
                reasoningEffort: nil,
                fastMode: false
            )
        )

        XCTAssertEqual(arguments, [
            "--no-alt-screen",
            "--disable", "plugins",
            "--disable", "apps",
            "-c", "mcp_servers.node_repl.enabled=false",
            "-c", "check_for_update_on_startup=false",
            "-c", "service_tier=\"default\"",
        ])
    }

    func testRuntimeUpdateValuesAreTrimmedAndBlankValuesClearSelection() throws {
        XCTAssertEqual(try CodexAdapter.normalizedRuntimeValue("  gpt-5.5  "), "gpt-5.5")
        XCTAssertEqual(try CodexAdapter.normalizedReasoningEffort("\n\txhigh "), "xhigh")
        XCTAssertNil(try CodexAdapter.normalizedRuntimeValue("   "))
    }

    func testRuntimeUpdateValuesRejectMalformedInput() throws {
        XCTAssertThrowsError(try CodexAdapter.normalizedRuntimeValue("gpt 5.5"))
        XCTAssertThrowsError(try CodexAdapter.normalizedRuntimeValue("gpt-5.5\""))
        XCTAssertThrowsError(try CodexAdapter.normalizedReasoningEffort("extreme"))
    }

    func testCodexCliRuntimeControlsDispatchThroughAgentAdapter() {
        let adapter: any AgentAdapter = CodexAdapter(
            agentID: "codex-cli",
            executable: "/usr/bin/true",
            cwd: FileManager.default.temporaryDirectory.path
        )

        let controls = adapter.runtimeControls()

        XCTAssertFalse(controls?.modelOptions.isEmpty ?? true)
        XCTAssertFalse(controls?.reasoningEffortOptions.isEmpty ?? true)
        XCTAssertEqual(controls?.supportsModelSelection, true)
        XCTAssertEqual(controls?.supportsReasoningEffort, true)
        XCTAssertEqual(controls?.editable, true)
    }

    func testCodexCliFallbackPtyTailIsRedactedBeforeSnapshots() {
        let secret = "GTSECRET_12345"
        let adapter = CodexAdapter(
            agentID: "codex-cli-tail-redaction-test-\(UUID().uuidString)",
            executable: "/bin/cat",
            redactor: SecretRedactor(patterns: [
                SecretRedactor.Pattern(name: "test_secret", regex: #"GTSECRET_[0-9]+"#),
            ])
        )

        let messages = adapter.snapshotMessages(from: "Provider auth failed with token \(secret).")
        let text = messages.map(\.text).joined(separator: "\n")

        XCTAssertFalse(text.contains(secret))
        XCTAssertTrue(text.contains("<redacted:test_secret>"))
        XCTAssertTrue(messages.contains { message in
            message.redacted && message.redactionReasons.contains("test_secret")
        })
    }

    func testCodexCliSnapshotsIncludeRuntimeControlsFromPtyEmitter() async throws {
        let adapter = CodexAdapter(
            agentID: "codex-cli-snapshot-controls-test-\(UUID().uuidString)",
            executable: "/bin/zsh",
            arguments: ["-f", "-c", "printf 'GT_CODEX_RUNTIME_CONTROLS\\n'"],
            cwd: FileManager.default.temporaryDirectory.path
        )

        try await withRunningAdapter(adapter) { adapter in
            let output = expectation(description: "codex cli runtime controls in snapshot")
            let observer = observeSnapshots(from: adapter, fulfilling: output) { snapshot in
                guard let controls = snapshot.runtimeControls else { return false }
                return controls.supportsModelSelection &&
                    controls.supportsReasoningEffort &&
                    !controls.modelOptions.isEmpty &&
                    !controls.reasoningEffortOptions.isEmpty &&
                    snapshot.recentMessages.contains { message in
                        message.text.contains("GT_CODEX_RUNTIME_CONTROLS")
                    }
            }
            defer { observer.cancel() }

            await fulfillment(of: [output], timeout: 8)
        }
    }

    func testCodexCliRuntimeUpdateRestartsWithUpdatedLaunchArguments() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-codex-runtime-restart-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let argumentsFile = directory.appendingPathComponent("arguments.txt")
        let executable = directory.appendingPathComponent("record-args.sh")
        let script = """
        #!/bin/sh
        : > "\(argumentsFile.path)"
        for arg in "$@"; do
          printf '%s\\n' "$arg" >> "\(argumentsFile.path)"
        done
        printf '>\\n'
        sleep 30
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = CodexAdapter(
            agentID: "codex-cli-runtime-restart-test-\(UUID().uuidString)",
            executable: executable.path,
            arguments: ["initial"],
            cwd: directory.path
        )

        try await withRunningAdapter(adapter) { adapter in
            try await waitForFile(argumentsFile, toEqualLines: ["initial"])
            _ = try await waitForSnapshot(adapter, timeout: 6) { snapshot in
                snapshot.status == .done && snapshot.statusDetail == "prompt returned"
            }

            async let restartingSnapshot = waitForSnapshot(adapter) { snapshot in
                snapshot.status == .working && snapshot.statusDetail == "starting Codex"
            }

            try await adapter.updateRuntimeSettings(
                AgentRuntimeSettingsUpdate(
                    agentId: adapter.agentID,
                    modelId: "  gpt-5.5  ",
                    reasoningEffort: "\txhigh\n",
                    fastMode: true
                )
            )
            _ = try await restartingSnapshot

            let expectedArguments = [
                "--no-alt-screen",
                "--disable", "plugins",
                "--disable", "apps",
                "-c", "mcp_servers.node_repl.enabled=false",
                "--model", "gpt-5.5",
                "-c", "model_reasoning_effort=\"xhigh\"",
                "-c", "check_for_update_on_startup=false",
                "-c", "service_tier=\"fast\"",
            ]
            XCTAssertEqual(adapter.arguments, expectedArguments)
            XCTAssertEqual(adapter.cwd, directory.path)
            try await waitForFile(argumentsFile, toEqualLines: expectedArguments)

            let controls = try XCTUnwrap(adapter.runtimeControls())
            XCTAssertEqual(controls.modelId, "gpt-5.5")
            XCTAssertEqual(controls.reasoningEffort, "xhigh")
            XCTAssertEqual(controls.fastMode, true)
            XCTAssertEqual(controls.appliesOn, .immediate)
            XCTAssertEqual(controls.note, "Restarts Codex CLI. App and plugin integrations are off.")
        }
    }

    func testCodexCliRejectsMalformedRuntimeUpdateWithoutChangingSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-codex-runtime-invalid-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let argumentsFile = directory.appendingPathComponent("arguments.txt")
        let executable = directory.appendingPathComponent("record-args.sh")
        let script = """
        #!/bin/sh
        : > "\(argumentsFile.path)"
        for arg in "$@"; do
          printf '%s\\n' "$arg" >> "\(argumentsFile.path)"
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = CodexAdapter(
            agentID: "codex-cli-runtime-invalid-test-\(UUID().uuidString)",
            executable: executable.path,
            arguments: ["initial"],
            cwd: directory.path
        )

        try await withRunningAdapter(adapter) { adapter in
            try await waitForFile(argumentsFile, toEqualLines: ["initial"])

            try await adapter.updateRuntimeSettings(
                AgentRuntimeSettingsUpdate(
                    agentId: adapter.agentID,
                    modelId: "gpt-5.5",
                    reasoningEffort: "xhigh",
                    fastMode: true
                )
            )

            let expectedArguments = [
                "--no-alt-screen",
                "--disable", "plugins",
                "--disable", "apps",
                "-c", "mcp_servers.node_repl.enabled=false",
                "--model", "gpt-5.5",
                "-c", "model_reasoning_effort=\"xhigh\"",
                "-c", "check_for_update_on_startup=false",
                "-c", "service_tier=\"fast\"",
            ]
            try await waitForFile(argumentsFile, toEqualLines: expectedArguments)

            async let rollbackSnapshot = waitForSnapshot(adapter) { snapshot in
                snapshot.statusDetail == "settings failed" &&
                    snapshot.runtimeControls?.modelId == "gpt-5.5" &&
                    snapshot.runtimeControls?.reasoningEffort == "xhigh" &&
                    snapshot.runtimeControls?.fastMode == true
            }

            do {
                try await adapter.updateRuntimeSettings(
                    AgentRuntimeSettingsUpdate(
                        agentId: adapter.agentID,
                        modelId: "gpt-5.4",
                        reasoningEffort: "xhigh\"",
                        fastMode: false
                    )
                )
                XCTFail("Malformed Codex runtime update should be rejected.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Codex reasoning effort"))
            }

            _ = try await rollbackSnapshot

            XCTAssertEqual(adapter.arguments, expectedArguments)
            try await waitForFile(argumentsFile, toEqualLines: expectedArguments)

            let controls = try XCTUnwrap(adapter.runtimeControls())
            XCTAssertEqual(controls.modelId, "gpt-5.5")
            XCTAssertEqual(controls.reasoningEffort, "xhigh")
            XCTAssertEqual(controls.fastMode, true)
        }
    }

    func testCodexCliRuntimeRestartFailureRollsBackSelectionAndArguments() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-codex-runtime-restart-fail-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let argumentsFile = directory.appendingPathComponent("arguments.txt")
        let executable = directory.appendingPathComponent("record-args.sh")
        let script = """
        #!/bin/sh
        : > "\(argumentsFile.path)"
        for arg in "$@"; do
          printf '%s\\n' "$arg" >> "\(argumentsFile.path)"
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = CodexAdapter(
            agentID: "codex-cli-runtime-restart-fail-test-\(UUID().uuidString)",
            executable: executable.path,
            arguments: ["initial"],
            cwd: directory.path
        )

        try await withRunningAdapter(adapter) { adapter in
            try await waitForFile(argumentsFile, toEqualLines: ["initial"])

            try await adapter.updateRuntimeSettings(
                AgentRuntimeSettingsUpdate(
                    agentId: adapter.agentID,
                    modelId: "gpt-5.5",
                    reasoningEffort: "xhigh",
                    fastMode: true
                )
            )

            let expectedArguments = [
                "--no-alt-screen",
                "--disable", "plugins",
                "--disable", "apps",
                "-c", "mcp_servers.node_repl.enabled=false",
                "--model", "gpt-5.5",
                "-c", "model_reasoning_effort=\"xhigh\"",
                "-c", "check_for_update_on_startup=false",
                "-c", "service_tier=\"fast\"",
            ]
            XCTAssertEqual(adapter.arguments, expectedArguments)
            try await waitForFile(argumentsFile, toEqualLines: expectedArguments)

            try FileManager.default.removeItem(at: executable)

            async let rollbackSnapshot = waitForSnapshot(adapter) { snapshot in
                snapshot.statusDetail == "settings failed" &&
                    snapshot.runtimeControls?.modelId == "gpt-5.5" &&
                    snapshot.runtimeControls?.reasoningEffort == "xhigh" &&
                    snapshot.runtimeControls?.fastMode == true
            }

            do {
                try await adapter.updateRuntimeSettings(
                    AgentRuntimeSettingsUpdate(
                        agentId: adapter.agentID,
                        modelId: "gpt-5.4",
                        reasoningEffort: "high",
                        fastMode: false
                    )
                )
                XCTFail("Codex runtime update should fail when restart fails.")
            } catch {
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }

            _ = try await rollbackSnapshot

            XCTAssertEqual(adapter.arguments, expectedArguments)
            try await waitForFile(argumentsFile, toEqualLines: expectedArguments)

            let controls = try XCTUnwrap(adapter.runtimeControls())
            XCTAssertEqual(controls.modelId, "gpt-5.5")
            XCTAssertEqual(controls.reasoningEffort, "xhigh")
            XCTAssertEqual(controls.fastMode, true)
        }
    }

    func testCodexCliRejectsRuntimeUpdateWhilePromptIsRunning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-codex-runtime-busy-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let argumentsFile = directory.appendingPathComponent("arguments.txt")
        let executable = directory.appendingPathComponent("record-args-and-wait.sh")
        let script = """
        #!/bin/sh
        : > "\(argumentsFile.path)"
        for arg in "$@"; do
          printf '%s\\n' "$arg" >> "\(argumentsFile.path)"
        done
        sleep 30
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = CodexAdapter(
            agentID: "codex-cli-runtime-busy-test-\(UUID().uuidString)",
            executable: executable.path,
            arguments: ["initial"],
            cwd: directory.path
        )

        try await withRunningAdapter(adapter) { adapter in
            try await waitForFile(argumentsFile, toEqualLines: ["initial"])
            let initialControls = try XCTUnwrap(adapter.runtimeControls())
            adapter.transitionTo(.working, detail: "user input submitted", forceEmit: true)

            let failedSettings = expectation(description: "codex runtime settings rejected while busy")
            let failedSettingsObserver = observeSnapshots(from: adapter, fulfilling: failedSettings) { snapshot in
                snapshot.statusDetail == "settings failed" &&
                    snapshot.status == .working &&
                    snapshot.runtimeControls?.modelId == initialControls.modelId &&
                    snapshot.runtimeControls?.fastMode == initialControls.fastMode
            }
            defer { failedSettingsObserver.cancel() }

            do {
                try await adapter.updateRuntimeSettings(
                    AgentRuntimeSettingsUpdate(
                        agentId: adapter.agentID,
                        modelId: "gpt-5.4",
                        reasoningEffort: "high",
                        fastMode: true
                    )
                )
                XCTFail("Codex runtime settings should be rejected while a prompt is running.")
            } catch {
                XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("running"))
            }

            await fulfillment(of: [failedSettings], timeout: 8)

            XCTAssertEqual(adapter.arguments, ["initial"])
            try await waitForFile(argumentsFile, toEqualLines: ["initial"])

            let controls = try XCTUnwrap(adapter.runtimeControls())
            XCTAssertEqual(controls.modelId, initialControls.modelId)
            XCTAssertEqual(controls.reasoningEffort, initialControls.reasoningEffort)
            XCTAssertEqual(controls.fastMode, initialControls.fastMode)
        }
    }

    func testCodexCliDoesNotMarkSilentWorkDoneWithoutPrompt() {
        let adapter = CodexAdapter()

        let transition = adapter.statusAfterOutputSilence(
            buffer: "Thinking through the requested refactor...",
            silenceDuration: 4
        )

        XCTAssertEqual(transition.status, .working)
        XCTAssertEqual(transition.detail, "waiting for Codex output")
    }

    func testCodexCliUpdatePromptWaitsForInput() {
        let adapter = CodexAdapter()
        let updatePrompt = """
        Update available! 0.137.0 - 0.139.0
        Release notes: https://github.com/openai/codex/releases/latest
        1. Update now (runs 'npm install -g @openai/codex')
        2. Skip
        3. Skip until next version
        Press enter to continue
        """

        let transition = adapter.statusAfterOutputSilence(
            buffer: updatePrompt,
            silenceDuration: 4
        )

        XCTAssertEqual(transition.status, .waitingInput)
        XCTAssertEqual(transition.detail, "Codex update prompt")
        XCTAssertTrue(CodexAdapter.isUpdatePrompt(updatePrompt))
    }

    func testCodexCliUpdatePromptDetectionHandlesCollapsedTuiOutput() {
        let collapsed = """
        Update
        available!0.137.0 - 0.139.0Release
        notes:
        https://github.com/openai/codex/releases/latest› 1. Update now (runs 'npm install -
        g @openai/codex')2.Skip3.SkipuntilnextversionPress enter to continue
        """

        XCTAssertTrue(CodexAdapter.isUpdatePrompt(collapsed))
    }

    func testCodexCliUpdatePromptPublishesChoices() {
        let request = CodexAdapter.updatePromptInputRequest()

        XCTAssertEqual(request.requestId, "codex-cli-update-prompt")
        XCTAssertEqual(request.questions.first?.questionId, "codex-cli-update-choice")
        XCTAssertEqual(request.questions.first?.choices.map(\.choiceId), ["2", "3", "1"])
        XCTAssertEqual(request.questions.first?.choices.first?.label, "Skip")
        XCTAssertEqual(request.questions.first?.choices.first?.recommended, true)
    }

    func testCodexCliMarksDoneOnlyAfterPromptReturns() {
        let adapter = CodexAdapter()

        let transition = adapter.statusAfterOutputSilence(
            buffer: """
            Here is the final answer.
            >
            """,
            silenceDuration: 4
        )

        XCTAssertEqual(transition.status, .done)
        XCTAssertEqual(transition.detail, "prompt returned")
    }

    func testCodexCliPromptDetectionUsesLastLinePromptSuffix() {
        XCTAssertTrue(CodexAdapter.isReadyPromptTail("answer\n>"))
        XCTAssertTrue(CodexAdapter.isReadyPromptTail("devbox ~/repo $"))
        XCTAssertTrue(CodexAdapter.isReadyPromptTail("root #"))
        XCTAssertFalse(CodexAdapter.isReadyPromptTail("Thinking through the requested refactor..."))
        XCTAssertFalse(CodexAdapter.isReadyPromptTail("Use the XML tag <goal>"))
    }

    func testCodexCliPromptDetectionHandlesCollapsedNoAltScreenTuiPrompt() {
        let collapsed = """
        ╭──────────────────────────────────────────────╮│ >_ OpenAI Codex (v0.137.0)                   ││                                              ││ model:       loading   /model to change      ││ directory:   ~/Documents/GitHub2/glasstunnel ││ permissions: YOLO mode                       │╰──────────────────────────────────────────────╯›Use /skills to list available skillsgpt-5.5 default · ~/Documents/GitHub2/glasstunnel•Starting MCP servers (0/2): creative_production_mcp, xcodebuildmcp(0s • esc to interrupt)›Use /skills to list available skillsgpt-5.5 low · ~/Documents/GitHub2/glasstunnel
        """

        let transition = CodexAdapter().statusAfterOutputSilence(
            buffer: collapsed,
            silenceDuration: 4
        )

        XCTAssertTrue(CodexAdapter.isReadyPromptTail(collapsed))
        XCTAssertEqual(transition.status, .done)
        XCTAssertEqual(transition.detail, "prompt returned")
    }

    func testCodexCliPromptDetectionHandlesCollapsedNoAltScreenTemplatePrompt() {
        let collapsed = """
        ╭──────────────────────────────────────────────╮│ >_ OpenAI Codex (v0.137.0)                   ││                                              ││ model:       loading   /model to change      ││ directory:   ~/Documents/GitHub2/glasstunnel ││ permissions: YOLO mode                       │╰──────────────────────────────────────────────╯›Write tests for @filenamegpt-5.5 default · ~/Documents/GitHub2/glasstunnel•Starting MCP servers (0/3): creative_production_mcp, openai-api-key-local-confirmation, xcodebuildmcp(0s • esc to interrupt)›Write tests for @filenamegpt-5.5 low · ~/Documents/GitHub2/glasstunnel
        """

        let transition = CodexAdapter().statusAfterOutputSilence(
            buffer: collapsed,
            silenceDuration: 4
        )

        XCTAssertTrue(CodexAdapter.isReadyPromptTail(collapsed))
        XCTAssertEqual(transition.status, .done)
        XCTAssertEqual(transition.detail, "prompt returned")
    }

    func testCodexCliDoesNotTreatTemplateRedrawAsDoneAfterSubmission() async throws {
        let adapter = CodexAdapter(
            agentID: "codex-cli-in-flight-\(UUID().uuidString)",
            executable: "/usr/bin/tee",
            arguments: ["/dev/null"],
            cwd: FileManager.default.temporaryDirectory.path
        )
        let collapsed = """
        ›Use /skills to list available skillsgpt-5.4-mini low · ~
        •Working(4s • esc to interrupt)
        ›Use /skills to list available skillsgpt-5.4-mini low · ~
        """

        try await withRunningAdapter(adapter) { adapter in
            try await adapter.sendInput("GT_CODEX_IN_FLIGHT", submit: true)

            let running = adapter.statusAfterOutputSilence(
                buffer: collapsed,
                silenceDuration: 4
            )
            XCTAssertEqual(running.status, .working)
            XCTAssertEqual(running.detail, "waiting for Codex output")

            try await adapter.interrupt()
            let recovered = adapter.statusAfterOutputSilence(
                buffer: collapsed,
                silenceDuration: 4
            )
            XCTAssertEqual(recovered.status, .done)
            XCTAssertEqual(recovered.detail, "prompt returned")
        }
    }

    func testCodexCliPromptDetectionWaitsForPromptAfterMCPStartup() {
        let starting = """
        ╭──────────────────────────────────────────────╮│ >_ OpenAI Codex (v0.137.0)                   ││                                              ││ model:       loading   /model to change      ││ directory:   ~/Documents/GitHub2/glasstunnel ││ permissions: YOLO mode                       │╰──────────────────────────────────────────────╯›Run /review on my current changesgpt-5.5 default · ~/Documents/GitHub2/glasstunnel•Starting MCP servers (0/2): node_repl, openai-api-key-local-confirmation(0s • esc to interrupt)
        """
        let ready = """
        \(starting)›Run /review on my current changesgpt-5.5 low · ~/Documents/GitHub2/glasstunnel
        """

        let startingTransition = CodexAdapter().statusAfterOutputSilence(
            buffer: starting,
            silenceDuration: 4
        )
        let readyTransition = CodexAdapter().statusAfterOutputSilence(
            buffer: ready,
            silenceDuration: 4
        )

        XCTAssertFalse(CodexAdapter.isReadyPromptTail(starting))
        XCTAssertEqual(startingTransition.status, .working)
        XCTAssertEqual(startingTransition.detail, "waiting for Codex output")
        XCTAssertTrue(CodexAdapter.isReadyPromptTail(ready))
        XCTAssertEqual(readyTransition.status, .done)
        XCTAssertEqual(readyTransition.detail, "prompt returned")
    }

    func testCodexCliAdapterDefaultsToUsableTermWhenHostEnvironmentIsDumb() async throws {
        let adapter = CodexAdapter(
            agentID: "codex-cli-term-test-\(UUID().uuidString)",
            executable: "/bin/zsh",
            arguments: ["-f", "-c", "printf 'GT_CODEX_TERM=%s\\n' \"$TERM\""],
            environment: [
                "TERM": "dumb",
            ],
            cwd: FileManager.default.temporaryDirectory.path
        )

        try await withRunningAdapter(adapter) { adapter in
            let output = expectation(description: "codex cli TERM output")
            let observer = observeSnapshots(from: adapter, fulfilling: output) { snapshot in
                snapshot.recentMessages.contains { message in
                    message.text.contains("GT_CODEX_TERM=xterm-256color")
                }
            }
            defer { observer.cancel() }

            await fulfillment(of: [output], timeout: 8)
        }
    }

    func testCodexCliUpdatePromptRecommendedSkipSendsDownThenEnterToPty() async throws {
        let adapter = CodexAdapter(
            agentID: "codex-cli-choice-test-\(UUID().uuidString)",
            executable: "/usr/bin/python3",
            arguments: ["-c", "import sys; data=sys.stdin.buffer.readline(); print('GT_CODEX_BYTES=' + data.hex())"],
            cwd: FileManager.default.temporaryDirectory.path
        )

        try await withRunningAdapter(adapter) { adapter in
            let output = expectation(description: "codex cli update choice output")
            let observer = observeSnapshots(from: adapter, fulfilling: output) { snapshot in
                snapshot.recentMessages.contains { message in
                    message.text.contains("GT_CODEX_BYTES=1b5b420a")
                }
            }
            defer { observer.cancel() }

            try await adapter.respondToInputRequest(
                AgentInputRequestResponse(
                    agentId: adapter.agentID,
                    requestId: "codex-cli-update-prompt",
                    answers: [
                        AgentInputRequestAnswer(
                            questionId: "codex-cli-update-choice",
                            choiceIds: ["2"]
                        ),
                    ]
                )
            )

            await fulfillment(of: [output], timeout: 8)
        }
    }

    func testCodexCliUpdatePromptExplicitUpdateChoiceSendsEnterToPty() async throws {
        let adapter = CodexAdapter(
            agentID: "codex-cli-explicit-choice-test-\(UUID().uuidString)",
            executable: "/usr/bin/python3",
            arguments: ["-c", "import sys; data=sys.stdin.buffer.readline(); print('GT_CODEX_BYTES=' + data.hex())"],
            cwd: FileManager.default.temporaryDirectory.path
        )

        try await withRunningAdapter(adapter) { adapter in
            let output = expectation(description: "codex cli explicit update choice output")
            let observer = observeSnapshots(from: adapter, fulfilling: output) { snapshot in
                snapshot.recentMessages.contains { message in
                    message.text.contains("GT_CODEX_BYTES=0a")
                }
            }
            defer { observer.cancel() }

            try await adapter.respondToInputRequest(
                AgentInputRequestResponse(
                    agentId: adapter.agentID,
                    requestId: "codex-cli-update-prompt",
                    answers: [
                        AgentInputRequestAnswer(
                            questionId: "codex-cli-update-choice",
                            choiceIds: ["1"]
                        ),
                    ]
                )
            )

            await fulfillment(of: [output], timeout: 8)
        }
    }

    func testCodexCliUpdatePromptResponseClearsStalePromptBeforeNextOutput() async throws {
        let prompt = """
        Update available! 0.137.0 - 0.139.0
        Release notes: https://github.com/openai/codex/releases/latest
        1. Update now (runs 'npm install -g @openai/codex')
        2. Skip
        3. Skip until next version
        Press enter to continue

        """
        let escapedPrompt = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "'\\''")
        let adapter = CodexAdapter(
            agentID: "codex-cli-clear-prompt-test-\(UUID().uuidString)",
            executable: "/bin/zsh",
            arguments: ["-f", "-c", "printf '\(escapedPrompt)'; IFS= read -r choice; printf 'GT_CODEX_AFTER=%s\\n' \"$choice\""],
            cwd: FileManager.default.temporaryDirectory.path
        )

        try await withRunningAdapter(adapter) { adapter in
            let promptPublished = expectation(description: "codex cli update prompt published")
            let promptObserver = observeSnapshots(from: adapter, fulfilling: promptPublished) { snapshot in
                snapshot.pendingInputRequest?.requestId == "codex-cli-update-prompt"
            }

            await fulfillment(of: [promptPublished], timeout: 8)
            promptObserver.cancel()

            let output = expectation(description: "codex cli output after update choice")
            let outputObserver = observeSnapshots(from: adapter, fulfilling: output) { snapshot in
                snapshot.pendingInputRequest == nil &&
                    snapshot.recentMessages.contains { message in
                        message.text.contains("GT_CODEX_AFTER=") &&
                            !message.text.contains("Update available")
                    }
            }
            defer { outputObserver.cancel() }

            try await adapter.respondToInputRequest(
                AgentInputRequestResponse(
                    agentId: adapter.agentID,
                    requestId: "codex-cli-update-prompt",
                    answers: [
                        AgentInputRequestAnswer(
                            questionId: "codex-cli-update-choice",
                            choiceIds: ["2"]
                        ),
                    ]
                )
            )

            await fulfillment(of: [output], timeout: 8)
        }
    }

    private func withRunningAdapter(
        _ adapter: CodexAdapter,
        body: (CodexAdapter) async throws -> Void
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
        from adapter: CodexAdapter,
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

    private func waitForSnapshot(
        _ adapter: CodexAdapter,
        timeout: TimeInterval = 4,
        matching predicate: @escaping (AgentStateSnapshot) -> Bool
    ) async throws -> AgentStateSnapshot {
        try await withThrowingTaskGroup(of: AgentStateSnapshot?.self) { group in
            group.addTask {
                for await snapshot in adapter.observeState() {
                    if predicate(snapshot) {
                        return snapshot
                    }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }

            let snapshot = try await group.next()
            group.cancelAll()
            if let snapshot = snapshot, let snapshot {
                return snapshot
            }
            throw NSError(
                domain: "CodexRuntimeCatalogTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for Codex snapshot."]
            )
        }
    }

    private func waitForFile(_ url: URL, toEqualLines expected: [String]) async throws {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if let contents = try? String(contentsOf: url, encoding: .utf8) {
                let lines = contents
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init)
                    .filter { !$0.isEmpty }
                if lines == expected {
                    return
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? "<missing>"
        XCTFail("Timed out waiting for \(url.path) to contain expected runtime arguments. Actual contents: \(contents)")
    }
}
