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
public final class ClaudeCodeAdapter: PTYAdapterBase, @unchecked Sendable {
    private let hookInstaller: ClaudeCodeHookInstaller
    private let hookListener: ClaudeCodeHookListener
    private let projectsRoot: URL
    private let sessionLock = NSLock()
    private let runtimeLock = NSLock()
    private let initialArguments: [String]
    private var sessionSummaries: [ClaudeCodeSessionSummary] = []
    private var selectedSessionId: String?
    private var currentMessages: [AgentChatMessage] = []
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
        projectsRoot: URL? = nil
    ) {
        self.hookInstaller = ClaudeCodeHookInstaller()
        self.hookListener = ClaudeCodeHookListener()
        self.projectsRoot = projectsRoot ?? ClaudeCodeSessionStore.defaultProjectsRoot()
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

    public override func start() async throws {
        refreshClaudeSessions()
        if let selected = selectedSession() {
            configureLaunch(arguments: runtimeArguments(base: ["--resume", selected.sessionId]), cwd: selected.workspaceRoot)
        }

        try hookInstaller.installIfNeeded()
        try hookListener.start()
        hookListener.onHook = { [weak self] event in
            self?.handleHook(event)
        }
        try await super.start()
        startRefreshLoop()
    }

    public override func stop() async {
        refreshTask?.cancel()
        refreshTask = nil
        hookListener.stop()
        await super.stop()
    }

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
        refreshClaudeSessions(preferredSessionId: targetID)
        guard let selected = selectedSession() else {
            throw NSError(
                domain: "ClaudeCodeAdapter",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Claude Code session \(targetID) was not found."]
            )
        }
        try restartProcess(arguments: runtimeArguments(base: ["--resume", selected.sessionId]), cwd: selected.workspaceRoot)
        refreshClaudeSessions(preferredSessionId: targetID)
        emitSnapshot(detail: "resumed \(selectedLabel(selected))")
    }

    public override func snapshotMessages(from buffer: String) -> [AgentChatMessage] {
        sessionLock.lock()
        let messages = currentMessages
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
        if !event.session.isEmpty {
            refreshClaudeSessions(preferredSessionId: event.session)
        }
        switch event.kind {
        case .stop:
            transitionTo(.done, detail: event.summary)
        case .subagentStop:
            transitionTo(.working, detail: "subagent finished: \(event.summary)")
        case .notification:
            transitionTo(.waitingInput, detail: event.summary)
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

    private func currentLaunch() -> (arguments: [String], cwd: String?) {
        if let selected = selectedSession() {
            return (["--resume", selected.sessionId], selected.workspaceRoot)
        }
        return (initialArguments, cwd)
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
                self.refreshClaudeSessions()
                self.emitSnapshot(detail: "Claude context synced")
            }
        }
    }

    private func refreshClaudeSessions(preferredSessionId: String? = nil) {
        let summaries = ClaudeCodeSessionStore.loadSummaries(projectsRoot: projectsRoot)
        let nextSelectedId = preferredSessionId
            ?? selectedSessionId
            ?? summaries.first?.sessionId
        let selected = summaries.first { $0.sessionId == nextSelectedId } ?? summaries.first
        let parsed = selected.flatMap {
            ClaudeCodeSessionParser.parseRecentFile(
                at: URL(fileURLWithPath: $0.path),
                agentID: agentID,
                maxMessages: AgentHistoryLimits.snapshotMessageCount
            )
        }

        sessionLock.lock()
        sessionSummaries = summaries
        selectedSessionId = selected?.sessionId
        currentMessages = parsed?.messages ?? []
        sessionLock.unlock()
    }

    private func selectedSession() -> ClaudeCodeSessionSummary? {
        sessionLock.lock()
        let summaries = sessionSummaries
        let selectedId = selectedSessionId
        sessionLock.unlock()
        return summaries.first { $0.sessionId == selectedId } ?? summaries.first
    }

    private func selectedLabel(_ summary: ClaudeCodeSessionSummary) -> String {
        summary.threadName ?? displayWorkspace(root: summary.workspaceRoot)
    }

    private func displayWorkspace(root: String) -> String {
        let url = URL(fileURLWithPath: root)
        let last = url.lastPathComponent
        return last.isEmpty ? root : last
    }

    private static func resolveExecutable() -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/bin/claude",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "claude"
    }
}
