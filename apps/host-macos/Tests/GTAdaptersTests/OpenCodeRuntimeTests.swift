import SQLite3
import XCTest
@testable import GTAdapters
import GTProtocol
import GTSecurity

final class OpenCodeRuntimeTests: XCTestCase {
    func testOpenCodeSilenceStaysWorkingWhenLatestSyncedMessageIsUserPrompt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-opencode-user-waiting-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("opencode.db")
        try makeOpenCodeDatabase(
            databaseURL,
            latestRole: "user",
            latestText: "Please keep working until I stop you."
        )

        let adapter = OpenCodeAdapter(
            agentID: "opencode-user-waiting-test-\(UUID().uuidString)",
            executable: "/bin/cat",
            databaseURL: databaseURL
        )

        try await withRunningAdapter(adapter) { adapter in
            let next = adapter.statusAfterOutputSilence(buffer: "", silenceDuration: 5)
            XCTAssertEqual(next.status, .working)
            XCTAssertEqual(next.detail, "waiting for OpenCode response")
        }
    }

    func testOpenCodeSilenceCanCompleteAfterLatestAssistantMessage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-opencode-assistant-done-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("opencode.db")
        try makeOpenCodeDatabase(
            databaseURL,
            latestRole: "assistant",
            latestText: "Done."
        )

        let adapter = OpenCodeAdapter(
            agentID: "opencode-assistant-done-test-\(UUID().uuidString)",
            executable: "/bin/cat",
            databaseURL: databaseURL
        )

        try await withRunningAdapter(adapter) { adapter in
            let next = adapter.statusAfterOutputSilence(buffer: "", silenceDuration: 5)
            XCTAssertEqual(next.status, .done)
        }
    }

    func testOpenCodeSilenceCanCompleteAfterLatestCompletedAssistantMessageWithoutParts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-opencode-blank-assistant-done-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("opencode.db")
        try makeOpenCodeDatabase(
            databaseURL,
            latestRole: "user",
            latestText: "Do not use tools. Reply with exactly GT_OK."
        )
        try insertOpenCodeMessage(
            databaseURL,
            id: "msg_completed_assistant_without_parts",
            role: "assistant",
            timeCreated: 3_000,
            completedAt: 3_100,
            text: nil
        )

        let adapter = OpenCodeAdapter(
            agentID: "opencode-blank-assistant-done-test-\(UUID().uuidString)",
            executable: "/bin/cat",
            databaseURL: databaseURL
        )

        try await withRunningAdapter(adapter) { adapter in
            let snapshot = try await waitForSnapshot(adapter) { snapshot in
                snapshot.recentMessages.contains { $0.text == "Do not use tools. Reply with exactly GT_OK." }
            }
            XCTAssertFalse(snapshot.recentMessages.contains { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })

            let next = adapter.statusAfterOutputSilence(buffer: "", silenceDuration: 5)
            XCTAssertEqual(next.status, .done)
        }
    }

    func testOpenCodeSilenceReportsLatestAssistantErrorWithoutParts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-opencode-assistant-error-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("opencode.db")
        try makeOpenCodeDatabase(
            databaseURL,
            latestRole: "user",
            latestText: "Use the selected model."
        )
        try insertOpenCodeMessage(
            databaseURL,
            id: "msg_error_assistant_without_parts",
            role: "assistant",
            timeCreated: 3_000,
            completedAt: 3_100,
            text: nil,
            errorMessage: "Model is disabled"
        )

        let adapter = OpenCodeAdapter(
            agentID: "opencode-assistant-error-test-\(UUID().uuidString)",
            executable: "/bin/cat",
            databaseURL: databaseURL
        )

        try await withRunningAdapter(adapter) { adapter in
            let snapshot = try await waitForSnapshot(adapter) { snapshot in
                snapshot.recentMessages.contains { $0.text == "OpenCode error: APIError: Model is disabled" }
            }
            XCTAssertTrue(snapshot.recentMessages.contains { $0.role == .assistant })

            let next = adapter.statusAfterOutputSilence(buffer: "", silenceDuration: 5)
            XCTAssertEqual(next.status, .error)
            XCTAssertEqual(next.detail, "APIError: Model is disabled")
        }
    }

    func testOpenCodeSilenceDoesNotErrorOnInterruptedAssistantMessage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-opencode-assistant-aborted-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("opencode.db")
        try makeOpenCodeDatabase(
            databaseURL,
            latestRole: "user",
            latestText: "Stop this prompt."
        )
        try insertOpenCodeMessage(
            databaseURL,
            id: "msg_aborted_assistant",
            role: "assistant",
            timeCreated: 3_000,
            completedAt: 3_100,
            text: "Partial response before Stop.",
            errorName: "MessageAbortedError",
            errorMessage: "Aborted"
        )

        let adapter = OpenCodeAdapter(
            agentID: "opencode-assistant-aborted-test-\(UUID().uuidString)",
            executable: "/bin/cat",
            databaseURL: databaseURL
        )

        try await withRunningAdapter(adapter) { adapter in
            let snapshot = try await waitForSnapshot(adapter) { snapshot in
                snapshot.recentMessages.contains { $0.text == "Partial response before Stop." }
            }
            XCTAssertTrue(snapshot.recentMessages.contains { $0.role == .assistant })

            let next = adapter.statusAfterOutputSilence(buffer: "", silenceDuration: 5)
            XCTAssertEqual(next.status, .done)
        }
    }

    func testOpenCodeDefaultSelectionSkipsNewestEmptySession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-opencode-empty-default-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("opencode.db")
        try makeOpenCodeDatabase(
            databaseURL,
            latestRole: "assistant",
            latestText: "Message-backed session."
        )
        let emptySessionDirectory = directory.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptySessionDirectory, withIntermediateDirectories: true)
        try insertOpenCodeSession(
            databaseURL,
            id: "ses_empty_latest",
            title: "New empty session",
            directory: emptySessionDirectory.path,
            timeCreated: 3_000,
            timeUpdated: 3_000
        )

        let adapter = OpenCodeAdapter(
            agentID: "opencode-empty-default-test-\(UUID().uuidString)",
            executable: "/bin/cat",
            databaseURL: databaseURL
        )

        try await withRunningAdapter(adapter) { adapter in
            XCTAssertEqual(adapter.arguments, ["--session", "ses_test"])

            let defaultSnapshot = try await waitForSnapshot(adapter) { snapshot in
                snapshot.availableTargets?.contains { $0.targetId == "ses_empty_latest" } == true &&
                    snapshot.availableTargets?.contains { $0.targetId == "ses_test" && $0.selected } == true
            }
            XCTAssertTrue(defaultSnapshot.recentMessages.contains { $0.text == "Message-backed session." })

            try await adapter.selectTarget("ses_empty_latest")

            let emptySnapshot = try await waitForSnapshot(adapter) { snapshot in
                snapshot.availableTargets?.contains { $0.targetId == "ses_empty_latest" && $0.selected } == true
            }
            XCTAssertEqual(adapter.arguments, ["--session", "ses_empty_latest"])
            XCTAssertTrue(emptySnapshot.recentMessages.isEmpty || emptySnapshot.recentMessages.allSatisfy { $0.messageId.hasSuffix("-tail") })
        }
    }

    func testOpenCodeSessionHistoryIsRedactedBeforeSnapshots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-opencode-history-redaction-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("opencode.db")
        let secret = "GTSECRET_98765"
        try makeOpenCodeDatabase(
            databaseURL,
            latestRole: "assistant",
            latestText: "Provider failed with token \(secret).",
            pendingToolTitle: "Using token \(secret)"
        )

        let adapter = OpenCodeAdapter(
            agentID: "opencode-history-redaction-test-\(UUID().uuidString)",
            executable: "/bin/cat",
            redactor: SecretRedactor(patterns: [
                SecretRedactor.Pattern(name: "test_secret", regex: #"GTSECRET_[0-9]+"#),
            ]),
            databaseURL: databaseURL
        )

        try await withRunningAdapter(adapter) { adapter in
            let snapshot = try await waitForSnapshot(adapter) { snapshot in
                snapshot.recentMessages.contains { message in
                    message.text.contains("<redacted:test_secret>")
                }
            }
            let text = snapshot.recentMessages.map(\.text).joined(separator: "\n")
            XCTAssertFalse(text.contains(secret))
            let toolSummaries = snapshot.recentMessages
                .flatMap(\.pendingToolCalls)
                .map(\.summary)
                .joined(separator: "\n")
            XCTAssertFalse(toolSummaries.contains(secret))
            XCTAssertTrue(toolSummaries.contains("<redacted:test_secret>"))
            XCTAssertTrue(snapshot.recentMessages.contains { message in
                message.redacted && message.redactionReasons.contains("test_secret")
            })
        }
    }

    func testOpenCodeFallbackPtyTailIsRedactedBeforeSnapshots() {
        let secret = "GTSECRET_12345"
        let adapter = OpenCodeAdapter(
            agentID: "opencode-tail-redaction-test-\(UUID().uuidString)",
            executable: "/bin/cat",
            redactor: SecretRedactor(patterns: [
                SecretRedactor.Pattern(name: "test_secret", regex: #"GTSECRET_[0-9]+"#),
            ]),
            databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("missing-opencode-\(UUID().uuidString).db")
        )

        let messages = adapter.snapshotMessages(from: "Provider auth failed with token \(secret).")
        let text = messages.map(\.text).joined(separator: "\n")

        XCTAssertFalse(text.contains(secret))
        XCTAssertTrue(text.contains("<redacted:test_secret>"))
        XCTAssertTrue(messages.contains { message in
            message.redacted && message.redactionReasons.contains("test_secret")
        })
    }

    func testOpenCodeRuntimeUpdateRestartsWithNormalizedModelArgument() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-opencode-runtime-restart-\(UUID().uuidString)",
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

        let adapter = OpenCodeAdapter(
            agentID: "opencode-runtime-restart-test-\(UUID().uuidString)",
            executable: executable.path,
            arguments: ["initial"],
            databaseURL: directory.appendingPathComponent("missing-opencode.db")
        )

        try await withRunningAdapter(adapter) { adapter in
            try await waitForFile(argumentsFile, toEqualLines: ["initial"])

            try await adapter.updateRuntimeSettings(
                AgentRuntimeSettingsUpdate(
                    agentId: adapter.agentID,
                    modelId: "  opencode/big-pickle  "
                )
            )

            let expectedArguments = ["--model", "opencode/big-pickle"]
            XCTAssertEqual(adapter.arguments, expectedArguments)
            try await waitForFile(argumentsFile, toEqualLines: expectedArguments)

            let controls = try XCTUnwrap(adapter.runtimeControls())
            XCTAssertEqual(controls.modelId, "opencode/big-pickle")
            XCTAssertEqual(controls.modelLabel, "Big Pickle")
            XCTAssertTrue(controls.modelOptions.contains { $0.id == "" && $0.label == "Default" })
            XCTAssertTrue(controls.modelOptions.contains { $0.id == "opencode/deepseek-v4-flash-free" && $0.label == "DeepSeek V4 Flash Free" })
            XCTAssertTrue(controls.modelOptions.contains { $0.id == "opencode/nemotron-3-ultra-free" && $0.label == "Nemotron 3 Ultra Free" })
            XCTAssertEqual(controls.appliesOn, .immediate)
        }
    }

    func testOpenCodeSubmittedInputUsesRunCommandForExistingSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-opencode-input-restart-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("opencode.db")
        try makeOpenCodeDatabase(
            databaseURL,
            latestRole: "assistant",
            latestText: "Ready."
        )

        let launchesFile = directory.appendingPathComponent("launches.txt")
        let inputsFile = directory.appendingPathComponent("inputs.txt")
        let executable = directory.appendingPathComponent("record-pty.sh")
        let script = """
        #!/bin/sh
        {
          printf '%s\\n' '--launch--'
          for arg in "$@"; do
            printf '%s\\n' "$arg"
          done
        } >> "\(launchesFile.path)"
        if [ "${1:-}" = "run" ]; then
          while IFS= read -r line; do
            printf '%s\\n' "$line" >> "\(inputsFile.path)"
          done
          exit 0
        fi
        while IFS= read -r line; do
          printf '%s\\n' "tui:$line" >> "\(inputsFile.path)"
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = OpenCodeAdapter(
            agentID: "opencode-input-restart-test-\(UUID().uuidString)",
            executable: executable.path,
            databaseURL: databaseURL
        )

        try await withRunningAdapter(adapter) { adapter in
            try await waitForFile(launchesFile, toContain: "--session\nses_test")

            try await adapter.updateRuntimeSettings(
                AgentRuntimeSettingsUpdate(
                    agentId: adapter.agentID,
                    modelId: "opencode/nemotron-3-ultra-free"
                )
            )
            try await waitForFile(launchesFile, toContain: "--model\nopencode/nemotron-3-ultra-free\n--session\nses_test")

            try await adapter.sendInput("existing session prompt", submit: true)
            try await waitForFile(inputsFile, toContain: "existing session prompt")
            try await waitForFile(launchesFile, toContain: "run\n--model\nopencode/nemotron-3-ultra-free\n--session\nses_test")
            let inputText = try String(contentsOf: inputsFile, encoding: .utf8)
            XCTAssertFalse(inputText.contains("tui:existing session prompt"))
        }
    }

    func testOpenCodeSubmittedInputRestartsAfterInterruptEvenWhenProcessSurvives() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-opencode-interrupt-restart-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("opencode.db")
        try makeOpenCodeDatabase(
            databaseURL,
            latestRole: "assistant",
            latestText: "Ready."
        )

        let launchesFile = directory.appendingPathComponent("launches.txt")
        let inputsFile = directory.appendingPathComponent("inputs.txt")
        let executable = directory.appendingPathComponent("record-interrupt-pty.sh")
        let script = """
        #!/bin/sh
        trap 'printf "%s\\n" interrupted >> "\(inputsFile.path)"' INT
        {
          printf '%s\\n' '--launch--'
          for arg in "$@"; do
            printf '%s\\n' "$arg"
          done
        } >> "\(launchesFile.path)"
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> "\(inputsFile.path)"
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = OpenCodeAdapter(
            agentID: "opencode-interrupt-restart-test-\(UUID().uuidString)",
            executable: executable.path,
            databaseURL: databaseURL
        )

        try await withRunningAdapter(adapter) { adapter in
            try await waitForFile(launchesFile, launchCountAtLeast: 1)
            try await adapter.updateRuntimeSettings(
                AgentRuntimeSettingsUpdate(
                    agentId: adapter.agentID,
                    modelId: "opencode/nemotron-3-ultra-free"
                )
            )
            try await waitForFile(launchesFile, launchCountAtLeast: 2)

            try await adapter.interrupt()
            try await adapter.sendInput("after-interrupt", submit: true)

            try await waitForFile(launchesFile, launchCountAtLeast: 3)
            try await waitForFile(inputsFile, toContain: "after-interrupt")
        }
    }

    func testOpenCodeSubmittedInputUsesRunCommandWhenNoSessionExists() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-opencode-run-without-session-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let launchesFile = directory.appendingPathComponent("launches.txt")
        let inputsFile = directory.appendingPathComponent("inputs.txt")
        let executable = directory.appendingPathComponent("record-opencode-run.sh")
        let script = """
        #!/bin/sh
        {
          printf '%s\\n' '--launch--'
          for arg in "$@"; do
            printf '%s\\n' "$arg"
          done
        } >> "\(launchesFile.path)"
        if [ "${1:-}" = "run" ]; then
          while IFS= read -r line; do
            printf '%s\\n' "$line" >> "\(inputsFile.path)"
          done
          exit 0
        fi
        while IFS= read -r line; do
          printf '%s\\n' "tui:$line" >> "\(inputsFile.path)"
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = OpenCodeAdapter(
            agentID: "opencode-empty-session-run-test-\(UUID().uuidString)",
            executable: executable.path,
            databaseURL: directory.appendingPathComponent("missing-opencode.db")
        )

        try await withRunningAdapter(adapter) { adapter in
            try await waitForFile(launchesFile, launchCountAtLeast: 1)

            try await adapter.updateRuntimeSettings(
                AgentRuntimeSettingsUpdate(
                    agentId: adapter.agentID,
                    modelId: "opencode/nemotron-3-ultra-free"
                )
            )
            try await waitForFile(launchesFile, toContain: "--model\nopencode/nemotron-3-ultra-free")

            try await adapter.sendInput("first hosted prompt", submit: true)

            try await waitForFile(inputsFile, toContain: "first hosted prompt")
            try await waitForFile(launchesFile, toContain: "run\n--model\nopencode/nemotron-3-ultra-free")
            _ = try await waitForSnapshot(adapter) { snapshot in
                snapshot.statusDetail == "prompt returned"
            }
        }
    }

    func testOpenCodeSubmittedInputUsesRunCommandWhenSelectedSessionIsEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-opencode-run-empty-session-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("opencode.db")
        try makeOpenCodeDatabase(
            databaseURL,
            latestRole: "assistant",
            latestText: "seed"
        )
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &db), SQLITE_OK)
        if let db {
            try exec(db, "DELETE FROM part; DELETE FROM message;")
        }
        sqlite3_close_v2(db)

        let launchesFile = directory.appendingPathComponent("launches.txt")
        let inputsFile = directory.appendingPathComponent("inputs.txt")
        let executable = directory.appendingPathComponent("record-empty-session-run.sh")
        let script = """
        #!/bin/sh
        {
          printf '%s\\n' '--launch--'
          for arg in "$@"; do
            printf '%s\\n' "$arg"
          done
        } >> "\(launchesFile.path)"
        if [ "${1:-}" = "run" ]; then
          while IFS= read -r line; do
            printf '%s\\n' "$line" >> "\(inputsFile.path)"
          done
          exit 0
        fi
        while IFS= read -r line; do
          printf '%s\\n' "tui:$line" >> "\(inputsFile.path)"
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = OpenCodeAdapter(
            agentID: "opencode-empty-existing-session-run-test-\(UUID().uuidString)",
            executable: executable.path,
            databaseURL: databaseURL
        )

        try await withRunningAdapter(adapter) { adapter in
            try await waitForFile(launchesFile, toContain: "--session\nses_test")

            try await adapter.updateRuntimeSettings(
                AgentRuntimeSettingsUpdate(
                    agentId: adapter.agentID,
                    modelId: "opencode/gpt-5-nano"
                )
            )
            try await waitForFile(launchesFile, toContain: "--model\nopencode/gpt-5-nano\n--session\nses_test")

            try await adapter.sendInput("empty session prompt", submit: true)

            try await waitForFile(inputsFile, toContain: "empty session prompt")
            try await waitForFile(launchesFile, toContain: "run\n--model\nopencode/gpt-5-nano\n--session\nses_test")
            let inputText = try String(contentsOf: inputsFile, encoding: .utf8)
            XCTAssertFalse(inputText.contains("tui:empty session prompt"))
        }
    }

    func testOpenCodeInterruptTerminatesRunCommandAndRestartsTUI() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-opencode-run-interrupt-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let launchesFile = directory.appendingPathComponent("launches.txt")
        let inputsFile = directory.appendingPathComponent("inputs.txt")
        let executable = directory.appendingPathComponent("slow-opencode-run.sh")
        let script = """
        #!/bin/sh
        {
          printf '%s\\n' '--launch--'
          for arg in "$@"; do
            printf '%s\\n' "$arg"
          done
        } >> "\(launchesFile.path)"
        if [ "${1:-}" = "run" ]; then
          while IFS= read -r line; do
            printf '%s\\n' "$line" >> "\(inputsFile.path)"
          done
          printf '%s\\n' 'run-waiting' >> "\(inputsFile.path)"
          sleep 30
          exit 0
        fi
        while IFS= read -r line; do
          printf '%s\\n' "tui:$line" >> "\(inputsFile.path)"
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = OpenCodeAdapter(
            agentID: "opencode-run-interrupt-test-\(UUID().uuidString)",
            executable: executable.path,
            databaseURL: directory.appendingPathComponent("missing-opencode.db")
        )

        try await withRunningAdapter(adapter) { adapter in
            try await waitForFile(launchesFile, launchCountAtLeast: 1)

            let submitted = Task {
                try await adapter.sendInput("slow hosted prompt", submit: true)
            }

            try await waitForFile(inputsFile, toContain: "slow hosted prompt")
            try await waitForFile(inputsFile, toContain: "run-waiting")
            try await adapter.interrupt()

            try await submitted.value
            try await waitForFile(launchesFile, launchCountAtLeast: 3)
        }
    }

    func testOpenCodeStopTerminatesRunCommandWithoutRestartingTUI() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-opencode-run-stop-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let launchesFile = directory.appendingPathComponent("launches.txt")
        let inputsFile = directory.appendingPathComponent("inputs.txt")
        let executable = directory.appendingPathComponent("slow-opencode-stop.sh")
        let script = """
        #!/bin/sh
        {
          printf '%s\\n' '--launch--'
          for arg in "$@"; do
            printf '%s\\n' "$arg"
          done
        } >> "\(launchesFile.path)"
        if [ "${1:-}" = "run" ]; then
          while IFS= read -r line; do
            printf '%s\\n' "$line" >> "\(inputsFile.path)"
          done
          printf '%s\\n' 'run-waiting' >> "\(inputsFile.path)"
          sleep 30
          exit 0
        fi
        while IFS= read -r line; do
          printf '%s\\n' "tui:$line" >> "\(inputsFile.path)"
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = OpenCodeAdapter(
            agentID: "opencode-run-stop-test-\(UUID().uuidString)",
            executable: executable.path,
            databaseURL: directory.appendingPathComponent("missing-opencode.db")
        )

        try await withRunningAdapter(adapter) { adapter in
            try await waitForFile(launchesFile, launchCountAtLeast: 1)

            let submitted = Task {
                try await adapter.sendInput("slow hosted prompt", submit: true)
            }

            try await waitForFile(inputsFile, toContain: "slow hosted prompt")
            try await waitForFile(inputsFile, toContain: "run-waiting")
            await adapter.stop()

            try await submitted.value
            let launchText = try String(contentsOf: launchesFile, encoding: .utf8)
            XCTAssertEqual(launchText.components(separatedBy: "--launch--").count - 1, 2)
        }
    }

    func testOpenCodeRunCommandFailurePublishesProviderModelBlockedDetail() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-opencode-run-provider-blocked-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("blocked-opencode.sh")
        let script = """
        #!/bin/sh
        if [ "${1:-}" = "run" ]; then
          while IFS= read -r line; do :; done
          printf '%s\\n' 'APIError: insufficient balance for opencode/gpt-5-nano token GTSECRET_12345' >&2
          exit 1
        fi
        while IFS= read -r line; do :; done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = OpenCodeAdapter(
            agentID: "opencode-run-provider-blocked-test-\(UUID().uuidString)",
            executable: executable.path,
            redactor: SecretRedactor(patterns: [
                SecretRedactor.Pattern(name: "test_secret", regex: #"GTSECRET_[0-9]+"#),
            ]),
            databaseURL: directory.appendingPathComponent("missing-opencode.db")
        )

        try await withRunningAdapter(adapter) { adapter in
            async let errorSnapshot = waitForSnapshot(adapter) { snapshot in
                snapshot.status == .error &&
                    snapshot.statusDetail == "Provider/model blocked by account, billing, quota, or authorization."
            }

            do {
                try await adapter.sendInput("use the selected model", submit: true)
                XCTFail("Blocked OpenCode provider/model run should fail.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("account, billing, quota, or authorization"))
                XCTAssertFalse(error.localizedDescription.contains("GTSECRET"))
            }

            let snapshot = try await errorSnapshot
            XCTAssertFalse(snapshot.statusDetail.contains("GTSECRET"))
        }
    }

    func testOpenCodeRunCommandFailurePublishesDisabledModelDetail() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-opencode-run-disabled-model-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("disabled-opencode.sh")
        let script = """
        #!/bin/sh
        if [ "${1:-}" = "run" ]; then
          while IFS= read -r line; do :; done
          printf '%s\\n' 'APIError: Model is disabled for this account' >&2
          exit 1
        fi
        while IFS= read -r line; do :; done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = OpenCodeAdapter(
            agentID: "opencode-run-disabled-model-test-\(UUID().uuidString)",
            executable: executable.path,
            databaseURL: directory.appendingPathComponent("missing-opencode.db")
        )

        try await withRunningAdapter(adapter) { adapter in
            async let errorSnapshot = waitForSnapshot(adapter) { snapshot in
                snapshot.status == .error &&
                    snapshot.statusDetail == "Provider/model is disabled for this account."
            }

            do {
                try await adapter.sendInput("use disabled model", submit: true)
                XCTFail("Disabled OpenCode provider/model run should fail.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("disabled"))
            }

            _ = try await errorSnapshot
        }
    }

    func testOpenCodeRunCommandFailurePublishesUnavailableModelDetail() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-opencode-run-unavailable-model-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("unavailable-opencode.sh")
        let script = """
        #!/bin/sh
        if [ "${1:-}" = "run" ]; then
          while IFS= read -r line; do :; done
          printf '%s\\n' 'ProviderModelNotFoundError: Model not found: opencode/gpt-5-nano. Did you mean: gpt-5-nano?' >&2
          exit 1
        fi
        while IFS= read -r line; do :; done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = OpenCodeAdapter(
            agentID: "opencode-run-unavailable-model-test-\(UUID().uuidString)",
            executable: executable.path,
            databaseURL: directory.appendingPathComponent("missing-opencode.db")
        )

        try await withRunningAdapter(adapter) { adapter in
            async let errorSnapshot = waitForSnapshot(adapter) { snapshot in
                snapshot.status == .error &&
                    snapshot.statusDetail == "Provider/model is not available for this account."
            }

            do {
                try await adapter.sendInput("use unavailable model", submit: true)
                XCTFail("Unavailable OpenCode provider/model run should fail.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("not available"))
            }

            _ = try await errorSnapshot
        }
    }

    func testOpenCodeRejectsMalformedRuntimeModelWithoutChangingSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-opencode-runtime-invalid-\(UUID().uuidString)",
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

        let adapter = OpenCodeAdapter(
            agentID: "opencode-runtime-invalid-test-\(UUID().uuidString)",
            executable: executable.path,
            arguments: ["initial"],
            databaseURL: directory.appendingPathComponent("missing-opencode.db")
        )

        try await withRunningAdapter(adapter) { adapter in
            try await waitForFile(argumentsFile, toEqualLines: ["initial"])

            try await adapter.updateRuntimeSettings(
                AgentRuntimeSettingsUpdate(
                    agentId: adapter.agentID,
                    modelId: "opencode/gpt-5.5"
                )
            )

            let expectedArguments = ["--model", "opencode/gpt-5.5"]
            try await waitForFile(argumentsFile, toEqualLines: expectedArguments)

            async let rollbackSnapshot = waitForSnapshot(adapter) { snapshot in
                snapshot.statusDetail == "settings failed" &&
                    snapshot.runtimeControls?.modelId == "opencode/gpt-5.5"
            }

            do {
                try await adapter.updateRuntimeSettings(
                    AgentRuntimeSettingsUpdate(
                        agentId: adapter.agentID,
                        modelId: "opencode/bad model"
                    )
                )
                XCTFail("Malformed OpenCode model value should be rejected.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("provider/model"))
            }

            let snapshot = try await rollbackSnapshot
            XCTAssertEqual(snapshot.runtimeControls?.modelLabel, "GPT 5.5")

            XCTAssertEqual(adapter.arguments, expectedArguments)
            try await waitForFile(argumentsFile, toEqualLines: expectedArguments)

            let controls = try XCTUnwrap(adapter.runtimeControls())
            XCTAssertEqual(controls.modelId, "opencode/gpt-5.5")
            XCTAssertEqual(controls.modelLabel, "GPT 5.5")
        }
    }

    func testOpenCodeRejectsRuntimeUpdateWhilePromptIsRunning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-opencode-runtime-busy-\(UUID().uuidString)",
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

        let adapter = OpenCodeAdapter(
            agentID: "opencode-runtime-busy-test-\(UUID().uuidString)",
            executable: executable.path,
            arguments: ["initial"],
            databaseURL: directory.appendingPathComponent("missing-opencode.db")
        )

        try await withRunningAdapter(adapter) { adapter in
            try await waitForFile(argumentsFile, toEqualLines: ["initial"])
            let initialControls = try XCTUnwrap(adapter.runtimeControls())
            adapter.transitionTo(.working, detail: "user input submitted", forceEmit: true)

            async let failedSettingsSnapshot = waitForSnapshot(adapter) { snapshot in
                snapshot.statusDetail == "settings failed" &&
                    snapshot.status == .working &&
                    snapshot.runtimeControls?.modelId == initialControls.modelId
            }

            do {
                try await adapter.updateRuntimeSettings(
                    AgentRuntimeSettingsUpdate(
                        agentId: adapter.agentID,
                        modelId: "opencode/gpt-5.5"
                    )
                )
                XCTFail("OpenCode runtime settings should be rejected while a prompt is running.")
            } catch {
                XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("running"))
            }

            _ = try await failedSettingsSnapshot

            XCTAssertEqual(adapter.arguments, ["initial"])
            try await waitForFile(argumentsFile, toEqualLines: ["initial"])

            let controls = try XCTUnwrap(adapter.runtimeControls())
            XCTAssertEqual(controls.modelId, initialControls.modelId)
            XCTAssertEqual(controls.modelLabel, initialControls.modelLabel)
        }
    }

    func testOpenCodeRuntimeRestartFailureRollsBackSelectionAndArguments() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-opencode-runtime-restart-fail-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionDirectory = directory.appendingPathComponent("session", isDirectory: true)
        let executableDirectory = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)

        let databaseURL = sessionDirectory.appendingPathComponent("opencode.db")
        try makeOpenCodeDatabase(
            databaseURL,
            latestRole: "assistant",
            latestText: "Ready."
        )

        let argumentsFile = executableDirectory.appendingPathComponent("arguments.txt")
        let executable = executableDirectory.appendingPathComponent("record-args.sh")
        let script = """
        #!/bin/sh
        : > "\(argumentsFile.path)"
        for arg in "$@"; do
          printf '%s\\n' "$arg" >> "\(argumentsFile.path)"
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = OpenCodeAdapter(
            agentID: "opencode-runtime-restart-fail-test-\(UUID().uuidString)",
            executable: executable.path,
            arguments: ["initial"],
            databaseURL: databaseURL
        )

        try await withRunningAdapter(adapter) { adapter in
            try await waitForFile(argumentsFile, toEqualLines: ["--session", "ses_test"])

            try await adapter.updateRuntimeSettings(
                AgentRuntimeSettingsUpdate(
                    agentId: adapter.agentID,
                    modelId: "opencode/gpt-5.5"
                )
            )

            let expectedArguments = ["--model", "opencode/gpt-5.5", "--session", "ses_test"]
            XCTAssertEqual(adapter.arguments, expectedArguments)
            try await waitForFile(argumentsFile, toEqualLines: expectedArguments)

            try FileManager.default.removeItem(at: sessionDirectory)

            async let rollbackSnapshot = waitForSnapshot(adapter) { snapshot in
                snapshot.statusDetail == "settings failed" &&
                    snapshot.runtimeControls?.modelId == "opencode/gpt-5.5"
            }

            do {
                try await adapter.updateRuntimeSettings(
                    AgentRuntimeSettingsUpdate(
                        agentId: adapter.agentID,
                        modelId: "opencode/nemotron-3-ultra-free"
                    )
                )
                XCTFail("OpenCode runtime update should fail when restart fails.")
            } catch {
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }

            _ = try await rollbackSnapshot

            XCTAssertEqual(adapter.arguments, expectedArguments)
            try await waitForFile(argumentsFile, toEqualLines: expectedArguments)

            let controls = try XCTUnwrap(adapter.runtimeControls())
            XCTAssertEqual(controls.modelId, "opencode/gpt-5.5")
            XCTAssertEqual(controls.modelLabel, "GPT 5.5")
        }
    }

    func testOpenCodeRuntimeControlsKeepCustomProviderModelEditableWithCatalogOptions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-opencode-runtime-custom-catalog-\(UUID().uuidString)",
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

        let adapter = OpenCodeAdapter(
            agentID: "opencode-runtime-custom-catalog-test-\(UUID().uuidString)",
            executable: executable.path,
            arguments: ["initial"],
            databaseURL: directory.appendingPathComponent("missing-opencode.db")
        )

        try await withRunningAdapter(adapter) { adapter in
            try await waitForFile(argumentsFile, toEqualLines: ["initial"])

            try await adapter.updateRuntimeSettings(
                AgentRuntimeSettingsUpdate(
                    agentId: adapter.agentID,
                    modelId: "zen/private-model"
                )
            )

            let expectedArguments = ["--model", "zen/private-model"]
            XCTAssertEqual(adapter.arguments, expectedArguments)
            try await waitForFile(argumentsFile, toEqualLines: expectedArguments)

            let controls = try XCTUnwrap(adapter.runtimeControls())
            XCTAssertEqual(controls.modelId, "zen/private-model")
            XCTAssertEqual(controls.modelLabel, "zen/private-model")
            XCTAssertTrue(controls.editable)
            XCTAssertTrue(controls.supportsModelSelection)
            XCTAssertTrue(controls.modelOptions.contains { $0.id == "opencode/deepseek-v4-flash-free" })
        }
    }

    func testOpenCodeBlankRuntimeModelClearsSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-opencode-runtime-clear-\(UUID().uuidString)",
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

        let adapter = OpenCodeAdapter(
            agentID: "opencode-runtime-clear-test-\(UUID().uuidString)",
            executable: executable.path,
            arguments: ["initial"],
            databaseURL: directory.appendingPathComponent("missing-opencode.db")
        )

        try await withRunningAdapter(adapter) { adapter in
            try await waitForFile(argumentsFile, toEqualLines: ["initial"])

            try await adapter.updateRuntimeSettings(
                AgentRuntimeSettingsUpdate(
                    agentId: adapter.agentID,
                    modelId: "   "
                )
            )

            XCTAssertEqual(adapter.arguments, [])
            try await waitForFile(argumentsFile, toEqualLines: [])

            let controls = try XCTUnwrap(adapter.runtimeControls())
            XCTAssertEqual(controls.modelId, "")
            XCTAssertEqual(controls.modelLabel, "Default")
        }
    }

    private func withRunningAdapter(
        _ adapter: OpenCodeAdapter,
        body: (OpenCodeAdapter) async throws -> Void
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
        _ adapter: OpenCodeAdapter,
        timeout: TimeInterval = 4,
        matching predicate: @escaping (AgentStateSnapshot) -> Bool
    ) async throws -> AgentStateSnapshot {
        let matched: AgentStateSnapshot? = await withTaskGroup(of: AgentStateSnapshot?.self) { group in
            group.addTask {
                for await snapshot in adapter.observeState() {
                    if predicate(snapshot) {
                        return snapshot
                    }
                }
                return nil
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch {
                    return nil
                }
                return nil
            }

            let snapshot = await group.next()
            group.cancelAll()
            if let snapshot = snapshot, let snapshot {
                return snapshot
            }
            return nil
        }
        if let matched {
            return matched
        }
        throw NSError(
            domain: "OpenCodeRuntimeTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for OpenCode snapshot."]
        )
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
        XCTFail("Timed out waiting for \(url.path) to contain expected OpenCode runtime arguments. Actual contents: \(contents)")
    }

    private func waitForFile(_ url: URL, toContain expected: String, timeout: TimeInterval = 4) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if contents.contains(expected) {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? "<missing>"
        XCTFail("Timed out waiting for \(url.path) to contain \(expected). Actual contents: \(contents)")
        throw NSError(
            domain: "OpenCodeRuntimeTests",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for OpenCode file contents."]
        )
    }

    private func waitForFile(_ url: URL, launchCountAtLeast minimum: Int) async throws {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let count = contents.components(separatedBy: "--launch--").count - 1
            if count >= minimum {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? "<missing>"
        XCTFail("Timed out waiting for \(url.path) to contain at least \(minimum) launches. Actual contents: \(contents)")
    }

    private func makeOpenCodeDatabase(
        _ url: URL,
        latestRole: String,
        latestText: String,
        pendingToolTitle: String? = nil
    ) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        guard let db else {
            XCTFail("Could not open OpenCode test database.")
            return
        }

        try exec(
            db,
            """
            CREATE TABLE session (
                id text PRIMARY KEY,
                project_id text,
                parent_id text,
                slug text,
                directory text,
                title text,
                version text,
                share_url text,
                summary_message_id text,
                summary text,
                permission text,
                time_created integer,
                time_updated integer,
                time_archived integer,
                workspace_id text,
                path text
            );
            CREATE TABLE message (
                id text PRIMARY KEY,
                session_id text,
                role text,
                data text,
                time_created integer,
                time_updated integer
            );
            CREATE TABLE part (
                id text PRIMARY KEY,
                message_id text,
                data text,
                time_created integer
            );
            """
        )

        try exec(
            db,
            """
            INSERT INTO session (id, title, directory, time_created, time_updated)
            VALUES ('ses_test', 'Test session', '\(url.deletingLastPathComponent().path)', 1000, 2000);
            INSERT INTO message (id, session_id, role, data, time_created, time_updated)
            VALUES ('msg_latest', 'ses_test', '\(latestRole)', '{"role":"\(latestRole)"}', 2000, 2000);
            INSERT INTO part (id, message_id, data, time_created)
            VALUES ('part_latest', 'msg_latest', '{"type":"text","text":"\(latestText)"}', 2000);
            """
        )

        if let pendingToolTitle {
            try exec(
                db,
                """
                INSERT INTO part (id, message_id, data, time_created)
                VALUES ('part_tool', 'msg_latest', '{"type":"tool","tool":"bash","callID":"call_test","state":{"title":"\(pendingToolTitle)","status":"running"}}', 2001);
                """
            )
        }
    }

    private func insertOpenCodeSession(
        _ url: URL,
        id: String,
        title: String,
        directory: String,
        timeCreated: Int64,
        timeUpdated: Int64
    ) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        guard let db else {
            XCTFail("Could not open OpenCode test database.")
            return
        }

        try exec(
            db,
            """
            INSERT INTO session (id, title, directory, path, time_created, time_updated)
            VALUES ('\(id)', '\(title)', '\(directory)', '\(directory)', \(timeCreated), \(timeUpdated));
            """
        )
    }

    private func insertOpenCodeMessage(
        _ url: URL,
        id: String,
        role: String,
        timeCreated: Int64,
        completedAt: Int64?,
        text: String?,
        errorName: String = "APIError",
        errorMessage: String? = nil
    ) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        guard let db else {
            XCTFail("Could not open OpenCode test database.")
            return
        }

        let completedJSON = completedAt.map { #","completed":\#($0)"# } ?? ""
        let errorJSON = errorMessage.map { #","error":{"name":"\#(errorName)","data":{"message":"\#($0)"}}"# } ?? ""
        try exec(
            db,
            """
            INSERT INTO message (id, session_id, role, data, time_created, time_updated)
            VALUES ('\(id)', 'ses_test', '\(role)', '{"role":"\(role)","time":{"created":\(timeCreated)\(completedJSON)}\(errorJSON)}', \(timeCreated), \(completedAt ?? timeCreated));
            """
        )

        if let text {
            try exec(
                db,
                """
                INSERT INTO part (id, message_id, data, time_created)
                VALUES ('part_\(id)', '\(id)', '{"type":"text","text":"\(text)"}', \(timeCreated));
                """
            )
        }
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(error)
            throw NSError(domain: "OpenCodeRuntimeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
