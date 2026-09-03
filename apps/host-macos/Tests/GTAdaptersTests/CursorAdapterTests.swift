#if os(macOS)
import XCTest
@testable import GTAdapters
import GTProtocol

/// The Cursor desktop card against a fixture store, a fake window driver, and
/// a fake hook source: chat listing, structured history, verified prompt
/// delivery, chat switching, hook-driven turn state, interrupt, and the
/// read-only runtime controls.
final class CursorAdapterTests: XCTestCase {
    private var root: URL!
    private var driver: FakeCursorDriver!
    private var hooks: FakeCursorHookSource!
    private var adapter: CursorAdapter!
    private var snapshots: CursorSnapshotCollector!

    override func setUpWithError() throws {
        root = try CursorTestFixtures.temporaryDirectory("gt-cursor-adapter")
        try CursorTestFixtures.writeDesktopStore(
            at: root,
            composers: [
                CursorTestFixtures.Composer(
                    composerId: "composer-release",
                    name: "Release chat",
                    workspaceId: "ws-1",
                    createdAt: 1_782_385_000_000,
                    lastUpdatedAt: 1_782_387_000_000,
                    messages: [
                        ["role": "system", "content": "You are Cursor."],
                        ["role": "user", "content": "<user_info>\nOS\n</user_info>"],
                        ["role": "user", "content": [["type": "text", "text": "Check the repo"]]],
                        ["role": "assistant", "content": [
                            ["type": "text", "text": "Looking."],
                            ["type": "tool-call", "toolCallId": "c1", "toolName": "Shell", "args": ["command": "git status --short"]],
                        ]],
                        ["role": "tool", "content": [["type": "tool-result", "toolCallId": "c1", "toolName": "Shell", "result": "clean"]]],
                        ["role": "assistant", "content": [["type": "text", "text": "All clean."]]],
                    ]
                ),
                CursorTestFixtures.Composer(
                    composerId: "composer-loose",
                    name: "Loose chat",
                    workspaceId: "empty-window",
                    createdAt: 1_770_000_000_000,
                    lastUpdatedAt: 1_770_000_003_000,
                    mode: "chat",
                    messages: [
                        ["role": "user", "content": [["type": "text", "text": "hello"]]],
                        ["role": "assistant", "content": [["type": "text", "text": "hi"]]],
                    ]
                ),
                CursorTestFixtures.Composer(composerId: "composer-draft", name: nil, workspaceId: "ws-1", createdAt: 1, lastUpdatedAt: 1, isDraft: true),
            ],
            workspaces: ["ws-1": "/Users/dev/App"]
        )
        driver = FakeCursorDriver()
        driver.frontTitle = "Release chat"
        hooks = FakeCursorHookSource()
        let source = hooks!
        adapter = CursorAdapter(
            agentID: "cursor",
            label: "Cursor",
            ui: driver,
            watcher: CursorStateWatcher(stateDir: root, agentID: "cursor"),
            hookRouter: CursorHookRouter(makeListener: { source }),
            hookInstaller: CursorHookInstaller(hooksFileURL: root.appendingPathComponent("hooks.json")),
            staleWorkingInterval: 600
        )
        snapshots = CursorSnapshotCollector(adapter.observeState())
    }

    override func tearDown() async throws {
        await adapter.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func testStartListsChatsAndStructuredHistoryWithReadOnlyModel() async throws {
        try await adapter.start()
        let ready = try await snapshots.wait(timeout: 5) { $0.status == .done }
        XCTAssertEqual(ready.statusDetail, CursorConversationBuilder.doneDetail)
        XCTAssertEqual(ready.agentLabel, "Release chat")
        let targets = try XCTUnwrap(ready.availableTargets)
        XCTAssertEqual(targets.map(\.threadLabel), ["Release chat", "Loose chat", "New chat"], "drafts stay out; a new chat can be started")
        XCTAssertEqual(targets[0].projectLabel, "App")
        XCTAssertEqual(targets[0].projectPath, "/Users/dev/App")
        XCTAssertEqual(targets[0].selected, true)
        XCTAssertEqual(targets[0].isActive, true, "the driver reports the chat in front")
        XCTAssertEqual(targets[1].subtitle, "Ask chat")
        XCTAssertNil(targets[1].projectLabel, "a chat without a folder stands alone")
        XCTAssertEqual(targets[1].label, "Loose chat")
        XCTAssertEqual(ready.recentMessages.map(\.kind), [.text, .text, .toolCall, .toolResult, .text])
        XCTAssertEqual(ready.recentMessages[0].text, "Check the repo")
        XCTAssertEqual(ready.recentMessages[2].title, "git status --short")
        XCTAssertEqual(ready.recentMessages[3].toolCallId, "c1")
        XCTAssertEqual(ready.recentMessages[4].text, "All clean.")
        let controls = try XCTUnwrap(ready.runtimeControls)
        XCTAssertEqual(controls.modelId, "composer-2.5")
        XCTAssertEqual(controls.modelLabel, "Composer 2.5")
        XCTAssertFalse(controls.editable)
        XCTAssertEqual(controls.appliesOn, .managedLocally)
        XCTAssertEqual(controls.note, "Agent chat · Managed in Cursor")
        XCTAssertTrue(CursorHookInstaller(hooksFileURL: root.appendingPathComponent("hooks.json")).isInstalled(), "the card installs the Cursor hooks")
        XCTAssertEqual(CursorAdapter.modelLabel("gpt-5.4-nano"), "GPT-5.4 Nano")
        XCTAssertEqual(CursorAdapter.modelLabel("default"), "Default")
    }

    func testChatTitleControlLabelsAreParsed() {
        XCTAssertEqual(CursorAccessibilityDriver.chatTitle(fromControlLabel: "Chat title. Glasstunnel live evidence"), "Glasstunnel live evidence")
        XCTAssertEqual(CursorAccessibilityDriver.chatTitle(fromControlLabel: "Chat title: Release"), "Release")
        XCTAssertNil(CursorAccessibilityDriver.chatTitle(fromControlLabel: "Glasstunnel live evidence 1m"))
        XCTAssertNil(CursorAccessibilityDriver.chatTitle(fromControlLabel: "Chat title."))
        XCTAssertTrue(CursorAccessibilityDriver.titlesMatch("Glasstunnel live evidence 1m", "Glasstunnel live evidence"), "sidebar rows carry the age after the name")
        XCTAssertTrue(CursorAccessibilityDriver.stopLabels.contains("Stop generation"))
        XCTAssertTrue(CursorAccessibilityDriver.composerPlaceholders.contains("Send follow-up"))
    }

    func testPromptIsTypedOnlyIntoTheConfirmedChat() async throws {
        try await adapter.start()
        _ = try await snapshots.wait(timeout: 5) { $0.status == .done }

        try await adapter.sendInput("Run the tests", submit: true)
        XCTAssertEqual(driver.delivered.map(\.text), ["Run the tests"])
        XCTAssertEqual(driver.delivered.first?.submit, true)
        let working = try await snapshots.wait(timeout: 5) { $0.status == .working }
        XCTAssertEqual(working.statusDetail, CursorAdapter.workingDetail)
        XCTAssertEqual(working.recentMessages.last?.role, .user)
        XCTAssertEqual(working.recentMessages.last?.text, "Run the tests", "the prompt is echoed before the store shows it")

        driver.frontTitle = "Some other chat"
        driver.followsSwitch = false
        do {
            try await adapter.sendInput("Wrong window", submit: true)
            XCTFail("a verifiable mismatch must refuse the prompt")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Switch Cursor to “Release chat”"))
        }
        XCTAssertEqual(driver.delivered.count, 1)
        XCTAssertEqual(driver.shown, ["Release chat"], "the adapter tried to bring the chat in front first")

        driver.frontTitle = nil
        try await adapter.sendInput("No title readable", submit: true)
        XCTAssertEqual(driver.delivered.count, 2, "without any readable title the composer is used")
    }

    func testSelectingAChatPressesItAndReportsWhetherTheAppFollowed() async throws {
        try await adapter.start()
        _ = try await snapshots.wait(timeout: 5) { $0.status == .done }

        driver.followsSwitch = true
        try await adapter.selectTarget("composer-loose")
        XCTAssertEqual(driver.shown, ["Loose chat"])
        let switched = try await snapshots.wait(timeout: 5) { snapshot in
            snapshot.availableTargets?.first { $0.targetId == "composer-loose" }?.isActive == true
                && snapshot.recentMessages.map(\.text) == ["hello", "hi"]
        }
        XCTAssertEqual(switched.availableTargets?.first { $0.targetId == "composer-loose" }?.isActive, true)
        XCTAssertEqual(switched.agentLabel, "Loose chat")

        driver.followsSwitch = false
        driver.frontTitle = "Loose chat"
        try await adapter.selectTarget("composer-release")
        let stuck = try await snapshots.wait(timeout: 5) { $0.statusDetail.contains("open “Release chat” in Cursor") }
        XCTAssertEqual(stuck.availableTargets?.first { $0.targetId == "composer-release" }?.selected, true)
        XCTAssertEqual(stuck.availableTargets?.first { $0.targetId == "composer-release" }?.isActive, false, "the phone retries until the app shows it")

        do {
            try await adapter.selectTarget("composer-missing")
            XCTFail("unknown chats are refused")
        } catch {
            XCTAssertTrue(String(describing: error).contains("not found"))
        }

        try await adapter.selectTarget(CursorAdapter.newChatTargetId)
        XCTAssertEqual(driver.newChats, 1)
        let fresh = try await snapshots.wait(timeout: 5) { $0.statusDetail == "New chat opened in Cursor" }
        XCTAssertEqual(fresh.status, .idle)
        driver.frontTitle = "Unrelated"
        try await adapter.sendInput("First prompt of the new chat", submit: true)
        XCTAssertEqual(driver.delivered.last?.text, "First prompt of the new chat", "a new chat has no title yet, so the front check is skipped")
    }

    func testHooksDriveTheTurnAndTheStoreSettlesIt() async throws {
        try await adapter.start()
        _ = try await snapshots.wait(timeout: 5) { $0.status == .done }

        hooks.emit(kind: "beforeSubmitPrompt", conversation: "composer-release")
        let working = try await snapshots.wait(timeout: 5) { $0.status == .working }
        XCTAssertEqual(working.statusDetail, CursorAdapter.workingDetail)

        hooks.emit(kind: "preToolUse", conversation: "composer-release", tool: "Shell", title: "pnpm test", callId: "h1")
        let running = try await snapshots.wait(timeout: 5) { $0.statusDetail == "Running Shell" }
        let row = try XCTUnwrap(running.recentMessages.last)
        XCTAssertEqual(row.kind, .toolCall)
        XCTAssertEqual(row.toolName, "Shell")
        XCTAssertEqual(row.title, "pnpm test")
        XCTAssertEqual(row.toolCallId, "h1")

        hooks.emit(kind: "postToolUseFailure", conversation: "composer-release", tool: "Shell", callId: "h1")
        let failed = try await snapshots.wait(timeout: 5) { $0.recentMessages.last?.kind == .toolResult }
        XCTAssertEqual(failed.recentMessages.last?.toolCallId, "h1")
        XCTAssertEqual(failed.recentMessages.last?.isError, true)
        XCTAssertEqual(failed.status, .working)

        hooks.emit(kind: "stop", conversation: "composer-release", status: "completed")
        let done = try await snapshots.wait(timeout: 5) { $0.status == .done && $0.statusDetail == CursorAdapter.doneDetail }
        XCTAssertTrue(done.recentMessages.contains { $0.toolCallId == "h1" }, "hook rows stay until the store shows the turn")

        // Events for another chat only refresh the list.
        hooks.emit(kind: "stop", conversation: "composer-loose", status: "aborted")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(adapter.currentStatusForTesting(), .done)

        hooks.emit(kind: "stop", conversation: "composer-release", status: "aborted")
        let stopped = try await snapshots.wait(timeout: 5) { $0.status == .idle && $0.statusDetail == CursorAdapter.stoppedDetail }
        XCTAssertEqual(stopped.recentMessages.last?.kind, .event)
        XCTAssertEqual(stopped.recentMessages.last?.text, "Stopped")

        hooks.emit(kind: "stop", conversation: "composer-release", status: "error")
        _ = try await snapshots.wait(timeout: 5) { $0.status == .error && $0.statusDetail == CursorAdapter.failedDetail }

        hooks.emit(kind: "stop", conversation: "composer-unknown", status: "completed")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(adapter.currentStatusForTesting(), .error, "an unknown chat never moves the card")
    }

    func testInterruptPressesStopAndWaitsForTheApp() async throws {
        try await adapter.start()
        _ = try await snapshots.wait(timeout: 5) { $0.status == .done }
        hooks.emit(kind: "beforeSubmitPrompt", conversation: "composer-release")
        _ = try await snapshots.wait(timeout: 5) { $0.status == .working }

        try await adapter.interrupt()
        XCTAssertEqual(driver.interrupts, 1)
        _ = try await snapshots.wait(timeout: 5) { $0.status == .working && $0.statusDetail == "Stopping" }
        hooks.emit(kind: "stop", conversation: "composer-release", status: "aborted")
        _ = try await snapshots.wait(timeout: 5) { $0.status == .idle && $0.statusDetail == CursorAdapter.stoppedDetail }
    }

    func testStoreChangesReplaceTheLiveRows() async throws {
        try await adapter.start()
        _ = try await snapshots.wait(timeout: 5) { $0.status == .done }
        try await adapter.sendInput("Add a line", submit: true)
        hooks.emit(kind: "preToolUse", conversation: "composer-release", tool: "Write", title: "notes.md", callId: "w1")
        _ = try await snapshots.wait(timeout: 5) { $0.recentMessages.contains { $0.toolCallId == "w1" } }

        // The app writes the turn into its store: the echo and hook rows give
        // way to the store's own rows.
        try CursorTestFixtures.writeDesktopStore(
            at: root,
            composers: [
                CursorTestFixtures.Composer(
                    composerId: "composer-release",
                    name: "Release chat",
                    workspaceId: "ws-1",
                    createdAt: 1_782_385_000_000,
                    lastUpdatedAt: 1_782_388_000_000,
                    messages: [
                        ["role": "user", "content": [["type": "text", "text": "Check the repo"]]],
                        ["role": "assistant", "content": [["type": "text", "text": "All clean."]]],
                        ["role": "user", "content": [["type": "text", "text": "Add a line"]]],
                        ["role": "assistant", "content": [
                            ["type": "tool-call", "toolCallId": "w1", "toolName": "Write", "args": ["path": "/Users/dev/App/notes.md"]],
                        ]],
                        ["role": "tool", "content": [["type": "tool-result", "toolCallId": "w1", "toolName": "Write", "result": "ok"]]],
                        ["role": "assistant", "content": [["type": "text", "text": "Added."]]],
                    ]
                ),
            ],
            workspaces: ["ws-1": "/Users/dev/App"]
        )
        hooks.emit(kind: "stop", conversation: "composer-release", status: "completed")
        let settled = try await snapshots.wait(timeout: 8) { $0.recentMessages.last?.text == "Added." }
        XCTAssertEqual(settled.recentMessages.map(\.kind), [.text, .text, .text, .toolCall, .toolResult, .text])
        XCTAssertEqual(settled.recentMessages.filter { $0.toolCallId == "w1" }.count, 2, "the hook row was replaced by the store's pair")
        XCTAssertEqual(settled.recentMessages[4].text, "ok")
        XCTAssertEqual(settled.status, .done)
    }
}

// MARK: - Fakes

private final class FakeCursorDriver: CursorDesktopUIDriving, @unchecked Sendable {
    struct Delivery: Equatable {
        let text: String
        let submit: Bool
    }

    private let lock = NSLock()
    private var _frontTitle: String?
    private(set) var delivered: [Delivery] = []
    private(set) var shown: [String] = []
    private(set) var newChats = 0
    private(set) var interrupts = 0
    private(set) var pressed: [String] = []
    /// When true, `showChat` makes the requested title the front title.
    var followsSwitch = true

    var frontTitle: String? {
        get { lock.lock(); defer { lock.unlock() }; return _frontTitle }
        set { lock.lock(); _frontTitle = newValue; lock.unlock() }
    }

    func deliver(text: String, submit: Bool) throws {
        lock.lock(); delivered.append(Delivery(text: text, submit: submit)); lock.unlock()
    }

    func frontChatTitle(candidates: [String]) -> String? {
        frontTitle
    }

    func showChat(titled title: String) throws {
        lock.lock()
        shown.append(title)
        if followsSwitch { _frontTitle = title }
        lock.unlock()
    }

    func newChat() throws {
        lock.lock(); newChats += 1; _frontTitle = nil; lock.unlock()
    }

    func interrupt() throws {
        lock.lock(); interrupts += 1; lock.unlock()
    }

    func press(label: String) throws {
        lock.lock(); pressed.append(label); lock.unlock()
    }
}

private final class FakeCursorHookSource: HookLineSource, @unchecked Sendable {
    var onLine: (@Sendable (String) -> Void)?
    func start() throws {}
    func stop() {}

    func emit(kind: String, conversation: String, status: String = "", tool: String = "", title: String = "", callId: String = "") {
        let object: [String: Any] = [
            "kind": kind, "conversation": conversation, "status": status, "tool": tool, "title": title, "callId": callId,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        onLine?(String(decoding: data, as: UTF8.self))
    }
}

private final class CursorSnapshotCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [AgentStateSnapshot] = []
    /// Snapshots before this index were consumed by earlier waits.
    private var cursor = 0
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<AgentStateSnapshot>) {
        task = Task { [weak self] in
            for await snapshot in stream {
                guard let self else { return }
                self.lock.withLock { self.snapshots.append(snapshot) }
            }
        }
    }

    deinit { task?.cancel() }

    func wait(timeout: TimeInterval, where predicate: @escaping (AgentStateSnapshot) -> Bool) async throws -> AgentStateSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let match: AgentStateSnapshot? = lock.withLock {
                let start = cursor
                let pending = Array(snapshots[start...])
                if let index = pending.firstIndex(where: predicate) {
                    cursor = start + index + 1
                    return pending[index]
                }
                cursor = snapshots.count
                return nil
            }
            if let match { return match }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        let summary = lock.withLock { snapshots.suffix(6).map { "\($0.status)/\($0.statusDetail)" }.joined(separator: " → ") }
        throw NSError(domain: "CursorSnapshotCollector", code: 1, userInfo: [NSLocalizedDescriptionKey: "timed out; last snapshots: \(summary)"])
    }
}
#endif
