#if os(macOS)
import AppKit
#endif
import Foundation
import GTInput
import GTProtocol

/// How the adapter drives the real Claude desktop window. The production
/// driver uses Accessibility, synthetic keystrokes, and the app's own
/// `claude://` deep links; tests substitute a fake.
protocol ClaudeDesktopUIDriving: Sendable {
    func deliver(text: String, submit: Bool) throws
    func press(label: String, exact: Bool) throws
    func interrupt() throws
    func open(_ url: URL) -> Bool
    /// The front window's title; nil when Accessibility cannot read it. Current
    /// builds title the window "Claude" regardless of session, so this is only
    /// a fallback for `currentSessionTitle()`.
    func frontWindowTitle() -> String?
    /// The name of the session shown in the front window, read from the Code
    /// UI's "<name>, rename session" control; nil when it is not exposed.
    func currentSessionTitle() -> String?
}

/// Adapter for Claude Code sessions hosted by the Claude desktop app.
///
/// The desktop app owns the session, so no second process is spawned. The
/// adapter:
/// - reads desktop-owned transcripts from the shared `~/.claude/projects` store
///   (entrypoint `claude-desktop`) for history, status, titles, and choices
/// - receives Claude Code hook events through the shared router for turn and
///   permission signals that the transcript cannot show
/// - types prompts into the real composer via Accessibility, only after the
///   front window is confirmed to show the selected session
/// - switches sessions with the app's `claude://code/continue` link when the
///   build accepts it (current builds gate those links off), else by pressing
///   the session's row through Accessibility
public final class ClaudeDesktopAdapter: AgentAdapter, @unchecked Sendable {
    public static let bundleID = "com.anthropic.claudefordesktop"

    /// Composer placeholder vocabulary from the desktop app's Code UI, most
    /// specific first.
    static let composerHints = [
        "Ask Claude a question or start a task",
        "Describe a task or ask a question",
        "Ask Claude",
        // The composer's accessibility description on build 1.40609.1.
        "Prompt",
        "Reply",
        "Message",
    ]
    /// Suffix of the accessibility description the Code UI gives the control
    /// that renames the session in front ("<name>, rename session").
    static let renameControlSuffix = ", rename session"
    static let permissionAllowLabels = ["Allow once", "Allow", "Yes", "Approve"]
    static let permissionDenyLabels = ["Deny", "No", "Reject"]
    static let choiceSubmitLabels = ["Submit", "Continue", "Send"]
    static let interruptLabels = ["Stop", "Interrupt"]
    /// Permission prompts have no transcript record, so the adapter publishes
    /// them as a structured question the phone answers with real buttons.
    static let permissionRequestPrefix = "permission-"
    static let permissionAllowChoiceId = "allow"
    static let permissionDenyChoiceId = "deny"

    public let agentID: AgentID
    public let kind: AdapterKind = .claudeDesktop
    public let label: String

    private let targetPID: Int32
    private let ui: any ClaudeDesktopUIDriving
    private let hookRouter: ClaudeHookRouter
    private let hookInstaller: ClaudeCodeHookInstaller
    private let projectsRoot: URL
    private let stateStream = StreamWriter<AgentStateSnapshot>()
    private let summaryCache: ClaudeCodeSessionSummaryCache
    private let lock = NSLock()

    private var sessionSummaries: [ClaudeCodeSessionSummary] = []
    private var selectedSessionId: String?
    private var currentMessages: [AgentChatMessage] = []
    private var currentStatus: AgentStatus = .idle
    private var currentDetail = ""
    private var currentPendingInputRequest: AgentInputRequest?
    private var currentThreadName: String?
    private var currentFrontWindowTitle: String?
    private var currentModel: String?
    private var lastActivityUnixMs = Int64(Date().timeIntervalSince1970 * 1000)
    private var parsedTranscript: (path: String, modifiedAt: Date)?
    /// Set while `currentStatus` (and a permission question) comes from a hook
    /// rather than the transcript. It holds the conversation's activity clock
    /// at hook time: the desktop app keeps appending housekeeping records while
    /// a dialog is open, so only a newer user/assistant record retires it.
    private var hookStatusActivityUnixMs: Int64?
    /// Serializes refreshes so a slow poll parse cannot finish after a hook
    /// and overwrite the state the hook just established.
    private let refreshLock = NSLock()
    /// A turn stopped mid-tool leaves no transcript marker and fires no hook;
    /// silence this long while "working" means the turn is over.
    static let defaultStaleWorkingInterval: TimeInterval = 10 * 60
    private let staleWorkingInterval: TimeInterval
    /// Ownership verdicts for sessions no scan has seen yet. Unknown owners
    /// (no transcript on disk) are re-checked after a short interval.
    private var ownerVerdicts: [String: (isDesktop: Bool, definitive: Bool, decidedAt: Date)] = [:]
    private static let unknownOwnerRecheckInterval: TimeInterval = 10
    private var hookSubscription: UUID?
    private var pollTask: Task<Void, Never>?
    private var lastRefreshAt = Date.distantPast

    public convenience init(agentID: AgentID, label: String, targetPID: Int32) {
        self.init(
            agentID: agentID,
            label: label,
            targetPID: targetPID,
            ui: ClaudeDesktopAccessibilityDriver(targetPID: targetPID)
        )
    }

    init(
        agentID: AgentID,
        label: String,
        targetPID: Int32,
        ui: any ClaudeDesktopUIDriving,
        projectsRoot: URL? = nil,
        hookRouter: ClaudeHookRouter = .shared,
        hookInstaller: ClaudeCodeHookInstaller = ClaudeCodeHookInstaller(),
        staleWorkingInterval: TimeInterval = ClaudeDesktopAdapter.defaultStaleWorkingInterval
    ) {
        self.agentID = agentID
        self.label = label
        self.targetPID = targetPID
        self.ui = ui
        self.projectsRoot = projectsRoot ?? ClaudeCodeSessionStore.defaultProjectsRoot()
        self.summaryCache = ClaudeCodeSessionSummaryCache.shared(for: self.projectsRoot)
        self.hookRouter = hookRouter
        self.hookInstaller = hookInstaller
        self.staleWorkingInterval = staleWorkingInterval
    }

    public func observeState() -> AsyncStream<AgentStateSnapshot> {
        stateStream.make()
    }

    public func runtimeControls() -> AgentRuntimeControls? {
        lock.lock()
        let model = currentModel
        lock.unlock()
        guard let model, !model.isEmpty else { return nil }
        return AgentRuntimeControls(
            modelId: model,
            modelLabel: Self.modelLabel(model),
            modelOptions: [AgentRuntimeOption(id: model, label: Self.modelLabel(model))],
            supportsModelSelection: true,
            editable: false,
            appliesOn: .managedLocally,
            note: "Managed in Claude"
        )
    }

    public func start() async throws {
        emitSnapshot(status: .working, detail: "loading Claude context")
        // The hooks live in the user-global settings file and fire inside
        // desktop-hosted sessions too; without them there is no permission
        // signal, so install them here as well as in the CLI adapter.
        try hookInstaller.installIfNeeded()
        hookSubscription = try hookRouter.subscribe(
            ownsSession: { [weak self] session in
                self?.ownsDesktopSession(session) ?? false
            },
            handler: { [weak self] event in
                self?.handleHook(event)
            }
        )
        refresh(force: true)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                self.pollRefresh()
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
        emitSnapshot(status: .disconnected, detail: "stopped")
    }

    public func sendInput(_ text: String, submit: Bool) async throws {
        if let selected = selectedSummary() {
            let confirmed = await bringSessionToFront(selected)
            // Typing into the wrong session would be far worse than failing:
            // refuse whenever the front session is readable and disagrees.
            if !confirmed, let front = frontSessionTitle(), !front.isEmpty,
               let title = selected.threadName {
                throw NSError(
                    domain: "ClaudeDesktopAdapter",
                    code: 409,
                    userInfo: [NSLocalizedDescriptionKey: "Switch Claude to “\(title)” before sending this prompt."]
                )
            }
        }
        try ui.deliver(text: text, submit: submit)

        applyOptimisticMessage(AgentChatMessage(
            messageId: "\(agentID)-local-\(Int(Date().timeIntervalSince1970 * 1000))",
            role: .user,
            text: text
        ))
        emitCurrentSnapshot()
    }

    public func respondToInputRequest(_ response: AgentInputRequestResponse) async throws {
        guard let request = pendingInputRequest(), request.requestId == response.requestId else {
            throw NSError(
                domain: "ClaudeDesktopAdapter",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Claude is not waiting for that question"]
            )
        }

        let answerByQuestion = Dictionary(
            response.answers.map { ($0.questionId, $0.choiceIds) },
            uniquingKeysWith: { first, _ in first }
        )

        if request.requestId.hasPrefix(Self.permissionRequestPrefix) {
            let choice = answerByQuestion.values.first { !$0.isEmpty }?.first
            let allow: Bool
            switch choice {
            case Self.permissionAllowChoiceId?: allow = true
            case Self.permissionDenyChoiceId?: allow = false
            default:
                throw NSError(
                    domain: "ClaudeDesktopAdapter",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Choose Allow or Deny to answer Claude's permission prompt."]
                )
            }
            try pressPermissionButton(allow: allow)
            completePermissionPrompt(allowed: allow)
            emitCurrentSnapshot()
            return
        }

        var summaryLines: [String] = []
        for question in request.questions {
            guard let choiceId = answerByQuestion[question.questionId]?.first,
                  let choice = question.choices.first(where: { $0.choiceId == choiceId }) else {
                continue
            }
            try ui.press(label: choice.label, exact: false)
            summaryLines.append("\(question.header): \(choice.label)")
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        for label in Self.choiceSubmitLabels {
            if (try? ui.press(label: label, exact: true)) != nil { break }
        }

        // The question stays pending — and the status stays "waiting", which
        // keeps the phone's choice buttons enabled — until the transcript
        // records the answer; if the app did not take it, the user can retry.
        appendOptimisticMessage(AgentChatMessage(
            messageId: "\(agentID)-choice-\(Int(Date().timeIntervalSince1970 * 1000))",
            role: .user,
            text: summaryLines.isEmpty
                ? "Answer sent to Claude"
                : "Answer sent to Claude:\n" + summaryLines.map { "- \($0)" }.joined(separator: "\n")
        ))
        setStatus(.waitingInput, detail: "answer sent")
        emitCurrentSnapshot()
    }

    public func interrupt() async throws {
        try ui.interrupt()
        clearHookOverride()
        setStatus(.working, detail: "Stopping")
        emitCurrentSnapshot()
    }

    public func selectTarget(_ targetID: String) async throws {
        refresh(force: false)
        guard let target = summary(forSessionId: targetID) else {
            throw NSError(
                domain: "ClaudeDesktopAdapter",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Claude session \(targetID) was not found."]
            )
        }
        let targetLabel = target.threadName ?? Self.displayWorkspace(target.workspaceRoot)

        beginSelection(of: target.sessionId, label: targetLabel)
        emitCurrentSnapshot()

        let confirmed = await bringSessionToFront(target)
        refresh(force: false)
        if !confirmed, ui.frontWindowTitle() != nil {
            // The phone keeps the selection and retries until the app shows it.
            setDetail("open “\(targetLabel)” in Claude to continue")
        }
        emitCurrentSnapshot()
    }

    /// Makes the app show `summary` and reports whether the front window now
    /// carries its title. Tries the deep link first (accepted only on builds
    /// that enable it), then the session's row through Accessibility.
    private func bringSessionToFront(_ summary: ClaudeCodeSessionSummary) async -> Bool {
        if Self.windowShowsSession(windowTitle: frontSessionTitle(), sessionTitle: summary.threadName) {
            return true
        }
        if let url = Self.continueSessionURL(summary.sessionId), ui.open(url) {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Self.windowShowsSession(windowTitle: frontSessionTitle(), sessionTitle: summary.threadName) {
                return true
            }
        }
        if let title = summary.threadName {
            // Sidebar entries are titled "<state> <name>" ("Idle …", "Running …",
            // "Unread response …"), so the exact press only hits untitled
            // builds; the substring press is the working path.
            if (try? ui.press(label: title, exact: true)) == nil {
                _ = try? ui.press(label: title, exact: false)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return Self.windowShowsSession(windowTitle: frontSessionTitle(), sessionTitle: summary.threadName)
    }

    /// The best available name for the session in front: the rename control's
    /// name when the Code UI exposes it, else the window title (which current
    /// builds leave at a generic "Claude", so it never verifies a session).
    private func frontSessionTitle() -> String? {
        if let current = ui.currentSessionTitle()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !current.isEmpty {
            return current
        }
        return ui.frontWindowTitle()
    }

    /// True when the front title is the session title, allowing the app's own
    /// suffixes; false when either side is unknown.
    static func windowShowsSession(windowTitle: String?, sessionTitle: String?) -> Bool {
        guard
            let window = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !window.isEmpty,
            let session = sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !session.isEmpty
        else {
            return false
        }
        let normalizedWindow = window.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let normalizedSession = session.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return normalizedWindow == normalizedSession || normalizedWindow.contains(normalizedSession)
    }

    // MARK: - Hooks

    private func ownsDesktopSession(_ session: String) -> Bool {
        guard !session.isEmpty else { return false }
        if let scanned = summaryCache.cachedSummary(forSessionId: session) {
            return scanned.owner == .desktop
        }

        lock.lock()
        if let verdict = ownerVerdicts[session],
           verdict.definitive || Date().timeIntervalSince(verdict.decidedAt) < Self.unknownOwnerRecheckInterval {
            lock.unlock()
            return verdict.isDesktop
        }
        lock.unlock()

        // A session newer than the last listing scan: one targeted read.
        let owner = ClaudeCodeSessionStore.owner(ofSessionId: session, projectsRoot: projectsRoot)
        lock.lock()
        ownerVerdicts[session] = (owner == .desktop, owner != nil, Date())
        lock.unlock()
        return owner == .desktop
    }

    private func handleHook(_ event: ClaudeCodeHookListener.Event) {
        guard event.session == currentSelectedSessionId() else {
            // Another desktop session moved; refresh the listing but never
            // switch what the phone is looking at.
            refresh(force: false)
            return
        }

        // Hook summaries are the raw event name unless Claude sent a message,
        // so the wording here is ours; notification messages are user-facing.
        let override: (status: AgentStatus, detail: String)
        var permissionRequest: AgentInputRequest?
        switch event.kind {
        case .stop:
            override = (.done, "Response ready")
        case .subagentStop:
            // The app also fires this for background work after a turn has
            // finished (title generation, summaries), so a finished turn must
            // not read as working again; only a turn already in flight does.
            lock.lock()
            let turnInFlight = currentStatus == .working
            lock.unlock()
            guard turnInFlight else {
                refresh(force: true)
                return
            }
            override = (.working, "Claude is working")
        case .notification:
            switch event.notificationType {
            case ClaudeCodeHookListener.idlePromptNotification:
                // Claude is merely idle after a finished turn.
                refresh(force: true)
                return
            case ClaudeCodeHookListener.permissionPromptNotification:
                let message = event.summary.isEmpty ? "Claude needs your permission" : event.summary
                permissionRequest = Self.makePermissionRequest(message: message)
                override = (.waitingInput, message)
            default:
                override = (.waitingInput, event.summary.isEmpty ? "Claude needs your input" : event.summary)
            }
        }

        // Bring the parse up to date first so the activity clock we anchor to
        // already includes the record that triggered this hook.
        refresh(force: false)
        lock.lock()
        currentStatus = override.status
        currentDetail = override.detail
        if let permissionRequest {
            currentPendingInputRequest = permissionRequest
        }
        hookStatusActivityUnixMs = lastActivityUnixMs
        lock.unlock()
        emitCurrentSnapshot()
    }

    static func makePermissionRequest(message: String) -> AgentInputRequest {
        AgentInputRequest(
            requestId: "\(permissionRequestPrefix)\(Int(Date().timeIntervalSince1970 * 1000))",
            questions: [
                AgentInputRequestQuestion(
                    questionId: "permission",
                    header: "Permission",
                    question: message,
                    choices: [
                        AgentInputRequestChoice(choiceId: permissionAllowChoiceId, label: "Allow", description: "Let Claude run this once"),
                        AgentInputRequestChoice(choiceId: permissionDenyChoiceId, label: "Deny", description: "Stop Claude from running this"),
                    ]
                ),
            ]
        )
    }

    // MARK: - Refresh

    private func pollRefresh() {
        // Skip a tick that a hook- or selection-driven refresh just covered.
        lock.lock()
        let recentlyRefreshed = Date().timeIntervalSince(lastRefreshAt) < 1.5
        lock.unlock()
        if recentlyRefreshed { return }
        refresh(force: false)
    }

    /// Re-reads desktop-owned sessions, re-derives the selection, and
    /// re-parses the selected transcript when it changed. Emits when the
    /// published state moved or `force` is set.
    private func refresh(force: Bool) {
        refreshLock.lock()
        defer { refreshLock.unlock() }
        var changedFrontWindow = false

        let summaries = ClaudeCodeSessionStore.loadSummaries(
            projectsRoot: projectsRoot,
            owner: .desktop,
            cache: summaryCache
        )
        let frontWindowTitle = frontSessionTitle()

        lock.lock()
        lastRefreshAt = Date()
        if currentFrontWindowTitle != frontWindowTitle {
            currentFrontWindowTitle = frontWindowTitle
            changedFrontWindow = true
        }
        let selected = summaries.first { $0.sessionId == selectedSessionId } ?? summaries.first
        let selectionChanged = selected?.sessionId != selectedSessionId
        var changed = summaries != sessionSummaries || selectionChanged
        sessionSummaries = summaries
        selectedSessionId = selected?.sessionId
        if selectionChanged {
            currentMessages = []
            parsedTranscript = nil
            hookStatusActivityUnixMs = nil
            currentPendingInputRequest = nil
        }
        if selected == nil {
            currentStatus = .idle
            currentDetail = "waiting for a Claude session"
        }
        // Modification dates are nanosecond-precise on APFS, so an unchanged
        // date means an unchanged transcript even when `force` asks to emit.
        let needsParse = selected.map { selected in
            parsedTranscript?.path != selected.path || parsedTranscript?.modifiedAt != selected.modifiedAt
        } ?? false
        lock.unlock()

        if let selected, needsParse,
           let parsed = ClaudeCodeSessionParser.parseRecentFile(
               at: URL(fileURLWithPath: selected.path),
               agentID: agentID,
               maxMessages: AgentHistoryLimits.snapshotMessageCount
           ) {
            lock.lock()
            if selectedSessionId == selected.sessionId {
                currentMessages = parsed.messages
                currentThreadName = parsed.threadName ?? selected.threadName
                currentModel = parsed.model ?? currentModel
                let activity = parsed.lastActivityUnixMs
                    ?? Int64(selected.modifiedAt.timeIntervalSince1970 * 1000)
                lastActivityUnixMs = activity
                // A hook-reported state (and its permission question) stands
                // until the conversation itself moves on.
                if hookStatusActivityUnixMs != activity {
                    hookStatusActivityUnixMs = nil
                    currentStatus = parsed.status
                    currentDetail = parsed.statusDetail
                    currentPendingInputRequest = parsed.pendingInputRequest
                }
                parsedTranscript = (selected.path, selected.modifiedAt)
                changed = true
            }
            lock.unlock()
        }

        if markStaleWorkingTurnIdle() {
            changed = true
        }

        if changed || changedFrontWindow || force {
            emitCurrentSnapshot()
        }
    }

    /// A turn stopped while a tool was running leaves the transcript's last
    /// record as `tool_use` and fires no hook, so "working" would otherwise
    /// stand forever. Returns true when the status was changed.
    private func markStaleWorkingTurnIdle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard currentStatus == .working, hookStatusActivityUnixMs == nil, currentPendingInputRequest == nil else {
            return false
        }
        let silence = Date().timeIntervalSince1970 - Double(lastActivityUnixMs) / 1_000
        guard silence > staleWorkingInterval else { return false }
        currentStatus = .idle
        currentDetail = "Idle"
        return true
    }

    // MARK: - Snapshot

    private func emitCurrentSnapshot() {
        lock.lock()
        let status = currentStatus
        let statusDetail = currentDetail.isEmpty ? Self.displayWorkspace(selectedWorkspaceRootLocked()) : currentDetail
        let messages = currentMessages
        let pending = currentPendingInputRequest
        let threadName = currentThreadName
        let activity = lastActivityUnixMs
        let targets = makeTargetsLocked()
        lock.unlock()

        stateStream.yield(AgentStateSnapshot(
            agentId: agentID,
            agentLabel: threadName ?? label,
            adapterKind: kind,
            status: status,
            statusDetail: statusDetail,
            recentMessages: messages,
            lastActivityUnixMs: activity,
            hasVideoTrack: false,
            availableTargets: targets.isEmpty ? nil : targets,
            pendingInputRequest: pending,
            runtimeControls: runtimeControls()
        ))
    }

    private func emitSnapshot(status: AgentStatus, detail: String) {
        setStatus(status, detail: detail)
        emitCurrentSnapshot()
    }

    private func makeTargetsLocked() -> [AgentTargetOption] {
        sessionSummaries.map { summary in
            let projectLabel = URL(fileURLWithPath: summary.workspaceRoot).lastPathComponent
            let threadLabel = summary.threadName ?? projectLabel
            let selected = summary.sessionId == selectedSessionId
            // Active means the app is confirmed to be showing this session; a
            // selected-but-inactive target tells the phone to retry the switch.
            let active = selected && (
                currentFrontWindowTitle == nil
                    || Self.windowShowsSession(windowTitle: currentFrontWindowTitle, sessionTitle: summary.threadName)
            )
            return AgentTargetOption(
                targetId: summary.sessionId,
                label: threadLabel,
                subtitle: Self.displayWorkspace(summary.workspaceRoot),
                selected: selected,
                projectId: summary.workspaceRoot,
                projectLabel: projectLabel,
                projectPath: summary.workspaceRoot,
                threadId: summary.sessionId,
                threadLabel: threadLabel,
                targetKind: "thread",
                lastActivityUnixMs: Int64(summary.modifiedAt.timeIntervalSince1970 * 1000),
                isActive: active,
                supportsNewThread: false
            )
        }
    }

    private func selectedSummary() -> ClaudeCodeSessionSummary? {
        lock.lock()
        defer { lock.unlock() }
        return sessionSummaries.first { $0.sessionId == selectedSessionId }
    }

    private func selectedWorkspaceRootLocked() -> String? {
        sessionSummaries.first { $0.sessionId == selectedSessionId }?.workspaceRoot
    }

    private func applyOptimisticMessage(_ message: AgentChatMessage) {
        appendOptimisticMessage(message)
        lock.lock()
        currentStatus = .working
        currentDetail = "Claude is working"
        hookStatusActivityUnixMs = nil
        lock.unlock()
    }

    private func appendOptimisticMessage(_ message: AgentChatMessage) {
        lock.lock()
        currentMessages.append(message)
        if currentMessages.count > AgentHistoryLimits.snapshotMessageCount {
            currentMessages.removeFirst(currentMessages.count - AgentHistoryLimits.snapshotMessageCount)
        }
        lastActivityUnixMs = message.atUnixMs
        lock.unlock()
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

    private func clearHookOverride() {
        lock.lock()
        hookStatusActivityUnixMs = nil
        lock.unlock()
    }

    private func clearPendingInputRequest() {
        lock.lock()
        currentPendingInputRequest = nil
        lock.unlock()
    }

    private func completePermissionPrompt(allowed: Bool) {
        lock.lock()
        currentPendingInputRequest = nil
        hookStatusActivityUnixMs = nil
        currentStatus = .working
        currentDetail = allowed ? "Allowed" : "Denied"
        lock.unlock()
    }

    private func summary(forSessionId sessionId: String) -> ClaudeCodeSessionSummary? {
        lock.lock()
        defer { lock.unlock() }
        return sessionSummaries.first { $0.sessionId == sessionId }
    }

    private func beginSelection(of sessionId: String, label: String) {
        lock.lock()
        selectedSessionId = sessionId
        currentMessages = []
        parsedTranscript = nil
        hookStatusActivityUnixMs = nil
        currentPendingInputRequest = nil
        currentStatus = .working
        currentDetail = "opening \(label)"
        lock.unlock()
    }

    func currentSelectedSessionId() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return selectedSessionId
    }

    func currentStatusForTesting() -> AgentStatus {
        lock.lock()
        defer { lock.unlock() }
        return currentStatus
    }

    private func pendingInputRequest() -> AgentInputRequest? {
        lock.lock()
        defer { lock.unlock() }
        return currentPendingInputRequest
    }

    private func pressPermissionButton(allow: Bool) throws {
        var lastError: Error?
        for label in allow ? Self.permissionAllowLabels : Self.permissionDenyLabels {
            do {
                try ui.press(label: label, exact: true)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(
            domain: "ClaudeDesktopAdapter",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "Could not find the permission buttons in Claude"]
        )
    }

    // MARK: - Helpers

    /// The desktop app's own entry point for a specific session.
    static func continueSessionURL(_ sessionId: String) -> URL? {
        guard UUID(uuidString: sessionId) != nil else { return nil }
        return URL(string: "claude://code/continue?session=\(sessionId.lowercased())")
    }

    static func displayWorkspace(_ workspaceRoot: String?) -> String {
        guard let workspaceRoot, !workspaceRoot.isEmpty else { return "Claude" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if workspaceRoot.hasPrefix(home) {
            return "~" + workspaceRoot.dropFirst(home.count)
        }
        return workspaceRoot
    }

    static func modelLabel(_ modelId: String) -> String {
        // "claude-opus-4-8" -> "Opus 4.8"; unknown shapes fall back to the id.
        let parts = modelId.split(separator: "-").map(String.init)
        guard parts.count >= 3, parts[0] == "claude" else { return modelId }
        let family = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
        let version = parts.dropFirst(2).filter { Int($0) != nil && $0.count <= 2 }
        guard !version.isEmpty else { return family }
        return "\(family) \(version.joined(separator: "."))"
    }
}

/// Production UI driver: Accessibility first, keystrokes second.
struct ClaudeDesktopAccessibilityDriver: ClaudeDesktopUIDriving {
    let targetPID: Int32
    let keyboard = KeyboardInjector()
    let accessibility = AccessibilityInjector()

    func deliver(text: String, submit: Bool) throws {
        var accessibilityError: Error?
        for hint in ClaudeDesktopAdapter.composerHints {
            do {
                try accessibility.deliver(
                    bundleID: ClaudeDesktopAdapter.bundleID,
                    text: text,
                    submit: submit,
                    targetHint: hint
                )
                return
            } catch {
                accessibilityError = error
            }
        }

        do {
            let pid = try currentPID()
            try focusComposer()
            keyboard.pressCommandA(targetPID: pid)
            keyboard.pressDelete(targetPID: pid)
            keyboard.typeString(text, targetPID: pid)
            if submit { keyboard.pressReturn(targetPID: pid) }
        } catch {
            let axDescription = accessibilityError.map { String(describing: $0) } ?? "not attempted"
            throw NSError(
                domain: "ClaudeDesktopAdapter",
                code: 502,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not deliver prompt to Claude. Accessibility path failed: \(axDescription). Keyboard path failed: \(error)."
                ]
            )
        }
    }

    func press(label: String, exact: Bool) throws {
        try accessibility.press(bundleID: ClaudeDesktopAdapter.bundleID, matching: label, exact: exact)
    }

    func interrupt() throws {
        for label in ClaudeDesktopAdapter.interruptLabels {
            if (try? accessibility.press(bundleID: ClaudeDesktopAdapter.bundleID, matching: label, exact: true)) != nil {
                return
            }
        }
        keyboard.focusApplication(pid: (try? currentPID()) ?? targetPID)
        keyboard.pressEscape()
    }

    func open(_ url: URL) -> Bool {
        #if os(macOS)
        if Thread.isMainThread {
            return NSWorkspace.shared.open(url)
        }
        return DispatchQueue.main.sync { NSWorkspace.shared.open(url) }
        #else
        return false
        #endif
    }

    func frontWindowTitle() -> String? {
        try? accessibility.frontWindowTitle(bundleID: ClaudeDesktopAdapter.bundleID)
    }

    func currentSessionTitle() -> String? {
        let suffix = ClaudeDesktopAdapter.renameControlSuffix
        guard let description = try? accessibility.frontWindowDescription(
            bundleID: ClaudeDesktopAdapter.bundleID,
            endingWith: suffix
        ) else {
            return nil
        }
        return String(description.dropLast(suffix.count))
    }

    private func focusComposer() throws {
        var lastError: Error?
        for hint in ClaudeDesktopAdapter.composerHints {
            do {
                try accessibility.focusInput(bundleID: ClaudeDesktopAdapter.bundleID, targetHint: hint, allowFallback: false)
                return
            } catch {
                lastError = error
            }
        }
        // Electron sometimes exposes only the window shell through AX; click
        // the composer strip near the bottom of the window and type into it.
        do {
            try accessibility.clickFrontWindow(bundleID: ClaudeDesktopAdapter.bundleID, xFraction: 0.5, yFromBottom: 60)
            Thread.sleep(forTimeInterval: 0.16)
            return
        } catch {
            lastError = lastError ?? error
        }
        do {
            try accessibility.focusInput(bundleID: ClaudeDesktopAdapter.bundleID, targetHint: nil, allowFallback: false)
        } catch {
            throw lastError ?? error
        }
    }

    private func currentPID() throws -> pid_t {
        #if os(macOS)
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: ClaudeDesktopAdapter.bundleID)
            .first
        else {
            throw AccessibilityInjector.InjectionError.appNotRunning(ClaudeDesktopAdapter.bundleID)
        }
        return app.processIdentifier
        #else
        return targetPID
        #endif
    }
}
