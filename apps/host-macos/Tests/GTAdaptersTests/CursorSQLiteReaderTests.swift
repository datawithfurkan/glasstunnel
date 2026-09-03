#if os(macOS)
import XCTest
import SQLite3
@testable import GTAdapters
import GTProtocol

/// These tests build a fake Cursor-style `state.vscdb` in a temp directory,
/// insert a handful of representative JSON blobs (matching shapes we've
/// observed across Cursor releases), then verify the reader extracts them.
final class CursorSQLiteReaderTests: XCTestCase {
    func testReadsComposerDataShape() throws {
        let path = try createDatabaseWithFixtures([
            (
                "composerData:abc123",
                """
                {"tabs":[{"messages":[
                  {"role":"user","content":"write me a react button","createdAt":1730000000000},
                  {"role":"assistant","content":"here you go","createdAt":1730000001000}
                ]}]}
                """
            ),
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let reader = CursorSQLiteReader(path: path)
        let messages = try reader.readRecentMessages(limit: 10)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "assistant")
        XCTAssertEqual(messages[0].text, "here you go")
        XCTAssertEqual(messages[1].role, "user")
    }

    func testReadsWorkbenchAichatShape() throws {
        let path = try createDatabaseWithFixtures([
            (
                "workbench.panel.aichat.view.aichat.chatdata",
                """
                {"messages":[
                  {"role":"user","text":"why is my test failing"},
                  {"role":"assistant","text":"missing null check"}
                ]}
                """
            ),
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let reader = CursorSQLiteReader(path: path)
        let messages = try reader.readRecentMessages(limit: 10)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.map { $0.text }.sorted(), ["missing null check", "why is my test failing"])
    }

    func testReadsOpenAIStyleContentArray() throws {
        let path = try createDatabaseWithFixtures([
            (
                "composerData:xyz",
                """
                {"messages":[
                  {"role":"user","content":[{"type":"text","text":"hello there"}]}
                ]}
                """
            ),
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let reader = CursorSQLiteReader(path: path)
        let messages = try reader.readRecentMessages(limit: 10)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].text, "hello there")
    }

    func testBubbleFormatChatTakesStatusFromTheComposerGenerationRecord() throws {
        // An older chat that keeps growing in the bubble format: its last bubble
        // is the prompt of an interrupted turn, which alone would read as a
        // running turn; Cursor's own record on the composer says it was aborted.
        let path = try createCursorDiskKVDatabase(rows: [
            (
                "composerData:composer-aborted",
                """
                {
                  "composerId": "composer-aborted",
                  "name": "Interrupted chat",
                  "status": "aborted",
                  "generatingBubbleIds": [],
                  "createdAt": 1770000000000,
                  "lastUpdatedAt": 1770000009000,
                  "fullConversationHeadersOnly": [
                    {"bubbleId": "b-user-1", "type": 1},
                    {"bubbleId": "b-assistant-1", "type": 2},
                    {"bubbleId": "b-user-2", "type": 1}
                  ]
                }
                """
            ),
            ("bubbleId:composer-aborted:b-user-1", #"{"bubbleId": "b-user-1", "type": 1, "text": "Reply with OK", "createdAt": "2026-02-01T12:00:00.000Z"}"#),
            ("bubbleId:composer-aborted:b-assistant-1", #"{"bubbleId": "b-assistant-1", "type": 2, "text": "OK", "createdAt": "2026-02-01T12:00:01.000Z"}"#),
            ("bubbleId:composer-aborted:b-user-2", #"{"bubbleId": "b-user-2", "type": 1, "text": "Count to four hundred", "createdAt": "2026-02-01T12:00:02.000Z"}"#),
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let reader = CursorDesktopStoreReader(stateDBPath: path, stateRoot: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        let conversation = reader.conversation(composerId: "composer-aborted", agentID: "cursor", maxMessages: 20)
        XCTAssertEqual(conversation?.messages.count, 3)
        XCTAssertEqual(conversation?.messages.last?.text, "Count to four hundred")
        XCTAssertEqual(conversation?.status, .idle, "the aborted record outranks the trailing prompt")
        XCTAssertEqual(conversation?.statusDetail, CursorConversationBuilder.stoppedDetail)
    }

    func testReadsModernCursorDiskKVComposerAndBubbles() throws {
        let path = try createCursorDiskKVDatabase(rows: [
            (
                "composerData:composer-1",
                """
                {
                  "composerId": "composer-1",
                  "name": "Glasstunnel Cursor work",
                  "subtitle": "~/Documents/GitHub/glasstunnel",
                  "workspaceIdentifier": {"id": "workspace-hash"},
                  "status": "completed",
                  "createdAt": 1770000000000,
                  "lastUpdatedAt": 1770000003000,
                  "fullConversationHeadersOnly": [
                    {"bubbleId": "bubble-user", "type": 1},
                    {"bubbleId": "bubble-assistant", "type": 2},
                    {"bubbleId": "bubble-empty-tool", "type": 2}
                  ]
                }
                """
            ),
            (
                "bubbleId:composer-1:bubble-user",
                """
                {
                  "bubbleId": "bubble-user",
                  "type": 1,
                  "text": "wire Cursor context into Glasstunnel",
                  "createdAt": "2026-02-01T12:00:00.000Z"
                }
                """
            ),
            (
                "bubbleId:composer-1:bubble-assistant",
                """
                {
                  "bubbleId": "bubble-assistant",
                  "type": 2,
                  "text": "Cursor context is available now",
                  "createdAt": "2026-02-01T12:00:01.000Z"
                }
                """
            ),
            (
                "bubbleId:composer-1:bubble-empty-tool",
                """
                {
                  "bubbleId": "bubble-empty-tool",
                  "type": 2,
                  "text": "",
                  "toolFormerData": {"name": "read_file", "status": "completed"},
                  "createdAt": "2026-02-01T12:00:02.000Z"
                }
                """
            ),
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let reader = CursorSQLiteReader(path: path)
        let composers = try reader.readRecentComposers(limit: 10)
        XCTAssertEqual(composers.count, 1)
        XCTAssertEqual(composers[0].composerId, "composer-1")
        XCTAssertEqual(composers[0].name, "Glasstunnel Cursor work")
        XCTAssertEqual(composers[0].workspaceIdentifier, "workspace-hash")

        let messages = try reader.readMessages(forComposerID: "composer-1", limit: 10)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "assistant")
        XCTAssertEqual(messages[0].text, "Cursor context is available now")
        XCTAssertEqual(messages[1].role, "user")
        XCTAssertEqual(messages[1].text, "wire Cursor context into Glasstunnel")

        let defaultMessages = try reader.readRecentMessages(limit: 10)
        XCTAssertEqual(defaultMessages.map(\.text), messages.map(\.text))
    }

    func testModernCursorComposerFallsBackToEmbeddedMessagesWhenBubbleRowsAreMissing() throws {
        let path = try createCursorDiskKVDatabase(rows: [
            (
                "composerData:composer-without-bubbles",
                """
                {
                  "composerId": "composer-without-bubbles",
                  "name": "Cursor composer without bubble rows",
                  "subtitle": "~/Documents/GitHub/glasstunnel",
                  "lastUpdatedAt": 1770000003000,
                  "fullConversationHeadersOnly": [
                    {"bubbleId": "missing-user", "type": 1},
                    {"bubbleId": "missing-assistant", "type": 2}
                  ],
                  "tabs": [{
                    "messages": [
                      {"role": "user", "content": "read the Cursor workspace", "createdAt": 1770000001000},
                      {"role": "assistant", "content": "Cursor workspace is readable", "createdAt": 1770000002000}
                    ]
                  }]
                }
                """
            ),
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let reader = CursorSQLiteReader(path: path)
        let messages = try reader.readMessages(forComposerID: "composer-without-bubbles", limit: 10)
        XCTAssertEqual(messages.map(\.text), ["Cursor workspace is readable", "read the Cursor workspace"])

        let defaultMessages = try reader.readRecentMessages(limit: 10)
        XCTAssertEqual(defaultMessages.map(\.text), messages.map(\.text))
    }

    func testReadsComposerTitleAsNameWhenNameIsMissing() throws {
        let path = try createCursorDiskKVDatabase(rows: [
            (
                "composerData:title-only",
                """
                {
                  "composerId": "title-only",
                  "title": "Cursor title field",
                  "lastUpdatedAt": 1770000003000,
                  "fullConversationHeadersOnly": []
                }
                """
            ),
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let reader = CursorSQLiteReader(path: path)
        let composers = try reader.readRecentComposers(limit: 10)

        XCTAssertEqual(composers.count, 1)
        XCTAssertEqual(composers[0].composerId, "title-only")
        XCTAssertEqual(composers[0].name, "Cursor title field")
    }

    func testSkipsNonChatRows() throws {
        let path = try createDatabaseWithFixtures([
            ("recently.opened", #"{"paths":["/some/file"]}"#),
            ("workbench.activity.pinnedViewlets", "[1,2,3]"),
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let reader = CursorSQLiteReader(path: path)
        let messages = try reader.readRecentMessages(limit: 10)
        XCTAssertEqual(messages.count, 0)
    }

    func testLimitCap() throws {
        var entries: [String] = []
        for i in 0..<30 {
            entries.append(#"{"role":"user","content":"msg \#(i)","createdAt":\#(1_700_000_000_000 + i)}"#)
        }
        let inner = "{\"messages\":[" + entries.joined(separator: ",") + "]}"
        let path = try createDatabaseWithFixtures([("composerData:many", inner)])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let reader = CursorSQLiteReader(path: path)
        let messages = try reader.readRecentMessages(limit: 5)
        XCTAssertEqual(messages.count, 5)
        // Sorted newest-first.
        let timestamps = messages.compactMap { $0.atUnixMs }
        XCTAssertEqual(timestamps, timestamps.sorted(by: >))
    }

    func testMissingFileReturnsEmptyNoThrow() throws {
        let reader = CursorSQLiteReader(path: "/nonexistent/state.vscdb")
        let messages = try reader.readRecentMessages()
        XCTAssertEqual(messages.count, 0)
    }

    func testWatcherExposesModernCursorComposerTargets() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor-watcher-test-\(UUID().uuidString)", isDirectory: true)
        let dbURL = root
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)
            .appendingPathComponent("state.vscdb")
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createCursorDiskKVDatabase(path: dbURL.path, rows: [
            (
                "composerData:composer-1",
                """
                {
                  "composerId": "composer-1",
                  "name": "Cursor target",
                  "subtitle": "~/Documents/GitHub/glasstunnel",
                  "lastUpdatedAt": 1770000003000,
                  "fullConversationHeadersOnly": [
                    {"bubbleId": "bubble-user", "type": 1}
                  ]
                }
                """
            ),
            (
                "bubbleId:composer-1:bubble-user",
                """
                {
                  "bubbleId": "bubble-user",
                  "type": 1,
                  "text": "hello from Cursor",
                  "createdAt": "2026-02-01T12:00:00.000Z"
                }
                """
            ),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let expectation = expectation(description: "watcher snapshot")
        final class Box: @unchecked Sendable {
            var snapshot: CursorStateWatcher.Snapshot?
        }
        let box = Box()
        let watcher = CursorStateWatcher(stateDir: root)
        watcher.onChange = { snapshot in
            box.snapshot = snapshot
            expectation.fulfill()
        }
        try watcher.start()
        wait(for: [expectation], timeout: 1.0)
        watcher.stop()

        let snapshot = try XCTUnwrap(box.snapshot)
        XCTAssertEqual(snapshot.availableTargets.count, 1)
        XCTAssertEqual(snapshot.availableTargets[0].targetId, "composer-1")
        XCTAssertEqual(snapshot.availableTargets[0].label, "Cursor target")
        XCTAssertEqual(snapshot.availableTargets[0].labelSource, .cursorName)
        XCTAssertTrue(snapshot.availableTargets[0].selected)
        XCTAssertEqual(snapshot.recentMessages.first?.text, "hello from Cursor")
    }

    func testWatcherExposesHeaderOnlyCursorTargetWithoutClaimingMessageContent() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor-header-only-state-\(UUID().uuidString)", isDirectory: true)
        let dbURL = root
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)
            .appendingPathComponent("state.vscdb")
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createCursorDiskKVDatabase(path: dbURL.path, rows: [
            (
                "composerData:composer-header-only",
                """
                {
                  "composerId": "composer-header-only",
                  "name": "Header-only Cursor composer",
                  "subtitle": "~/Documents/GitHub/glasstunnel",
                  "lastUpdatedAt": 1770000003000,
                  "fullConversationHeadersOnly": [
                    {"bubbleId": "missing-user", "type": 1},
                    {"bubbleId": "missing-assistant", "type": 2}
                  ]
                }
                """
            ),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let expectation = expectation(description: "header-only watcher snapshot")
        final class Box: @unchecked Sendable {
            var snapshot: CursorStateWatcher.Snapshot?
        }
        let box = Box()
        let watcher = CursorStateWatcher(stateDir: root)
        watcher.onChange = { snapshot in
            box.snapshot = snapshot
            expectation.fulfill()
        }
        try watcher.start()
        wait(for: [expectation], timeout: 1.0)
        watcher.stop()

        let snapshot = try XCTUnwrap(box.snapshot)
        XCTAssertEqual(snapshot.availableTargets.count, 1)
        XCTAssertEqual(snapshot.availableTargets[0].targetId, "composer-header-only")
        XCTAssertEqual(snapshot.availableTargets[0].label, "Header-only Cursor composer")
        XCTAssertEqual(snapshot.availableTargets[0].labelSource, .cursorName)
        XCTAssertTrue(snapshot.availableTargets[0].selected)
        XCTAssertEqual(snapshot.recentMessages.count, 0)
        XCTAssertEqual(snapshot.schemaWarning, "Waiting for Cursor chat content.")
    }

    func testWatcherMarksSubtitleDerivedCursorTargetLabels() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor-subtitle-target-label-\(UUID().uuidString)", isDirectory: true)
        let dbURL = root
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)
            .appendingPathComponent("state.vscdb")
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createCursorDiskKVDatabase(path: dbURL.path, rows: [
            (
                "composerData:subtitle-derived",
                """
                {
                  "composerId": "subtitle-derived",
                  "subtitle": "~/Documents/GitHub2/glasstunnel",
                  "lastUpdatedAt": 1770000003000,
                  "fullConversationHeadersOnly": [
                    {"bubbleId": "missing-subtitle", "type": 1}
                  ]
                }
                """
            ),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let expectation = expectation(description: "subtitle-derived target label")
        final class Box: @unchecked Sendable {
            var snapshot: CursorStateWatcher.Snapshot?
        }
        let box = Box()
        let watcher = CursorStateWatcher(stateDir: root)
        watcher.onChange = { snapshot in
            box.snapshot = snapshot
            expectation.fulfill()
        }
        try watcher.start()
        wait(for: [expectation], timeout: 1.0)
        watcher.stop()

        let target = try XCTUnwrap(box.snapshot?.availableTargets.first)
        XCTAssertEqual(target.label, "glasstunnel")
        XCTAssertEqual(target.labelSource, .cursorSubtitle)
    }

    func testWatcherGivesUnnamedCursorTargetsDistinctFallbackLabels() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor-unnamed-targets-\(UUID().uuidString)", isDirectory: true)
        let dbURL = root
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)
            .appendingPathComponent("state.vscdb")
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createCursorDiskKVDatabase(path: dbURL.path, rows: [
            (
                "composerData:older-unnamed",
                """
                {
                  "composerId": "older-unnamed",
                  "lastUpdatedAt": 1770000001000,
                  "fullConversationHeadersOnly": [
                    {"bubbleId": "missing-older", "type": 1}
                  ]
                }
                """
            ),
            (
                "composerData:newer-unnamed",
                """
                {
                  "composerId": "newer-unnamed",
                  "lastUpdatedAt": 1770000003000,
                  "fullConversationHeadersOnly": [
                    {"bubbleId": "missing-newer", "type": 1}
                  ]
                }
                """
            ),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let expectation = expectation(description: "unnamed target labels")
        final class Box: @unchecked Sendable {
            var snapshot: CursorStateWatcher.Snapshot?
        }
        let box = Box()
        let watcher = CursorStateWatcher(stateDir: root)
        watcher.onChange = { snapshot in
            box.snapshot = snapshot
            expectation.fulfill()
        }
        try watcher.start()
        wait(for: [expectation], timeout: 1.0)
        watcher.stop()

        let snapshot = try XCTUnwrap(box.snapshot)
        XCTAssertEqual(snapshot.availableTargets.map(\.targetId), ["newer-unnamed", "older-unnamed"])
        XCTAssertEqual(snapshot.availableTargets.map(\.label), ["Cursor chat 1", "Cursor chat 2"])
        XCTAssertEqual(snapshot.availableTargets.map(\.labelSource), [.generatedFallback, .generatedFallback])
        XCTAssertEqual(snapshot.selectedTargetId, "newer-unnamed")
        XCTAssertEqual(snapshot.selectedTitle, "Cursor chat 1")
        XCTAssertTrue(snapshot.availableTargets[0].selected)
        XCTAssertFalse(snapshot.availableTargets[1].selected)
    }

    func testWatcherUsesWorkspaceStorageFolderAsProjectPathWithoutInventingChatLabel() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor-workspace-folder-\(UUID().uuidString)", isDirectory: true)
        let workspaceRoot = root
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("workspaceStorage", isDirectory: true)
            .appendingPathComponent("workspace-hash", isDirectory: true)
        let dbURL = workspaceRoot.appendingPathComponent("state.vscdb")
        let projectURL = URL(fileURLWithPath: "/Users/tester/Documents/GitHub2/glasstunnel", isDirectory: true)
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"folder":"\#(projectURL.absoluteString)"}"#.utf8).write(to: workspaceRoot.appendingPathComponent("workspace.json"))
        try createCursorDiskKVDatabase(path: dbURL.path, rows: [
            (
                "composerData:workspace-derived",
                """
                {
                  "composerId": "workspace-derived",
                  "lastUpdatedAt": 1770000003000,
                  "fullConversationHeadersOnly": [
                    {"bubbleId": "missing-workspace", "type": 1}
                  ]
                }
                """
            ),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let expectation = expectation(description: "workspace-folder target")
        final class Box: @unchecked Sendable {
            var snapshot: CursorStateWatcher.Snapshot?
        }
        let box = Box()
        let watcher = CursorStateWatcher(stateDir: root)
        watcher.onChange = { snapshot in
            box.snapshot = snapshot
            expectation.fulfill()
        }
        try watcher.start()
        wait(for: [expectation], timeout: 1.0)
        watcher.stop()

        let target = try XCTUnwrap(box.snapshot?.availableTargets.first)
        XCTAssertEqual(target.label, "Cursor chat 1")
        XCTAssertEqual(target.labelSource, .generatedFallback)
        XCTAssertEqual(target.subtitle, "Workspace composer")
        XCTAssertEqual(target.projectPath, "/Users/tester/Documents/GitHub2/glasstunnel")

        let option = CursorAdapter.protocolTarget(from: target)
        XCTAssertEqual(option.label, "glasstunnel")
        XCTAssertEqual(option.projectLabel, "glasstunnel")
        XCTAssertEqual(option.projectPath, "/Users/tester/Documents/GitHub2/glasstunnel")
        XCTAssertEqual(option.threadLabel, "Cursor chat 1")
    }

    func testWatcherUsesWorkspaceIdentifierFolderForGlobalComposerProjectPath() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor-global-workspace-id-\(UUID().uuidString)", isDirectory: true)
        let globalDB = root
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)
            .appendingPathComponent("state.vscdb")
        let workspaceRoot = root
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("workspaceStorage", isDirectory: true)
            .appendingPathComponent("workspace-hash", isDirectory: true)
        let projectURL = URL(fileURLWithPath: "/Users/tester/Documents/GitHub2/glasstunnel", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try Data(#"{"folder":"\#(projectURL.absoluteString)"}"#.utf8).write(to: workspaceRoot.appendingPathComponent("workspace.json"))
        try createCursorDiskKVDatabase(path: globalDB.path, rows: [
            (
                "composerData:global-workspace-derived",
                """
                {
                  "composerId": "global-workspace-derived",
                  "workspaceIdentifier": {"id": "workspace-hash"},
                  "lastUpdatedAt": 1770000003000,
                  "fullConversationHeadersOnly": [
                    {"bubbleId": "missing-global-workspace", "type": 1}
                  ]
                }
                """
            ),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let expectation = expectation(description: "global workspace-id target")
        final class Box: @unchecked Sendable {
            var snapshot: CursorStateWatcher.Snapshot?
        }
        let box = Box()
        let watcher = CursorStateWatcher(stateDir: root)
        watcher.onChange = { snapshot in
            box.snapshot = snapshot
            expectation.fulfill()
        }
        try watcher.start()
        wait(for: [expectation], timeout: 1.0)
        watcher.stop()

        let target = try XCTUnwrap(box.snapshot?.availableTargets.first)
        XCTAssertEqual(target.label, "Cursor chat 1")
        XCTAssertEqual(target.labelSource, .generatedFallback)
        XCTAssertEqual(target.projectPath, "/Users/tester/Documents/GitHub2/glasstunnel")

        let option = CursorAdapter.protocolTarget(from: target)
        XCTAssertEqual(option.label, "glasstunnel")
        XCTAssertEqual(option.projectPath, "/Users/tester/Documents/GitHub2/glasstunnel")
        XCTAssertEqual(option.threadLabel, "Cursor chat 1")
    }

    func testWatcherMissingStateWarningIsUserSafe() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor-missing-state-\(UUID().uuidString)", isDirectory: true)

        let expectation = expectation(description: "missing state snapshot")
        final class Box: @unchecked Sendable {
            var snapshot: CursorStateWatcher.Snapshot?
        }
        let box = Box()
        let watcher = CursorStateWatcher(stateDir: root)
        watcher.onChange = { snapshot in
            box.snapshot = snapshot
            expectation.fulfill()
        }
        try watcher.start()
        wait(for: [expectation], timeout: 1.0)
        watcher.stop()

        let warning = try XCTUnwrap(box.snapshot?.schemaWarning)
        XCTAssertEqual(warning, "Open Cursor once to sync chats.")
        XCTAssertFalse(warning.contains(root.path))
        XCTAssertFalse(warning.contains("state.vscdb"))
    }

    func testWatcherNoDatabaseWarningIsUserSafe() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor-empty-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let expectation = expectation(description: "empty state snapshot")
        final class Box: @unchecked Sendable {
            var snapshot: CursorStateWatcher.Snapshot?
        }
        let box = Box()
        let watcher = CursorStateWatcher(stateDir: root)
        watcher.onChange = { snapshot in
            box.snapshot = snapshot
            expectation.fulfill()
        }
        try watcher.start()
        wait(for: [expectation], timeout: 1.0)
        watcher.stop()

        let warning = try XCTUnwrap(box.snapshot?.schemaWarning)
        XCTAssertEqual(warning, "Open a Cursor chat to sync context.")
        XCTAssertFalse(warning.contains(root.path))
        XCTAssertFalse(warning.contains("state.vscdb"))
    }

    func testWatcherUnsupportedDatabaseSchemaWarningIsUserSafe() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor-unsupported-schema-\(UUID().uuidString)", isDirectory: true)
        let dbURL = root
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)
            .appendingPathComponent("state.vscdb")
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try createUnsupportedCursorDatabase(path: dbURL.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let expectation = expectation(description: "unsupported schema snapshot")
        final class Box: @unchecked Sendable {
            var snapshot: CursorStateWatcher.Snapshot?
        }
        let box = Box()
        let watcher = CursorStateWatcher(stateDir: root)
        watcher.onChange = { snapshot in
            box.snapshot = snapshot
            expectation.fulfill()
        }
        try watcher.start()
        wait(for: [expectation], timeout: 1.0)
        watcher.stop()

        let warning = try XCTUnwrap(box.snapshot?.schemaWarning)
        XCTAssertEqual(warning, "Cursor chat format changed. Update Glasstunnel.")
        XCTAssertFalse(warning.contains(root.path))
        XCTAssertFalse(warning.contains("state.vscdb"))
        XCTAssertEqual(box.snapshot?.availableTargets.count, 0)
        XCTAssertEqual(box.snapshot?.recentMessages.count, 0)
    }

    // MARK: - helpers

    private func createDatabaseWithFixtures(_ rows: [(String, String)]) throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor-test-\(UUID().uuidString).vscdb")
        let path = url.path

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            throw NSError(domain: "CursorSQLiteReaderTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "sqlite open"])
        }
        defer { sqlite3_close_v2(db) }

        sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB NOT NULL)", nil, nil, nil)

        for (key, json) in rows {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO ItemTable (key, value) VALUES (?, ?)", -1, &stmt, nil)
            _ = key.withCString { ptr in
                sqlite3_bind_text(stmt, 1, ptr, -1, unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self))
            }
            let data = Data(json.utf8)
            _ = data.withUnsafeBytes { buf in
                sqlite3_bind_blob(stmt, 2, buf.baseAddress, Int32(data.count), unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self))
            }
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }

        return path
    }

    @discardableResult
    private func createCursorDiskKVDatabase(path explicitPath: String? = nil, rows: [(String, String)]) throws -> String {
        let path = explicitPath ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor-diskkv-test-\(UUID().uuidString).vscdb")
            .path

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            throw NSError(domain: "CursorSQLiteReaderTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "sqlite open"])
        }
        defer { sqlite3_close_v2(db) }

        sqlite3_exec(db, "CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value BLOB NOT NULL)", nil, nil, nil)

        for (key, json) in rows {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)", -1, &stmt, nil)
            _ = key.withCString { ptr in
                sqlite3_bind_text(stmt, 1, ptr, -1, unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self))
            }
            let data = Data(json.utf8)
            _ = data.withUnsafeBytes { buf in
                sqlite3_bind_blob(stmt, 2, buf.baseAddress, Int32(data.count), unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self))
            }
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }

        return path
    }

    private func createUnsupportedCursorDatabase(path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            throw NSError(domain: "CursorSQLiteReaderTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "sqlite open"])
        }
        defer { sqlite3_close_v2(db) }

        sqlite3_exec(db, "CREATE TABLE unrelated_state (key TEXT PRIMARY KEY, value BLOB NOT NULL)", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO unrelated_state (key, value) VALUES ('layout', '{}')", nil, nil, nil)
    }
}

/// Roundtrip check for the role normalizer.
final class CursorRoleNormalizerTests: XCTestCase {
    func testMapsCommonRoles() {
        XCTAssertEqual(CursorStateWatcher.role(fromCursorRole: "user"), .user)
        XCTAssertEqual(CursorStateWatcher.role(fromCursorRole: "Human"), .user)
        XCTAssertEqual(CursorStateWatcher.role(fromCursorRole: "assistant"), .assistant)
        XCTAssertEqual(CursorStateWatcher.role(fromCursorRole: "AI"), .assistant)
        XCTAssertEqual(CursorStateWatcher.role(fromCursorRole: "model"), .assistant)
        XCTAssertEqual(CursorStateWatcher.role(fromCursorRole: "tool"), .tool)
        XCTAssertEqual(CursorStateWatcher.role(fromCursorRole: "system"), .system)
        XCTAssertEqual(CursorStateWatcher.role(fromCursorRole: "unknown-thing"), .assistant)
    }
}
#endif
