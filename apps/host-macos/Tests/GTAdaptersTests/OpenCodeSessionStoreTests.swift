import SQLite3
import XCTest
@testable import GTAdapters
import GTProtocol

final class OpenCodeSessionStoreTests: XCTestCase {
    func testDefaultDatabaseLoadsRealSessionsWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["GT_OPENCODE_REAL_DB_AUDIT"] == "1" else {
            throw XCTSkip("Set GT_OPENCODE_REAL_DB_AUDIT=1 to audit the real local OpenCode database.")
        }

        let databaseURL = ProcessInfo.processInfo.environment["GT_OPENCODE_DB_PATH"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? OpenCodeSessionStore.defaultDatabaseURL()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: databaseURL.path),
            "Expected OpenCode database at the default local path."
        )

        let selected = try XCTUnwrap(
            OpenCodeSessionStore.loadMostRecentSummaryWithMessages(databaseURL: databaseURL),
            "Expected at least one real OpenCode session summary with messages."
        )
        let messages = OpenCodeSessionStore.loadMessages(
            sessionId: selected.sessionId,
            databaseURL: databaseURL,
            agentID: "opencode",
            maxMessages: 24
        )
        XCTAssertFalse(messages.isEmpty, "Expected the latest real OpenCode session to expose parsed messages.")
    }

    func testReadsRecentSessionsAndMessages() throws {
        let databaseURL = try makeDatabase()

        try insertSession(
            databaseURL,
            id: "ses_recent",
            title: "Fix mobile connection",
            directory: "/Users/developer/Documents/GitHub/glasstunnel",
            timeUpdated: 1_800
        )
        try insertSession(
            databaseURL,
            id: "ses_old",
            title: "Older task",
            directory: "/Users/developer/Documents/GitHub/old",
            timeUpdated: 900
        )
        try insertSession(
            databaseURL,
            id: "ses_archived",
            title: "Archived task",
            directory: "/Users/developer/Documents/GitHub/archive",
            timeUpdated: 2_000,
            archived: true
        )

        try insertMessage(
            databaseURL,
            id: "msg_user",
            sessionId: "ses_recent",
            role: "user",
            timeCreated: 1_000,
            parts: [
                (id: "part_user", data: #"{"type":"text","text":"Test OpenCode adapter."}"#)
            ]
        )
        try insertMessage(
            databaseURL,
            id: "msg_assistant",
            sessionId: "ses_recent",
            role: "assistant",
            timeCreated: 1_500,
            parts: [
                (id: "part_assistant_text", data: #"{"type":"text","text":"I will inspect the session database."}"#),
                (id: "part_assistant_tool", data: #"{"type":"tool","tool":"bash","callID":"call_1","state":{"status":"running","title":"Listing files"}}"#)
            ]
        )

        let summaries = OpenCodeSessionStore.loadSummaries(databaseURL: databaseURL)
        XCTAssertEqual(summaries.map(\.sessionId), ["ses_recent", "ses_old"])
        XCTAssertEqual(summaries.first?.title, "Fix mobile connection")
        XCTAssertEqual(summaries.first?.directory, "/Users/developer/Documents/GitHub/glasstunnel")

        let messages = OpenCodeSessionStore.loadMessages(
            sessionId: "ses_recent",
            databaseURL: databaseURL,
            agentID: "opencode",
            maxMessages: 24
        )

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].text, "Test OpenCode adapter.")
        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertEqual(messages[1].text, "I will inspect the session database.")
        XCTAssertEqual(messages[1].pendingToolCalls.first?.toolName, "bash")
        XCTAssertEqual(messages[1].pendingToolCalls.first?.toolCallId, "call_1")
    }

    func testMostRecentSummaryWithMessagesSkipsNewEmptySessions() throws {
        let databaseURL = try makeDatabase()

        try insertSession(
            databaseURL,
            id: "ses_empty_latest",
            title: "New empty session",
            directory: "/Users/developer/Documents/GitHub/empty",
            timeUpdated: 2_000
        )
        try insertSession(
            databaseURL,
            id: "ses_message_backed",
            title: "Useful session",
            directory: "/Users/developer/Documents/GitHub/glasstunnel",
            timeUpdated: 1_000
        )
        try insertMessage(
            databaseURL,
            id: "msg_user",
            sessionId: "ses_message_backed",
            role: "user",
            timeCreated: 1_000,
            parts: [
                (id: "part_user", data: #"{"type":"text","text":"Use this OpenCode context."}"#)
            ]
        )

        let summaries = OpenCodeSessionStore.loadSummaries(databaseURL: databaseURL)
        XCTAssertEqual(summaries.first?.sessionId, "ses_empty_latest")

        let messageBacked = try XCTUnwrap(
            OpenCodeSessionStore.loadMostRecentSummaryWithMessages(databaseURL: databaseURL)
        )
        XCTAssertEqual(messageBacked.sessionId, "ses_message_backed")
    }

    func testToolOnlyMessagesBecomeToolSummaries() throws {
        let databaseURL = try makeDatabase()
        try insertSession(
            databaseURL,
            id: "ses_tools",
            title: "Tool only",
            directory: "/tmp/project",
            timeUpdated: 1_000
        )
        try insertMessage(
            databaseURL,
            id: "msg_tool",
            sessionId: "ses_tools",
            role: "assistant",
            timeCreated: 1_000,
            parts: [
                (id: "part_tool", data: #"{"type":"tool","tool":"grep","callID":"call_2","state":{"status":"completed","title":"Searching code"}}"#)
            ]
        )

        let messages = OpenCodeSessionStore.loadMessages(
            sessionId: "ses_tools",
            databaseURL: databaseURL,
            agentID: "opencode",
            maxMessages: 24
        )

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .assistant)
        XCTAssertEqual(messages[0].text, "Searching code (completed)")
        XCTAssertTrue(messages[0].pendingToolCalls.isEmpty)
    }

    func testLatestMessageStateTracksCompletedAssistantRowsWithoutParts() throws {
        let databaseURL = try makeDatabase()
        try insertSession(
            databaseURL,
            id: "ses_blank_assistant",
            title: "Blank assistant",
            directory: "/tmp/project",
            timeUpdated: 2_000
        )
        try insertMessage(
            databaseURL,
            id: "msg_user",
            sessionId: "ses_blank_assistant",
            role: "user",
            timeCreated: 1_000,
            parts: [
                (id: "part_user", data: #"{"type":"text","text":"Reply with exactly OK."}"#)
            ]
        )
        try insertMessage(
            databaseURL,
            id: "msg_assistant_empty",
            sessionId: "ses_blank_assistant",
            role: "assistant",
            timeCreated: 1_500,
            completedAt: 1_600,
            parts: []
        )

        let messages = OpenCodeSessionStore.loadMessages(
            sessionId: "ses_blank_assistant",
            databaseURL: databaseURL,
            agentID: "opencode",
            maxMessages: 24
        )
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .user)

        let latest = try XCTUnwrap(
            OpenCodeSessionStore.loadLatestMessageState(
                sessionId: "ses_blank_assistant",
                databaseURL: databaseURL
            )
        )
        XCTAssertEqual(latest.messageId, "msg_assistant_empty")
        XCTAssertEqual(latest.role, .assistant)
        XCTAssertEqual(latest.completedAtUnixMs, 1_600)
        XCTAssertEqual(latest.partCount, 0)
    }

    func testAssistantErrorsWithoutPartsBecomeVisibleMessages() throws {
        let databaseURL = try makeDatabase()
        try insertSession(
            databaseURL,
            id: "ses_error",
            title: "Provider error",
            directory: "/tmp/project",
            timeUpdated: 2_000
        )
        try insertMessage(
            databaseURL,
            id: "msg_error",
            sessionId: "ses_error",
            role: "assistant",
            timeCreated: 1_500,
            completedAt: 1_600,
            errorMessage: "Model is disabled",
            parts: []
        )

        let messages = OpenCodeSessionStore.loadMessages(
            sessionId: "ses_error",
            databaseURL: databaseURL,
            agentID: "opencode",
            maxMessages: 24
        )
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.role, .assistant)
        XCTAssertEqual(messages.first?.text, "OpenCode error: APIError: Model is disabled")

        let latest = try XCTUnwrap(
            OpenCodeSessionStore.loadLatestMessageState(
                sessionId: "ses_error",
                databaseURL: databaseURL
            )
        )
        XCTAssertEqual(latest.errorSummary, "APIError: Model is disabled")
    }

    func testMessageAbortedErrorIsNotTreatedAsHardProviderFailure() throws {
        let databaseURL = try makeDatabase()
        try insertSession(
            databaseURL,
            id: "ses_abort",
            title: "Stopped response",
            directory: "/tmp/project",
            timeUpdated: 2_000
        )
        try insertMessage(
            databaseURL,
            id: "msg_abort",
            sessionId: "ses_abort",
            role: "assistant",
            timeCreated: 1_500,
            completedAt: 1_600,
            errorName: "MessageAbortedError",
            errorMessage: "Aborted",
            parts: [
                (id: "part_abort_text", data: #"{"type":"text","text":"Partial response before Stop."}"#)
            ]
        )

        let messages = OpenCodeSessionStore.loadMessages(
            sessionId: "ses_abort",
            databaseURL: databaseURL,
            agentID: "opencode",
            maxMessages: 24
        )
        XCTAssertEqual(messages.first?.text, "Partial response before Stop.")

        let latest = try XCTUnwrap(
            OpenCodeSessionStore.loadLatestMessageState(
                sessionId: "ses_abort",
                databaseURL: databaseURL
            )
        )
        XCTAssertNil(latest.errorSummary)
    }

    private func makeDatabase() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let url = directory.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }

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
                time_created integer,
                time_updated integer,
                data text NOT NULL
            );
            CREATE TABLE part (
                id text PRIMARY KEY,
                message_id text,
                session_id text,
                time_created integer,
                time_updated integer,
                data text NOT NULL
            );
            """
        )

        return url
    }

    private func insertSession(
        _ databaseURL: URL,
        id: String,
        title: String,
        directory: String,
        timeUpdated: Int64,
        archived: Bool = false
    ) throws {
        try withDatabase(databaseURL) { db in
            try prepareAndRun(
                db,
                """
                INSERT INTO session (id, directory, title, time_created, time_updated, time_archived, path)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    id,
                    directory,
                    title,
                    "\(timeUpdated - 100)",
                    "\(timeUpdated)",
                    archived ? "\(timeUpdated + 1)" : nil,
                    directory
                ]
            )
        }
    }

    private func insertMessage(
        _ databaseURL: URL,
        id: String,
        sessionId: String,
        role: String,
        timeCreated: Int64,
        completedAt: Int64? = nil,
        errorName: String = "APIError",
        errorMessage: String? = nil,
        parts: [(id: String, data: String)]
    ) throws {
        try withDatabase(databaseURL) { db in
            var time: [String: Any] = ["created": timeCreated]
            if let completedAt {
                time["completed"] = completedAt
            }
            var message: [String: Any] = ["role": role, "time": time]
            if let errorMessage {
                message["error"] = [
                    "name": errorName,
                    "data": ["message": errorMessage],
                ]
            }
            let messageData = try XCTUnwrap(
                String(data: JSONSerialization.data(withJSONObject: message), encoding: .utf8)
            )
            try prepareAndRun(
                db,
                """
                INSERT INTO message (id, session_id, time_created, time_updated, data)
                VALUES (?, ?, ?, ?, ?)
                """,
                [id, sessionId, "\(timeCreated)", "\(timeCreated)", messageData]
            )

            for (index, part) in parts.enumerated() {
                try prepareAndRun(
                    db,
                    """
                    INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    [
                        part.id,
                        id,
                        sessionId,
                        "\(timeCreated + Int64(index))",
                        "\(timeCreated + Int64(index))",
                        part.data
                    ]
                )
            }
        }
    }

    private func withDatabase(_ url: URL, _ body: (OpaquePointer) throws -> Void) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        try body(db!)
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(error)
            XCTFail(message)
        }
    }

    private func prepareAndRun(_ db: OpaquePointer, _ sql: String, _ values: [String?]) throws {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }

        for (index, value) in values.enumerated() {
            let sqliteIndex = Int32(index + 1)
            guard let value else {
                sqlite3_bind_null(statement, sqliteIndex)
                continue
            }
            _ = value.withCString { pointer in
                sqlite3_bind_text(
                    statement,
                    sqliteIndex,
                    pointer,
                    -1,
                    unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
                )
            }
        }

        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }
}
