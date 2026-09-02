import Foundation
import GTProtocol
import GTSecurity

/// Adapter for Anthropic's Claude Code CLI.
///
/// Integrates via two channels:
///
/// 1. PTY wrapper around `claude` so we capture output and can inject input.
/// 2. Claude Code "hooks" written to `~/.claude/settings.json` that post a
///    small JSON blob to a local Unix socket we listen on. This gives us
///    structured signals for SubagentStop / Stop / Notification that are
///    vastly more reliable than trying to detect idle states from stdout.
///
/// On start, the adapter installs its hooks if they aren't already present.
/// It never mutates hooks you already configured yourself (it merges in a
/// `glasstunnel` section and leaves the rest alone).
///
/// The adapter always knows which session its PTY is driving: it launches
/// `claude` with `--resume <id>` for an existing session or `--session-id
/// <id>` for a fresh one, so hook events can be matched to that id without
/// touching disk, and sessions driven by other clients (another `claude` in
/// Terminal, the Claude desktop app) can never move this adapter's state.
public final class ClaudeCodeAdapter: PTYAdapterBase, @unchecked Sendable {
    private struct LiveSession {
        let id: String
        /// Base launch arguments that keep the PTY on this session.
        let arguments: [String]
        let cwd: String?
    }

    private let hookInstaller: ClaudeCodeHookInstaller
    private let hookRouter: ClaudeHookRouter
    private var hookSubscription: UUID?
    private let projectsRoot: URL
    private let summaryCache: ClaudeCodeSessionSummaryCache
    private let sessionLock = NSLock()
    private let runtimeLock = NSLock()
    private let initialArguments: [String]
    private var sessionSummaries: [ClaudeCodeSessionSummary] = []
    private var selectedSessionId: String?
    private var liveSession: LiveSession?
    /// Set once `--resume` was refused because another process holds the
    /// session and the adapter relaunched with a fresh id.
    private var fellBackToFreshSession = false
    private var startupGraceUntil = Date.distantPast
    /// Whether the composer hint has been seen since the last launch or reset.
    private var composerSeenSinceLaunch = false
    private var currentMessages: [AgentChatMessage] = []
    private var parsedTranscript: (path: String, modifiedAt: Date)?
    private var refreshTask: Task<Void, Never>?
    private var runtimeModelId: String?
    private var runtimeEffort: String?

    public init(
        agentID: AgentID = "claude-code",
        label: String = "Claude Code",
        executable: String? = nil,
        cwd: String? = nil,
        arguments: [String] = [],
        redactor: SecretRedactor = SecretRedactor(),
        projectsRoot: URL? = nil,
        hookRouter: ClaudeHookRouter = .shared,
        hookInstaller: ClaudeCodeHookInstaller = ClaudeCodeHookInstaller()
    ) {
        self.hookInstaller = hookInstaller
        self.hookRouter = hookRouter
        self.projectsRoot = projectsRoot ?? ClaudeCodeSessionStore.defaultProjectsRoot()
        self.summaryCache = ClaudeCodeSessionSummaryCache.shared(for: self.projectsRoot)
        self.initialArguments = arguments
        super.init(
            agentID: agentID,
            kind: .claudeCode,
            label: label,
            executable: executable ?? ClaudeCodeAdapter.resolveExecutable(),
            arguments: arguments,
            environment: [:],
            cwd: cwd,
            redactor: redactor
        )
    }

    /// Claude Code's TUI treats text and Return arriving in one burst as a
    /// paste and keeps the prompt in the composer; a short pause makes Return
    /// a submit.
    public override var submittedInputSettleNanoseconds: UInt64 { 120_000_000 }

    public override func start() async throws {
        beginStartupGrace()
        // Pin an explicitly requested session before the first scan, so the
        // scan never selects (and briefly publishes) some other session.
        if let explicitId = Self.explicitSessionId(in: initialArguments) {
            setLiveSession(LiveSession(id: explicitId, arguments: initialArguments, cwd: cwd))
        }
        refreshClaudeSessions()
        if liveSessionId() != nil {
            // Already pinned above.
        } else if let selected = selectedSession() {
            setLiveSession(LiveSession(
                id: selected.sessionId,
                arguments: ["--resume", selected.sessionId],
                cwd: selected.workspaceRoot
            ))
        } else if !Self.hasExplicitSessionArgument(initialArguments) {
            let id = UUID().uuidString.lowercased()
            setLiveSession(LiveSession(id: id, arguments: initialArguments + ["--session-id", id], cwd: cwd))
        }
        let launch = currentLaunch()
        configureLaunch(arguments: runtimeArguments(base: launch.arguments), cwd: launch.cwd)

        try hookInstaller.installIfNeeded()
        // Hooks fire for every Claude Code session by any client. Only events
        // for the session this PTY drives are ours; session-less events come
        // from older Claude Code builds that omit session_id and have no
        // other possible consumer.
        hookSubscription = try hookRouter.subscribe(
            ownsSession: { [weak self] session in
                session.isEmpty || session == self?.liveSessionId()
            },
            handler: { [weak self] event in
                self?.handleHook(event)
            }
        )
        do {
            try await super.start()
        } catch {
            releaseHookSubscription()
            throw error
        }
        startRefreshLoop()
    }

    public override func stop() async {
        refreshTask?.cancel()
        refreshTask = nil
        releaseHookSubscription()
        await super.stop()
    }

    // MARK: - Sessions held by another process

    /// `--resume` fails when another process (a background agent, a second
    /// terminal) still holds the session; Claude Code prints this and exits 1.
    static func isSessionHeldElsewhere(_ text: String) -> Bool {
        let compact = text.lowercased().filter { !$0.isWhitespace }
        // Two wordings are in the wild: "is currently running as a background
        // agent (bg) … add --fork-session" and "is running as a background
        // session … Run `claude attach <id>`".
        let running = compact.contains("iscurrentlyrunning") || compact.contains("isrunningasabackground")
        let remedy = compact.contains("--fork-session") || compact.contains("attachtoit") || compact.contains("claudeattach")
        return running && remedy
    }

    public override func didExitProcess(status: Int32) {
        super.didExitProcess(status: status)
        guard status != 0 else { return }
        // A resume that dies before ever showing the composer did not resume:
        // the session is held elsewhere (the message names it), unreadable, or
        // from an incompatible build. A fresh session in the same folder is
        // the useful recovery for all of them.
        let held = Self.isSessionHeldElsewhere(recentOutputTail(maxLength: 4096))
        sessionLock.lock()
        let wasResume = currentLaunchArgumentsLocked().contains("--resume")
        let sawComposer = composerSeenSinceLaunch
        let alreadyFellBack = fellBackToFreshSession
        let heldSession = liveSession?.id
        let shouldFallBack = wasResume && (held || !sawComposer) && !alreadyFellBack
        if shouldFallBack { fellBackToFreshSession = true }
        sessionLock.unlock()
        // One fallback per launch: a fresh id cannot be held by anyone, so a
        // second failure is a different problem and must stay visible.
        guard shouldFallBack else { return }

        let id = UUID().uuidString.lowercased()
        setLiveSession(LiveSession(id: id, arguments: initialArguments + ["--session-id", id], cwd: cwd))
        Task { [weak self] in
            // Let the base adapter publish the exit first; the restart then
            // moves the card back to working instead of the two racing.
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self else { return }
            let launch = self.currentLaunch()
            do {
                self.beginStartupGrace()
                try self.restartProcess(arguments: self.runtimeArguments(base: launch.arguments), cwd: launch.cwd)
                self.transitionTo(
                    .working,
                    detail: "Session \(heldSession.map { String($0.prefix(8)) } ?? "") is open elsewhere; starting a fresh one",
                    forceEmit: true
                )
            } catch {
                self.transitionTo(.error, detail: "Could not start a fresh session: \(error.localizedDescription)", forceEmit: true)
            }
        }
    }

    // MARK: - Workspace trust dialog

    /// Claude Code opens a folder it has not seen before with a "Quick safety
    /// check" dialog instead of the composer. Text typed while it is up is
    /// dropped, so the dialog is published as a decision for the phone and
    /// prompts are refused until it is answered.
    static let trustPromptRequestId = "claude-code-trust-prompt"
    static let trustPromptQuestionId = "claude-code-trust-choice"
    /// Choice ids on the phone; they are not keystrokes (see
    /// `respondToInputRequest`, which moves the dialog's highlight instead).
    static let trustChoiceId = "trust"
    static let exitChoiceId = "exit"

    static func isTrustPrompt(_ text: String) -> Bool {
        let compact = text.lowercased().filter { !$0.isWhitespace }
        return compact.contains("isthisaprojectyoucreatedoroneyoutrust")
            || (compact.contains("yes,itrustthisfolder") && compact.contains("no,exit"))
    }

    static func trustPromptInputRequest(cwd: String?) -> AgentInputRequest {
        let folder = cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "this folder"
        return AgentInputRequest(
            requestId: trustPromptRequestId,
            questions: [
                AgentInputRequestQuestion(
                    questionId: trustPromptQuestionId,
                    header: "Workspace trust",
                    question: "Claude Code asks whether to trust \(folder) before it runs there.",
                    choices: [
                        AgentInputRequestChoice(
                            choiceId: trustChoiceId,
                            label: "Yes, I trust this folder",
                            description: "Claude Code can read, edit, and run files there."
                        ),
                        AgentInputRequestChoice(
                            choiceId: exitChoiceId,
                            label: "No, exit",
                            description: "Stop Claude Code without touching the folder."
                        ),
                    ]
                ),
            ]
        )
    }

    private func trustPromptIsShowing() -> Bool {
        Self.isTrustPrompt(recentOutputTail(maxLength: 4096))
    }

    /// The hint line Claude Code draws under its composer once input is
    /// accepted ("? for shortcuts"). Startup and the trust dialog print
    /// nothing like it, so silence before it is still "starting".
    static func showsComposer(_ text: String) -> Bool {
        let compact = text.lowercased().filter { !$0.isWhitespace }
        return compact.contains("?forshortcuts")
    }

    /// Silence during startup is not readiness; past this, assume a build
    /// without the hint line rather than hiding the composer forever.
    static let startupSilenceGraceSeconds: TimeInterval = 20

    /// Until this instant, silence without the composer hint means the process
    /// is still starting. Reset whenever the output buffer restarts from
    /// scratch (launch, trust answer, relaunch), because the base adapter's
    /// silence clock is meaningless right after a reset.
    private func beginStartupGrace() {
        sessionLock.lock()
        startupGraceUntil = Date().addingTimeInterval(Self.startupSilenceGraceSeconds)
        composerSeenSinceLaunch = false
        sessionLock.unlock()
    }

    /// The launch arguments the running process was started with, for callers
    /// already holding `sessionLock`.
    private func currentLaunchArgumentsLocked() -> [String] {
        guard let live = liveSession else { return initialArguments }
        let hasTranscript = sessionSummaries.contains { $0.sessionId == live.id }
        if hasTranscript, live.arguments.contains("--session-id") {
            return ["--resume", live.id]
        }
        return live.arguments
    }

    private func withinStartupGrace() -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return Date() < startupGraceUntil
    }

    public override func statusAfterOutputSilence(buffer: String, silenceDuration: TimeInterval) -> (status: AgentStatus, detail: String) {
        if Self.isTrustPrompt(buffer) {
            return (.waitingInput, "Trust this folder?")
        }
        if !Self.showsComposer(buffer), withinStartupGrace() {
            return (.working, "Starting Claude Code")
        }
        return super.statusAfterOutputSilence(buffer: buffer, silenceDuration: silenceDuration)
    }

    public override func snapshotPendingInputRequest() -> AgentInputRequest? {
        guard trustPromptIsShowing() else {
            return super.snapshotPendingInputRequest()
        }
        return Self.trustPromptInputRequest(cwd: cwd)
    }

    public override func sendInput(_ text: String, submit: Bool) async throws {
        if trustPromptIsShowing() {
            let folder = cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "this folder"
            throw NSError(
                domain: "ClaudeCodeAdapter",
                code: 409,
                userInfo: [
                    NSLocalizedDescriptionKey: "Claude Code is asking whether to trust \(folder). Answer that first.",
                ]
            )
        }
        try await super.sendInput(text, submit: submit)
    }

    public override func respondToInputRequest(_ response: AgentInputRequestResponse) async throws {
        guard response.requestId == Self.trustPromptRequestId else {
            try await super.respondToInputRequest(response)
            return
        }
        let choice = response.answers
            .first(where: { $0.questionId == Self.trustPromptQuestionId })?
            .choiceIds
            .first
        guard let choice, choice == Self.trustChoiceId || choice == Self.exitChoiceId else {
            throw NSError(
                domain: "ClaudeCodeAdapter",
                code: 422,
                userInfo: [NSLocalizedDescriptionKey: "Claude Code trust choice is not valid"]
            )
        }
        // The phone can answer within milliseconds of the dialog text arriving,
        // before Claude Code has put the terminal into raw mode; a keystroke
        // sent that early waits in the line buffer until the next Return and
        // the dialog looks ignored. Let the screen settle first.
        var waited: TimeInterval = 0
        while timeSinceLastOutput() < Self.dialogSettleSeconds, waited < Self.dialogSettleTimeoutSeconds {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        // The dialog's option order and default differ between builds and
        // launch contexts ("❯ 1. Yes, I trust" first in a terminal, "❯ No,
        // exit" first under the host's PTY), so never press a number or a bare
        // Return: move the highlight until it sits on the wanted option, read
        // the redraw back, and only then confirm.
        let wanted: TrustDialogSelection = choice == Self.trustChoiceId ? .trust : .exit
        var moves = 0
        while Self.trustDialogSelection(in: recentOutputTail(maxLength: 4096)) != wanted {
            guard moves < 4 else {
                throw NSError(
                    domain: "ClaudeCodeAdapter",
                    code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "Could not move Claude Code's trust dialog to “\(wanted.label)”."]
                )
            }
            try await super.sendInput("\u{1b}[B", submit: false)
            moves += 1
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        // Drop the dialog text first so the confirm is not refused as a
        // prompt typed over the dialog, and so a stale match cannot republish
        // the decision after it was answered.
        clearOutputBuffer()
        beginStartupGrace()
        transitionTo(.working, detail: wanted == .trust ? "Opening the folder" : "Exiting")
        try await super.sendInput("\r", submit: false)
    }

    enum TrustDialogSelection: Equatable {
        case trust
        case exit

        var label: String {
            switch self {
            case .trust: return "Yes, I trust this folder"
            case .exit: return "No, exit"
            }
        }
    }

    /// Which option the dialog's highlight ("❯") currently sits on, read from
    /// the newest rendering in the output; nil when it cannot be told.
    static func trustDialogSelection(in text: String) -> TrustDialogSelection? {
        let compact = text.lowercased().filter { !$0.isWhitespace }
        guard let marker = compact.range(of: "❯", options: .backwards) else { return nil }
        let after = compact[marker.upperBound...].prefix(40)
        if after.hasPrefix("1.") || after.hasPrefix("2.") {
            // Numbered variant: "❯ 1. Yes, I trust…" / "❯ 2. No, exit".
            return after.dropFirst(2).hasPrefix("yes") ? .trust : (after.dropFirst(2).hasPrefix("no,exit") ? .exit : nil)
        }
        if after.hasPrefix("yes,itrust") { return .trust }
        if after.hasPrefix("no,exit") { return .exit }
        return nil
    }

    /// How long the dialog must have been quiet before it is answered, and
    /// the most the answer waits for that.
    static let dialogSettleSeconds: TimeInterval = 0.6
    static let dialogSettleTimeoutSeconds: TimeInterval = 3

    public override func runtimeControls() -> AgentRuntimeControls? {
        runtimeLock.lock()
        let modelId = runtimeModelId
        let effort = runtimeEffort
        runtimeLock.unlock()

        return AgentRuntimeControls(
            modelId: modelId ?? "",
            modelLabel: modelLabel(modelId),
            modelOptions: Self.modelOptions,
            reasoningEffort: effort ?? "",
            reasoningEffortLabel: effortLabel(effort),
            reasoningEffortOptions: Self.effortOptions,
            supportsModelSelection: true,
            supportsReasoningEffort: true,
            editable: true,
            appliesOn: .immediate,
            note: "Restarts Claude Code"
        )
    }

    public override func updateRuntimeSettings(_ update: AgentRuntimeSettingsUpdate) async throws {
        let previousModelId = currentRuntimeModelId()
        let previousEffort = currentRuntimeEffort()
        let previousArguments = arguments
        let previousCwd = cwd
        let nextRuntime: (modelId: String?, effort: String?)
        do {
            nextRuntime = try runtimeSelection(applying: update)
        } catch {
            emitSnapshot(detail: "settings failed")
            throw error
        }
        let launch = currentLaunch()
        do {
            try restartProcess(
                arguments: runtimeArguments(
                    base: launch.arguments,
                    modelId: nextRuntime.modelId,
                    effort: nextRuntime.effort
                ),
                cwd: launch.cwd
            )
        } catch {
            setRuntime(modelId: previousModelId, effort: previousEffort)
            configureLaunch(arguments: previousArguments, cwd: previousCwd)
            emitSnapshot(detail: "settings failed")
            throw error
        }
        setRuntime(modelId: nextRuntime.modelId, effort: nextRuntime.effort)
        emitSnapshot(detail: "settings updated")
    }

    private func runtimeSelection(applying update: AgentRuntimeSettingsUpdate) throws -> (modelId: String?, effort: String?) {
        runtimeLock.lock()
        defer { runtimeLock.unlock() }

        var modelId = runtimeModelId
        var effort = runtimeEffort
        if let value = update.modelId {
            modelId = try Self.normalizedRuntimeValue(value, fieldName: "Claude Code model")
        }
        if let value = update.reasoningEffort {
            effort = try Self.normalizedReasoningEffort(value)
        }
        return (modelId, effort)
    }

    private func currentRuntimeModelId() -> String? {
        runtimeLock.lock()
        defer { runtimeLock.unlock() }
        return runtimeModelId
    }

    private func currentRuntimeEffort() -> String? {
        runtimeLock.lock()
        defer { runtimeLock.unlock() }
        return runtimeEffort
    }

    private func setRuntime(modelId: String?, effort: String?) {
        runtimeLock.lock()
        runtimeModelId = modelId
        runtimeEffort = effort
        runtimeLock.unlock()
    }

    public override func selectTarget(_ targetID: String) async throws {
        refreshClaudeSessions()
        guard let target = summary(forSessionId: targetID) else {
            throw NSError(
                domain: "ClaudeCodeAdapter",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Claude Code session \(targetID) was not found."]
            )
        }
        let resume = ["--resume", target.sessionId]
        try restartProcess(arguments: runtimeArguments(base: resume), cwd: target.workspaceRoot)
        setLiveSession(LiveSession(id: target.sessionId, arguments: resume, cwd: target.workspaceRoot))
        refreshClaudeSessions()
        emitSnapshot(detail: "resumed \(selectedLabel(target))")
    }

    public override func snapshotMessages(from buffer: String) -> [AgentChatMessage] {
        sessionLock.lock()
        let messages = currentMessages
        // Every snapshot carries the current PTY buffer, which makes this the
        // one place the adapter sees output arrive.
        if !composerSeenSinceLaunch, Self.showsComposer(buffer) {
            composerSeenSinceLaunch = true
        }
        sessionLock.unlock()
        if !messages.isEmpty {
            return messages
        }
        return super.snapshotMessages(from: buffer)
    }

    public override func snapshotAvailableTargets() -> [AgentTargetOption]? {
        sessionLock.lock()
        let summaries = sessionSummaries
        let selectedId = selectedSessionId
        sessionLock.unlock()

        guard !summaries.isEmpty else { return nil }
        return summaries.map { summary in
            let projectLabel = displayWorkspace(root: summary.workspaceRoot)
            let threadLabel = summary.threadName ?? projectLabel
            return AgentTargetOption(
                targetId: summary.sessionId,
                label: projectLabel,
                subtitle: threadLabel,
                selected: summary.sessionId == selectedId,
                projectId: summary.workspaceRoot,
                projectLabel: projectLabel,
                projectPath: summary.workspaceRoot,
                threadId: summary.sessionId,
                threadLabel: threadLabel,
                targetKind: "thread",
                lastActivityUnixMs: Int64(summary.modifiedAt.timeIntervalSince1970 * 1000),
                isActive: summary.sessionId == selectedId,
                supportsNewThread: false
            )
        }
    }

    private func handleHook(_ event: ClaudeCodeHookListener.Event) {
        refreshClaudeSessions()
        // A hook marks the end of a turn or a prompt for input; the transcript
        // has new content even when status and detail repeat, so always emit.
        // Stop payloads carry no message, so the summary is the raw event name.
        switch event.kind {
        case .stop:
            transitionTo(.done, detail: event.summary == "Stop" ? "Response ready" : event.summary, forceEmit: true)
        case .subagentStop:
            transitionTo(.working, detail: "Claude is working", forceEmit: true)
        case .notification where event.notificationType == ClaudeCodeHookListener.idlePromptNotification:
            // Claude is merely idle after a finished turn; the turn's own
            // Stop already set the status, so only publish the fresh transcript.
            emitSnapshotKeepingDetail()
        case .notification:
            transitionTo(.waitingInput, detail: event.summary, forceEmit: true)
        }
    }

    private static let modelOptions = [
        AgentRuntimeOption(id: "", label: "Default"),
        AgentRuntimeOption(id: "claude-opus-4-8", label: "Opus 4.8"),
        AgentRuntimeOption(id: "claude-opus-4-7", label: "Opus 4.7"),
        AgentRuntimeOption(id: "claude-sonnet-4-6", label: "Sonnet 4.6"),
        AgentRuntimeOption(id: "claude-opus-4-6", label: "Opus 4.6"),
        AgentRuntimeOption(id: "claude-opus-4-5-20251101", label: "Opus 4.5"),
        AgentRuntimeOption(id: "claude-haiku-4-5-20251001", label: "Haiku 4.5"),
        AgentRuntimeOption(id: "claude-sonnet-4-5-20250929", label: "Sonnet 4.5"),
    ]

    private static let effortOptions = [
        AgentRuntimeOption(id: "", label: "Default"),
        AgentRuntimeOption(id: "low", label: "Low"),
        AgentRuntimeOption(id: "medium", label: "Medium"),
        AgentRuntimeOption(id: "high", label: "High"),
        AgentRuntimeOption(id: "xhigh", label: "Extra high"),
        AgentRuntimeOption(id: "max", label: "Max"),
    ]

    static func normalizedRuntimeValue(_ value: String, fieldName: String = "Claude Code setting") throws -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let forbiddenCharacters = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: "\"'`"))
        if trimmed.rangeOfCharacter(from: forbiddenCharacters) != nil {
            throw NSError(
                domain: "ClaudeCodeAdapter",
                code: -2,
                userInfo: [
                    NSLocalizedDescriptionKey: "\(fieldName) must be one value without spaces or quotes.",
                ]
            )
        }

        return trimmed
    }

    static func normalizedReasoningEffort(_ value: String) throws -> String? {
        guard let effort = try normalizedRuntimeValue(value, fieldName: "Claude Code effort") else {
            return nil
        }
        let allowedEfforts = Set(effortOptions.map(\.id).filter { !$0.isEmpty })
        guard allowedEfforts.contains(effort) else {
            throw NSError(
                domain: "ClaudeCodeAdapter",
                code: -3,
                userInfo: [
                    NSLocalizedDescriptionKey: "Claude Code effort must be one of low, medium, high, xhigh, or max.",
                ]
            )
        }
        return effort
    }

    /// True when the caller already pinned a session on the command line, so
    /// the adapter must not inject its own `--session-id`.
    static func hasExplicitSessionArgument(_ arguments: [String]) -> Bool {
        let sessionFlags: Set<String> = ["--resume", "-r", "--continue", "-c", "--session-id", "--fork-session"]
        return arguments.contains { argument in
            sessionFlags.contains(argument) || sessionFlags.contains { argument.hasPrefix($0 + "=") }
        }
    }

    /// The session id a caller pinned via `--resume <id>`, `-r <id>`, or
    /// `--session-id <id>` (space- or `=`-separated), if any. `--continue`
    /// names no id, so it yields nil.
    static func explicitSessionId(in arguments: [String]) -> String? {
        let idFlags: Set<String> = ["--resume", "-r", "--session-id"]
        for (index, argument) in arguments.enumerated() {
            if idFlags.contains(argument) {
                let next = arguments.indices.contains(index + 1) ? arguments[index + 1] : ""
                return next.hasPrefix("-") || next.isEmpty ? nil : next
            }
            for flag in idFlags where argument.hasPrefix(flag + "=") {
                let value = String(argument.dropFirst(flag.count + 1))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private func runtimeArguments(base: [String]) -> [String] {
        runtimeLock.lock()
        let modelId = runtimeModelId
        let effort = runtimeEffort
        runtimeLock.unlock()

        return runtimeArguments(base: base, modelId: modelId, effort: effort)
    }

    private func runtimeArguments(base: [String], modelId: String?, effort: String?) -> [String] {
        var args: [String] = []
        if let modelId, !modelId.isEmpty {
            args += ["--model", modelId]
        }
        if let effort, !effort.isEmpty {
            args += ["--effort", effort]
        }
        return args + base
    }

    /// The launch that keeps the PTY on its live session. A session we created
    /// with `--session-id` is resumed instead once its transcript exists,
    /// because Claude Code refuses to create a session id that is already in use.
    private func currentLaunch() -> (arguments: [String], cwd: String?) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        let arguments = currentLaunchArgumentsLocked()
        guard let live = liveSession else {
            return (arguments, cwd)
        }
        return (arguments, live.cwd)
    }

    private func modelLabel(_ modelId: String?) -> String {
        guard let modelId, !modelId.isEmpty else { return "Default" }
        return Self.modelOptions.first { $0.id == modelId }?.label ?? modelId
    }

    private func effortLabel(_ effort: String?) -> String {
        guard let effort, !effort.isEmpty else { return "Default" }
        return Self.effortOptions.first { $0.id == effort }?.label ?? effort
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                if self.refreshClaudeSessions() {
                    self.emitSnapshotKeepingDetail()
                }
            }
        }
    }

    /// Re-reads CLI-owned sessions and re-derives the selection. Returns true
    /// when the published state (targets, selection, or messages) changed.
    @discardableResult
    private func refreshClaudeSessions() -> Bool {
        let summaries = ClaudeCodeSessionStore.loadSummaries(
            projectsRoot: projectsRoot,
            owner: .cli,
            cache: summaryCache
        )

        sessionLock.lock()
        let selected: ClaudeCodeSessionSummary?
        if let live = liveSession {
            // Selection follows the PTY's session; until its transcript exists
            // there is nothing to show but the raw terminal output.
            selected = summaries.first { $0.sessionId == live.id }
        } else {
            selected = summaries.first { $0.sessionId == selectedSessionId } ?? summaries.first
        }
        let selectionChanged = selected?.sessionId != selectedSessionId
        let changed = summaries != sessionSummaries || selectionChanged
        sessionSummaries = summaries
        selectedSessionId = selected?.sessionId
        if selectionChanged || selected == nil {
            // Never show one session's messages under another session's name.
            currentMessages = []
            parsedTranscript = nil
        }
        let needsParse = selected.map { selected in
            parsedTranscript?.path != selected.path || parsedTranscript?.modifiedAt != selected.modifiedAt
        } ?? false
        sessionLock.unlock()

        guard let selected, needsParse else { return changed }
        let parsed = ClaudeCodeSessionParser.parseRecentFile(
            at: URL(fileURLWithPath: selected.path),
            agentID: agentID,
            maxMessages: AgentHistoryLimits.snapshotMessageCount
        )
        // A transient read failure while Claude Code rewrites the file must
        // not blank the chat; keep the last good messages and retry next tick.
        guard let parsed else { return changed }

        sessionLock.lock()
        let messagesUpdated = selectedSessionId == selected.sessionId
        if messagesUpdated {
            currentMessages = parsed.messages
            parsedTranscript = (selected.path, selected.modifiedAt)
        }
        sessionLock.unlock()
        return changed || messagesUpdated
    }

    private func selectedSession() -> ClaudeCodeSessionSummary? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return sessionSummaries.first { $0.sessionId == selectedSessionId }
    }

    private func summary(forSessionId sessionId: String) -> ClaudeCodeSessionSummary? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return sessionSummaries.first { $0.sessionId == sessionId }
    }

    private func liveSessionId() -> String? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return liveSession?.id
    }

    private func setLiveSession(_ session: LiveSession) {
        sessionLock.lock()
        liveSession = session
        sessionLock.unlock()
    }

    private func releaseHookSubscription() {
        if let hookSubscription {
            hookRouter.unsubscribe(hookSubscription)
        }
        hookSubscription = nil
    }

    private func selectedLabel(_ summary: ClaudeCodeSessionSummary) -> String {
        summary.threadName ?? displayWorkspace(root: summary.workspaceRoot)
    }

    private func displayWorkspace(root: String) -> String {
        let url = URL(fileURLWithPath: root)
        let last = url.lastPathComponent
        return last.isEmpty ? root : last
    }

    /// Shared with the `claude-code` RemoteAppDefinition so availability
    /// detection and process launch agree on where `claude` may live.
    public static func executableCandidates() -> [String] {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        return [
            "claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/bin/claude",
            "\(home)/.cargo/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.npm-global/bin/claude",
        ]
    }

    private static func resolveExecutable() -> String {
        for candidate in executableCandidates() where canLaunch(candidate) {
            return candidate
        }
        return "claude"
    }

    private static func canLaunch(_ executable: String) -> Bool {
        let fileManager = FileManager.default
        if executable.contains("/") {
            return fileManager.isExecutableFile(atPath: executable)
        }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":").map(String.init) {
            let fullPath = (directory as NSString).appendingPathComponent(executable)
            if fileManager.isExecutableFile(atPath: fullPath) {
                return true
            }
        }
        return false
    }
}
