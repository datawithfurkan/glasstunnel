import Foundation
import GTProtocol
import GTSecurity

/// Adapter for the Codex CLI. Pure PTY wrapper: Codex doesn't expose hooks,
/// so we require both output silence and a returned prompt before marking a
/// turn done.
public final class CodexAdapter: PTYAdapterBase, @unchecked Sendable {
    public override var idleThresholdSeconds: Double { 2.5 }
    public override var collapsesTerminalRewritesForLog: Bool { true }
    public override var submittedInputSettleNanoseconds: UInt64 { 80_000_000 }

    private static let updatePromptRequestId = "codex-cli-update-prompt"
    private static let updatePromptQuestionId = "codex-cli-update-choice"
    private static let promptSuffixes = [">", "$", "#"]
    private let runtimeLock = NSLock()
    private let promptStateLock = NSLock()
    private var runtimeSelection: CodexRuntimeSelection
    private var promptInFlight = false

    public init(
        agentID: AgentID = "codex",
        label: String = "Codex CLI",
        executable: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:],
        cwd: String? = nil,
        redactor: SecretRedactor = SecretRedactor()
    ) {
        let selection = CodexRuntimeCatalog.defaultSelection()
        let launchCwd = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        self.runtimeSelection = selection
        super.init(
            agentID: agentID,
            kind: .codexCli,
            label: label,
            executable: executable ?? CodexAdapter.resolveExecutable(),
            arguments: arguments.isEmpty ? CodexRuntimeCatalog.launchArguments(selection: selection) : arguments,
            environment: environment,
            cwd: launchCwd,
            redactor: redactor
        )
    }

    public override func runtimeControls() -> AgentRuntimeControls? {
        runtimeLock.lock()
        let selection = runtimeSelection
        runtimeLock.unlock()
        return CodexRuntimeCatalog.controls(
            selection: selection,
            editable: true,
            appliesOn: .immediate,
            note: "Restarts Codex CLI. App and plugin integrations are off."
        )
    }

    public override func start() async throws {
        setPromptInFlight(false)
        try await super.start()
        transitionTo(.working, detail: "starting Codex", forceEmit: true)
    }

    public override func sendInput(_ text: String, submit: Bool) async throws {
        if submit {
            setPromptInFlight(true)
        }
        do {
            try await super.sendInput(text, submit: submit)
        } catch {
            if submit {
                setPromptInFlight(false)
            }
            throw error
        }
    }

    public override func interrupt() async throws {
        try await super.interrupt()
        setPromptInFlight(false)
    }

    public override func didExitProcess(status: Int32) {
        _ = status
        setPromptInFlight(false)
    }

    public override func updateRuntimeSettings(_ update: AgentRuntimeSettingsUpdate) async throws {
        let previousSelection = currentRuntimeSelection()
        let previousArguments = arguments
        let previousCwd = cwd
        let selection: CodexRuntimeSelection
        do {
            try rejectRuntimeSettingsUpdateIfWorking()
            selection = try runtimeSelection(applying: update)
        } catch {
            emitSnapshot(detail: "settings failed")
            throw error
        }
        do {
            try restartProcess(
                arguments: CodexRuntimeCatalog.launchArguments(selection: selection),
                cwd: previousCwd
            )
        } catch {
            setRuntimeSelection(previousSelection)
            configureLaunch(arguments: previousArguments, cwd: previousCwd)
            emitSnapshot(detail: "settings failed")
            throw error
        }
        setRuntimeSelection(selection)
        setPromptInFlight(false)
        transitionTo(.working, detail: "starting Codex", forceEmit: true)
    }

    private func runtimeSelection(applying update: AgentRuntimeSettingsUpdate) throws -> CodexRuntimeSelection {
        runtimeLock.lock()
        defer { runtimeLock.unlock() }
        var selection = runtimeSelection
        if let modelId = update.modelId { selection.modelId = try Self.normalizedRuntimeValue(modelId, fieldName: "Codex model") }
        if let effort = update.reasoningEffort { selection.reasoningEffort = try Self.normalizedReasoningEffort(effort) }
        if let fast = update.fastMode { selection.fastMode = fast }
        return selection
    }

    private func currentRuntimeSelection() -> CodexRuntimeSelection {
        runtimeLock.lock()
        defer { runtimeLock.unlock() }
        return runtimeSelection
    }

    private func setRuntimeSelection(_ selection: CodexRuntimeSelection) {
        runtimeLock.lock()
        runtimeSelection = selection
        runtimeLock.unlock()
    }

    static func normalizedRuntimeValue(_ value: String, fieldName: String = "Codex setting") throws -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let forbiddenCharacters = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: "\"'`"))
        if trimmed.rangeOfCharacter(from: forbiddenCharacters) != nil {
            throw NSError(
                domain: "CodexAdapter",
                code: -2,
                userInfo: [
                    NSLocalizedDescriptionKey: "\(fieldName) must be one value without spaces or quotes.",
                ]
            )
        }

        return trimmed
    }

    static func normalizedReasoningEffort(_ value: String) throws -> String? {
        guard let effort = try normalizedRuntimeValue(value, fieldName: "Codex reasoning effort") else {
            return nil
        }
        guard ["low", "medium", "high", "xhigh"].contains(effort) else {
            throw NSError(
                domain: "CodexAdapter",
                code: -3,
                userInfo: [
                    NSLocalizedDescriptionKey: "Codex reasoning effort must be one of low, medium, high, or xhigh.",
                ]
            )
        }
        return effort
    }

    public override func statusAfterOutputSilence(buffer: String, silenceDuration: TimeInterval) -> (status: AgentStatus, detail: String) {
        if Self.isUpdatePrompt(buffer) {
            return (.waitingInput, "Codex update prompt")
        }
        if !isPromptInFlight(), Self.isReadyPromptTail(buffer) {
            return (.done, "prompt returned")
        }
        return (.working, "waiting for Codex output")
    }

    private func isPromptInFlight() -> Bool {
        promptStateLock.lock()
        defer { promptStateLock.unlock() }
        return promptInFlight
    }

    private func setPromptInFlight(_ value: Bool) {
        promptStateLock.lock()
        promptInFlight = value
        promptStateLock.unlock()
    }

    public override func respondToInputRequest(_ response: AgentInputRequestResponse) async throws {
        guard response.requestId == Self.updatePromptRequestId else {
            let summary = response.answers
                .map { "\($0.questionId): \($0.choiceIds.joined(separator: ", "))" }
                .joined(separator: "\n")
            try await sendInput(summary, submit: true)
            return
        }

        let choiceId = response.answers
            .first(where: { $0.questionId == Self.updatePromptQuestionId })?
            .choiceIds
            .first ?? "2"
        guard ["1", "2", "3"].contains(choiceId) else {
            throw NSError(
                domain: "CodexAdapter",
                code: 422,
                userInfo: [NSLocalizedDescriptionKey: "Codex update choice is not valid"]
            )
        }
        let input: String
        switch choiceId {
        case "1":
            input = ""
        case "2":
            input = "\u{001B}[B"
        case "3":
            input = "\u{001B}[B\u{001B}[B"
        default:
            input = choiceId
        }
        clearOutputBuffer()
        try await sendInput(input, submit: true)
        setPromptInFlight(false)
    }

    public override func snapshotMessages(from buffer: String) -> [AgentChatMessage] {
        super.snapshotMessages(from: buffer)
    }

    public override func snapshotPendingInputRequest() -> AgentInputRequest? {
        guard Self.isUpdatePrompt(recentOutputTail(maxLength: 4096)) else {
            return nil
        }
        return Self.updatePromptInputRequest()
    }

    static func updatePromptInputRequest() -> AgentInputRequest {
        return AgentInputRequest(
            requestId: Self.updatePromptRequestId,
            questions: [
                AgentInputRequestQuestion(
                    questionId: Self.updatePromptQuestionId,
                    header: "Codex update",
                    question: "Codex CLI is asking how to handle an available update.",
                    choices: [
                        AgentInputRequestChoice(
                            choiceId: "2",
                            label: "Skip",
                            description: "Continue this session now.",
                            recommended: true
                        ),
                        AgentInputRequestChoice(
                            choiceId: "3",
                            label: "Skip this version",
                            description: "Do not ask again for this version."
                        ),
                        AgentInputRequestChoice(
                            choiceId: "1",
                            label: "Update now",
                            description: "Run the Codex CLI updater on this Mac."
                        ),
                    ]
                ),
            ]
        )
    }

    static func isUpdatePrompt(_ text: String) -> Bool {
        let compact = text
            .lowercased()
            .filter { !$0.isWhitespace }
        return compact.contains("updateavailable") &&
            compact.contains("1.updatenow") &&
            compact.contains("2.skip") &&
            compact.contains("3.skipuntilnextversion") &&
            compact.contains("pressentertocontinue")
    }

    static func isReadyPromptTail(_ text: String) -> Bool {
        guard let lastLine = lastNonEmptyLine(in: text) else {
            return false
        }

        if promptSuffixes.contains(lastLine) {
            return true
        }

        if promptSuffixes.contains(where: { suffix in
            lastLine.hasSuffix(" \(suffix)")
        }) {
            return true
        }

        return hasCollapsedNoAltScreenPrompt(in: text)
    }

    private static func hasCollapsedNoAltScreenPrompt(in text: String) -> Bool {
        guard let promptRange = text.range(of: "›", options: .backwards) else {
            return false
        }

        let promptTail = text[promptRange.lowerBound...].lowercased()
        let knownReadyPrompts = [
            "use /skills to list available skills",
            "write tests for @filename",
            "run /review on my current changes",
        ]
        let looksLikeCodexStatusPrompt = promptTail.contains(" · ") &&
            (promptTail.contains("gpt-") || promptTail.contains("codex"))
        guard knownReadyPrompts.contains(where: { promptTail.contains($0) }) ||
            looksLikeCodexStatusPrompt else {
            return false
        }

        if let interruptRange = text.range(of: "esc to interrupt", options: [.caseInsensitive, .backwards]) {
            return promptRange.lowerBound > interruptRange.lowerBound
        }

        return true
    }

    public static func executableCandidates() -> [String] {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        return [
            "codex",
            "\(home)/.codex-cli/bin/codex",
            "\(home)/.volta/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.cargo/bin/codex",
            "\(home)/.bun/bin/codex",
            "\(home)/.npm-global/bin/codex",
        ]
    }

    private static func resolveExecutable() -> String {
        let candidates = executableCandidates()
        for candidate in candidates where canLaunch(candidate) {
            return candidate
        }
        return "codex"
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

    private static func lastNonEmptyLine(in text: String) -> String? {
        let normalized = text.replacingOccurrences(of: "\r", with: "\n")
        return normalized
            .components(separatedBy: "\n")
            .last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
