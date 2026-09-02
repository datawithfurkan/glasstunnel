import XCTest
@testable import GTAdapters
import GTProtocol

final class AdapterFactoryTests: XCTestCase {
    func testResolveCursor() {
        XCTAssertEqual(AdapterFactory.resolveKind(forBundleID: "com.todesktop.230313mzl4w4u92"), .cursor)
    }

    func testLegacyGuessedClaudeBundleIDsFallBackToMirror() {
        // These identifiers never matched a shipping app; the Claude desktop
        // app is `com.anthropic.claudefordesktop` and the CLI has no bundle.
        XCTAssertEqual(AdapterFactory.resolveKind(forBundleID: "com.anthropic.claudecode"), .mirror)
        XCTAssertEqual(AdapterFactory.resolveKind(forBundleID: "com.anthropic.claudecode.macos"), .mirror)
    }

    func testResolveClaudeDesktop() {
        XCTAssertEqual(AdapterFactory.resolveKind(forBundleID: "com.anthropic.claudefordesktop"), .claudeDesktop)
        XCTAssertEqual(ClaudeDesktopAdapter.bundleID, "com.anthropic.claudefordesktop")
    }

    func testClaudeCodeExecutableCandidatesCoverCommonLocalInstalls() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let candidates = ClaudeCodeAdapter.executableCandidates()

        XCTAssertEqual(candidates.first, "claude")
        XCTAssertTrue(candidates.contains("/opt/homebrew/bin/claude"))
        XCTAssertTrue(candidates.contains("/usr/local/bin/claude"))
        XCTAssertTrue(candidates.contains("\(home)/.local/bin/claude"))
        XCTAssertTrue(candidates.contains("\(home)/.claude/local/bin/claude"))
        XCTAssertTrue(candidates.contains("\(home)/.cargo/bin/claude"))
        XCTAssertTrue(candidates.contains("\(home)/.bun/bin/claude"))
        XCTAssertTrue(candidates.contains("\(home)/.npm-global/bin/claude"))
    }

    func testResolveCodexDesktopFallsBackToMirror() {
        XCTAssertEqual(AdapterFactory.resolveKind(forBundleID: "com.openai.codex"), .mirror)
    }

    func testResolveCodexCLI() {
        XCTAssertEqual(AdapterFactory.resolveKind(forBundleID: "com.openai.codex.cli"), .codexCli)
    }

    func testResolveGeminiCLI() {
        XCTAssertEqual(AdapterFactory.resolveKind(forBundleID: "com.google.gemini.cli"), .geminiCli)
        XCTAssertEqual(AdapterFactory.resolveKind(forBundleID: "com.google.gemini"), .geminiCli)
    }

    func testCodexExecutableCandidatesCoverCommonLocalInstalls() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let candidates = CodexAdapter.executableCandidates()

        XCTAssertEqual(candidates.first, "codex")
        XCTAssertTrue(candidates.contains("\(home)/.codex-cli/bin/codex"))
        XCTAssertTrue(candidates.contains("\(home)/.volta/bin/codex"))
        XCTAssertTrue(candidates.contains("/opt/homebrew/bin/codex"))
        XCTAssertTrue(candidates.contains("\(home)/.bun/bin/codex"))
        XCTAssertTrue(candidates.contains("\(home)/.npm-global/bin/codex"))
    }

    func testGeminiExecutableCandidatesCoverCommonLocalInstalls() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let candidates = GeminiAdapter.executableCandidates()

        XCTAssertEqual(candidates.first, "gemini")
        XCTAssertTrue(candidates.contains("/opt/homebrew/bin/gemini"))
        XCTAssertTrue(candidates.contains("/usr/local/bin/gemini"))
        XCTAssertTrue(candidates.contains("\(home)/.bun/bin/gemini"))
        XCTAssertTrue(candidates.contains("\(home)/.npm-global/bin/gemini"))
        XCTAssertTrue(candidates.contains("\(home)/.volta/bin/gemini"))
    }

    func testCursorAgentExecutableCandidatesCoverCommonLocalInstalls() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let candidates = CursorAgentAdapter.executableCandidates()

        XCTAssertEqual(candidates.first, "cursor-agent")
        XCTAssertTrue(candidates.contains("\(home)/.local/bin/cursor-agent"))
        XCTAssertTrue(candidates.contains("/opt/homebrew/bin/cursor-agent"))
        XCTAssertTrue(candidates.contains("/usr/local/bin/cursor-agent"))
        XCTAssertTrue(candidates.contains("\(home)/.bun/bin/cursor-agent"))
        XCTAssertTrue(candidates.contains("\(home)/.npm-global/bin/cursor-agent"))
        XCTAssertTrue(candidates.contains("\(home)/.volta/bin/cursor-agent"))
    }

    func testOpenCodeExecutableCandidatesCoverCommonLocalInstalls() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let candidates = OpenCodeAdapter.executableCandidates()

        XCTAssertEqual(candidates.first, "opencode")
        XCTAssertTrue(candidates.contains("\(home)/.volta/bin/opencode"))
        XCTAssertTrue(candidates.contains("/opt/homebrew/bin/opencode"))
        XCTAssertTrue(candidates.contains("/usr/local/bin/opencode"))
        XCTAssertTrue(candidates.contains("\(home)/.local/bin/opencode"))
        XCTAssertTrue(candidates.contains("\(home)/.cargo/bin/opencode"))
        XCTAssertTrue(candidates.contains("\(home)/.bun/bin/opencode"))
        XCTAssertTrue(candidates.contains("\(home)/.npm-global/bin/opencode"))
        XCTAssertTrue(candidates.contains("/Applications/OpenCode.app/Contents/MacOS/opencode-cli"))
        XCTAssertTrue(candidates.contains("\(home)/Applications/OpenCode.app/Contents/MacOS/opencode-cli"))
        XCTAssertFalse(candidates.contains("/Applications/OpenCode.app/Contents/MacOS/OpenCode"))
        XCTAssertFalse(candidates.contains("\(home)/Applications/OpenCode.app/Contents/MacOS/OpenCode"))
    }

    func testResolveOpenCode() {
        XCTAssertEqual(AdapterFactory.resolveKind(forBundleID: "ai.opencode.app"), .openCode)
        XCTAssertEqual(AdapterFactory.resolveKind(forBundleID: "ai.opencode.desktop"), .openCode)
    }

    func testFallbackToMirror() {
        XCTAssertEqual(AdapterFactory.resolveKind(forBundleID: "com.unknown.whatever"), .mirror)
    }
}

final class ANSIStripperTests: XCTestCase {
    func testStripsColors() {
        let input = "\u{001B}[31mhello\u{001B}[0m world"
        XCTAssertEqual(ANSIStripper.strip(input), "hello world")
    }

    func testStripsCursorMoves() {
        let input = "\u{001B}[2J\u{001B}[Hcleared"
        XCTAssertEqual(ANSIStripper.strip(input), "cleared")
    }

    func testLeavesPlainTextAlone() {
        let input = "plain text without escapes"
        XCTAssertEqual(ANSIStripper.strip(input), "plain text without escapes")
    }

    func testCollapsesCarriageReturnRewrites() {
        let input = "Starting MCP servers (1/5)\u{001B}[2K\rStarting MCP servers (2/5)\u{001B}[2K\rReady"
        XCTAssertEqual(ANSIStripper.normalizeForLog(input), "Ready")
    }

    func testCollapsesAnsiClearLineRewrites() {
        let input = "Starting\u{001B}[2K\rDone"
        XCTAssertEqual(ANSIStripper.normalizeForLog(input), "Done")
    }

    func testCollapsesBackspaceRewrites() {
        let input = "Spinnx\u{0008}er"
        XCTAssertEqual(ANSIStripper.normalizeForLog(input), "Spinner")
    }
}

final class PTYWrapperTests: XCTestCase {
    func testReapsRecordedProcessesOwnedByDeadHost() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GTPTYWrapperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stale = PTYWrapper.ProcessRecord(
            ownerPid: 1111,
            childPid: 2222,
            executable: "/bin/sh",
            arguments: ["-l"],
            preserveOnOwnerExit: false,
            createdAt: Date()
        )
        let staleURL = directory.appendingPathComponent("2222.json")
        try JSONEncoder().encode(stale).write(to: staleURL)

        var signals: [(pid_t, Int32)] = []
        let count = PTYWrapper.reapStaleRecordedProcesses(
            currentOwnerPid: 9999,
            processIsRunning: { _ in false },
            signalProcessGroup: { pid, signal in signals.append((pid, signal)) },
            registryDirectory: directory
        )

        XCTAssertEqual(count, 1)
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals.first?.0, 2222)
        XCTAssertEqual(signals.first?.1, SIGTERM)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
    }

    func testKeepsRecordedProcessesForCurrentOrLiveHost() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GTPTYWrapperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let current = PTYWrapper.ProcessRecord(
            ownerPid: 100,
            childPid: 200,
            executable: "/bin/sh",
            arguments: [],
            preserveOnOwnerExit: false,
            createdAt: Date()
        )
        let liveOther = PTYWrapper.ProcessRecord(
            ownerPid: 101,
            childPid: 201,
            executable: "/bin/sh",
            arguments: [],
            preserveOnOwnerExit: false,
            createdAt: Date()
        )
        let currentURL = directory.appendingPathComponent("200.json")
        let liveURL = directory.appendingPathComponent("201.json")
        try JSONEncoder().encode(current).write(to: currentURL)
        try JSONEncoder().encode(liveOther).write(to: liveURL)

        var signals: [(pid_t, Int32)] = []
        let count = PTYWrapper.reapStaleRecordedProcesses(
            currentOwnerPid: 100,
            processIsRunning: { $0 == 101 },
            signalProcessGroup: { pid, signal in signals.append((pid, signal)) },
            registryDirectory: directory
        )

        XCTAssertEqual(count, 0)
        XCTAssertTrue(signals.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveURL.path))
    }

    func testReapsTerminalScreenAttachmentOwnedByDeadHost() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GTPTYWrapperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let terminal = PTYWrapper.ProcessRecord(
            ownerPid: 1111,
            childPid: 2222,
            executable: "/usr/bin/screen",
            arguments: ["-xRR", "-S", "glasstunnel-terminal"],
            preserveOnOwnerExit: true,
            createdAt: Date()
        )
        let terminalURL = directory.appendingPathComponent("2222.json")
        try JSONEncoder().encode(terminal).write(to: terminalURL)

        var signals: [(pid_t, Int32)] = []
        let count = PTYWrapper.reapStaleRecordedProcesses(
            currentOwnerPid: 9999,
            processIsRunning: { _ in false },
            signalProcessGroup: { pid, signal in signals.append((pid, signal)) },
            registryDirectory: directory
        )

        XCTAssertEqual(count, 1)
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals.first?.0, 2222)
        XCTAssertEqual(signals.first?.1, SIGTERM)
        XCTAssertFalse(FileManager.default.fileExists(atPath: terminalURL.path))
    }

    func testRespondsToBasicTerminalCapabilityQueries() throws {
        let wrapper = PTYWrapper(
            executable: "/usr/bin/python3",
            arguments: [
                "-c",
                """
                import os, sys, termios, tty
                original = termios.tcgetattr(0)
                tty.setraw(0)
                sys.stdout.write("\\x1b[6n\\x1b]10;?\\x1b\\\\\\x1b]11;?\\x1b\\\\\\x1b[c")
                sys.stdout.flush()
                data = os.read(0, 256)
                termios.tcsetattr(0, termios.TCSADRAIN, original)
                checks = [
                    b"\\x1b[1;1R" in data,
                    b"\\x1b]10;rgb:ffff/ffff/ffff\\x1b\\\\" in data,
                    b"\\x1b]11;rgb:0000/0000/0000\\x1b\\\\" in data,
                    b"\\x1b[?1;2c" in data,
                ]
                print("GT_PTY_QUERY_RESPONSES=" + ",".join("1" if item else "0" for item in checks))
                """,
            ]
        )
        let responded = expectation(description: "PTY wrapper answers terminal capability queries")
        let output = LockedTestString()
        wrapper.onData = { data in
            guard let text = String(data: data, encoding: .utf8) else { return }
            output.append(text)
            if output.contains("GT_PTY_QUERY_RESPONSES=1,1,1,1") {
                responded.fulfill()
            }
        }

        try wrapper.start()

        wait(for: [responded], timeout: 5)
        wrapper.stop()
    }

    func testInterruptSignalsSpawnedProcessGroup() throws {
        let wrapper = PTYWrapper(
            executable: "/usr/bin/perl",
            arguments: [
                "-e",
                "$SIG{INT} = sub { print \"GT_PTY_GROUP_INTERRUPTED\\n\"; exit 130; }; sleep 20; print \"GT_PTY_NOT_INTERRUPTED\\n\";",
            ]
        )
        let interrupted = expectation(description: "spawned process group receives SIGINT")
        let output = LockedTestString()
        wrapper.onData = { data in
            guard let text = String(data: data, encoding: .utf8) else { return }
            output.append(text)
            if output.contains("GT_PTY_GROUP_INTERRUPTED") {
                interrupted.fulfill()
            }
        }

        try wrapper.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            wrapper.interrupt()
        }

        wait(for: [interrupted], timeout: 5)
        wrapper.stop()

        XCTAssertFalse(output.value.contains("GT_PTY_NOT_INTERRUPTED"))
    }

    func testStopDetachesLateExitCallbacksBeforeNextWorkingState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GTPTYAdapterStopRace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let releaseFile = directory.appendingPathComponent("release-exit")
        let executable = directory.appendingPathComponent("exit-after-release.sh")
        let script = """
        #!/bin/sh
        trap '' TERM HUP INT
        while [ ! -f "\(releaseFile.path)" ]; do
          sleep 0.05
        done
        exit 0
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let adapter = TestPTYAdapter(executable: executable.path)
        let recorder = SnapshotRecorder()
        let collection = Task {
            for await snapshot in adapter.observeState() {
                await recorder.append(snapshot)
            }
        }
        defer { collection.cancel() }

        try await adapter.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        await adapter.stop()
        adapter.transitionTo(.working, detail: "running OpenCode prompt", forceEmit: true)
        try "release\n".write(to: releaseFile, atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 400_000_000)

        let snapshots = await recorder.values
        let workingIndex = try XCTUnwrap(snapshots.lastIndex {
            $0.status == .working && $0.statusDetail == "running OpenCode prompt"
        })
        let afterWorking = snapshots.suffix(from: snapshots.index(after: workingIndex))
        XCTAssertFalse(afterWorking.contains {
            $0.status == .done && $0.statusDetail.hasPrefix("process exited")
        }, "Stopped PTY exit must not overwrite a newer working state.")
    }
}

private final class LockedTestString: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ text: String) {
        lock.lock()
        storage.append(text)
        lock.unlock()
    }

    func contains(_ text: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.contains(text)
    }
}

private final class TestPTYAdapter: PTYAdapterBase, @unchecked Sendable {
    init(executable: String) {
        super.init(
            agentID: "test-pty-\(UUID().uuidString)",
            kind: .terminal,
            label: "Test PTY",
            executable: executable
        )
    }
}

private actor SnapshotRecorder {
    private(set) var values: [AgentStateSnapshot] = []

    func append(_ snapshot: AgentStateSnapshot) {
        values.append(snapshot)
    }
}

final class StreamWriterTests: XCTestCase {
    func testLateSubscriberReceivesLatestValue() async {
        let writer = StreamWriter<Int>()
        writer.yield(42)

        let values = await collect(stream: writer.make(), count: 1)

        XCTAssertEqual(values, [42])
    }

    func testMultipleSubscribers() async {
        let writer = StreamWriter<Int>()
        let s1 = writer.make()
        let s2 = writer.make()

        async let values1 = collect(stream: s1, count: 3)
        async let values2 = collect(stream: s2, count: 3)

        try? await Task.sleep(nanoseconds: 50_000_000)
        writer.yield(1)
        writer.yield(2)
        writer.yield(3)
        writer.finish()

        let v1 = await values1
        let v2 = await values2
        XCTAssertEqual(v1, [1, 2, 3])
        XCTAssertEqual(v2, [1, 2, 3])
    }

    private func collect<T: Sendable>(stream: AsyncStream<T>, count: Int) async -> [T] {
        var out: [T] = []
        for await v in stream {
            out.append(v)
            if out.count >= count { break }
        }
        return out
    }
}
