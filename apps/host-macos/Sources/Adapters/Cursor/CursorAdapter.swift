import Foundation
import GTProtocol
import GTInput
import GTSecurity

/// Adapter for the Cursor desktop app.
///
/// The app owns the chats, so no second process is spawned. The adapter:
/// - reads chats and their transcripts from the app's own store
///   (`state.vscdb`, through `CursorStateWatcher`) for history, titles, tool
///   rows, the model, and turn state
/// - receives Cursor hook events through the shared `CursorHookRouter` for the
///   live signals the store cannot give in time: the start of a turn, each
///   tool call, and the end of a turn (completed, aborted, or failed)
/// - types prompts into the real composer through Accessibility, only after
///   the window is confirmed to show the selected chat (or when the app
///   exposes no chat title at all)
/// - switches chats by pressing their sidebar entry and re-checking the title
public final class CursorAdapter: AgentAdapter, @unchecked Sendable {
    public enum DeliveryError: Error, CustomStringConvertible {
        case chatNotInFront(String)
        case chatNotFound(String)
        case notWaitingForThatQuestion

        public var description: String {
            switch self {
            case .chatNotInFront(let title):
                return "Switch Cursor to “\(title)” before sending this prompt."
            case .chatNotFound(let id):
                return "Cursor chat \(id) was not found."
            case .notWaitingForThatQuestion:
                return "Cursor is not waiting for that question"
            }
        }
    }

    public static let bundleID = "com.todesktop.230313mzl4w4u92"
    public static let newChatTargetId = "cursor-new-chat"
    public static let workingDetail = "Cursor is working"
    public static let doneDetail = "Response ready"
    public static let stoppedDetail = "Stopped"
    public static let failedDetail = "Cursor reported an error"
    public static let undeliveredDetail = "Prompt not delivered"
    /// A turn stopped without a hook leaves "working" standing; silence this
    /// long means the turn is over.
    static let defaultStaleWorkingInterval: TimeInterval = 10 * 60

    public let agentID: AgentID
    public let kind: AdapterKind = .cursor
    public let label: String

    private let ui: any CursorDesktopUIDriving
    private let watcher: CursorStateWatcher
    private let hookRouter: CursorHookRouter
    private let hookInstaller: CursorHookInstaller
    private let staleWorkingInterval: TimeInterval
    private let stateStream = StreamWriter<AgentStateSnapshot>()
    private let lock = NSLock()

    private var latest: CursorStateWatcher.Snapshot?
    private var currentStatus: AgentStatus = .idle
    private var currentDetail = ""
    private var currentFrontTitle: String?
    private var frontTitleReadAt = Date.distantPast
    /// A hook-reported state stands until the store moves past this anchor.
    private var hookAnchor: String?
    /// True after a stop hook ended the current turn. The store cannot tell an
    /// aborted turn from one still running (both end with the prompt and no
    /// reply), so its "working" reading is ignored until a new turn starts.
    private var turnEndedByHook = false
    /// The status and detail the ending stop hook reported.
    private var hookVerdict: (AgentStatus, String)?
    /// True from a prompt (phone or `beforeSubmitPrompt` hook) until a stop
    /// hook or a settled store state ends the turn. While it runs, the
    /// composer's record still names the previous generation's outcome, so a
    /// stale "aborted" there must not stop the running turn.
    private var turnInProgress = false
    /// The last chat the store reported as selected; a read that found none
    /// does not count as a switch.
    private var lastSelectedTargetId: String?
    private var liveRows: [LiveRow] = []
    private var liveEvents: [AgentChatMessage] = []
    private var turnStartMessageCount: Int?
    private var optimisticPrompt: AgentChatMessage?
    private var pendingAnswerNote: AgentChatMessage?
    private var awaitingNewChat = false
    private var lastActivityUnixMs = Int64(Date().timeIntervalSince1970 * 1000)
    private var lastWorkingSince = Date.distantPast
    private var hookSubscription: UUID?
    private var pollTask: Task<Void, Never>?
    private var pollCount = 0

    private struct LiveRow {
        let callId: String
        let name: String
        let title: String
        let startedAtUnixMs: Int64
        var completed: Bool
        var isError: Bool
        var durationMs: Int64
    }

    public convenience init(agentID: AgentID = "cursor", label: String = "Cursor") {
        #if os(macOS)
        self.init(agentID: agentID, label: label, ui: CursorAccessibilityDriver())
        #else
        self.init(agentID: agentID, label: label, ui: CursorNoopDriver())
        #endif
    }

    init(
        agentID: AgentID = "cursor",
        label: String = "Cursor",
        ui: any CursorDesktopUIDriving,
        watcher: CursorStateWatcher? = nil,
        hookRouter: CursorHookRouter = .shared,
        hookInstaller: CursorHookInstaller = CursorHookInstaller(),
        staleWorkingInterval: TimeInterval = CursorAdapter.defaultStaleWorkingInterval
    ) {
        self.agentID = agentID
        self.label = label
        self.ui = ui
        self.watcher = watcher ?? CursorStateWatcher(agentID: agentID)
        self.hookRouter = hookRouter
        self.hookInstaller = hookInstaller
        self.staleWorkingInterval = staleWorkingInterval
    }

    public func observeState() -> AsyncStream<AgentStateSnapshot> {
        stateStream.make()
    }

    // MARK: - Lifecycle

    public func start() async throws {
        setStatus(.working, detail: "loading Cursor context")
        emitCurrentSnapshot()
        do {
            try hookInstaller.installIfNeeded()
        } catch {
            setStatus(.working, detail: "Cursor hooks not installed: \(error)")
        }
        hookSubscription = try? hookRouter.subscribe(
            ownsConversation: { [weak self] conversation in
                self?.ownsComposer(conversation) ?? false
            },
            handler: { [weak self] event in
                self?.handleHook(event)
            }
        )
        watcher.onChange = { [weak self] snapshot in
            self?.apply(snapshot)
        }
        try watcher.start()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                self.poll()
            }
        }
    }

    public func stop() async {
        pollTask?.cancel()
        pollTask = nil
        if let hookSubscription {
            hookRouter.unsubscribe(hookSubscription)
        }
        hookSubscription = nil
        watcher.stop()
        setStatus(.disconnected, detail: "stopped")
        emitCurrentSnapshot()
    }

    // MARK: - Prompts

    public func sendInput(_ text: String, submit: Bool) async throws {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        let selected = latest?.availableTargets.first { $0.selected }
        let awaitingNewChat = self.awaitingNewChat
        lock.unlock()

        if let selected, !awaitingNewChat {
            let confirmed = bringChatToFront(selected)
            // Typing into the wrong chat would be far worse than failing:
            // refuse whenever the front chat is readable and disagrees.
            if !confirmed, let front = readFrontTitle(force: true), !front.isEmpty {
                recordDeliveryFailure(DeliveryError.chatNotInFront(selected.label))
                throw DeliveryError.chatNotInFront(selected.label)
            }
        }
        do {
            try ui.deliver(text: text, submit: submit)
        } catch {
            recordDeliveryFailure(error)
            throw error
        }
        guard submit, !prompt.isEmpty else { return }

        lock.lock()
        optimisticPrompt = AgentChatMessage(
            messageId: "\(agentID)-local-\(Int(Date().timeIntervalSince1970 * 1000))",
            role: .user,
            text: prompt,
            kind: .text
        )
        liveRows = []
        liveEvents = []
        pendingAnswerNote = nil
        turnStartMessageCount = latest?.messages.count ?? 0
        hookAnchor = nil
        turnEndedByHook = false
        turnInProgress = true
        currentStatus = .working
        currentDetail = Self.workingDetail
        lastWorkingSince = Date()
        lastActivityUnixMs = Int64(Date().timeIntervalSince1970 * 1000)
        lock.unlock()
        emitCurrentSnapshot()
    }

    public func interrupt() async throws {
        try ui.interrupt()
        lock.lock()
        hookAnchor = nil
        currentStatus = .working
        currentDetail = "Stopping"
        lock.unlock()
        emitCurrentSnapshot()
    }

    public func respondToInputRequest(_ response: AgentInputRequestResponse) async throws {
        lock.lock()
        let request = latest?.pendingInputRequest
        let selected = latest?.availableTargets.first { $0.selected }
        lock.unlock()
        guard let request, request.requestId == response.requestId else {
            throw DeliveryError.notWaitingForThatQuestion
        }
        if let selected {
            let confirmed = bringChatToFront(selected)
            if !confirmed, let front = readFrontTitle(force: true), !front.isEmpty {
                throw DeliveryError.chatNotInFront(selected.label)
            }
        }
        let answers = Dictionary(response.answers.map { ($0.questionId, $0.choiceIds) }, uniquingKeysWith: { first, _ in first })
        var summary: [String] = []
        for question in request.questions {
            guard let choiceId = answers[question.questionId]?.first,
                  let choice = question.choices.first(where: { $0.choiceId == choiceId }) else { continue }
            try ui.press(label: choice.label)
            summary.append("\(question.header): \(choice.label)")
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        lock.lock()
        pendingAnswerNote = AgentChatMessage(
            messageId: "\(agentID)-answer-\(Int(Date().timeIntervalSince1970 * 1000))",
            role: .user,
            text: summary.isEmpty ? "Answer sent to Cursor" : "Answer sent to Cursor:\n" + summary.map { "- \($0)" }.joined(separator: "\n"),
            kind: .text
        )
        currentStatus = .waitingInput
        currentDetail = "answer sent"
        lock.unlock()
        emitCurrentSnapshot()
    }

    public func messageDetail(_ messageId: MessageID) -> AgentMessageDetail? {
        lock.lock()
        defer { lock.unlock() }
        guard let text = latest?.messageDetails[messageId] else { return nil }
        return AgentMessageDetail(messageId: messageId, text: text, truncated: text.utf8.count >= TranscriptPreview.detailByteCount)
    }

    // MARK: - Targets

    public func selectTarget(_ targetID: String) async throws {
        if targetID == Self.newChatTargetId {
            try ui.newChat()
            lock.lock()
            awaitingNewChat = true
            optimisticPrompt = nil
            liveRows = []
            liveEvents = []
            currentStatus = .idle
            currentDetail = "New chat opened in Cursor"
            lock.unlock()
            emitCurrentSnapshot()
            return
        }
        lock.lock()
        let target = latest?.availableTargets.first { $0.targetId == targetID }
        lock.unlock()
        guard let target else { throw DeliveryError.chatNotFound(targetID) }

        lock.lock()
        awaitingNewChat = false
        optimisticPrompt = nil
        liveRows = []
        liveEvents = []
        pendingAnswerNote = nil
        hookAnchor = nil
        currentStatus = .working
        currentDetail = "opening \(target.label)"
        lock.unlock()
        emitCurrentSnapshot()

        watcher.selectTarget(targetID)
        let confirmed = bringChatToFront(target)
        watcher.refreshNow()
        if !confirmed, readFrontTitle(force: true) != nil {
            // The phone keeps the selection and retries until the app shows it.
            setDetail("open “\(target.label)” in Cursor to continue")
        }
        emitCurrentSnapshot()
    }

    /// Makes the app show `target` and reports whether the window now carries
    /// its title. Unknown titles (drafts, unreadable trees) count as unconfirmed.
    private func bringChatToFront(_ target: CursorStateWatcher.TargetEntry) -> Bool {
        let candidates = candidateTitles()
        if let front = readFrontTitle(force: true, candidates: candidates), Self.titlesMatch(front, target.label) {
            return true
        }
        guard target.labelSource == .cursorName else { return false }
        if (try? ui.showChat(titled: target.label)) == nil { return false }
        Thread.sleep(forTimeInterval: 0.5)
        guard let front = readFrontTitle(force: true, candidates: candidates) else { return false }
        return Self.titlesMatch(front, target.label)
    }

    private func candidateTitles() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return (latest?.availableTargets ?? []).filter { $0.labelSource == .cursorName }.map(\.label)
    }

    /// Reads the front chat's title, at most every few seconds unless forced;
    /// each read keeps Electron's accessibility tree alive.
    @discardableResult
    private func readFrontTitle(force: Bool, candidates: [String]? = nil) -> String? {
        lock.lock()
        let stale = Date().timeIntervalSince(frontTitleReadAt) > 8
        let cached = currentFrontTitle
        lock.unlock()
        guard force || stale else { return cached }
        let title = ui.frontChatTitle(candidates: candidates ?? candidateTitles())
        lock.lock()
        currentFrontTitle = title
        frontTitleReadAt = Date()
        lock.unlock()
        return title
    }

    static func titlesMatch(_ shown: String, _ wanted: String) -> Bool {
        let a = shown.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
        let b = wanted.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.hasPrefix(b) || b.hasPrefix(a)
    }

    // MARK: - Runtime controls

    public func runtimeControls() -> AgentRuntimeControls? {
        lock.lock()
        let model = latest?.model
        let mode = latest?.availableTargets.first { $0.selected }?.mode
        lock.unlock()
        let note = mode == "agent" ? "Agent chat · Managed in Cursor" : (mode == "chat" ? "Ask chat · Managed in Cursor" : "Managed in Cursor")
        guard let model, !model.isEmpty else {
            return AgentRuntimeControls(
                modelOptions: [],
                reasoningEffortOptions: [],
                editable: false,
                appliesOn: .managedLocally,
                note: note
            )
        }
        return AgentRuntimeControls(
            modelId: model,
            modelLabel: Self.modelLabel(model),
            modelOptions: [AgentRuntimeOption(id: model, label: Self.modelLabel(model))],
            supportsModelSelection: true,
            editable: false,
            appliesOn: .managedLocally,
            note: note
        )
    }

    static func modelLabel(_ modelId: String) -> String {
        switch modelId.lowercased() {
        case "default": return "Default"
        case "auto": return "Auto"
        default:
            // "composer-2.5" -> "Composer 2.5", "gpt-5.4-nano" -> "GPT-5.4 Nano".
            let parts = modelId.split(separator: "-").map(String.init)
            guard parts.count >= 2 else { return modelId }
            return parts.enumerated().map { index, part in
                if part.lowercased() == "gpt" { return "GPT" }
                if index > 0, parts[index - 1].lowercased() == "gpt", part.first?.isNumber == true { return part }
                return part.prefix(1).uppercased() + part.dropFirst()
            }.joined(separator: " ").replacingOccurrences(of: "GPT ", with: "GPT-")
        }
    }

    // MARK: - Hooks

    private func ownsComposer(_ conversation: String) -> Bool {
        guard !conversation.isEmpty else { return false }
        if knownComposerIds().contains(conversation) { return true }
        // A chat newer than the last read: one targeted re-read.
        watcher.pollIfChanged()
        return knownComposerIds().contains(conversation)
    }

    private func knownComposerIds() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set((latest?.availableTargets ?? []).map(\.targetId))
    }

    private func handleHook(_ event: CursorHookEvent) {
        lock.lock()
        let selectedId = latest?.selectedTargetId
        lock.unlock()
        guard event.conversation == selectedId else {
            // Another chat moved; refresh the listing but never switch what
            // the phone is looking at.
            watcher.pollIfChanged()
            return
        }

        let now = event.receivedAtUnixMs
        lock.lock()
        switch event.kind {
        case .beforeSubmitPrompt:
            currentStatus = .working
            currentDetail = Self.workingDetail
            liveRows = []
            liveEvents = []
            turnStartMessageCount = latest?.messages.count ?? 0
            lastWorkingSince = Date()
            turnEndedByHook = false
            turnInProgress = true
        case .preToolUse:
            let name = event.toolName.isEmpty ? "tool" : event.toolName
            let id = event.toolCallId.isEmpty ? "\(name)-\(liveRows.count + 1)" : event.toolCallId
            if !liveRows.contains(where: { $0.callId == id }) {
                liveRows.append(LiveRow(callId: id, name: name, title: event.toolTitle, startedAtUnixMs: now, completed: false, isError: false, durationMs: 0))
            }
            currentStatus = .working
            currentDetail = "Running \(name)"
        case .postToolUse, .postToolUseFailure:
            let failed = event.kind == .postToolUseFailure
            if let index = liveRows.lastIndex(where: { !$0.completed && (event.toolCallId.isEmpty ? $0.name == event.toolName : $0.callId == event.toolCallId) }) {
                liveRows[index].completed = true
                liveRows[index].isError = failed
                liveRows[index].durationMs = max(0, now - liveRows[index].startedAtUnixMs)
            } else if !event.toolName.isEmpty {
                liveRows.append(LiveRow(callId: event.toolCallId.isEmpty ? "\(event.toolName)-\(liveRows.count + 1)" : event.toolCallId, name: event.toolName, title: event.toolTitle, startedAtUnixMs: now, completed: true, isError: failed, durationMs: 0))
            }
            currentStatus = .working
            currentDetail = Self.workingDetail
        case .stop:
            switch event.status {
            case "aborted", "cancelled", "canceled":
                currentStatus = .idle
                currentDetail = Self.stoppedDetail
                liveEvents.append(AgentChatMessage(messageId: "\(agentID)-stopped-\(now)", role: .system, text: Self.stoppedDetail, atUnixMs: now, kind: .event))
            case "error", "errored", "failed":
                currentStatus = .error
                currentDetail = Self.failedDetail
            default:
                currentStatus = .done
                currentDetail = Self.doneDetail
            }
            // The echoed prompt stays until the store shows the same words;
            // an aborted prompt is sometimes never persisted, and the echo is
            // then the only record the phone has of it.
            turnEndedByHook = true
            turnInProgress = false
            hookVerdict = (currentStatus, currentDetail)
        case .other:
            lock.unlock()
            watcher.pollIfChanged()
            return
        }
        hookAnchor = Self.anchor(for: latest)
        lastActivityUnixMs = now
        lock.unlock()
        emitCurrentSnapshot()
        if event.kind == .stop {
            watcher.refreshNow()
        }
    }

    private static func anchor(for snapshot: CursorStateWatcher.Snapshot?) -> String {
        guard let snapshot else { return "none" }
        return "\(snapshot.messages.count)|\(snapshot.lastActivityUnixMs ?? 0)|\(snapshot.status.rawValue)"
    }

    // MARK: - Store snapshots

    private func apply(_ snapshot: CursorStateWatcher.Snapshot) {
        lock.lock()
        let previousAnchor = latest.map(Self.anchor(for:))
        // A read that found no chats (the store between writes) is not a
        // switch; only a different selected chat resets the turn state.
        let previousSelection = lastSelectedTargetId
        let selectionChanged = snapshot.selectedTargetId != nil && previousSelection != nil && previousSelection != snapshot.selectedTargetId
        if let selected = snapshot.selectedTargetId { lastSelectedTargetId = selected }
        let previousIds = Set((latest?.availableTargets ?? []).map(\.targetId))
        latest = snapshot
        let storeMoved = previousAnchor != Self.anchor(for: snapshot)
        // A chat opened with "New chat" has no store row until its first
        // prompt; once it appears it becomes the selection.
        var newestUnseen: String?
        if awaitingNewChat, let unseen = snapshot.availableTargets.first(where: { !previousIds.contains($0.targetId) }) {
            awaitingNewChat = false
            newestUnseen = unseen.targetId
        }
        if selectionChanged {
            optimisticPrompt = nil
            liveRows = []
            liveEvents = []
            pendingAnswerNote = nil
            hookAnchor = nil
            turnEndedByHook = false
            turnInProgress = false
        }
        // Live rows and the echoed prompt are stand-ins until the store shows
        // the turn itself. The echo goes only when the store holds the same
        // words: counting rows misfires when the previous turn's reply lands
        // late, and an aborted prompt may never be persisted at all, in which
        // case the echo is the only record the phone has of it.
        if let echoed = optimisticPrompt,
           snapshot.messages.contains(where: { $0.role == .user && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == echoed.text }) {
            optimisticPrompt = nil
        }
        if let start = turnStartMessageCount, snapshot.messages.count > start {
            let storeHasLiveRow = snapshot.messages.contains { message in message.kind == .toolCall && liveRows.contains { $0.callId == message.toolCallId } }
            if storeHasLiveRow || snapshot.messages.count >= start + 1 + liveRows.count {
                liveRows = []
            }
            if snapshot.status != .waitingInput { pendingAnswerNote = nil }
        }
        // A hook-reported state stands until the store itself moves on.
        if let hookAnchor, hookAnchor == Self.anchor(for: snapshot), !storeMoved || previousAnchor == nil {
            // keep the hook's status
        } else if hookAnchor != nil, !storeMoved {
            // keep the hook's status
        } else {
            hookAnchor = nil
            if let warning = snapshot.schemaWarning, snapshot.availableTargets.isEmpty {
                currentStatus = .idle
                currentDetail = warning
            } else if optimisticPrompt != nil, snapshot.status != .waitingInput, !storeMoved {
                // The prompt was just typed; the store has not seen it yet.
            } else if turnEndedByHook, snapshot.status == .working || snapshot.status == .done {
                // The store persisted the ended turn's prompt (and perhaps a
                // partial reply); the stop hook already settled that turn.
                if let hookVerdict {
                    currentStatus = hookVerdict.0
                    currentDetail = hookVerdict.1
                }
            } else if turnInProgress, snapshot.status == .idle {
                // Either the composer's record still names the previous
                // generation's abort, or a read caught the store between
                // writes; the turn that just started is running.
            } else {
                currentStatus = snapshot.status
                currentDetail = snapshot.statusDetail
                if currentStatus == .idle, currentDetail.isEmpty, let warning = snapshot.schemaWarning {
                    currentDetail = warning
                }
                switch snapshot.status {
                case .working: lastWorkingSince = Date()
                case .done, .error, .waitingInput: turnInProgress = false
                default: break
                }
            }
        }
        if let activity = snapshot.lastActivityUnixMs, activity > lastActivityUnixMs {
            lastActivityUnixMs = activity
        }
        lock.unlock()
        if let newestUnseen {
            watcher.selectTarget(newestUnseen)
        }
        emitCurrentSnapshot()
    }

    private func poll() {
        pollCount += 1
        let moved = watcher.pollIfChanged()
        if pollCount % 5 == 0 {
            let before = currentFrontTitleValue()
            let after = readFrontTitle(force: true)
            if before != after, !moved { emitCurrentSnapshot() }
        }
        if markStaleWorkingIdle() { emitCurrentSnapshot() }
    }

    private func markStaleWorkingIdle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard currentStatus == .working, latest?.pendingInputRequest == nil else { return false }
        guard Date().timeIntervalSince(lastWorkingSince) > staleWorkingInterval else { return false }
        currentStatus = .idle
        currentDetail = "Idle"
        hookAnchor = nil
        optimisticPrompt = nil
        turnInProgress = false
        return true
    }

    private func currentFrontTitleValue() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return currentFrontTitle
    }

    // MARK: - Snapshot

    private func emitCurrentSnapshot() {
        lock.lock()
        let snapshot = latest
        let status = currentStatus
        var detail = currentDetail
        if detail.isEmpty {
            detail = snapshot?.availableTargets.first { $0.selected }?.subtitle ?? "Cursor"
        }
        var messages = snapshot?.messages ?? []
        if let optimisticPrompt { messages.append(optimisticPrompt) }
        messages.append(contentsOf: liveRowMessages())
        messages.append(contentsOf: liveEvents)
        if let pendingAnswerNote { messages.append(pendingAnswerNote) }
        if messages.count > AgentHistoryLimits.snapshotMessageCount {
            messages = Array(messages.suffix(AgentHistoryLimits.snapshotMessageCount))
        }
        let pending = status == .waitingInput || snapshot?.status == .waitingInput ? snapshot?.pendingInputRequest : nil
        let targets = makeTargetsLocked()
        let title = snapshot?.availableTargets.first { $0.selected && $0.labelSource == .cursorName }?.label
        let activity = lastActivityUnixMs
        lock.unlock()

        stateStream.yield(AgentStateSnapshot(
            agentId: agentID,
            agentLabel: title ?? label,
            adapterKind: kind,
            status: status,
            statusDetail: detail,
            recentMessages: messages,
            lastActivityUnixMs: activity,
            hasVideoTrack: false,
            availableTargets: targets.isEmpty ? nil : targets,
            pendingInputRequest: pending,
            runtimeControls: runtimeControls()
        ))
    }

    private func liveRowMessages() -> [AgentChatMessage] {
        liveRows.flatMap { row -> [AgentChatMessage] in
            var rows = [AgentChatMessage(
                messageId: "\(agentID)-hook-\(row.callId)",
                role: .tool,
                text: "Using \(row.name)",
                atUnixMs: row.startedAtUnixMs,
                pendingToolCalls: [PendingToolCall(toolName: row.name, toolCallId: row.callId, summary: "Using \(row.name)")],
                kind: .toolCall,
                toolName: row.name,
                toolCallId: row.callId,
                title: row.title
            )]
            if row.completed {
                rows.append(AgentChatMessage(
                    messageId: "\(agentID)-hook-\(row.callId)-r",
                    role: .tool,
                    text: "",
                    atUnixMs: row.startedAtUnixMs + row.durationMs,
                    kind: .toolResult,
                    toolName: row.name,
                    toolCallId: row.callId,
                    durationMs: row.durationMs,
                    isError: row.isError
                ))
            }
            return rows
        }
    }

    private func makeTargetsLocked() -> [AgentTargetOption] {
        guard let snapshot = latest else { return [] }
        let front = currentFrontTitle
        var targets = snapshot.availableTargets.map { target -> AgentTargetOption in
            // Active means the app is confirmed to be showing this chat, or no
            // title can be read at all; a selected-but-inactive target tells
            // the phone to retry the switch.
            let active = target.selected && (front == nil || Self.titlesMatch(front!, target.label))
            return Self.protocolTarget(from: target, isActive: active)
        }
        targets.append(AgentTargetOption(
            targetId: Self.newChatTargetId,
            label: "Cursor",
            subtitle: "New chat",
            selected: false,
            projectId: "cursor",
            projectLabel: "Cursor",
            threadId: Self.newChatTargetId,
            threadLabel: "New chat",
            targetKind: "thread",
            isActive: false,
            supportsNewThread: true
        ))
        return targets
    }

    /// One chat as the phone sees it: the workspace folder is the project when
    /// the store names one, otherwise the chat stands alone; the chat's own
    /// title is the thread label.
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

    /// A prompt that never reached Cursor is reported in the transcript and
    /// the status, not only as a rejected call, so the phone shows why.
    private func recordDeliveryFailure(_ error: Error) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let reason = String(describing: error)
        lock.lock()
        liveEvents.append(AgentChatMessage(
            messageId: "\(agentID)-undelivered-\(now)",
            role: .system,
            text: "\(Self.undeliveredDetail): \(reason)",
            atUnixMs: now,
            kind: .event
        ))
        currentStatus = .error
        currentDetail = Self.undeliveredDetail
        lastActivityUnixMs = now
        lock.unlock()
        emitCurrentSnapshot()
    }

    private func setStatus(_ status: AgentStatus, detail: String) {
        lock.lock()
        currentStatus = status
        currentDetail = detail
        lock.unlock()
    }

    private func setDetail(_ detail: String) {
        lock.lock()
        currentDetail = detail
        lock.unlock()
    }

    func currentStatusForTesting() -> AgentStatus {
        lock.lock()
        defer { lock.unlock() }
        return currentStatus
    }
}

#if !os(macOS)
struct CursorNoopDriver: CursorDesktopUIDriving {
    func deliver(text: String, submit: Bool) throws {}
    func frontChatTitle(candidates: [String]) -> String? { nil }
    func showChat(titled title: String) throws {}
    func newChat() throws {}
    func interrupt() throws {}
    func press(label: String) throws {}
}
#endif
