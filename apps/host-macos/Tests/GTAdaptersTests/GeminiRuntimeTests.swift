import XCTest
@testable import GTAdapters
import GTProtocol
import GTSecurity

final class GeminiRuntimeTests: XCTestCase {
    func testGeminiRuntimeModelNormalizationRejectsUnsafeValues() throws {
        XCTAssertEqual(try GeminiAdapter.normalizedRuntimeValue("  gemini-2.5-flash  "), "gemini-2.5-flash")
        XCTAssertNil(try GeminiAdapter.normalizedRuntimeValue("   "))
        XCTAssertThrowsError(try GeminiAdapter.normalizedRuntimeValue("gemini-2.5 flash"))
        XCTAssertThrowsError(try GeminiAdapter.normalizedRuntimeValue("gemini-2.5-flash\""))
        XCTAssertThrowsError(try GeminiAdapter.normalizedRuntimeValue("gemini-2.5-flash\u{0000}"))
    }

    func testGeminiSubmittedPromptUsesSupportedHeadlessPromptMode() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-gemini-headless-prompt-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let argumentsFile = directory.appendingPathComponent("arguments.txt")
        let executable = directory.appendingPathComponent("record-headless-prompt.sh")
        let script = """
        #!/bin/sh
        : > "\(argumentsFile.path)"
        for arg in "$@"; do
          printf '%s\\n' "$arg" >> "\(argumentsFile.path)"
        done
        printf 'GT_GEMINI_HEADLESS_OK\\n'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = GeminiAdapter(
            agentID: "gemini-headless-prompt-test-\(UUID().uuidString)",
            executable: executable.path,
            cwd: directory.path
        )

        try await withRunningAdapter(adapter) { adapter in
            XCTAssertFalse(FileManager.default.fileExists(atPath: argumentsFile.path))

            try await adapter.sendInput("Reply with a marker", submit: true)
            try await waitForFile(argumentsFile, toEqualLines: ["--skip-trust", "--prompt", "Reply with a marker"])
        }
    }

    func testGeminiInterruptDoesNotTurnStoppedHeadlessPromptIntoError() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-gemini-headless-interrupt-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let argumentsFile = directory.appendingPathComponent("arguments.txt")
        let executable = directory.appendingPathComponent("record-sleeping-prompt.sh")
        let script = """
        #!/bin/sh
        : > "\(argumentsFile.path)"
        for arg in "$@"; do
          printf '%s\\n' "$arg" >> "\(argumentsFile.path)"
        done
        printf 'GT_GEMINI_HEADLESS_STARTED\\n'
        sleep 20
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = GeminiAdapter(
            agentID: "gemini-headless-interrupt-test-\(UUID().uuidString)",
            executable: executable.path,
            cwd: directory.path
        )

        try await withRunningAdapter(adapter) { adapter in
            let interruptedSnapshotTask = Task {
                try await waitForSnapshot(adapter) { snapshot in
                    snapshot.status == .idle && snapshot.statusDetail == "interrupted"
                }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            let promptTask = Task {
                try await adapter.sendInput("Start and wait", submit: true)
            }

            try await waitForFile(argumentsFile, toEqualLines: ["--skip-trust", "--prompt", "Start and wait"])
            try await adapter.interrupt()

            try await promptTask.value
            let snapshot = try await interruptedSnapshotTask.value
            XCTAssertEqual(snapshot.status, .idle)
        }
    }

    func testGeminiHeadlessPromptRepairsDumbTerminalEnvironment() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-gemini-headless-term-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let environmentFile = directory.appendingPathComponent("environment.txt")
        let executable = directory.appendingPathComponent("record-env.sh")
        let script = """
        #!/bin/sh
        printf 'TERM=%s\\n' "$TERM" > "\(environmentFile.path)"
        printf 'COLORTERM=%s\\n' "$COLORTERM" >> "\(environmentFile.path)"
        printf 'GT_CUSTOM=%s\\n' "$GT_CUSTOM" >> "\(environmentFile.path)"
        printf 'GT_GEMINI_ENV_OK\\n'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = GeminiAdapter(
            agentID: "gemini-headless-term-test-\(UUID().uuidString)",
            executable: executable.path,
            environment: [
                "COLORTERM": "",
                "TERM": "dumb",
                "GT_CUSTOM": "preserved",
            ],
            cwd: directory.path
        )

        try await withRunningAdapter(adapter) { adapter in
            try await adapter.sendInput("Check environment", submit: true)
            try await waitForFile(
                environmentFile,
                toEqualLines: ["TERM=xterm-256color", "COLORTERM=truecolor", "GT_CUSTOM=preserved"]
            )
        }
    }

    func testGeminiHeadlessOutputIsRedactedBeforeSnapshotsAndErrors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-gemini-headless-redaction-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("print-secret-and-fail.sh")
        let secret = "GTSECRET_12345"
        let script = """
        #!/bin/sh
        printf 'provider auth failed for token \(secret)\\n'
        exit 9
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = GeminiAdapter(
            agentID: "gemini-headless-redaction-test-\(UUID().uuidString)",
            executable: executable.path,
            cwd: directory.path,
            redactor: SecretRedactor(patterns: [
                SecretRedactor.Pattern(name: "test_secret", regex: #"GTSECRET_[0-9]+"#),
            ])
        )

        try await withRunningAdapter(adapter) { adapter in
            let errorSnapshotTask = Task {
                try await waitForSnapshot(adapter) { snapshot in
                    snapshot.status == .error && snapshot.recentMessages.contains { message in
                        message.text.contains("<redacted:test_secret>")
                    }
                }
            }

            do {
                try await adapter.sendInput("Trigger provider auth failure", submit: true)
                XCTFail("Gemini headless prompt should fail when the executable exits non-zero.")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains(secret))
            }

            let snapshot = try await errorSnapshotTask.value
            let text = snapshot.recentMessages.map(\.text).joined(separator: "\n")
            XCTAssertFalse(text.contains(secret))
            XCTAssertTrue(text.contains("<redacted:test_secret>"))
        }
    }

    func testGeminiInteractiveFallbackPtyTailIsRedactedBeforeSnapshots() {
        let secret = "GTSECRET_12345"
        let adapter = GeminiAdapter(
            agentID: "gemini-tail-redaction-test-\(UUID().uuidString)",
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

    func testGeminiRuntimeUpdateAppliesNormalizedModelToNextHeadlessPrompt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-gemini-runtime-restart-\(UUID().uuidString)",
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

        let adapter = GeminiAdapter(
            agentID: "gemini-runtime-restart-test-\(UUID().uuidString)",
            executable: executable.path,
            arguments: ["initial"],
            cwd: directory.path
        )

        try await withRunningAdapter(adapter) { adapter in
            XCTAssertFalse(FileManager.default.fileExists(atPath: argumentsFile.path))

            try await adapter.updateRuntimeSettings(
                AgentRuntimeSettingsUpdate(
                    agentId: adapter.agentID,
                    modelId: "  gemini-2.5-pro  "
                )
            )

            let controls = try XCTUnwrap(adapter.runtimeControls())
            XCTAssertEqual(controls.modelId, "gemini-2.5-pro")
            XCTAssertEqual(controls.modelLabel, "gemini-2.5-pro")
            XCTAssertEqual(controls.supportsModelSelection, true)
            XCTAssertEqual(controls.appliesOn, .nextStart)

            try await adapter.sendInput("Use the selected model", submit: true)

            let expectedArguments = ["--model", "gemini-2.5-pro", "--skip-trust", "initial", "--prompt", "Use the selected model"]
            try await waitForFile(argumentsFile, toEqualLines: expectedArguments)
        }
    }

    func testGeminiRejectsMalformedRuntimeModelWithoutChangingSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-gemini-runtime-invalid-\(UUID().uuidString)",
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

        let adapter = GeminiAdapter(
            agentID: "gemini-runtime-invalid-test-\(UUID().uuidString)",
            executable: executable.path,
            arguments: ["initial"],
            cwd: directory.path
        )

        try await withRunningAdapter(adapter) { adapter in
            XCTAssertFalse(FileManager.default.fileExists(atPath: argumentsFile.path))

            try await adapter.updateRuntimeSettings(
                AgentRuntimeSettingsUpdate(
                    agentId: adapter.agentID,
                    modelId: "gemini-2.5-flash"
                )
            )

            async let rollbackSnapshot = waitForSnapshot(adapter) { snapshot in
                snapshot.statusDetail == "settings failed" &&
                    snapshot.runtimeControls?.modelId == "gemini-2.5-flash"
            }

            do {
                try await adapter.updateRuntimeSettings(
                    AgentRuntimeSettingsUpdate(
                        agentId: adapter.agentID,
                        modelId: "gemini-2.5 flash"
                    )
                )
                XCTFail("Malformed Gemini model value should be rejected.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Gemini model"))
            }

            let snapshot = try await rollbackSnapshot
            XCTAssertEqual(snapshot.runtimeControls?.modelLabel, "gemini-2.5-flash")

            let controls = try XCTUnwrap(adapter.runtimeControls())
            XCTAssertEqual(controls.modelId, "gemini-2.5-flash")
            XCTAssertEqual(controls.modelLabel, "gemini-2.5-flash")

            try await adapter.sendInput("Use the previous selected model", submit: true)

            let expectedArguments = [
                "--model", "gemini-2.5-flash",
                "--skip-trust", "initial",
                "--prompt", "Use the previous selected model",
            ]
            try await waitForFile(argumentsFile, toEqualLines: expectedArguments)
        }
    }

    func testGeminiRejectsRuntimeModelChangesWhilePromptIsRunning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-gemini-runtime-busy-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let argumentsFile = directory.appendingPathComponent("arguments.txt")
        let executable = directory.appendingPathComponent("record-sleeping-prompt.sh")
        let script = """
        #!/bin/sh
        : > "\(argumentsFile.path)"
        for arg in "$@"; do
          printf '%s\\n' "$arg" >> "\(argumentsFile.path)"
        done
        printf 'GT_GEMINI_BUSY_STARTED\\n'
        sleep 20
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = GeminiAdapter(
            agentID: "gemini-runtime-busy-test-\(UUID().uuidString)",
            executable: executable.path,
            arguments: ["initial"],
            cwd: directory.path
        )

        try await withRunningAdapter(adapter) { adapter in
            try await adapter.updateRuntimeSettings(
                AgentRuntimeSettingsUpdate(
                    agentId: adapter.agentID,
                    modelId: "gemini-2.5-flash"
                )
            )

            let promptTask = Task {
                try await adapter.sendInput("Keep running", submit: true)
            }
            try await waitForFile(
                argumentsFile,
                toEqualLines: [
                    "--model", "gemini-2.5-flash",
                    "--skip-trust", "initial",
                    "--prompt", "Keep running",
                ]
            )

            async let rollbackSnapshot = waitForSnapshot(adapter) { snapshot in
                snapshot.statusDetail == "settings failed" &&
                    snapshot.runtimeControls?.modelId == "gemini-2.5-flash"
            }

            do {
                try await adapter.updateRuntimeSettings(
                    AgentRuntimeSettingsUpdate(
                        agentId: adapter.agentID,
                        modelId: "gemini-2.5-pro"
                    )
                )
                XCTFail("Gemini model changes should wait until the running prompt is finished or interrupted.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("already running"))
            }

            let snapshot = try await rollbackSnapshot
            XCTAssertEqual(snapshot.runtimeControls?.modelLabel, "gemini-2.5-flash")

            let controls = try XCTUnwrap(adapter.runtimeControls())
            XCTAssertEqual(controls.modelId, "gemini-2.5-flash")

            try await adapter.interrupt()
            try await promptTask.value
        }
    }

    func testGeminiBlankRuntimeModelClearsSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-gemini-runtime-clear-\(UUID().uuidString)",
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

        let adapter = GeminiAdapter(
            agentID: "gemini-runtime-clear-test-\(UUID().uuidString)",
            executable: executable.path,
            arguments: ["initial"],
            cwd: directory.path
        )

        try await withRunningAdapter(adapter) { adapter in
            XCTAssertFalse(FileManager.default.fileExists(atPath: argumentsFile.path))

            try await adapter.updateRuntimeSettings(
                AgentRuntimeSettingsUpdate(
                    agentId: adapter.agentID,
                    modelId: "   "
                )
            )

            let controls = try XCTUnwrap(adapter.runtimeControls())
            XCTAssertEqual(controls.modelId, "")
            XCTAssertEqual(controls.modelLabel, "Default")

            try await adapter.sendInput("Use default model", submit: true)
            try await waitForFile(argumentsFile, toEqualLines: ["--skip-trust", "initial", "--prompt", "Use default model"])
        }
    }

    func testGeminiDoesNotDuplicateExplicitSkipTrustArgument() {
        XCTAssertEqual(
            GeminiAdapter.trustCurrentWorkspaceForSession(["--skip-trust", "--model", "gemini-2.5-flash"]),
            ["--skip-trust", "--model", "gemini-2.5-flash"]
        )
    }

    func testGeminiStatusKeepsAuthenticationAndThinkingStatesWorking() {
        let adapter = GeminiAdapter(executable: "/usr/bin/true")

        let authenticating = adapter.statusAfterOutputSilence(
            buffer: "⠴ Waiting for authentication... (Press Esc or Ctrl+C to cancel)",
            silenceDuration: 7
        )
        XCTAssertEqual(authenticating.status, .working)
        XCTAssertEqual(authenticating.detail, "authenticating")

        let thinking = adapter.statusAfterOutputSilence(
            buffer: "⠋ Thinking... (esc to cancel, 12s)",
            silenceDuration: 7
        )
        XCTAssertEqual(thinking.status, .working)
        XCTAssertEqual(thinking.detail, "running prompt")

        let ready = adapter.statusAfterOutputSilence(
            buffer: "Type your message or @path/to/file",
            silenceDuration: 7
        )
        XCTAssertEqual(ready.status, .done)
        XCTAssertEqual(ready.detail, "idle for 7s")
    }

    private func withRunningAdapter(
        _ adapter: GeminiAdapter,
        body: (GeminiAdapter) async throws -> Void
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

    private func waitForSnapshot(
        _ adapter: GeminiAdapter,
        matching predicate: @escaping (AgentStateSnapshot) -> Bool
    ) async throws -> AgentStateSnapshot {
        try await withThrowingTaskGroup(of: AgentStateSnapshot.self) { group in
            group.addTask {
                for await snapshot in adapter.observeState() {
                    if predicate(snapshot) {
                        return snapshot
                    }
                }
                throw CancellationError()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 4_000_000_000)
                throw CancellationError()
            }

            let snapshot = try await group.next()
            group.cancelAll()
            if let snapshot {
                return snapshot
            }
            throw CancellationError()
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
        XCTFail("Timed out waiting for \(url.path) to contain expected Gemini runtime arguments. Actual contents: \(contents)")
    }
}
