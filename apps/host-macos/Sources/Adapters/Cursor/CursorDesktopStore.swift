#if os(macOS)
import Foundation
import GTProtocol

/// One chat ("composer") of the Cursor desktop app, from the `composerHeaders`
/// table of `state.vscdb` (Cursor 3.x) or, on older builds, the
/// `composerData:` rows.
public struct CursorComposerSummary: Equatable, Sendable {
    public let composerId: String
    public let name: String?
    /// Cursor's own subtitle for the chat (older builds put the folder here).
    public let subtitle: String?
    public let status: String?
    public let workspaceId: String?
    public let workspacePath: String?
    public let createdAtUnixMs: Int64?
    public let lastUpdatedAtUnixMs: Int64?
    public let isArchived: Bool
    public let isSubagent: Bool
    public let isDraft: Bool
    /// `agent` or `chat` (ask).
    public let mode: String?
    public let hasBlockingPendingActions: Bool
    public let hasPendingPlan: Bool
    public let hasUnreadMessages: Bool

    public var title: String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Read-only access to the desktop app's chat list and conversations.
final class CursorDesktopStoreReader {
    let stateDBPath: String
    /// `~/Library/Application Support/Cursor`, for `workspaceStorage` lookups.
    let stateRoot: URL
    /// The folder a per-workspace database belongs to, when known.
    let fallbackWorkspacePath: String?

    init(stateDBPath: String, stateRoot: URL, fallbackWorkspacePath: String? = nil) {
        self.stateDBPath = stateDBPath
        self.stateRoot = stateRoot
        self.fallbackWorkspacePath = fallbackWorkspacePath
    }

    /// True when the database carries any table this reader knows.
    func hasKnownChatStorage() -> Bool {
        guard let db = try? CursorSQLiteDatabase(path: stateDBPath) else { return false }
        return db.tableExists("composerHeaders") || db.tableExists("cursorDiskKV") || db.tableExists("ItemTable")
    }

    /// Chats newest first, drafts and subagents excluded, capped at `limit`.
    func composers(limit: Int = AgentHistoryLimits.sessionSummaryCount, includeArchived: Bool = false) throws -> [CursorComposerSummary] {
        let db = try CursorSQLiteDatabase(path: stateDBPath)
        var summaries: [CursorComposerSummary]
        if db.tableExists("composerHeaders") {
            summaries = try db.rows(
                "SELECT composerId, workspaceId, createdAt, lastUpdatedAt, isArchived, isSubagent, value FROM composerHeaders"
            ) { row -> CursorComposerSummary? in
                guard let composerId = row.string(0), !composerId.isEmpty else { return nil }
                let value = row.data(6).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let workspaceId = row.string(1) ?? Self.workspaceIdentifier(value["workspaceIdentifier"])
                return CursorComposerSummary(
                    composerId: composerId,
                    name: value["name"] as? String,
                    subtitle: Self.nonEmpty(value["subtitle"] as? String),
                    status: Self.nonEmpty(value["status"] as? String),
                    workspaceId: workspaceId,
                    workspacePath: self.workspacePath(forWorkspaceId: workspaceId, subtitle: value["subtitle"] as? String),
                    createdAtUnixMs: row.int(2) ?? (value["createdAt"] as? NSNumber)?.int64Value,
                    lastUpdatedAtUnixMs: row.int(3) ?? (value["lastUpdatedAt"] as? NSNumber)?.int64Value,
                    isArchived: (row.int(4) ?? 0) != 0 || value["isArchived"] as? Bool == true,
                    isSubagent: (row.int(5) ?? 0) != 0,
                    isDraft: value["isDraft"] as? Bool == true,
                    mode: value["unifiedMode"] as? String,
                    hasBlockingPendingActions: value["hasBlockingPendingActions"] as? Bool == true,
                    hasPendingPlan: value["hasPendingPlan"] as? Bool == true,
                    hasUnreadMessages: value["hasUnreadMessages"] as? Bool == true
                )
            }
        } else if db.tableExists("cursorDiskKV") {
            summaries = try db.rows("SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%'") { row -> CursorComposerSummary? in
                guard let key = row.string(0), let data = row.data(1),
                      let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                let composerId = (value["composerId"] as? String) ?? String(key.dropFirst("composerData:".count))
                guard !composerId.isEmpty else { return nil }
                let workspaceId = Self.workspaceIdentifier(value["workspaceIdentifier"])
                return CursorComposerSummary(
                    composerId: composerId,
                    name: Self.composerName(from: value),
                    subtitle: Self.nonEmpty(value["subtitle"] as? String),
                    status: Self.nonEmpty(value["status"] as? String),
                    workspaceId: workspaceId,
                    workspacePath: self.workspacePath(forWorkspaceId: workspaceId, subtitle: value["subtitle"] as? String),
                    createdAtUnixMs: (value["createdAt"] as? NSNumber)?.int64Value,
                    lastUpdatedAtUnixMs: (value["lastUpdatedAt"] as? NSNumber)?.int64Value,
                    isArchived: value["isArchived"] as? Bool == true,
                    isSubagent: value["isSubagent"] as? Bool == true,
                    isDraft: value["isDraft"] as? Bool == true,
                    mode: value["unifiedMode"] as? String,
                    hasBlockingPendingActions: false,
                    hasPendingPlan: false,
                    hasUnreadMessages: value["hasUnreadMessages"] as? Bool == true
                )
            }
        } else {
            summaries = []
        }
        return summaries
            .filter { !$0.isSubagent && !$0.isDraft && (includeArchived || !$0.isArchived) }
            .sorted { ($0.lastUpdatedAtUnixMs ?? $0.createdAtUnixMs ?? 0) > ($1.lastUpdatedAtUnixMs ?? $1.createdAtUnixMs ?? 0) }
            .prefix(max(0, limit))
            .map { $0 }
    }

    /// The model the chat runs on, from its `composerData` row.
    func modelName(composerId: String) -> String? {
        guard let db = try? CursorSQLiteDatabase(path: stateDBPath), let object = composerData(composerId, in: db) else { return nil }
        let config = object["modelConfig"] as? [String: Any]
        let name = (config?["modelName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The chat's conversation: the 3.x blob store first, the older bubble
    /// rows second. Nil when the chat has no readable conversation.
    func conversation(composerId: String, agentID: AgentID, maxMessages: Int) -> CursorConversation? {
        guard let db = try? CursorSQLiteDatabase(path: stateDBPath), db.tableExists("cursorDiskKV") else { return nil }
        guard let object = composerData(composerId, in: db) else { return nil }
        let lastUpdated = (object["lastUpdatedAt"] as? NSNumber)?.int64Value

        if let ids = Self.messageBlobIds(fromConversationState: object["conversationState"]), !ids.isEmpty {
            let stored = ids.compactMap { id -> CursorStoredMessage? in
                guard let data = (try? db.rows("SELECT value FROM cursorDiskKV WHERE key = ? LIMIT 1", bindings: ["agentKv:blob:\(id)"]) { $0.data(0) })?.first else {
                    return nil
                }
                return CursorMessageCodec.decode(data)
            }
            if !stored.isEmpty {
                return CursorConversationBuilder.build(messages: stored, agentID: agentID, maxMessages: maxMessages, lastActivityUnixMs: lastUpdated)
            }
        }

        // Older chats: header list plus one bubble row per message.
        let reader = CursorSQLiteReader(path: stateDBPath)
        guard let parsed = try? reader.readMessages(forComposerID: composerId, limit: maxMessages), !parsed.isEmpty else {
            return nil
        }
        let ordered = parsed.sorted { ($0.atUnixMs ?? 0) < ($1.atUnixMs ?? 0) }
        let messages = ordered.enumerated().map { index, message -> AgentChatMessage in
            let role = CursorStateWatcher.role(fromCursorRole: message.role)
            return AgentChatMessage(
                messageId: message.messageId ?? "\(agentID)-cursor-bubble-\(index)",
                role: role,
                text: message.text,
                atUnixMs: message.atUnixMs ?? 0,
                kind: .text
            )
        }
        let last = messages.last
        let status: AgentStatus = last?.role == .assistant ? .done : (last == nil ? .idle : .working)
        return CursorConversation(
            messages: messages,
            messageDetails: [:],
            status: status,
            statusDetail: status == .done ? CursorConversationBuilder.doneDetail : (status == .working ? CursorConversationBuilder.workingDetail : ""),
            pendingInputRequest: nil,
            lastActivityUnixMs: lastUpdated ?? last?.atUnixMs
        )
    }

    /// `conversationState` is base64 protobuf whose repeated field 1 lists the
    /// 32-byte ids of the message blobs in order.
    static func messageBlobIds(fromConversationState value: Any?) -> [String]? {
        guard let string = value as? String, string.count >= 40, let data = Data(base64Encoded: string) else { return nil }
        let ids = CursorProtobuf.lengthDelimitedValues(in: data, field: 1)
            .filter { $0.count == 32 }
            .map(CursorProtobuf.hexString)
        return ids.isEmpty ? nil : ids
    }

    private func composerData(_ composerId: String, in db: CursorSQLiteDatabase) -> [String: Any]? {
        guard let data = (try? db.rows("SELECT value FROM cursorDiskKV WHERE key = ? LIMIT 1", bindings: ["composerData:\(composerId)"]) { $0.data(0) })?.first else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func composerName(from value: [String: Any]) -> String? {
        for key in ["name", "title", "displayName", "label"] {
            if let name = nonEmpty(value[key] as? String) { return name }
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func workspaceIdentifier(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let dict = value as? [String: Any], let id = dict["id"] as? String, !id.isEmpty { return id }
        return nil
    }

    /// The folder a chat belongs to: a path-like subtitle (older builds), the
    /// workspace's `workspace.json`, else the database's own folder.
    private func workspacePath(forWorkspaceId id: String?, subtitle: String?) -> String? {
        if let subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), subtitle.hasPrefix("/") || subtitle.hasPrefix("~") {
            return subtitle
        }
        if let id, let path = workspacePath(forWorkspaceId: id) {
            return path
        }
        return fallbackWorkspacePath
    }

    /// `User/workspaceStorage/<id>/workspace.json` names the folder a chat
    /// belongs to; `empty-window` chats have none.
    func workspacePath(forWorkspaceId id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "empty-window" else { return nil }
        let workspaceJSON = stateRoot
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("workspaceStorage", isDirectory: true)
            .appendingPathComponent(trimmed, isDirectory: true)
            .appendingPathComponent("workspace.json")
        return Self.folderPath(fromWorkspaceJSON: workspaceJSON)
    }

    static func folderPath(fromWorkspaceJSON workspaceJSON: URL) -> String? {
        guard
            let data = try? Data(contentsOf: workspaceJSON),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let folder = object["folder"] as? String,
            let url = URL(string: folder), url.isFileURL
        else {
            return nil
        }
        let path = url.path.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
#endif
