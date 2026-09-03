#if os(macOS)
import Foundation
import SQLite3
@testable import GTAdapters

/// Builds Cursor-shaped stores in temp directories for the adapter tests.
enum CursorTestFixtures {
    static func temporaryDirectory(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func protobufBytes(field: Int, _ value: Data) -> Data {
        var data = Data()
        data.append(UInt8(field << 3 | 2))
        data.append(UInt8(value.count))
        data.append(value)
        return data
    }

    struct Composer {
        var composerId: String
        var name: String?
        var workspaceId: String
        var createdAt: Int64
        var lastUpdatedAt: Int64
        var mode: String = "agent"
        var isDraft = false
        var isArchived = false
        var isSubagent = false
        var hasBlockingPendingActions = false
        var model: String? = "composer-2.5"
        /// Cursor's record of the last generation: completed, aborted, none.
        var status: String? = nil
        /// Bubble ids Cursor is still generating; non-empty while a turn runs.
        var generatingBubbleIds: [String] = []
        /// AI-SDK messages stored as agentKv blobs.
        var messages: [[String: Any]] = []
    }

    /// Writes a Cursor state directory holding `state.vscdb` with the given
    /// chats, and `workspaceStorage/<id>/workspace.json` for `workspaces`.
    @discardableResult
    static func writeDesktopStore(at root: URL, composers: [Composer], workspaces: [String: String] = [:]) throws -> String {
        for (id, folder) in workspaces {
            let dir = root.appendingPathComponent("User/workspaceStorage/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "{\"folder\":\"file://\(folder)\"}".write(to: dir.appendingPathComponent("workspace.json"), atomically: true, encoding: .utf8)
        }
        let dbPath = root.appendingPathComponent("User/globalStorage/state.vscdb").path
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: dbPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        // Build the database beside the live one and swap it in atomically, so
        // a watcher reading mid-write never sees a half-written file.
        let stagingPath = dbPath + ".staging-\(UUID().uuidString)"

        var kvRows: [(String, Data)] = []
        var headers: [(String, String, Int64, Int64, Int, Int, String)] = []
        for composer in composers {
            var state = Data()
            for message in composer.messages {
                let data = try JSONSerialization.data(withJSONObject: message)
                let id = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
                kvRows.append(("agentKv:blob:\(CursorProtobuf.hexString(id))", data))
                state.append(protobufBytes(field: 1, id))
            }
            var composerData: [String: Any] = [
                "composerId": composer.composerId,
                "createdAt": composer.createdAt,
                "lastUpdatedAt": composer.lastUpdatedAt,
                "fullConversationHeadersOnly": [],
                "isDraft": composer.isDraft,
                "unifiedMode": composer.mode,
            ]
            if let model = composer.model { composerData["modelConfig"] = ["modelName": model] }
            if let status = composer.status { composerData["status"] = status }
            composerData["generatingBubbleIds"] = composer.generatingBubbleIds
            if !state.isEmpty { composerData["conversationState"] = state.base64EncodedString() }
            if let name = composer.name { composerData["name"] = name }
            kvRows.append(("composerData:\(composer.composerId)", try JSONSerialization.data(withJSONObject: composerData)))
            var value: [String: Any] = [
                "unifiedMode": composer.mode,
                "isDraft": composer.isDraft,
                "hasBlockingPendingActions": composer.hasBlockingPendingActions,
            ]
            if let name = composer.name { value["name"] = name }
            headers.append((
                composer.composerId, composer.workspaceId, composer.createdAt, composer.lastUpdatedAt,
                composer.isArchived ? 1 : 0, composer.isSubagent ? 1 : 0,
                String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
            ))
        }

        try withDatabase(stagingPath) { db in
            try exec(db, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
            try exec(db, "CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
            try exec(db, "CREATE TABLE composerHeaders (composerId TEXT PRIMARY KEY, workspaceId TEXT, createdAt INTEGER, lastUpdatedAt INTEGER, isArchived INTEGER, isSubagent INTEGER, recency INTEGER, checkpointAt INTEGER, subagentTypeName TEXT, value TEXT)")
            for (key, value) in kvRows {
                try insert(db, "INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)", texts: [key], blob: value)
            }
            for header in headers {
                try insert(
                    db,
                    "INSERT INTO composerHeaders (composerId, workspaceId, createdAt, lastUpdatedAt, isArchived, isSubagent, recency, checkpointAt, subagentTypeName, value) VALUES (?, ?, \(header.2), \(header.3), \(header.4), \(header.5), 0, 0, '', ?)",
                    texts: [header.0, header.1, header.6]
                )
            }
        }
        guard rename(stagingPath, dbPath) == 0 else {
            throw NSError(domain: "CursorTestFixtures", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "rename failed"])
        }
        return dbPath
    }

    static func withDatabase(_ path: String, _ body: (OpaquePointer) throws -> Void) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "CursorTestFixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "open failed"])
        }
        defer { sqlite3_close(db) }
        try body(db)
    }

    static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "CursorTestFixtures", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    /// Binds `texts` to the leading placeholders and `blob` to the one after them.
    static func insert(_ db: OpaquePointer, _ sql: String, texts: [String], blob: Data? = nil) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NSError(domain: "CursorTestFixtures", code: 3, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        for (index, text) in texts.enumerated() {
            _ = text.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, transient) }
        }
        if let blob {
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(texts.count + 1), $0.baseAddress, Int32(blob.count), transient) }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "CursorTestFixtures", code: 4, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }
}
#endif
