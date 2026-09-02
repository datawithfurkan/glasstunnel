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
            for await snapshot in adapter.observeState() where snapshot.statusDetail == "Stop" {
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
                try await Task.sleep(nanoseconds: 4_000_000_000)
                throw CancellationError()
            }
            let snapshot = try await group.next()
            group.cancelAll()
            if let snapshot { return snapshot }
            throw CancellationError()
        }
    }
}
