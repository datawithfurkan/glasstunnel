import Foundation
import GTProtocol
import GTInput
import GTSecurity

public protocol CursorInputDelivering: Sendable {
    func deliver(
        bundleID: String,
        text: String,
        submit: Bool,
        targetHint: String?
    ) throws -> AccessibilityDeliveryResult
}

extension AccessibilityInjector: CursorInputDelivering {}

/// Adapter for Cursor (the AI-powered VSCode fork).
///
/// Cursor persists chat state in a local SQLite database under
/// `~/Library/Application Support/Cursor`. This adapter:
///
/// - Watches that directory for file-system changes via DispatchSource.
/// - Parses the most recent chat rows from the SQLite database (we only need
///   chat_messages-style tables; the schema varies by Cursor version and we
///   handle that gracefully with a compatibility layer).
/// - Delivers user input by targeting Cursor via the Accessibility API:
///   raise the window, find the chat input field, set its value, post Return.
///
/// If SQLite introspection fails (Cursor version changed its schema), the
/// adapter falls back to mirror mode for the chat pane and logs a warning.
public final class CursorAdapter: AgentAdapter, @unchecked Sendable {
    public enum DeliveryError: Error, CustomStringConvertible {
        case unverifiedInputWrite
        case unverifiedTargetSelection

        public var description: String {
            switch self {
            case .unverifiedInputWrite:
                return "Cursor input write was not verified"
            case .unverifiedTargetSelection:
                return "Cursor target selection is local-only until the chat is opened in Cursor"
            }
        }
    }

    public static let localOnlyTargetSelectionDetail = "Open this chat in Cursor to send"

    public let agentID: AgentID
    public let kind: AdapterKind = .cursor
    public let label: String

    private let cursorBundleID = "com.todesktop.230313mzl4w4u92"
    private let injector: any CursorInputDelivering
    private let watcher: CursorStateWatcher
    private let stateStream = StreamWriter<AgentStateSnapshot>()
    private var currentSnapshot: AgentStateSnapshot
    private let lock = NSLock()
    private var localOnlySelectedTargetID: String?

    public init(agentID: AgentID = "cursor", label: String = "Cursor", injector: any CursorInputDelivering = AccessibilityInjector()) {
        self.agentID = agentID
        self.label = label
        self.injector = injector
        self.watcher = CursorStateWatcher()
        self.currentSnapshot = AgentStateSnapshot(
            agentId: agentID,
            agentLabel: label,
            adapterKind: .cursor,
            status: .idle,
            statusDetail: "awaiting activity"
        )
    }

    public func observeState() -> AsyncStream<AgentStateSnapshot> {
        stateStream.make()
    }

    public func runtimeControls() -> AgentRuntimeControls? {
        AgentRuntimeControls(
            modelOptions: [],
            reasoningEffortOptions: [],
            editable: false,
            appliesOn: .managedLocally,
            note: "Managed in Cursor"
        )
    }

    public func start() async throws {
        watcher.onChange = { [weak self] snapshot in
            self?.apply(snapshot)
        }
        try watcher.start()
        emitSnapshot()
    }

    public func stop() async {
        watcher.stop()
    }

    public func sendInput(_ text: String, submit: Bool) async throws {
        if isLocalOnlyTargetSelectionActive() {
            transition(status: .waitingInput, detail: Self.localOnlyTargetSelectionDetail)
            throw DeliveryError.unverifiedTargetSelection
        }
        try verify(deliverToCursor(text: text, submit: submit))
        transition(status: .working, detail: "input delivered")
    }

    public func interrupt() async throws {
        try verify(deliverToCursor(text: "", submit: false))
        transition(status: .idle, detail: "interrupted")
    }

    public func selectTarget(_ targetID: String) async throws {
        let alreadySelected = isCurrentTargetSelected(targetID)
        setLocalOnlySelectedTargetID(alreadySelected ? nil : targetID)
        watcher.selectTarget(targetID)
        if !alreadySelected {
            transition(status: .waitingInput, detail: Self.localOnlyTargetSelectionDetail)
        }
    }

    private func apply(_ snapshot: CursorStateWatcher.Snapshot) {
        let messages = snapshot.recentMessages.map { entry in
            AgentChatMessage(
                messageId: entry.messageId,
                role: entry.role,
                text: entry.text,
                atUnixMs: entry.atUnixMs
            )
        }
        let hasPending = snapshot.recentMessages.contains { !$0.pendingToolCalls.isEmpty }
        let localOnlyTargetActive = updateLocalOnlySelection(forSelectedTargetID: snapshot.selectedTargetId)
        let status: AgentStatus = localOnlyTargetActive ? .waitingInput : (hasPending ? .working : .idle)
        let detail = localOnlyTargetActive ? Self.localOnlyTargetSelectionDetail : (snapshot.schemaWarning ?? "")
        let targets = snapshot.availableTargets.map { target in
            Self.protocolTarget(from: target, isActive: target.selected && !localOnlyTargetActive)
        }
        transition(
            status: status,
            detail: detail,
            messages: messages,
            targets: targets,
            title: snapshot.selectedTitle
        )
    }

    private func transition(
        status: AgentStatus,
        detail: String,
        messages: [AgentChatMessage]? = nil,
        targets: [AgentTargetOption]? = nil,
        title: String? = nil
    ) {
        lock.lock()
        currentSnapshot.agentLabel = title ?? label
        currentSnapshot.status = status
        currentSnapshot.statusDetail = detail
        currentSnapshot.lastActivityUnixMs = Int64(Date().timeIntervalSince1970 * 1000)
        if let messages { currentSnapshot.recentMessages = messages }
        if let targets { currentSnapshot.availableTargets = targets }
        currentSnapshot.runtimeControls = runtimeControls()
        let snap = currentSnapshot
        lock.unlock()
        stateStream.yield(snap)
    }

    private func emitSnapshot() {
        lock.lock()
        currentSnapshot.runtimeControls = runtimeControls()
        let snap = currentSnapshot
        lock.unlock()
        stateStream.yield(snap)
    }

    private func deliverToCursor(text: String, submit: Bool) throws -> AccessibilityDeliveryResult {
        do {
            return try injector.deliver(
                bundleID: cursorBundleID,
                text: text,
                submit: submit,
                targetHint: "chat"
            )
        } catch AccessibilityInjector.InjectionError.noInputField {
            return try injector.deliver(
                bundleID: cursorBundleID,
                text: text,
                submit: submit,
                targetHint: nil
            )
        }
    }

    private func verify(_ result: AccessibilityDeliveryResult) throws {
        guard result.verified else {
            throw DeliveryError.unverifiedInputWrite
        }
    }

    private func isCurrentTargetSelected(_ targetID: String) -> Bool {
        lock.lock()
        let selected = currentSnapshot.availableTargets?.contains {
            $0.targetId == targetID && $0.selected
        } ?? false
        lock.unlock()
        return selected
    }

    private func setLocalOnlySelectedTargetID(_ targetID: String?) {
        lock.lock()
        localOnlySelectedTargetID = targetID
        lock.unlock()
    }

    private func isLocalOnlyTargetSelectionActive() -> Bool {
        lock.lock()
        let active = localOnlySelectedTargetID != nil
        lock.unlock()
        return active
    }

    private func updateLocalOnlySelection(forSelectedTargetID selectedTargetID: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let localOnlySelectedTargetID else {
            return false
        }
        if selectedTargetID != localOnlySelectedTargetID {
            self.localOnlySelectedTargetID = nil
            return false
        }
        return true
    }

    static func protocolTarget(
        from target: CursorStateWatcher.TargetEntry,
        isActive: Bool? = nil
    ) -> AgentTargetOption {
        let projectPath = target.projectPath ?? Self.projectPath(from: target.subtitle)
        let projectLabel = projectPath.map { Self.projectLabel(fromPath: $0, fallback: "Cursor") }
        return AgentTargetOption(
            targetId: target.targetId,
            label: projectLabel ?? target.label,
            subtitle: target.subtitle,
            selected: target.selected,
            projectId: projectPath,
            projectLabel: projectLabel,
            projectPath: projectPath,
            threadId: target.targetId,
            threadLabel: target.label,
            targetKind: "thread",
            lastActivityUnixMs: target.lastUpdatedAtUnixMs,
            isActive: isActive ?? target.selected,
            supportsNewThread: false
        )
    }

    private static func projectLabel(fromPath path: String, fallback: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let last = URL(fileURLWithPath: trimmed).lastPathComponent
        return last.isEmpty ? trimmed : last
    }

    private static func projectPath(from subtitle: String) -> String? {
        let trimmed = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("/") || trimmed.hasPrefix("~") ? trimmed : nil
    }
}
