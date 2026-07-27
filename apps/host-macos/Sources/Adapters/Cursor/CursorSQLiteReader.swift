#if os(macOS)
import Foundation
import SQLite3

/// Read-only accessor for Cursor's chat state stored in `state.vscdb`.
///
/// Cursor's schema shifts between releases: earlier versions put chat data
/// under `workbench.panel.aichat.view.aichat.chatdata`; more recent builds
/// use `composerData:<id>` keys. Rather than hard-code one, we scan `ItemTable`
/// for any key that looks chat-shaped, parse the BLOB as JSON, and walk the
/// resulting tree looking for objects that quack like a message (role + text
/// or role + content).
///
/// Everything here is READ-ONLY. We open the SQLite handle with
/// `SQLITE_OPEN_READONLY` and never touch Cursor's own write path.
public final class CursorSQLiteReader {
    public struct ParsedMessage: Sendable {
        public let role: String
        public let text: String
        public let atUnixMs: Int64?
        public let messageId: String?
    }

    public struct ParsedComposer: Sendable {
        public let composerId: String
        public let name: String?
        public let subtitle: String?
        public let workspaceIdentifier: String?
        public let status: String?
        public let createdAtUnixMs: Int64?
        public let lastUpdatedAtUnixMs: Int64?

        public init(
            composerId: String,
            name: String?,
            subtitle: String?,
            workspaceIdentifier: String?,
            status: String?,
            createdAtUnixMs: Int64?,
            lastUpdatedAtUnixMs: Int64?
        ) {
            self.composerId = composerId
            self.name = name
            self.subtitle = subtitle
            self.workspaceIdentifier = workspaceIdentifier
            self.status = status
            self.createdAtUnixMs = createdAtUnixMs
            self.lastUpdatedAtUnixMs = lastUpdatedAtUnixMs
        }
    }

    public struct StorageShape: Sendable {
        public let hasCursorDiskKV: Bool
        public let hasItemTable: Bool

        public var hasKnownChatStorage: Bool {
            hasCursorDiskKV || hasItemTable
        }
    }

    public enum ReadError: Error, CustomStringConvertible {
        case open(Int32, String)
        case prepare(Int32, String)
        case step(Int32, String)

        public var description: String {
            switch self {
            case .open(let c, let m): return "sqlite open failed code=\(c): \(m)"
            case .prepare(let c, let m): return "sqlite prepare failed code=\(c): \(m)"
            case .step(let c, let m): return "sqlite step failed code=\(c): \(m)"
            }
        }
    }

    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// Read the most recent N messages across every chat-shaped key. Results
    /// are returned newest-first and capped at `limit` entries total.
    public func readRecentMessages(limit: Int = 20) throws -> [ParsedMessage] {
        guard FileManager.default.fileExists(atPath: path) else {
            return []
        }

        return try withDatabase { db in
            if tableExists("cursorDiskKV", in: db) {
                let composers = try readRecentComposers(in: db, limit: 1)
                if let composer = composers.first {
                    let messages = try readMessages(in: db, composerId: composer.composerId, limit: limit)
                    if !messages.isEmpty {
                        return messages
                    }
                }
            }
            return try readItemTableMessages(in: db, limit: limit)
        }
    }

    public func readRecentComposers(limit: Int = 20) throws -> [ParsedComposer] {
        guard FileManager.default.fileExists(atPath: path) else {
            return []
        }

        return try withDatabase { db in
            guard tableExists("cursorDiskKV", in: db) else { return [] }
            return try readRecentComposers(in: db, limit: limit)
        }
    }

    public func readMessages(forComposerID composerId: String, limit: Int = 20) throws -> [ParsedMessage] {
        guard FileManager.default.fileExists(atPath: path) else {
            return []
        }

        return try withDatabase { db in
            guard tableExists("cursorDiskKV", in: db) else { return [] }
            return try readMessages(in: db, composerId: composerId, limit: limit)
        }
    }

    public func storageShape() throws -> StorageShape {
        guard FileManager.default.fileExists(atPath: path) else {
            return StorageShape(hasCursorDiskKV: false, hasItemTable: false)
        }

        return try withDatabase { db in
            StorageShape(
                hasCursorDiskKV: tableExists("cursorDiskKV", in: db),
                hasItemTable: tableExists("ItemTable", in: db)
            )
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        let openFlags = SQLITE_OPEN_READONLY
        let openResult = sqlite3_open_v2(path, &db, openFlags, nil)
        defer {
            if db != nil { sqlite3_close_v2(db) }
        }
        if openResult != SQLITE_OK {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? ""
            throw ReadError.open(openResult, msg)
        }
        return try body(db!)
    }

    private func readRecentComposers(in db: OpaquePointer, limit: Int) throws -> [ParsedComposer] {
        let sql = """
        SELECT key, value FROM cursorDiskKV
        WHERE key LIKE 'composerData:%'
        """
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        if prepareResult != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw ReadError.prepare(prepareResult, msg)
        }

        var composers: [ParsedComposer] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            if step != SQLITE_ROW {
                let msg = String(cString: sqlite3_errmsg(db))
                throw ReadError.step(step, msg)
            }

            let key = columnString(stmt, 0) ?? ""
            guard let data = columnData(stmt, 1),
                  let json = try? JSONSerialization.jsonObject(with: data, options: []),
                  let dict = json as? [String: Any] else { continue }

            let keyComposerId = String(key.dropFirst("composerData:".count))
            let composerId = stringValue(dict["composerId"]) ?? keyComposerId
            guard !composerId.isEmpty else { continue }
            composers.append(
                ParsedComposer(
                    composerId: composerId,
                    name: composerName(from: dict),
                    subtitle: nonEmptyString(dict["subtitle"]),
                    workspaceIdentifier: workspaceIdentifier(from: dict["workspaceIdentifier"]),
                    status: nonEmptyString(dict["status"]),
                    createdAtUnixMs: unixMsValue(dict["createdAt"]),
                    lastUpdatedAtUnixMs: unixMsValue(dict["lastUpdatedAt"])
                )
            )
        }

        composers.sort {
            ($0.lastUpdatedAtUnixMs ?? $0.createdAtUnixMs ?? 0) > ($1.lastUpdatedAtUnixMs ?? $1.createdAtUnixMs ?? 0)
        }
        return Array(composers.prefix(max(0, limit)))
    }

    private func readMessages(in db: OpaquePointer, composerId: String, limit: Int) throws -> [ParsedMessage] {
        guard let composerData = try cursorDiskKVValue(in: db, key: "composerData:\(composerId)"),
              let json = try? JSONSerialization.jsonObject(with: composerData, options: []),
              let dict = json as? [String: Any] else {
            return []
        }

        guard let headers = dict["fullConversationHeadersOnly"] as? [[String: Any]], !headers.isEmpty else {
            let directMessages = extractMessages(from: dict)
            return cappedNewestFirst(directMessages, limit: limit)
        }

        // Query from the tail because large Cursor composers can contain
        // hundreds of bubbles and some bubble payloads are many megabytes.
        let tail = Array(headers.suffix(max(limit * 4, limit)))
        var messages: [ParsedMessage] = []
        for header in tail {
            guard let bubbleId = stringValue(header["bubbleId"]) else { continue }
            let key = "bubbleId:\(composerId):\(bubbleId)"
            guard let bubbleData = try cursorDiskKVValue(in: db, key: key),
                  let json = try? JSONSerialization.jsonObject(with: bubbleData, options: []),
                  let bubble = json as? [String: Any],
                  let parsed = parseBubbleObject(bubble) else { continue }
            messages.append(parsed)
        }

        if messages.count > limit {
            messages = Array(messages.suffix(limit))
        }
        if messages.isEmpty {
            return cappedNewestFirst(extractMessages(from: dict), limit: limit)
        }
        messages.sort { lhs, rhs in
            (lhs.atUnixMs ?? 0) > (rhs.atUnixMs ?? 0)
        }
        return messages
    }

    private func readItemTableMessages(in db: OpaquePointer, limit: Int) throws -> [ParsedMessage] {
        guard tableExists("ItemTable", in: db) else { return [] }

        // Narrow to keys that *might* contain chat; ItemTable in Cursor has
        // hundreds of unrelated entries (workbench layout, recently-opened
        // files, etc.) and scanning all of them would be wasteful.
        let sql = """
        SELECT key, value FROM ItemTable
        WHERE key LIKE 'composerData:%'
           OR key LIKE 'workbench.panel.aichat%'
           OR key LIKE 'aichat.%'
           OR key LIKE 'cursor.chat%'
           OR key LIKE 'cursor.composer%'
        """
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        if prepareResult != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw ReadError.prepare(prepareResult, msg)
        }

        var collected: [ParsedMessage] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            if step != SQLITE_ROW {
                let msg = String(cString: sqlite3_errmsg(db))
                throw ReadError.step(step, msg)
            }

            guard let data = columnData(stmt, 1) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else { continue }
            collected.append(contentsOf: extractMessages(from: json))
        }

        // Sort newest-first. Missing timestamps sort to the end deterministically.
        collected.sort { lhs, rhs in
            (lhs.atUnixMs ?? 0) > (rhs.atUnixMs ?? 0)
        }
        if collected.count > limit {
            collected = Array(collected.prefix(limit))
        }
        return collected
    }

    private func cursorDiskKVValue(in db: OpaquePointer, key: String) throws -> Data? {
        let sql = "SELECT value FROM cursorDiskKV WHERE key = ? LIMIT 1"
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        if prepareResult != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw ReadError.prepare(prepareResult, msg)
        }

        _ = key.withCString { ptr in
            sqlite3_bind_text(stmt, 1, ptr, -1, unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self))
        }

        let step = sqlite3_step(stmt)
        if step == SQLITE_DONE { return nil }
        if step != SQLITE_ROW {
            let msg = String(cString: sqlite3_errmsg(db))
            throw ReadError.step(step, msg)
        }
        return columnData(stmt, 0)
    }

    private func tableExists(_ table: String, in db: OpaquePointer) -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        _ = table.withCString { ptr in
            sqlite3_bind_text(stmt, 1, ptr, -1, unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self))
        }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }

    private func columnData(_ stmt: OpaquePointer?, _ index: Int32) -> Data? {
        let len = sqlite3_column_bytes(stmt, index)
        guard len > 0 else { return nil }
        let type = sqlite3_column_type(stmt, index)
        if type == SQLITE_TEXT, let ptr = sqlite3_column_text(stmt, index) {
            return Data(bytes: ptr, count: Int(len))
        }
        if let ptr = sqlite3_column_blob(stmt, index) {
            return Data(bytes: ptr, count: Int(len))
        }
        return nil
    }

    // MARK: - JSON walker

    /// Recursively look for objects that look like chat messages.
    ///
    /// Cursor rewrites its schema between versions, so we accept a few shapes:
    ///   - {messages: [{role, content}, ...]}          — "messages list" container
    ///   - {chatMessages: [...]}                        — older variant
    ///   - {role, content}                              — a bare message object
    ///   - {role, text}                                 — a bare message object
    ///   - {role, content: [{type:"text", text:"..."}]} — OpenAI-style parts
    ///
    /// To avoid double-counting we track which dicts we've already parsed as
    /// "messages" and don't recurse back into them. We also never treat an
    /// OpenAI-style content-parts array as a list of messages.
    private func extractMessages(from value: Any) -> [ParsedMessage] {
        var out: [ParsedMessage] = []
        walk(value: value, insideMessagesArray: false, out: &out)
        return out
    }

    private func walk(value: Any, insideMessagesArray: Bool, out: inout [ParsedMessage]) {
        if let dict = value as? [String: Any] {
            var parsedHere = false
            if let msgs = dict["messages"] as? [[String: Any]] {
                for m in msgs {
                    if let parsed = parseMessageObject(m) {
                        out.append(parsed)
                    }
                }
                parsedHere = true
            }
            if let msgs = dict["chatMessages"] as? [[String: Any]] {
                for m in msgs {
                    if let parsed = parseMessageObject(m) {
                        out.append(parsed)
                    }
                }
                parsedHere = true
            }

            // Bare message object (but not inside a `messages` array we just
            // processed, and not if we already extracted children from this dict).
            if !parsedHere, !insideMessagesArray, let parsed = parseMessageObject(dict) {
                out.append(parsed)
            }

            for (key, v) in dict {
                // Skip arrays we've already parsed as messages.
                if parsedHere && (key == "messages" || key == "chatMessages") { continue }
                // Don't recurse into an OpenAI-style content parts array. The
                // enclosing parseMessageObject already collapsed it to text.
                if key == "content" && v is [Any] { continue }
                walk(value: v, insideMessagesArray: false, out: &out)
            }
        } else if let arr = value as? [Any] {
            for v in arr {
                walk(value: v, insideMessagesArray: false, out: &out)
            }
        } else if let string = value as? String,
                  let nested = parseNestedJSONString(string) {
            walk(value: nested, insideMessagesArray: false, out: &out)
        }
    }

    private func parseMessageObject(_ dict: [String: Any]) -> ParsedMessage? {
        guard let role = dict["role"] as? String ?? dict["type"] as? String,
              !role.isEmpty else { return nil }
        let text: String
        if let s = dict["text"] as? String { text = s }
        else if let s = dict["content"] as? String { text = s }
        else if let s = dict["body"] as? String { text = s }
        else if let parts = dict["content"] as? [[String: Any]] {
            // OpenAI-style content array: [{type:"text", text:"..."}]
            text = parts.compactMap { ($0["text"] as? String) ?? ($0["content"] as? String) }
                .joined(separator: "\n")
        } else {
            return nil
        }
        if text.isEmpty { return nil }

        let atUnixMs: Int64?
        if let n = dict["createdAt"] as? Double { atUnixMs = Int64(n) }
        else if let n = dict["timestamp"] as? Double { atUnixMs = Int64(n) }
        else if let s = dict["createdAt"] as? String, let n = Int64(s) { atUnixMs = n }
        else { atUnixMs = nil }

        let messageId: String?
        if let s = dict["id"] as? String { messageId = s }
        else if let s = dict["messageId"] as? String { messageId = s }
        else { messageId = nil }

        return ParsedMessage(role: role, text: text, atUnixMs: atUnixMs, messageId: messageId)
    }

    private func parseBubbleObject(_ dict: [String: Any]) -> ParsedMessage? {
        guard let text = nonEmptyString(dict["text"]) ?? richTextPlainString(dict["richText"]) else {
            return nil
        }

        let role: String
        if let rawRole = nonEmptyString(dict["role"]) {
            role = rawRole
        } else if let rawType = intValue(dict["type"]) {
            switch rawType {
            case 1:
                role = "user"
            case 2:
                role = "assistant"
            default:
                role = "assistant"
            }
        } else {
            role = "assistant"
        }

        return ParsedMessage(
            role: role,
            text: text,
            atUnixMs: unixMsValue(dict["createdAt"]),
            messageId: nonEmptyString(dict["bubbleId"]) ?? nonEmptyString(dict["serverBubbleId"])
        )
    }

    private func cappedNewestFirst(_ messages: [ParsedMessage], limit: Int) -> [ParsedMessage] {
        var collected = messages
        collected.sort { lhs, rhs in
            (lhs.atUnixMs ?? 0) > (rhs.atUnixMs ?? 0)
        }
        if collected.count > limit {
            collected = Array(collected.prefix(limit))
        }
        return collected
    }

    private func parseNestedJSONString(_ string: String) -> Any? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count < 2_000_000,
              trimmed.first == "{" || trimmed.first == "[" else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [])
    }

    private func richTextPlainString(_ value: Any?) -> String? {
        guard let string = value as? String,
              let json = parseNestedJSONString(string) else { return nil }
        var parts: [String] = []
        collectTextFragments(from: json, into: &parts)
        let text = parts.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func collectTextFragments(from value: Any, into parts: inout [String]) {
        if let dict = value as? [String: Any] {
            if let text = nonEmptyString(dict["text"]) {
                parts.append(text)
            }
            if let text = nonEmptyString(dict["content"]),
               dict["type"] as? String == "text" {
                parts.append(text)
            }
            for child in dict.values {
                collectTextFragments(from: child, into: &parts)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectTextFragments(from: child, into: &parts)
            }
        }
    }

    private func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func composerName(from dict: [String: Any]) -> String? {
        for key in ["name", "title", "displayName", "label"] {
            if let value = nonEmptyString(dict[key]) {
                return value
            }
        }
        return nil
    }

    private func workspaceIdentifier(from value: Any?) -> String? {
        if let string = nonEmptyString(value) {
            return string
        }
        if let dict = value as? [String: Any] {
            return nonEmptyString(dict["id"])
        }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let int64 = value as? Int64 { return Int(int64) }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func unixMsValue(_ value: Any?) -> Int64? {
        if let int = value as? Int { return Int64(int) }
        if let int64 = value as? Int64 { return int64 }
        if let double = value as? Double { return Int64(double) }
        guard let string = value as? String else { return nil }
        if let int = Int64(string) { return int }
        if let double = Double(string) { return Int64(double) }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        let basic = ISO8601DateFormatter()
        if let date = basic.date(from: string) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        return nil
    }
}
#endif
