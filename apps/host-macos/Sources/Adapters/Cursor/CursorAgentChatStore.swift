#if os(macOS)
import CryptoKit
import Foundation
import GTProtocol
import SQLite3

/// Read-only SQLite access shared by the Cursor store readers. Every handle is
/// opened `SQLITE_OPEN_READONLY`; nothing here ever writes to Cursor's files.
final class CursorSQLiteDatabase {
    enum ReadError: Error, CustomStringConvertible {
        case open(Int32, String)
        case prepare(Int32, String)
        case step(Int32, String)

        var description: String {
            switch self {
            case .open(let code, let message): return "sqlite open failed code=\(code): \(message)"
            case .prepare(let code, let message): return "sqlite prepare failed code=\(code): \(message)"
            case .step(let code, let message): return "sqlite step failed code=\(code): \(message)"
            }
        }
    }

    private let db: OpaquePointer

    /// Opens read-only. A WAL-mode database whose writer has gone (the CLI's
    /// chat stores, which keep no `-shm` sidecar) cannot even start a read
    /// through a plain read-only handle (SQLITE_CANTOPEN on the first query),
    /// so that case falls back to an immutable open, which reads the main
    /// file as it is. The desktop app's store keeps its sidecars while Cursor
    /// runs, so the first open sees its live WAL.
    init(path: String) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? ""
            if let handle { sqlite3_close_v2(handle) }
            throw ReadError.open(result, message)
        }
        if Self.canRead(opened) {
            self.db = opened
            return
        }
        sqlite3_close_v2(opened)

        let escaped = path.addingPercentEncoding(withAllowedCharacters: Self.uriPathAllowed) ?? path
        var immutable: OpaquePointer?
        let retry = sqlite3_open_v2("file:\(escaped)?immutable=1", &immutable, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard retry == SQLITE_OK, let fallback = immutable, Self.canRead(fallback) else {
            let message = immutable.map { String(cString: sqlite3_errmsg($0)) } ?? ""
            if let immutable { sqlite3_close_v2(immutable) }
            throw ReadError.open(retry == SQLITE_OK ? SQLITE_CANTOPEN : retry, message)
        }
        self.db = fallback
    }

    private static let uriPathAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "?#%")
        return set
    }()

    private static func canRead(_ db: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        return step == SQLITE_ROW || step == SQLITE_DONE
    }

    deinit {
        sqlite3_close_v2(db)
    }

    func tableExists(_ table: String) -> Bool {
        (try? rows("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1", bindings: [table]) { _ in true })?.isEmpty == false
    }

    /// Runs `sql` with text bindings and maps every row through `map`.
    func rows<T>(_ sql: String, bindings: [String] = [], map: (Row) -> T?) throws -> [T] {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        defer { if statement != nil { sqlite3_finalize(statement) } }
        guard prepared == SQLITE_OK, let statement else {
            throw ReadError.prepare(prepared, String(cString: sqlite3_errmsg(db)))
        }
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            _ = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, transient) }
        }
        var results: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw ReadError.step(step, String(cString: sqlite3_errmsg(db)))
            }
            if let mapped = map(Row(statement: statement)) {
                results.append(mapped)
            }
        }
        return results
    }

    struct Row {
        let statement: OpaquePointer

        func string(_ index: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: pointer)
        }

        func int(_ index: Int32) -> Int64? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
            return sqlite3_column_int64(statement, index)
        }

        /// TEXT or BLOB columns as bytes.
        func data(_ index: Int32) -> Data? {
            let length = sqlite3_column_bytes(statement, index)
            guard length > 0 else { return nil }
            if sqlite3_column_type(statement, index) == SQLITE_TEXT, let pointer = sqlite3_column_text(statement, index) {
                return Data(bytes: pointer, count: Int(length))
            }
            guard let pointer = sqlite3_column_blob(statement, index) else { return nil }
            return Data(bytes: pointer, count: Int(length))
        }
    }
}

/// One chat kept by the `cursor-agent` CLI under `~/.cursor/chats`.
struct CursorCLIChatSummary: Equatable, Sendable {
    let chatId: String
    let storePath: String
    /// md5 of the workspace path, which names the directory the chat lives in.
    let workspaceHash: String
    /// The workspace path when it could be resolved from a trusted-workspace
    /// record or a caller-known workspace; nil otherwise.
    let workspacePath: String?
    let name: String?
    let mode: String?
    let createdAtUnixMs: Int64?
    let updatedAtUnixMs: Int64?
    let hasConversation: Bool
    let modifiedAt: Date

    var title: String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        return "Cursor chat"
    }
}

/// Discovers CLI chats and resolves their workspaces.
enum CursorCLIChatCatalog {
    static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor", isDirectory: true)
    }

    /// `~/.cursor/chats/<md5(workspace path)>`.
    static func workspaceHash(_ workspacePath: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(workspacePath.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Workspaces the CLI has trusted, from `~/.cursor/projects/*/.workspace-trusted`,
    /// keyed by their chat-directory hash.
    static func trustedWorkspaces(root: URL = defaultRoot()) -> [String: String] {
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return [:]
        }
        var result: [String: String] = [:]
        for entry in entries {
            let record = entry.appendingPathComponent(".workspace-trusted")
            guard
                let data = try? Data(contentsOf: record),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let path = object["workspacePath"] as? String, !path.isEmpty
            else {
                continue
            }
            result[workspaceHash(path)] = path
        }
        return result
    }

    /// Every chat under the root, newest first, capped at `limit`.
    static func chats(root: URL = defaultRoot(), knownWorkspaces: [String] = [], limit: Int = AgentHistoryLimits.sessionSummaryCount) -> [CursorCLIChatSummary] {
        var workspaces = trustedWorkspaces(root: root)
        for path in knownWorkspaces where !path.isEmpty {
            workspaces[workspaceHash(path)] = path
        }
        let chatsRoot = root.appendingPathComponent("chats", isDirectory: true)
        guard let hashDirs = try? FileManager.default.contentsOfDirectory(at: chatsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        var summaries: [CursorCLIChatSummary] = []
        for hashDir in hashDirs {
            let hash = hashDir.lastPathComponent
            guard let chatDirs = try? FileManager.default.contentsOfDirectory(at: hashDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                continue
            }
            for chatDir in chatDirs {
                let store = chatDir.appendingPathComponent("store.db")
                guard FileManager.default.fileExists(atPath: store.path) else { continue }
                let meta = readMetaJSON(chatDir.appendingPathComponent("meta.json"))
                let storeMeta = CursorChatStoreReader(path: store.path).meta()
                let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: store.path)[.modificationDate] as? Date) ?? .distantPast
                summaries.append(CursorCLIChatSummary(
                    chatId: chatDir.lastPathComponent,
                    storePath: store.path,
                    workspaceHash: hash,
                    workspacePath: workspaces[hash],
                    name: storeMeta?.name,
                    mode: storeMeta?.mode,
                    createdAtUnixMs: meta?.createdAtUnixMs ?? storeMeta?.createdAtUnixMs,
                    updatedAtUnixMs: meta?.updatedAtUnixMs ?? Int64(modifiedAt.timeIntervalSince1970 * 1000),
                    hasConversation: meta?.hasConversation ?? (storeMeta?.latestRootBlobId != nil),
                    modifiedAt: modifiedAt
                ))
            }
        }
        // Resuming a chat in another folder makes the CLI keep a second store
        // for it under that folder's hash; the newest copy stands for the chat.
        var seen = Set<String>()
        return summaries
            .sorted { ($0.updatedAtUnixMs ?? 0) > ($1.updatedAtUnixMs ?? 0) }
            .filter { seen.insert($0.chatId).inserted }
            .prefix(max(0, limit))
            .map { $0 }
    }

    private struct MetaJSON {
        let createdAtUnixMs: Int64?
        let updatedAtUnixMs: Int64?
        let hasConversation: Bool?
    }

    private static func readMetaJSON(_ url: URL) -> MetaJSON? {
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return MetaJSON(
            createdAtUnixMs: (object["createdAtMs"] as? NSNumber)?.int64Value,
            updatedAtUnixMs: (object["updatedAtMs"] as? NSNumber)?.int64Value,
            hasConversation: object["hasConversation"] as? Bool
        )
    }
}

/// Reads one CLI chat's `store.db`: a `meta` table whose value is hex-encoded
/// JSON naming the latest root blob, and a `blobs` table of content-addressed
/// entries (protobuf roots listing message ids in field 1; JSON messages).
final class CursorChatStoreReader {
    struct Meta {
        let agentId: String?
        let latestRootBlobId: String?
        let name: String?
        let mode: String?
        let createdAtUnixMs: Int64?
    }

    let path: String

    init(path: String) {
        self.path = path
    }

    func meta() -> Meta? {
        guard FileManager.default.fileExists(atPath: path), let db = try? CursorSQLiteDatabase(path: path), db.tableExists("meta") else {
            return nil
        }
        let objects = (try? db.rows("SELECT value FROM meta") { row -> [String: Any]? in
            guard let raw = row.data(0) else { return nil }
            return Self.decodeMetaValue(raw)
        }) ?? []
        guard let object = objects.first(where: { $0["latestRootBlobId"] != nil }) ?? objects.first else { return nil }
        return Meta(
            agentId: object["agentId"] as? String,
            latestRootBlobId: object["latestRootBlobId"] as? String,
            name: nonEmpty(object["name"] as? String),
            mode: nonEmpty(object["mode"] as? String),
            createdAtUnixMs: (object["createdAt"] as? NSNumber)?.int64Value
        )
    }

    /// The chat's messages in order, or nil when the store is unreadable.
    func conversation(agentID: AgentID, maxMessages: Int) -> CursorConversation? {
        guard let meta = meta() else { return nil }
        guard let root = meta.latestRootBlobId, let db = try? CursorSQLiteDatabase(path: path), db.tableExists("blobs") else {
            return CursorConversation.empty
        }
        guard let rootData = blob(root, in: db) else { return CursorConversation.empty }
        let ids = CursorProtobuf.lengthDelimitedValues(in: rootData, field: 1)
            .filter { $0.count == 32 }
            .map(CursorProtobuf.hexString)
        let stored = ids.compactMap { id -> CursorStoredMessage? in
            guard let data = blob(id, in: db) else { return nil }
            return CursorMessageCodec.decode(data)
        }
        let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
        return CursorConversationBuilder.build(
            messages: stored,
            agentID: agentID,
            maxMessages: maxMessages,
            lastActivityUnixMs: modifiedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        )
    }

    private func blob(_ id: String, in db: CursorSQLiteDatabase) -> Data? {
        (try? db.rows("SELECT data FROM blobs WHERE id = ? LIMIT 1", bindings: [id]) { $0.data(0) })?.first
    }

    /// The meta value is the JSON's UTF-8 bytes as lowercase hex; plain JSON is
    /// accepted too in case a build stops encoding it.
    static func decodeMetaValue(_ raw: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
            return object
        }
        let text = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded = CursorProtobuf.data(fromHex: text) else { return nil }
        return try? JSONSerialization.jsonObject(with: decoded) as? [String: Any]
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
