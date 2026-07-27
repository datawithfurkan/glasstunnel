import Foundation
import GTProtocol
import SQLite3

struct OpenCodeSessionSummary: Equatable {
    let sessionId: String
    let title: String
    let directory: String
    let path: String?
    let modifiedAtUnixMs: Int64
}

struct OpenCodeMessageState: Equatable {
    let messageId: String
    let role: ChatRole
    let createdAtUnixMs: Int64
    let updatedAtUnixMs: Int64
    let completedAtUnixMs: Int64?
    let partCount: Int
    let errorSummary: String?
}

enum OpenCodeSessionStore {
    enum ReadError: Error, CustomStringConvertible {
        case open(Int32, String)
        case prepare(Int32, String)
        case step(Int32, String)

        var description: String {
            switch self {
            case .open(let code, let message):
                return "sqlite open failed code=\(code): \(message)"
            case .prepare(let code, let message):
                return "sqlite prepare failed code=\(code): \(message)"
            case .step(let code, let message):
                return "sqlite step failed code=\(code): \(message)"
            }
        }
    }

    static func defaultDatabaseURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = nonEmptyString(environment["GT_OPENCODE_DB_PATH"]) {
            return URL(fileURLWithPath: override)
        }
        if let xdgDataHome = nonEmptyString(environment["XDG_DATA_HOME"]) {
            return URL(fileURLWithPath: xdgDataHome, isDirectory: true)
                .appendingPathComponent("opencode", isDirectory: true)
                .appendingPathComponent("opencode.db")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("opencode.db")
    }

    static func loadSummaries(
        databaseURL: URL = defaultDatabaseURL(),
        limit: Int = AgentHistoryLimits.sessionSummaryCount
    ) -> [OpenCodeSessionSummary] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return []
        }

        return (try? withDatabase(databaseURL: databaseURL) { db in
            try readSummaries(in: db, limit: limit)
        }) ?? []
    }

    static func loadMostRecentSummaryWithMessages(
        databaseURL: URL = defaultDatabaseURL()
    ) -> OpenCodeSessionSummary? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return nil
        }

        return (try? withDatabase(databaseURL: databaseURL) { db in
            try readSummaries(in: db, limit: 1, requireMessages: true).first
        }) ?? nil
    }

    static func loadMessages(
        sessionId: String,
        databaseURL: URL = defaultDatabaseURL(),
        agentID: AgentID,
        maxMessages: Int = AgentHistoryLimits.snapshotMessageCount
    ) -> [AgentChatMessage] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return []
        }

        return (try? withDatabase(databaseURL: databaseURL) { db in
            try readMessages(in: db, sessionId: sessionId, agentID: agentID, maxMessages: maxMessages)
        }) ?? []
    }

    static func loadLatestMessageState(
        sessionId: String,
        databaseURL: URL = defaultDatabaseURL()
    ) -> OpenCodeMessageState? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return nil
        }

        return try? withDatabase(databaseURL: databaseURL) { db in
            try readLatestMessageState(in: db, sessionId: sessionId)
        }
    }

    private static func withDatabase<T>(databaseURL: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil)
        defer {
            if db != nil { sqlite3_close_v2(db) }
        }
        if openResult != SQLITE_OK {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? ""
            throw ReadError.open(openResult, message)
        }
        return try body(db!)
    }

    private static func readSummaries(
        in db: OpaquePointer,
        limit: Int,
        requireMessages: Bool = false
    ) throws -> [OpenCodeSessionSummary] {
        guard tableExists("session", in: db) else { return [] }
        if requireMessages, !tableExists("message", in: db) {
            return []
        }

        let messageFilter = requireMessages
            ? "AND EXISTS (SELECT 1 FROM message WHERE message.session_id = session.id)"
            : ""
        let sql = """
        SELECT id, title, directory, path, time_updated, time_created
        FROM session
        WHERE time_archived IS NULL
        \(messageFilter)
        ORDER BY time_updated DESC, time_created DESC, id DESC
        LIMIT ?
        """
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        defer { if statement != nil { sqlite3_finalize(statement) } }
        if prepareResult != SQLITE_OK {
            throw ReadError.prepare(prepareResult, String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int(statement, 1, Int32(max(0, limit)))

        var summaries: [OpenCodeSessionSummary] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            if step != SQLITE_ROW {
                throw ReadError.step(step, String(cString: sqlite3_errmsg(db)))
            }

            guard let id = columnString(statement, 0), !id.isEmpty else { continue }
            let directory = nonEmptyString(columnString(statement, 2)) ?? ""
            let title = nonEmptyString(columnString(statement, 1))
                ?? displayName(directory: directory, fallback: id)
            let modifiedAt = columnInt64(statement, 4) ?? columnInt64(statement, 5) ?? 0
            summaries.append(
                OpenCodeSessionSummary(
                    sessionId: id,
                    title: title,
                    directory: directory,
                    path: nonEmptyString(columnString(statement, 3)),
                    modifiedAtUnixMs: modifiedAt
                )
            )
        }

        return summaries
    }

    private static func readMessages(
        in db: OpaquePointer,
        sessionId: String,
        agentID: AgentID,
        maxMessages: Int
    ) throws -> [AgentChatMessage] {
        guard tableExists("message", in: db), tableExists("part", in: db) else { return [] }

        let sql = """
        SELECT id, data, time_created, time_updated
        FROM message
        WHERE session_id = ?
        ORDER BY time_created ASC, id ASC
        """
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        defer { if statement != nil { sqlite3_finalize(statement) } }
        if prepareResult != SQLITE_OK {
            throw ReadError.prepare(prepareResult, String(cString: sqlite3_errmsg(db)))
        }
        bindText(statement, 1, sessionId)

        var messages: [AgentChatMessage] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            if step != SQLITE_ROW {
                throw ReadError.step(step, String(cString: sqlite3_errmsg(db)))
            }

            guard let messageId = columnString(statement, 0) else { continue }
            let messageJSON = columnData(statement, 1)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let role = chatRole(from: nonEmptyString(messageJSON?["role"]))
            let timestamp = columnInt64(statement, 2)
                ?? columnInt64(statement, 3)
                ?? unixMsValue((messageJSON?["time"] as? [String: Any])?["created"])
                ?? Int64(Date().timeIntervalSince1970 * 1000)
            let parts = try readParts(in: db, messageId: messageId)
            guard let message = buildMessage(
                messageId: "\(agentID)-opencode-\(messageId)",
                role: role,
                atUnixMs: timestamp,
                parts: parts,
                errorSummary: errorSummary(from: messageJSON)
            ) else {
                continue
            }
            messages.append(message)
        }

        if messages.count > maxMessages {
            messages = Array(messages.suffix(maxMessages))
        }
        return messages
    }

    private struct ParsedPart {
        let type: String
        let text: String?
        let toolName: String?
        let toolCallId: String?
        let toolSummary: String?
        let toolStatus: String?
    }

    private static func readLatestMessageState(
        in db: OpaquePointer,
        sessionId: String
    ) throws -> OpenCodeMessageState? {
        guard tableExists("message", in: db) else { return nil }

        let partCountExpression = tableExists("part", in: db)
            ? "(SELECT COUNT(1) FROM part WHERE part.message_id = message.id)"
            : "0"
        let sql = """
        SELECT id, data, time_created, time_updated, \(partCountExpression)
        FROM message
        WHERE session_id = ?
        ORDER BY time_created DESC, id DESC
        LIMIT 1
        """
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        defer { if statement != nil { sqlite3_finalize(statement) } }
        if prepareResult != SQLITE_OK {
            throw ReadError.prepare(prepareResult, String(cString: sqlite3_errmsg(db)))
        }
        bindText(statement, 1, sessionId)

        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        if step != SQLITE_ROW {
            throw ReadError.step(step, String(cString: sqlite3_errmsg(db)))
        }

        guard let messageId = columnString(statement, 0) else { return nil }
        let messageJSON = columnData(statement, 1)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let time = messageJSON?["time"] as? [String: Any]
        let createdAt = columnInt64(statement, 2)
            ?? unixMsValue(time?["created"])
            ?? 0
        let updatedAt = columnInt64(statement, 3) ?? createdAt
        let role = chatRole(from: nonEmptyString(messageJSON?["role"]))
        return OpenCodeMessageState(
            messageId: messageId,
            role: role,
            createdAtUnixMs: createdAt,
            updatedAtUnixMs: updatedAt,
            completedAtUnixMs: unixMsValue(time?["completed"]),
            partCount: Int(sqlite3_column_int(statement, 4)),
            errorSummary: errorSummary(from: messageJSON)
        )
    }

    private static func readParts(in db: OpaquePointer, messageId: String) throws -> [ParsedPart] {
        let sql = """
        SELECT id, data, time_created
        FROM part
        WHERE message_id = ?
        ORDER BY time_created ASC, id ASC
        """
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        defer { if statement != nil { sqlite3_finalize(statement) } }
        if prepareResult != SQLITE_OK {
            throw ReadError.prepare(prepareResult, String(cString: sqlite3_errmsg(db)))
        }
        bindText(statement, 1, messageId)

        var parts: [ParsedPart] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            if step != SQLITE_ROW {
                throw ReadError.step(step, String(cString: sqlite3_errmsg(db)))
            }

            guard
                let partId = columnString(statement, 0),
                let data = columnData(statement, 1),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = nonEmptyString(json["type"])
            else {
                continue
            }

            switch type {
            case "text":
                parts.append(ParsedPart(type: type, text: nonEmptyString(json["text"]), toolName: nil, toolCallId: nil, toolSummary: nil, toolStatus: nil))
            case "reasoning":
                parts.append(ParsedPart(type: type, text: nonEmptyString(json["text"]), toolName: nil, toolCallId: nil, toolSummary: nil, toolStatus: nil))
            case "tool":
                let state = json["state"] as? [String: Any]
                let toolName = nonEmptyString(json["tool"]) ?? "tool"
                let status = nonEmptyString(state?["status"])
                let title = nonEmptyString(state?["title"]) ?? "Using \(toolName)"
                let summary = status.map { "\(title) (\($0))" } ?? title
                let callId = nonEmptyString(json["callID"]) ?? partId
                parts.append(ParsedPart(type: type, text: nil, toolName: toolName, toolCallId: callId, toolSummary: summary, toolStatus: status))
            default:
                continue
            }
        }
        return parts
    }

    private static func buildMessage(
        messageId: MessageID,
        role: ChatRole,
        atUnixMs: Int64,
        parts: [ParsedPart],
        errorSummary: String?
    ) -> AgentChatMessage? {
        let texts = parts
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .filter { !$0.isEmpty }
        let reasoning = parts
            .filter { $0.type == "reasoning" }
            .compactMap(\.text)
            .filter { !$0.isEmpty }
        let toolSummaries = parts
            .filter { $0.type == "tool" }
            .compactMap(\.toolSummary)
        let pendingTools = parts
            .filter { $0.type == "tool" && !isCompletedToolStatus($0.toolStatus) }
            .compactMap { part -> PendingToolCall? in
                guard let toolName = part.toolName, let toolCallId = part.toolCallId else { return nil }
                return PendingToolCall(
                    toolName: toolName,
                    toolCallId: toolCallId,
                    summary: part.toolSummary ?? "Using \(toolName)"
                )
            }

        var text = texts.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, !reasoning.isEmpty {
            text = reasoning.joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.isEmpty, !toolSummaries.isEmpty {
            text = toolSummaries.joined(separator: "\n")
        }
        if text.isEmpty, let errorSummary {
            text = "OpenCode error: \(errorSummary)"
        }
        if text.isEmpty, pendingTools.isEmpty {
            return nil
        }

        return AgentChatMessage(
            messageId: messageId,
            role: text.isEmpty ? .tool : role,
            text: text,
            atUnixMs: atUnixMs,
            pendingToolCalls: pendingTools
        )
    }

    private static func errorSummary(from messageJSON: [String: Any]?) -> String? {
        guard let error = messageJSON?["error"] as? [String: Any] else { return nil }
        let data = error["data"] as? [String: Any]
        let name = nonEmptyString(error["name"])
        if name == "MessageAbortedError" {
            return nil
        }
        let message = nonEmptyString(error["message"])
            ?? nonEmptyString(data?["message"])
            ?? nonEmptyString(error["code"])
            ?? name

        guard let message else { return nil }
        if let name, !message.localizedCaseInsensitiveContains(name) {
            return "\(name): \(message)"
        }
        return message
    }

    private static func tableExists(_ table: String, in db: OpaquePointer) -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, table)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        _ = value.withCString { pointer in
            sqlite3_bind_text(
                statement,
                index,
                pointer,
                -1,
                unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
            )
        }
    }

    private static func columnString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private static func columnInt64(_ statement: OpaquePointer?, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    private static func columnData(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        let length = sqlite3_column_bytes(statement, index)
        guard length > 0 else { return nil }
        if sqlite3_column_type(statement, index) == SQLITE_TEXT,
           let pointer = sqlite3_column_text(statement, index) {
            return Data(bytes: pointer, count: Int(length))
        }
        if let pointer = sqlite3_column_blob(statement, index) {
            return Data(bytes: pointer, count: Int(length))
        }
        return nil
    }

    private static func chatRole(from raw: String?) -> ChatRole {
        switch raw {
        case "user":
            return .user
        case "assistant":
            return .assistant
        case "system":
            return .system
        case "tool":
            return .tool
        default:
            return .assistant
        }
    }

    private static func displayName(directory: String, fallback: String) -> String {
        let lastPathComponent = URL(fileURLWithPath: directory).lastPathComponent
        return lastPathComponent.isEmpty ? fallback : lastPathComponent
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func unixMsValue(_ value: Any?) -> Int64? {
        if let int = value as? Int { return Int64(int) }
        if let int64 = value as? Int64 { return int64 }
        if let double = value as? Double { return Int64(double) }
        guard let string = value as? String else { return nil }
        if let int64 = Int64(string) { return int64 }
        if let double = Double(string) { return Int64(double) }
        return nil
    }

    private static func isCompletedToolStatus(_ status: String?) -> Bool {
        guard let status else { return false }
        return ["completed", "done", "success"].contains(status.lowercased())
    }
}
