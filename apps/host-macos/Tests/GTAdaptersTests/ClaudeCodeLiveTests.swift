import XCTest
@testable import GTAdapters
import GTProtocol

/// Opt-in end-to-end run against the real `claude` CLI and the signed-in
/// account on this Mac. It exercises the adapter exactly as the host does:
/// a PTY launch pinned to a fresh session id, hooks loaded from a temporary
/// settings file (`--settings`, so the user's own settings are untouched),
/// a prompt delivered through `sendInput`, the Stop hook, and the transcript
/// parse that produces the phone's chat.
///
///     GT_CLAUDE_LIVE=1 GT_CLAUDE_LIVE_CWD=/trusted/project \
///       swift test --package-path apps/host-macos --filter ClaudeCodeLiveTests
///
/// The run leaves one small transcript in `~/.claude/projects` for the chosen
/// working directory, like any Claude Code session would.
final class ClaudeCodeLiveTests: XCTestCase {
    private static let marker = "GT_CLAUDE_LIVE_OK"

    func testRealClaudeCodePromptRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["GT_CLAUDE_LIVE"] == "1" else {
            throw XCTSkip("Set GT_CLAUDE_LIVE=1 to run the live Claude Code CLI round trip.")
        }
        let cwd = ProcessInfo.processInfo.environment["GT_CLAUDE_LIVE_CWD"]
            ?? FileManager.default.currentDirectoryPath
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("gt-claude-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Hooks go into a temporary settings file that `claude --settings`
        // merges in, so the real ~/.claude/settings.json is never written.
        let settingsFile = scratch.appendingPathComponent("settings.json")
        let sessionId = UUID().uuidString.lowercased()
        let launcher = try Self.makeCleanEnvironmentLauncher(in: scratch)
        let adapter = ClaudeCodeAdapter(
            agentID: "claude-code-live",
            executable: launcher.path,
            cwd: cwd,
            arguments: ["--settings", settingsFile.path, "--session-id", sessionId],
            hookInstaller: ClaudeCodeHookInstaller(settingsFileURL: settingsFile)
        )
        defer { Task { await adapter.stop() } }

        let recorder = LiveSnapshotRecorder()
        let collecting = Task {
            var lastPrinted = ""
            for await snapshot in adapter.observeState() {
                await recorder.append(snapshot)
                let tail = snapshot.recentMessages.last.map { "[\($0.role)] " + $0.text.replacingOccurrences(of: "\n", with: "⏎").suffix(220) } ?? "-"
                let line = "\(snapshot.status) '\(snapshot.statusDetail)' n=\(snapshot.recentMessages.count) \(tail)"
                if line != lastPrinted {
                    print("GT_CLAUDE_LIVE snapshot: \(line)")
                    lastPrinted = line
                }
            }
        }
        defer { collecting.cancel() }

        print("GT_CLAUDE_LIVE: launching session \(sessionId) via \(launcher.lastPathComponent) in \(cwd)")
        try await adapter.start()
        XCTAssertTrue(adapter.arguments.contains("--session-id"), "The launch must pin the fresh session id.")
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsFile)) as? [String: Any]
        XCTAssertNotNil((settings?["hooks"] as? [String: Any])?["Stop"], "Hooks were installed into the temporary settings file.")

        // Wait until the TUI has drawn its welcome box before typing; on a
        // cold start that takes a few seconds. The captured text is
        // whitespace-collapsed, so match on tokens that survive collapsing.
        _ = try await recorder.waitFor(timeout: 45) { snapshot in
            snapshot.recentMessages.contains { message in
                message.text.contains("❯") || message.text.contains("CLAUDE.md") || message.text.contains("What'snew")
            }
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try await adapter.sendInput("Reply with exactly this text and nothing else: \(Self.marker)", submit: true)

        // The PTY idle heuristic may report "done" a moment before the Stop
        // hook lands; the hook's own wording proves the hook path worked.
        let finished = try await recorder.waitFor(timeout: 120) { snapshot in
            snapshot.status == .done
                && snapshot.statusDetail == "Response ready"
                && snapshot.recentMessages.contains { $0.role == .assistant && $0.text.contains(Self.marker) }
        }
        let replies = finished.recentMessages.filter { $0.role == .assistant }
        XCTAssertTrue(replies.last?.text.contains(Self.marker) == true)
        XCTAssertEqual(
            finished.availableTargets?.first { $0.selected }?.targetId,
            sessionId,
            "The transcript the adapter parsed belongs to the session it launched."
        )

        print("GT_CLAUDE_LIVE: session \(sessionId) completed a turn; final status \(finished.status) '\(finished.statusDetail)'; \(finished.recentMessages.count) messages parsed from the transcript")
    }

    /// The host app launches `claude` with a plain login environment. This
    /// test may itself run inside a Claude Code session, whose CLAUDE_* and
    /// ANTHROPIC_* variables would turn the child into a child session that
    /// keeps no transcript of its own, so strip them before exec.
    private static func makeCleanEnvironmentLauncher(in directory: URL) throws -> URL {
        let claude = try XCTUnwrap(
            ClaudeCodeAdapter.executableCandidates().first { candidate in
                if candidate.contains("/") {
                    return FileManager.default.isExecutableFile(atPath: candidate)
                }
                let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
                return path.split(separator: ":").contains { directory in
                    FileManager.default.isExecutableFile(atPath: "\(directory)/\(candidate)")
                }
            },
            "claude must be installed to run the live test"
        )
        let unset = ProcessInfo.processInfo.environment.keys
            .filter { $0.hasPrefix("CLAUDE") || $0.hasPrefix("ANTHROPIC") }
            .sorted()
            .map { "-u \($0)" }
            .joined(separator: " ")
        let launcher = directory.appendingPathComponent("claude-clean-env.sh")
        let script = """
        #!/bin/sh
        exec /usr/bin/env \(unset) "\(claude)" "$@"
        """
        try script.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        return launcher
    }
}

private actor LiveSnapshotRecorder {
    private var snapshots: [AgentStateSnapshot] = []

    func append(_ snapshot: AgentStateSnapshot) {
        snapshots.append(snapshot)
    }

    func waitFor(timeout: TimeInterval, matching predicate: @escaping (AgentStateSnapshot) -> Bool) async throws -> AgentStateSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = snapshots.last(where: predicate) {
                return match
            }
            // Keep waiting even if the surrounding task is cancelled so the
            // diagnostic below, not a bare CancellationError, is what fails.
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let recent = snapshots.suffix(4).map { snapshot in
            let tail = snapshot.recentMessages.suffix(2).map { message in
                "[\(message.role)] " + message.text.replacingOccurrences(of: "\n", with: " ").prefix(160)
            }.joined(separator: " | ")
            return "\(snapshot.status) '\(snapshot.statusDetail)' messages=\(snapshot.recentMessages.count) tail=\(tail)"
        }.joined(separator: "\n  ")
        throw NSError(
            domain: "ClaudeCodeLiveTests",
            code: 408,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for the live Claude Code snapshot; recent snapshots:\n  \(recent)"]
        )
    }
}
