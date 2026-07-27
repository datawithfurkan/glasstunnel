import XCTest
@testable import GTAdapters
import GTProtocol

final class ClaudeCodeRuntimeTests: XCTestCase {
    func testClaudeCodeRuntimeValueNormalizationRejectsUnsafeValues() throws {
        XCTAssertEqual(
            try ClaudeCodeAdapter.normalizedRuntimeValue("  claude-sonnet-4-5-20250929  "),
            "claude-sonnet-4-5-20250929"
        )
        XCTAssertNil(try ClaudeCodeAdapter.normalizedRuntimeValue("   "))
        XCTAssertThrowsError(try ClaudeCodeAdapter.normalizedRuntimeValue("claude sonnet"))
        XCTAssertThrowsError(try ClaudeCodeAdapter.normalizedRuntimeValue("claude-sonnet\""))
        XCTAssertThrowsError(try ClaudeCodeAdapter.normalizedRuntimeValue("claude-sonnet\u{0000}"))
    }

    func testClaudeCodeReasoningEffortNormalizationAllowsOnlyPublishedOptions() throws {
        XCTAssertEqual(try ClaudeCodeAdapter.normalizedReasoningEffort(" xhigh "), "xhigh")
        XCTAssertEqual(try ClaudeCodeAdapter.normalizedReasoningEffort(" max "), "max")
        XCTAssertNil(try ClaudeCodeAdapter.normalizedReasoningEffort("   "))
        XCTAssertThrowsError(try ClaudeCodeAdapter.normalizedReasoningEffort("turbo"))
        XCTAssertThrowsError(try ClaudeCodeAdapter.normalizedReasoningEffort("xhigh\""))
    }

    func testClaudeCodeRuntimeUpdateRestartsWithNormalizedModelAndEffortArguments() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-claude-runtime-restart-\(UUID().uuidString)",
            isDirectory: true
        )
        let binDirectory = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let argumentsFile = directory.appendingPathComponent("arguments.txt")
        let executable = binDirectory.appendingPathComponent("record-args.sh")
        let script = """
        #!/bin/sh
        : > "\(argumentsFile.path)"
        for arg in "$@"; do
          printf '%s\\n' "$arg" >> "\(argumentsFile.path)"
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = ClaudeCodeAdapter(
            agentID: "claude-code-runtime-restart-test-\(UUID().uuidString)",
            executable: executable.path,
            cwd: directory.path,
            arguments: ["initial"],
            projectsRoot: directory.appendingPathComponent("projects", isDirectory: true)
        )

        try await adapter.updateRuntimeSettings(
            AgentRuntimeSettingsUpdate(
                agentId: adapter.agentID,
                modelId: "  claude-sonnet-4-5-20250929  ",
                reasoningEffort: "\thigh\n"
            )
        )
        defer { Task { await adapter.stop() } }

        let expectedArguments = [
            "--model", "claude-sonnet-4-5-20250929",
            "--effort", "high",
            "initial",
        ]
        XCTAssertEqual(adapter.arguments, expectedArguments)
        try await waitForFile(argumentsFile, toEqualLines: expectedArguments)

        let controls = try XCTUnwrap(adapter.runtimeControls())
        XCTAssertEqual(controls.modelId, "claude-sonnet-4-5-20250929")
        XCTAssertEqual(controls.reasoningEffort, "high")
        XCTAssertEqual(controls.appliesOn, .immediate)
    }

    func testClaudeCodeBlankRuntimeValuesClearSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-claude-runtime-clear-\(UUID().uuidString)",
            isDirectory: true
        )
        let binDirectory = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let argumentsFile = directory.appendingPathComponent("arguments.txt")
        let executable = binDirectory.appendingPathComponent("record-args.sh")
        let script = """
        #!/bin/sh
        : > "\(argumentsFile.path)"
        for arg in "$@"; do
          printf '%s\\n' "$arg" >> "\(argumentsFile.path)"
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = ClaudeCodeAdapter(
            agentID: "claude-code-runtime-clear-test-\(UUID().uuidString)",
            executable: executable.path,
            cwd: directory.path,
            arguments: ["initial"],
            projectsRoot: directory.appendingPathComponent("projects", isDirectory: true)
        )

        try await adapter.updateRuntimeSettings(
            AgentRuntimeSettingsUpdate(
                agentId: adapter.agentID,
                modelId: "   ",
                reasoningEffort: "\n\t"
            )
        )
        defer { Task { await adapter.stop() } }

        XCTAssertEqual(adapter.arguments, ["initial"])
        try await waitForFile(argumentsFile, toEqualLines: ["initial"])

        let controls = try XCTUnwrap(adapter.runtimeControls())
        XCTAssertEqual(controls.modelId, "")
        XCTAssertEqual(controls.modelLabel, "Default")
        XCTAssertEqual(controls.reasoningEffort, "")
        XCTAssertEqual(controls.reasoningEffortLabel, "Default")
    }

    func testClaudeCodeRejectsMalformedRuntimeUpdateWithoutChangingSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-claude-runtime-invalid-\(UUID().uuidString)",
            isDirectory: true
        )
        let binDirectory = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let argumentsFile = directory.appendingPathComponent("arguments.txt")
        let executable = binDirectory.appendingPathComponent("record-args.sh")
        let script = """
        #!/bin/sh
        : > "\(argumentsFile.path)"
        for arg in "$@"; do
          printf '%s\\n' "$arg" >> "\(argumentsFile.path)"
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = ClaudeCodeAdapter(
            agentID: "claude-code-runtime-invalid-test-\(UUID().uuidString)",
            executable: executable.path,
            cwd: directory.path,
            arguments: ["initial"],
            projectsRoot: directory.appendingPathComponent("projects", isDirectory: true)
        )

        try await adapter.updateRuntimeSettings(
            AgentRuntimeSettingsUpdate(
                agentId: adapter.agentID,
                modelId: "claude-sonnet-4-5-20250929",
                reasoningEffort: "xhigh"
            )
        )
        defer { Task { await adapter.stop() } }

        let expectedArguments = [
            "--model", "claude-sonnet-4-5-20250929",
            "--effort", "xhigh",
            "initial",
        ]
        XCTAssertEqual(adapter.arguments, expectedArguments)
        try await waitForFile(argumentsFile, toEqualLines: expectedArguments)

        async let rollbackSnapshot = waitForSnapshot(adapter) { snapshot in
            snapshot.statusDetail == "settings failed" &&
                snapshot.runtimeControls?.modelId == "claude-sonnet-4-5-20250929" &&
                snapshot.runtimeControls?.reasoningEffort == "xhigh"
        }

        do {
            try await adapter.updateRuntimeSettings(
                AgentRuntimeSettingsUpdate(
                    agentId: adapter.agentID,
                    modelId: "claude-opus-4-8",
                    reasoningEffort: "xhigh\""
                )
            )
            XCTFail("Malformed Claude Code runtime update should be rejected.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Claude Code effort"))
        }

        _ = try await rollbackSnapshot

        XCTAssertEqual(adapter.arguments, expectedArguments)
        try await waitForFile(argumentsFile, toEqualLines: expectedArguments)

        let controls = try XCTUnwrap(adapter.runtimeControls())
        XCTAssertEqual(controls.modelId, "claude-sonnet-4-5-20250929")
        XCTAssertEqual(controls.reasoningEffort, "xhigh")
    }

    func testClaudeCodeRuntimeRestartFailureRollsBackSelectionAndArguments() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gt-claude-runtime-restart-failure-\(UUID().uuidString)",
            isDirectory: true
        )
        let binDirectory = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let argumentsFile = directory.appendingPathComponent("arguments.txt")
        let executable = binDirectory.appendingPathComponent("record-args.sh")
        let script = """
        #!/bin/sh
        : > "\(argumentsFile.path)"
        for arg in "$@"; do
          printf '%s\\n' "$arg" >> "\(argumentsFile.path)"
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = ClaudeCodeAdapter(
            agentID: "claude-code-runtime-restart-failure-test-\(UUID().uuidString)",
            executable: executable.path,
            cwd: directory.path,
            arguments: ["initial"],
            projectsRoot: directory.appendingPathComponent("projects", isDirectory: true)
        )

        try await adapter.updateRuntimeSettings(
            AgentRuntimeSettingsUpdate(
                agentId: adapter.agentID,
                modelId: "claude-sonnet-4-5-20250929",
                reasoningEffort: "high"
            )
        )
        defer { Task { await adapter.stop() } }

        let previousArguments = [
            "--model", "claude-sonnet-4-5-20250929",
            "--effort", "high",
            "initial",
        ]
        XCTAssertEqual(adapter.arguments, previousArguments)
        try await waitForFile(argumentsFile, toEqualLines: previousArguments)

        try FileManager.default.removeItem(at: executable)

        async let rollbackSnapshot = waitForSnapshot(adapter) { snapshot in
            snapshot.statusDetail == "settings failed" &&
                snapshot.runtimeControls?.modelId == "claude-sonnet-4-5-20250929" &&
                snapshot.runtimeControls?.reasoningEffort == "high"
        }

        do {
            try await adapter.updateRuntimeSettings(
                AgentRuntimeSettingsUpdate(
                    agentId: adapter.agentID,
                    modelId: "claude-opus-4-8",
                    reasoningEffort: "max"
                )
            )
            XCTFail("Claude Code restart failure should be surfaced.")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }

        _ = try await rollbackSnapshot

        XCTAssertEqual(adapter.arguments, previousArguments)
        let controls = try XCTUnwrap(adapter.runtimeControls())
        XCTAssertEqual(controls.modelId, "claude-sonnet-4-5-20250929")
        XCTAssertEqual(controls.reasoningEffort, "high")
    }

    private func waitForSnapshot(
        _ adapter: ClaudeCodeAdapter,
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
        XCTFail("Timed out waiting for \(url.path) to contain expected Claude Code runtime arguments. Actual contents: \(contents)")
    }
}
