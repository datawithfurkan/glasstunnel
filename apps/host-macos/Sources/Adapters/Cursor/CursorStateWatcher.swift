import Foundation
import GTProtocol

/// Watches the Cursor desktop app's state store and parses its chats.
///
/// Cursor 3.x keeps every chat in `state.vscdb` (the `composerHeaders` table
/// lists them; messages live in the `agentKv` blob store, older chats in
/// bubble rows), read through `CursorDesktopStoreReader`. A change in the
/// store directory triggers a re-read, and `pollIfChanged` re-reads when the
/// database's modification time moved, which is how the adapter's timer keeps
/// up with a turn the app is writing. If the store cannot be read the
/// snapshot carries a `schemaWarning` the adapter shows instead of guessing.
public final class CursorStateWatcher: @unchecked Sendable {
    public struct MessageEntry: Sendable {
        public let messageId: String
        public let role: ChatRole
        public let text: String
        public let atUnixMs: Int64
        public let pendingToolCalls: [PendingToolCall]

        public init(messageId: String, role: ChatRole, text: String, atUnixMs: Int64, pendingToolCalls: [PendingToolCall] = []) {
            self.messageId = messageId
            self.role = role
            self.text = text
            self.atUnixMs = atUnixMs
            self.pendingToolCalls = pendingToolCalls
        }
    }

    public struct TargetEntry: Sendable {
        public enum LabelSource: String, Sendable {
            case cursorName
            case cursorSubtitle
            case generatedFallback
        }

        public let targetId: String
        public let label: String
        public let labelSource: LabelSource
        public let subtitle: String
        public let projectPath: String?
        public let selected: Bool
        public let lastUpdatedAtUnixMs: Int64
        /// `agent` or `chat` (ask), when the store says.
        public let mode: String?
        /// The app is waiting on the person (a permission, a plan review).
        public let needsAttention: Bool

        public init(
            targetId: String,
            label: String,
            labelSource: LabelSource = .cursorName,
            subtitle: String,
            projectPath: String? = nil,
            selected: Bool,
            lastUpdatedAtUnixMs: Int64,
            mode: String? = nil,
            needsAttention: Bool = false
        ) {
            self.targetId = targetId
            self.label = label
            self.labelSource = labelSource
            self.subtitle = subtitle
            self.projectPath = projectPath
            self.selected = selected
            self.lastUpdatedAtUnixMs = lastUpdatedAtUnixMs
            self.mode = mode
            self.needsAttention = needsAttention
        }
    }

    public struct Snapshot: Sendable {
        public let recentMessages: [MessageEntry]
        public let schemaWarning: String?
        public let availableTargets: [TargetEntry]
        public let selectedTargetId: String?
        public let selectedTitle: String?
        /// The selected chat's transcript with the structured tool rows.
        public let messages: [AgentChatMessage]
        public let messageDetails: [MessageID: String]
        public let status: AgentStatus
        public let statusDetail: String
        public let pendingInputRequest: AgentInputRequest?
        /// The selected chat's model, from its store row.
        public let model: String?
        public let lastActivityUnixMs: Int64?

        init(
            recentMessages: [MessageEntry],
            schemaWarning: String?,
            availableTargets: [TargetEntry],
            selectedTargetId: String?,
            selectedTitle: String?,
            messages: [AgentChatMessage] = [],
            messageDetails: [MessageID: String] = [:],
            status: AgentStatus = .idle,
            statusDetail: String = "",
            pendingInputRequest: AgentInputRequest? = nil,
            model: String? = nil,
            lastActivityUnixMs: Int64? = nil
        ) {
            self.recentMessages = recentMessages
            self.schemaWarning = schemaWarning
            self.availableTargets = availableTargets
            self.selectedTargetId = selectedTargetId
            self.selectedTitle = selectedTitle
            self.messages = messages
            self.messageDetails = messageDetails
            self.status = status
            self.statusDetail = statusDetail
            self.pendingInputRequest = pendingInputRequest
            self.model = model
            self.lastActivityUnixMs = lastActivityUnixMs
        }
    }

    public var onChange: (@Sendable (Snapshot) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "io.glasstunnel.cursor-watcher")
    private let stateDir: URL
    private let agentID: AgentID
    private let lock = NSLock()
    private var selectedComposerId: String?
    private var lastReadStoreClock: Date?
    private var lastSnapshot: Snapshot?

    public init(stateDir: URL? = nil, agentID: AgentID = "cursor") {
        self.stateDir = stateDir ?? CursorStateWatcher.defaultStateDir()
        self.agentID = agentID
    }

    public static func defaultStateDir() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? fm.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Cursor", isDirectory: true)
    }

    /// `User/globalStorage/state.vscdb` under the state directory.
    public var stateDatabaseURL: URL {
        stateDir
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)
            .appendingPathComponent("state.vscdb")
    }

    public func start() throws {
        stop()

        if !FileManager.default.fileExists(atPath: stateDir.path) {
            // Cursor not installed / never launched. Emit an empty snapshot with a warning.
            publish(Snapshot(
                recentMessages: [],
                schemaWarning: "Open Cursor once to sync chats.",
                availableTargets: [],
                selectedTargetId: nil,
                selectedTitle: nil
            ))
            return
        }

        let watched = stateDatabaseURL.deletingLastPathComponent()
        let fd = open(FileManager.default.fileExists(atPath: watched.path) ? watched.path : stateDir.path, O_EVTONLY)
        if fd == -1 {
            throw NSError(domain: "CursorStateWatcher", code: Int(errno))
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .link, .attrib],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.refresh()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.fd = fd
        self.source = source
        refresh()
    }

    public func selectTarget(_ targetID: String) {
        lock.lock()
        selectedComposerId = targetID
        lock.unlock()
        queue.async { [weak self] in
            self?.refresh()
        }
    }

    public func stop() {
        source?.cancel()
        source = nil
        if fd != -1 { fd = -1 }
    }

    /// The selected composer id, as last derived.
    public func currentSelectedTargetId() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return selectedComposerId
    }

    public func latestSnapshot() -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return lastSnapshot
    }

    /// Re-reads when the store moved since the last read (the database or its
    /// write-ahead log). Returns true when a snapshot was published.
    @discardableResult
    public func pollIfChanged() -> Bool {
        let clock = storeClock()
        lock.lock()
        let unchanged = clock != nil && clock == lastReadStoreClock
        lock.unlock()
        if unchanged { return false }
        refresh()
        return true
    }

    /// Forces a re-read and publishes the result.
    public func refreshNow() {
        refresh()
    }

    /// The newest modification time of the database and its sidecars.
    func storeClock() -> Date? {
        let base = stateDatabaseURL.path
        return [base, base + "-wal"]
            .compactMap { (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate]) as? Date }
            .max()
    }

    private func refresh() {
        let clock = storeClock()
        let databases = Self.candidateDatabases(under: stateDir)
        guard !databases.isEmpty else {
            publish(Snapshot(
                recentMessages: [],
                schemaWarning: "Open a Cursor chat to sync context.",
                availableTargets: [],
                selectedTargetId: nil,
                selectedTitle: nil
            ))
            return
        }

        // The global store holds every chat on current builds; older builds
        // also scattered chats over per-workspace databases.
        struct Entry {
            let composer: CursorComposerSummary
            let reader: CursorDesktopStoreReader
            let fromWorkspaceDatabase: Bool
        }
        var entries: [Entry] = []
        var seen = Set<String>()
        var supportedDatabases = 0
        var readFailures = 0
        for database in databases {
            let fromWorkspaceDatabase = database.deletingLastPathComponent().lastPathComponent != "globalStorage"
            let folder = fromWorkspaceDatabase
                ? CursorDesktopStoreReader.folderPath(fromWorkspaceJSON: database.deletingLastPathComponent().appendingPathComponent("workspace.json"))
                : nil
            let reader = CursorDesktopStoreReader(stateDBPath: database.path, stateRoot: stateDir, fallbackWorkspacePath: folder)
            guard reader.hasKnownChatStorage() else { continue }
            supportedDatabases += 1
            do {
                for composer in try reader.composers(limit: AgentHistoryLimits.sessionSummaryCount) where seen.insert(composer.composerId).inserted {
                    entries.append(Entry(composer: composer, reader: reader, fromWorkspaceDatabase: fromWorkspaceDatabase))
                }
            } catch {
                readFailures += 1
            }
        }
        entries.sort { ($0.composer.lastUpdatedAtUnixMs ?? $0.composer.createdAtUnixMs ?? 0) > ($1.composer.lastUpdatedAtUnixMs ?? $1.composer.createdAtUnixMs ?? 0) }
        if entries.count > AgentHistoryLimits.sessionSummaryCount {
            entries = Array(entries.prefix(AgentHistoryLimits.sessionSummaryCount))
        }

        var warning: String?
        if entries.isEmpty {
            if supportedDatabases == 0 {
                warning = "Cursor chat format changed. Update Glasstunnel."
            } else if readFailures > 0 {
                warning = "Cursor context could not be read."
            } else {
                warning = "Open a Cursor chat to sync context."
            }
        }

        let selectedID = selectedTargetId(from: entries.map(\.composer))
        var targets = entries.map { entry -> TargetEntry in
            let composer = entry.composer
            let displayName = Self.displayName(for: composer)
            return TargetEntry(
                targetId: composer.composerId,
                label: displayName.label,
                labelSource: displayName.source,
                subtitle: Self.subtitle(for: composer, fromWorkspaceDatabase: entry.fromWorkspaceDatabase),
                projectPath: composer.workspacePath,
                selected: composer.composerId == selectedID,
                lastUpdatedAtUnixMs: composer.lastUpdatedAtUnixMs ?? composer.createdAtUnixMs ?? 0,
                mode: composer.mode,
                needsAttention: composer.hasBlockingPendingActions
            )
        }
        targets = Self.disambiguatedFallbackLabels(for: targets)

        var conversation: CursorConversation?
        var model: String?
        let selectedEntry = entries.first { $0.composer.composerId == selectedID }
        if let selectedID, let selectedEntry {
            conversation = selectedEntry.reader.conversation(composerId: selectedID, agentID: agentID, maxMessages: AgentHistoryLimits.snapshotMessageCount)
            model = selectedEntry.reader.modelName(composerId: selectedID)
            if conversation?.messages.isEmpty ?? true, warning == nil {
                warning = "Waiting for Cursor chat content."
            }
        }

        let messages = conversation?.messages ?? []
        let messageEntries = messages.map { message in
            MessageEntry(
                messageId: message.messageId,
                role: message.role,
                text: message.text,
                atUnixMs: message.atUnixMs,
                pendingToolCalls: message.pendingToolCalls
            )
        }
        let selectedComposer = selectedEntry?.composer
        var status = conversation?.status ?? .idle
        var detail = conversation?.statusDetail ?? ""
        if selectedComposer?.hasBlockingPendingActions == true {
            status = .waitingInput
            detail = "Cursor is waiting for you in the app"
        }

        lock.lock()
        lastReadStoreClock = clock
        lock.unlock()

        publish(Snapshot(
            recentMessages: messageEntries,
            schemaWarning: warning,
            availableTargets: targets,
            selectedTargetId: selectedID,
            selectedTitle: targets.first(where: { $0.selected })?.label,
            messages: messages,
            messageDetails: conversation?.messageDetails ?? [:],
            status: status,
            statusDetail: detail,
            pendingInputRequest: conversation?.pendingInputRequest,
            model: model,
            lastActivityUnixMs: conversation?.lastActivityUnixMs ?? selectedComposer?.lastUpdatedAtUnixMs
        ))
    }

    private func publish(_ snapshot: Snapshot) {
        lock.lock()
        lastSnapshot = snapshot
        lock.unlock()
        onChange?(snapshot)
    }

    /// Returns the list of plausible `state.vscdb` paths to inspect, ordered
    /// by recency. Kept for the diagnostics that audit workspace databases.
    static func candidateDatabases(under stateDir: URL) -> [URL] {
        let global = stateDir
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("globalStorage", isDirectory: true)
            .appendingPathComponent("state.vscdb")

        var results: [URL] = []
        if FileManager.default.fileExists(atPath: global.path) {
            results.append(global)
        }

        let workspaceRoot = stateDir
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("workspaceStorage", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(at: workspaceRoot, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let workspaceDBs = entries
                .map { $0.appendingPathComponent("state.vscdb") }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .sorted { a, b in
                    let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return ad > bd
                }
            results.append(contentsOf: workspaceDBs.prefix(3))
        }
        return results
    }

    /// Cursor stores role strings in a handful of shapes. Normalize into our ChatRole enum.
    static func role(fromCursorRole raw: String) -> ChatRole {
        switch raw.lowercased() {
        case "user", "human":
            return .user
        case "assistant", "ai", "bot", "model":
            return .assistant
        case "system":
            return .system
        case "tool", "function", "tool_result":
            return .tool
        default:
            return .assistant
        }
    }

    private func selectedTargetId(from composers: [CursorComposerSummary]) -> String? {
        lock.lock()
        let requested = selectedComposerId
        lock.unlock()

        if let requested, composers.contains(where: { $0.composerId == requested }) {
            return requested
        }
        let fallback = composers.first?.composerId
        if fallback != requested {
            lock.lock()
            selectedComposerId = fallback
            lock.unlock()
        }
        return fallback
    }

    private static func disambiguatedFallbackLabels(for targets: [TargetEntry]) -> [TargetEntry] {
        var fallbackIndex = 0
        return targets.map { target in
            guard target.labelSource == .generatedFallback else { return target }
            fallbackIndex += 1
            return TargetEntry(
                targetId: target.targetId,
                label: "Cursor chat \(fallbackIndex)",
                labelSource: .generatedFallback,
                subtitle: target.subtitle,
                projectPath: target.projectPath,
                selected: target.selected,
                lastUpdatedAtUnixMs: target.lastUpdatedAtUnixMs,
                mode: target.mode,
                needsAttention: target.needsAttention
            )
        }
    }

    private struct DisplayName {
        let label: String
        let source: TargetEntry.LabelSource
    }

    /// The chat's own name first, else a folder-like subtitle (older builds
    /// put the workspace there), else a generated fallback that
    /// `disambiguatedFallbackLabels` numbers.
    private static func displayName(for composer: CursorComposerSummary) -> DisplayName {
        if let name = composer.title {
            return DisplayName(label: clamp(name.replacingOccurrences(of: "\n", with: " "), maxLength: 48), source: .cursorName)
        }
        if let subtitle = composer.subtitle, !subtitle.isEmpty {
            return DisplayName(label: clamp(lastPathComponentLike(subtitle), maxLength: 48), source: .cursorSubtitle)
        }
        return DisplayName(label: "Cursor composer", source: .generatedFallback)
    }

    private static func subtitle(for composer: CursorComposerSummary, fromWorkspaceDatabase: Bool) -> String {
        if let subtitle = composer.subtitle, !subtitle.isEmpty {
            return clamp(subtitle.replacingOccurrences(of: "\n", with: " "), maxLength: 72)
        }
        if let status = composer.status, !status.isEmpty {
            return status
        }
        if fromWorkspaceDatabase {
            return "Workspace composer"
        }
        switch composer.mode {
        case "agent": return "Agent chat"
        case "chat": return "Ask chat"
        default: return "Cursor"
        }
    }

    private static func lastPathComponentLike(_ string: String) -> String {
        if string.contains("/") {
            return URL(fileURLWithPath: string).lastPathComponent
        }
        return string
    }

    private static func clamp(_ string: String, maxLength: Int) -> String {
        guard string.count > maxLength else { return string }
        return String(string.prefix(maxLength - 1)) + "…"
    }
}
