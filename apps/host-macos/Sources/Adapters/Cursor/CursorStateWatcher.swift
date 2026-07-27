import Foundation
import GTProtocol

/// Watches the Cursor Application Support directory and parses recent chat
/// state. Cursor's schema changes between versions, so we keep this resilient:
/// if we can't find the expected tables we fall back to an empty snapshot
/// with a schemaWarning string that the adapter surfaces in the UI.
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

        public init(
            targetId: String,
            label: String,
            labelSource: LabelSource = .cursorName,
            subtitle: String,
            projectPath: String? = nil,
            selected: Bool,
            lastUpdatedAtUnixMs: Int64
        ) {
            self.targetId = targetId
            self.label = label
            self.labelSource = labelSource
            self.subtitle = subtitle
            self.projectPath = projectPath
            self.selected = selected
            self.lastUpdatedAtUnixMs = lastUpdatedAtUnixMs
        }
    }

    public struct Snapshot: Sendable {
        public let recentMessages: [MessageEntry]
        public let schemaWarning: String?
        public let availableTargets: [TargetEntry]
        public let selectedTargetId: String?
        public let selectedTitle: String?
    }

    public var onChange: (@Sendable (Snapshot) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "io.glasstunnel.cursor-watcher")
    private let stateDir: URL
    private let lock = NSLock()
    private var selectedComposerId: String?

    public init(stateDir: URL? = nil) {
        self.stateDir = stateDir ?? CursorStateWatcher.defaultStateDir()
    }

    public static func defaultStateDir() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? fm.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Cursor", isDirectory: true)
    }

    public func start() throws {
        stop()

        if !FileManager.default.fileExists(atPath: stateDir.path) {
            // Cursor not installed / never launched. Emit an empty snapshot with a warning.
            onChange?(Snapshot(
                recentMessages: [],
                schemaWarning: "Open Cursor once to sync chats.",
                availableTargets: [],
                selectedTargetId: nil,
                selectedTitle: nil
            ))
            return
        }

        let fd = open(stateDir.path, O_EVTONLY)
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

    private func refresh() {
        var messages: [MessageEntry] = []
        var warning: String? = nil
        var targetRefs: [(entry: TargetEntry, db: URL)] = []
        var seenTargets = Set<String>()
        var foundSupportedStorage = false
        var foundUnsupportedStorage = false
        var foundReadFailure = false

        let candidates = CursorStateWatcher.candidateDatabases(under: stateDir)
        if candidates.isEmpty {
            warning = "Open a Cursor chat to sync context."
        } else {
            for url in candidates {
                let reader = CursorSQLiteReader(path: url.path)
                do {
                    let shape = try reader.storageShape()
                    guard shape.hasKnownChatStorage else {
                        foundUnsupportedStorage = true
                        continue
                    }
                    foundSupportedStorage = true
                    let composers = try reader.readRecentComposers(limit: AgentHistoryLimits.sessionSummaryCount)
                    for composer in composers where !seenTargets.contains(composer.composerId) {
                        seenTargets.insert(composer.composerId)
                        let updated = composer.lastUpdatedAtUnixMs ?? composer.createdAtUnixMs ?? 0
                        let displayName = CursorStateWatcher.displayName(for: composer)
                        targetRefs.append((
                            entry: TargetEntry(
                                targetId: composer.composerId,
                                label: displayName.label,
                                labelSource: displayName.source,
                                subtitle: CursorStateWatcher.subtitle(for: composer, databaseURL: url),
                                projectPath: CursorStateWatcher.projectPath(for: composer, databaseURL: url),
                                selected: false,
                                lastUpdatedAtUnixMs: updated
                            ),
                            db: url
                        ))
                    }
                } catch {
                    foundReadFailure = true
                }
            }

            if targetRefs.isEmpty && warning == nil {
                if foundReadFailure {
                    warning = "Cursor context could not be read."
                } else if foundUnsupportedStorage && !foundSupportedStorage {
                    warning = "Cursor chat format changed. Update Glasstunnel."
                }
            }

            targetRefs.sort { $0.entry.lastUpdatedAtUnixMs > $1.entry.lastUpdatedAtUnixMs }
            if targetRefs.count > AgentHistoryLimits.sessionSummaryCount {
                targetRefs = Array(targetRefs.prefix(AgentHistoryLimits.sessionSummaryCount))
            }
            targetRefs = CursorStateWatcher.disambiguatedFallbackLabels(for: targetRefs)

            let selectedID = selectedTargetId(from: targetRefs.map(\.entry))
            if let selectedID,
               let selectedRef = targetRefs.first(where: { $0.entry.targetId == selectedID }) {
                let reader = CursorSQLiteReader(path: selectedRef.db.path)
                do {
                    let recent = try reader.readMessages(forComposerID: selectedID, limit: AgentHistoryLimits.snapshotMessageCount)
                    messages = recent.map { parsed in
                        MessageEntry(
                            messageId: parsed.messageId ?? "cursor-\(selectedID)-\(parsed.atUnixMs ?? 0)-\(parsed.role)",
                            role: CursorStateWatcher.role(fromCursorRole: parsed.role),
                            text: parsed.text,
                            atUnixMs: parsed.atUnixMs ?? Int64(Date().timeIntervalSince1970 * 1000)
                        )
                    }
                    if messages.isEmpty && warning == nil {
                        warning = "Waiting for Cursor chat content."
                    }
                } catch {
                    warning = "Cursor chat could not be read."
                }
            } else if warning == nil {
                var parsedAny = false
                for url in candidates {
                    let reader = CursorSQLiteReader(path: url.path)
                    do {
                        let recent = try reader.readRecentMessages(limit: AgentHistoryLimits.snapshotMessageCount)
                        if !recent.isEmpty {
                            parsedAny = true
                            messages.append(contentsOf: recent.map { parsed in
                                MessageEntry(
                                    messageId: parsed.messageId ?? "cursor-\(url.lastPathComponent)-\(parsed.atUnixMs ?? 0)-\(parsed.role)",
                                    role: CursorStateWatcher.role(fromCursorRole: parsed.role),
                                    text: parsed.text,
                                    atUnixMs: parsed.atUnixMs ?? Int64(Date().timeIntervalSince1970 * 1000)
                                )
                            })
                        }
                    } catch {
                        warning = "Cursor context could not be read."
                    }
                }
                if !parsedAny && warning == nil {
                    warning = "Open a Cursor chat to sync context."
                }
            }
        }

        let selectedID = selectedTargetId(from: targetRefs.map(\.entry))
        let targets = targetRefs.map { ref in
            TargetEntry(
                targetId: ref.entry.targetId,
                label: ref.entry.label,
                labelSource: ref.entry.labelSource,
                subtitle: ref.entry.subtitle,
                projectPath: ref.entry.projectPath,
                selected: ref.entry.targetId == selectedID,
                lastUpdatedAtUnixMs: ref.entry.lastUpdatedAtUnixMs
            )
        }
        let selectedTitle = targets.first(where: { $0.selected })?.label

        onChange?(Snapshot(
            recentMessages: messages,
            schemaWarning: warning,
            availableTargets: targets,
            selectedTargetId: selectedID,
            selectedTitle: selectedTitle
        ))
    }

    /// Returns the list of plausible `state.vscdb` paths to inspect, ordered
    /// by recency (most recently modified first). Cursor's default is
    /// `User/globalStorage/state.vscdb`, but some releases also scatter
    /// per-workspace databases under `User/workspaceStorage/*/state.vscdb`.
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

    private func selectedTargetId(from targets: [TargetEntry]) -> String? {
        lock.lock()
        let requested = selectedComposerId
        lock.unlock()

        if let requested, targets.contains(where: { $0.targetId == requested }) {
            return requested
        }
        let fallback = targets.first?.targetId
        if fallback != requested {
            lock.lock()
            selectedComposerId = fallback
            lock.unlock()
        }
        return fallback
    }

    private static func disambiguatedFallbackLabels(
        for refs: [(entry: TargetEntry, db: URL)]
    ) -> [(entry: TargetEntry, db: URL)] {
        var fallbackIndex = 0
        return refs.map { ref in
            guard isFallbackDisplayName(ref.entry.label) else {
                return ref
            }
            fallbackIndex += 1
            return (
                entry: TargetEntry(
                    targetId: ref.entry.targetId,
                    label: "Cursor chat \(fallbackIndex)",
                    labelSource: .generatedFallback,
                    subtitle: ref.entry.subtitle,
                    projectPath: ref.entry.projectPath,
                    selected: ref.entry.selected,
                    lastUpdatedAtUnixMs: ref.entry.lastUpdatedAtUnixMs
                ),
                db: ref.db
            )
        }
    }

    private struct DisplayName {
        let label: String
        let source: TargetEntry.LabelSource
    }

    private static func displayName(for composer: CursorSQLiteReader.ParsedComposer) -> DisplayName {
        if let name = composer.name, !name.isEmpty {
            return DisplayName(
                label: clamp(name.replacingOccurrences(of: "\n", with: " "), maxLength: 48),
                source: .cursorName
            )
        }
        if let subtitle = composer.subtitle, !subtitle.isEmpty {
            return DisplayName(
                label: clamp(lastPathComponentLike(subtitle), maxLength: 48),
                source: .cursorSubtitle
            )
        }
        return DisplayName(label: "Cursor composer", source: .generatedFallback)
    }

    private static func isFallbackDisplayName(_ label: String) -> Bool {
        normalizedDisplayName(label) == "cursor composer"
    }

    private static func normalizedDisplayName(_ string: String) -> String {
        string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    private static func subtitle(for composer: CursorSQLiteReader.ParsedComposer, databaseURL: URL) -> String {
        if let subtitle = composer.subtitle, !subtitle.isEmpty {
            return clamp(subtitle.replacingOccurrences(of: "\n", with: " "), maxLength: 72)
        }
        if let status = composer.status, !status.isEmpty {
            return status
        }
        if databaseURL.path.contains("/workspaceStorage/") {
            return "Workspace composer"
        }
        return "Cursor"
    }

    private static func projectPath(for composer: CursorSQLiteReader.ParsedComposer, databaseURL: URL) -> String? {
        if let subtitle = composer.subtitle, isPathLike(subtitle) {
            return subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let workspaceIdentifier = composer.workspaceIdentifier,
           let path = workspaceFolderPath(forWorkspaceIdentifier: workspaceIdentifier, databaseURL: databaseURL) {
            return path
        }
        return workspaceFolderPath(forDatabaseURL: databaseURL)
    }

    private static func workspaceFolderPath(forWorkspaceIdentifier identifier: String, databaseURL: URL) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "empty-window" else {
            return nil
        }

        let stateRoot = cursorStateRoot(fromDatabaseURL: databaseURL)
        let workspaceJSON = stateRoot
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("workspaceStorage", isDirectory: true)
            .appendingPathComponent(trimmed, isDirectory: true)
            .appendingPathComponent("workspace.json")
        return folderPath(fromWorkspaceJSON: workspaceJSON)
    }

    private static func workspaceFolderPath(forDatabaseURL databaseURL: URL) -> String? {
        guard databaseURL.lastPathComponent == "state.vscdb",
              databaseURL.deletingLastPathComponent().lastPathComponent != "globalStorage"
        else {
            return nil
        }

        let workspaceJSON = databaseURL.deletingLastPathComponent().appendingPathComponent("workspace.json")
        return folderPath(fromWorkspaceJSON: workspaceJSON)
    }

    private static func folderPath(fromWorkspaceJSON workspaceJSON: URL) -> String? {
        guard let data = try? Data(contentsOf: workspaceJSON),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any],
              let folder = dict["folder"] as? String,
              let url = URL(string: folder),
              url.isFileURL
        else {
            return nil
        }

        let path = url.path.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func cursorStateRoot(fromDatabaseURL databaseURL: URL) -> URL {
        let components = databaseURL.standardizedFileURL.pathComponents
        guard let userIndex = components.lastIndex(of: "User"), userIndex > 0 else {
            return databaseURL.deletingLastPathComponent()
        }
        let rootComponents = Array(components.prefix(userIndex))
        return URL(fileURLWithPath: NSString.path(withComponents: rootComponents), isDirectory: true)
    }

    private static func isPathLike(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("/") || trimmed.hasPrefix("~")
    }

    private static func clamp(_ string: String, maxLength: Int) -> String {
        guard string.count > maxLength else { return string }
        return String(string.prefix(maxLength - 1)) + "…"
    }

    private static func lastPathComponentLike(_ string: String) -> String {
        if string.contains("/") {
            return URL(fileURLWithPath: string).lastPathComponent
        }
        return string
    }
}
