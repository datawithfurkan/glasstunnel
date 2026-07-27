import Foundation
import GTProtocol
import GTSecurity

/// Adapter for OpenCode. Also a PTY wrapper with a slightly different prompt
/// regex; shares almost everything with CodexAdapter.
public final class OpenCodeAdapter: PTYAdapterBase, @unchecked Sendable {
    public override var idleThresholdSeconds: Double { 2.0 }

    private let databaseURL: URL
    private let sessionLock = NSLock()
    private let runtimeLock = NSLock()
    private let runProcessLock = NSLock()
    private var sessionSummaries: [OpenCodeSessionSummary] = []
    private var selectedSessionId: String?
    private var currentMessages: [AgentChatMessage] = []
    private var latestMessageState: OpenCodeMessageState?
    private var refreshTask: Task<Void, Never>?
    private var processStarted = false
    private var processExited = false
    private var restartAfterInterrupt = false
    private var runtimeModelId: String?
    private var currentRunProcess: Process?
    private var currentRunInterrupted = false
    private var currentRunStopped = false

    public init(
        agentID: AgentID = "opencode",
        label: String = "OpenCode",
        executable: String? = nil,
        arguments: [String] = [],
        redactor: SecretRedactor = SecretRedactor(),
        databaseURL: URL? = nil
    ) {
        self.databaseURL = databaseURL ?? OpenCodeSessionStore.defaultDatabaseURL()
        super.init(
            agentID: agentID,
            kind: .openCode,
            label: label,
            executable: executable ?? OpenCodeAdapter.resolveExecutable(),
            arguments: arguments,
            environment: [:],
            cwd: nil,
            redactor: redactor
        )
    }

    public override func start() async throws {
        refreshOpenCodeSessions()

        if let selected = selectedSession() {
            configureLaunch(arguments: runtimeArguments(base: ["--session", selected.sessionId]), cwd: selected.directory)
        }

        if OpenCodeAdapter.canLaunch(executable) {
            try await super.start()
            processStarted = true
            processExited = false
            restartAfterInterrupt = false
        } else {
            emitSnapshot(detail: "OpenCode CLI not found; showing cached sessions")
        }
        startRefreshLoop()
    }

    public override func stop() async {
        refreshTask?.cancel()
        refreshTask = nil
        stopCurrentRunProcess()
        processStarted = false
        processExited = false
        restartAfterInterrupt = false
        await super.stop()
    }

    public override func sendInput(_ text: String, submit: Bool) async throws {
        if submit && shouldUseRunCommandForSubmittedInput() {
            try await runSubmittedInputWithRunCommand(text)
            return
        }
        guard processStarted else {
            throw NSError(
                domain: "OpenCodeAdapter",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenCode CLI is not running. Install or expose the `opencode` executable to send prompts."]
            )
        }
        try await super.sendInput(text, submit: submit)
    }

    public override func interrupt() async throws {
        if interruptCurrentRunProcess() {
            restartAfterInterrupt = true
            return
        }
        try await super.interrupt()
        restartAfterInterrupt = true
    }

    public override func didExitProcess(status: Int32) {
        _ = status
        processStarted = false
        processExited = true
    }

    public override func runtimeControls() -> AgentRuntimeControls? {
        runtimeLock.lock()
        let modelId = runtimeModelId
        runtimeLock.unlock()

        return AgentRuntimeControls(
            modelId: modelId ?? "",
            modelLabel: Self.modelLabel(modelId),
            modelOptions: Self.modelOptions,
            reasoningEffortOptions: [],
            supportsModelSelection: true,
            editable: true,
            appliesOn: .immediate,
            note: "Choose or type provider/model"
        )
    }

    public override func updateRuntimeSettings(_ update: AgentRuntimeSettingsUpdate) async throws {
        let previousModelId = currentRuntimeModelId()
        let previousArguments = arguments
        let previousCwd = cwd
        let nextModelId: String?
        do {
            try rejectRuntimeSettingsUpdateIfWorking()
            nextModelId = try runtimeModelId(applying: update)
        } catch {
            emitSnapshot(detail: "settings failed")
            throw error
        }

        guard OpenCodeAdapter.canLaunch(executable) else {
            setRuntimeModelId(nextModelId)
            emitSnapshot(detail: "settings saved; OpenCode CLI not found")
            return
        }

        let selected = selectedSession()
        let base = selected.map { ["--session", $0.sessionId] } ?? []
        do {
            try restartProcess(arguments: runtimeArguments(base: base, modelId: nextModelId), cwd: selected?.directory)
        } catch {
            setRuntimeModelId(previousModelId)
            configureLaunch(arguments: previousArguments, cwd: previousCwd)
            emitSnapshot(detail: "settings failed")
            throw error
        }
        setRuntimeModelId(nextModelId)
        processStarted = true
        emitSnapshot(detail: "settings updated")
    }

    private func runtimeModelId(applying update: AgentRuntimeSettingsUpdate) throws -> String? {
        if let modelId = update.modelId {
            return try Self.normalizedRuntimeValue(modelId)
        }
        return currentRuntimeModelId()
    }

    private func currentRuntimeModelId() -> String? {
        runtimeLock.lock()
        defer { runtimeLock.unlock() }
        return runtimeModelId
    }

    private func setRuntimeModelId(_ modelId: String?) {
        runtimeLock.lock()
        runtimeModelId = modelId
        runtimeLock.unlock()
    }

    private func shouldUseRunCommandForSubmittedInput() -> Bool {
        // Remote OpenCode prompts need process exit status and stderr to surface
        // provider/model failures. The interactive TUI can accept text while
        // leaving the web UI stuck in a running state, so submitted prompts use
        // `opencode run` and then reopen the TUI for session visibility.
        true
    }

    private func runSubmittedInputWithRunCommand(_ text: String) async throws {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw NSError(
                domain: "OpenCodeAdapter",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "OpenCode prompt is empty."]
            )
        }

        guard OpenCodeAdapter.canLaunch(executable) else {
            throw NSError(
                domain: "OpenCodeAdapter",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "OpenCode CLI not found."]
            )
        }
        refreshOpenCodeSessions()
        let selectedBeforeRun = selectedSession()

        processStarted = false
        processExited = false
        restartAfterInterrupt = false
        await super.stop()
        transitionTo(.working, detail: "running OpenCode prompt", forceEmit: true)

        let result: OpenCodeRunResult
        do {
            result = try await runOpenCodePrompt(
                prompt,
                arguments: runtimeRunArguments(sessionId: selectedBeforeRun?.sessionId),
                cwd: selectedBeforeRun?.directory
            )
        } catch {
            try? restartOpenCodeTUI(preferredSessionId: selectedBeforeRun?.sessionId)
            transitionTo(.error, detail: error.localizedDescription, forceEmit: true)
            throw error
        }

        if result.stopped {
            return
        }

        if result.interrupted {
            try restartOpenCodeTUI(preferredSessionId: selectedBeforeRun?.sessionId)
            restartAfterInterrupt = true
            transitionTo(.idle, detail: "interrupted", forceEmit: true)
            return
        }

        guard result.status == 0 else {
            let detail = runFailureDetail(status: result.status, output: result.output)
            let error = NSError(
                domain: "OpenCodeAdapter",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
            transitionTo(.error, detail: detail, forceEmit: true)
            throw error
        }

        try restartOpenCodeTUI(preferredSessionId: selectedBeforeRun?.sessionId)
        restartAfterInterrupt = false
        emitSnapshot(detail: "prompt returned")
    }

    private func runFailureDetail(status: Int32, output: String) -> String {
        let (redactedOutput, _) = redactOutputForSnapshot(output)
        let normalized = ANSIStripper.strip(redactedOutput)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()

        if lower.contains("model is disabled") ||
            lower.contains("disabled model") ||
            lower.range(of: #"model\b.*\bdisabled"#, options: .regularExpression) != nil {
            return "Provider/model is disabled for this account."
        }

        if lower.contains("providermodelnotfounderror") ||
            lower.contains("model not found") ||
            lower.range(of: #"\bunknown\b.*\bmodel\b"#, options: .regularExpression) != nil {
            return "Provider/model is not available for this account."
        }

        if lower.contains("insufficient balance") ||
            lower.contains("billing") ||
            lower.contains("payment required") ||
            lower.range(of: #"\bno credits?\b"#, options: .regularExpression) != nil ||
            lower.contains("quota") ||
            lower.contains("rate limit") ||
            lower.contains("rate-limited") ||
            lower.contains("too many requests") ||
            lower.contains("not authorized") ||
            lower.contains("unauthorized") ||
            lower.contains("forbidden") ||
            lower.contains("not enabled") {
            return "Provider/model blocked by account, billing, quota, or authorization."
        }

        if lower.contains("login") ||
            lower.contains("auth") ||
            lower.contains("credential") ||
            lower.contains("api key") ||
            lower.contains("not configured") {
            return "Provider credentials needed for OpenCode."
        }

        return "OpenCode prompt failed with exit code \(status)."
    }

    private func restartOpenCodeTUI(preferredSessionId: String?) throws {
        refreshOpenCodeSessions(preferredSessionId: preferredSessionId)
        let selectedAfterRun = selectedSession()
        let base = selectedAfterRun.map { ["--session", $0.sessionId] } ?? []
        try restartProcess(arguments: runtimeArguments(base: base), cwd: selectedAfterRun?.directory)
        refreshOpenCodeSessions(preferredSessionId: selectedAfterRun?.sessionId)
        processStarted = true
        processExited = false
    }

    static func normalizedRuntimeValue(_ value: String) throws -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil ||
            trimmed.rangeOfCharacter(from: .controlCharacters) != nil {
            throw NSError(
                domain: "OpenCodeAdapter",
                code: -2,
                userInfo: [
                    NSLocalizedDescriptionKey: "OpenCode provider/model must be one value, for example opencode/gpt-5.5.",
                ]
            )
        }

        return trimmed
    }

    public override func selectTarget(_ targetID: String) async throws {
        refreshOpenCodeSessions(preferredSessionId: targetID)
        guard let selected = selectedSession() else {
            throw NSError(
                domain: "OpenCodeAdapter",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenCode session \(targetID) was not found."]
            )
        }

        if OpenCodeAdapter.canLaunch(executable) {
            try restartProcess(arguments: runtimeArguments(base: ["--session", selected.sessionId]), cwd: selected.directory)
            processStarted = true
        }

        refreshOpenCodeSessions(preferredSessionId: targetID)
        emitSnapshot(detail: "selected \(selected.title)")
    }

    public override func snapshotMessages(from buffer: String) -> [AgentChatMessage] {
        sessionLock.lock()
        let messages = currentMessages
        sessionLock.unlock()
        if !messages.isEmpty {
            return redactMessagesForSnapshot(messages)
        }

        let tail = String(buffer.suffix(4096))
        guard !tail.isEmpty else { return [] }
        let (redactedTail, reasons) = redactOutputForSnapshot(tail)
        return [
            AgentChatMessage(
                messageId: "\(agentID)-tail",
                role: .assistant,
                text: redactedTail,
                redacted: !reasons.isEmpty,
                redactionReasons: reasons
            ),
        ]
    }

    private func redactMessagesForSnapshot(_ messages: [AgentChatMessage]) -> [AgentChatMessage] {
        messages.map { message in
            let (redactedText, textReasons) = redactOutputForSnapshot(message.text)
            var reasons = Set(message.redactionReasons)
            reasons.formUnion(textReasons)

            let pendingTools = message.pendingToolCalls.map { tool in
                let (redactedToolName, toolNameReasons) = redactOutputForSnapshot(tool.toolName)
                let (redactedSummary, summaryReasons) = redactOutputForSnapshot(tool.summary)
                reasons.formUnion(toolNameReasons)
                reasons.formUnion(summaryReasons)
                return PendingToolCall(
                    toolName: redactedToolName,
                    toolCallId: tool.toolCallId,
                    summary: redactedSummary
                )
            }

            return AgentChatMessage(
                messageId: message.messageId,
                role: message.role,
                text: redactedText,
                atUnixMs: message.atUnixMs,
                redacted: message.redacted || !reasons.isEmpty,
                pendingToolCalls: pendingTools,
                redactionReasons: Array(reasons).sorted()
            )
        }
    }

    public override func snapshotAvailableTargets() -> [AgentTargetOption]? {
        sessionLock.lock()
        let summaries = sessionSummaries
        let selectedId = selectedSessionId
        sessionLock.unlock()

        guard !summaries.isEmpty else { return nil }
        return summaries.map { summary in
            let directory = summary.directory.trimmingCharacters(in: .whitespacesAndNewlines)
            let projectLabel = displayProject(directory: directory, fallback: summary.title)
            return AgentTargetOption(
                targetId: summary.sessionId,
                label: projectLabel,
                subtitle: displaySubtitle(summary),
                selected: summary.sessionId == selectedId,
                projectId: directory.isEmpty ? summary.sessionId : directory,
                projectLabel: projectLabel,
                projectPath: directory.isEmpty ? nil : directory,
                threadId: summary.sessionId,
                threadLabel: summary.title,
                targetKind: "thread",
                lastActivityUnixMs: summary.modifiedAtUnixMs,
                isActive: summary.sessionId == selectedId,
                supportsNewThread: false
            )
        }
    }

    public override func statusAfterOutputSilence(buffer: String, silenceDuration: TimeInterval) -> (status: AgentStatus, detail: String) {
        sessionLock.lock()
        let latestMessage = currentMessages.last
        let latestRawMessage = latestMessageState
        sessionLock.unlock()

        if latestRawMessage?.role == .user || (latestRawMessage == nil && latestMessage?.role == .user) {
            return (.working, "waiting for OpenCode response")
        }

        if let errorSummary = latestRawMessage?.errorSummary {
            return (.error, errorSummary)
        }

        if latestMessage?.pendingToolCalls.isEmpty == false {
            return (.working, "waiting for OpenCode tool")
        }

        if let latestRawMessage,
           latestRawMessage.role == .assistant,
           latestRawMessage.completedAtUnixMs == nil,
           latestMessage?.messageId != "\(agentID)-opencode-\(latestRawMessage.messageId)" {
            return (.working, "waiting for OpenCode response")
        }

        return super.statusAfterOutputSilence(buffer: buffer, silenceDuration: silenceDuration)
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    break
                }
                guard let self else { return }
                self.refreshOpenCodeSessions()
                self.emitSnapshot(detail: "OpenCode context synced")
            }
        }
    }

    private func runtimeArguments(base: [String]) -> [String] {
        runtimeArguments(base: base, modelId: currentRuntimeModelId())
    }

    private func runtimeArguments(base: [String], modelId: String?) -> [String] {
        guard let modelId, !modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return base
        }
        return ["--model", modelId] + base
    }

    private func runtimeRunArguments(sessionId: String?) -> [String] {
        var args = ["run"]
        if let modelId = currentRuntimeModelId(), !modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(contentsOf: ["--model", modelId])
        }
        if let sessionId, !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(contentsOf: ["--session", sessionId])
        }
        return args
    }

    private struct OpenCodeRunResult {
        let status: Int32
        let interrupted: Bool
        let stopped: Bool
        let output: String
    }

    private final class RunOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var output = ""

        func append(_ text: String) {
            guard !text.isEmpty else { return }
            let normalized = ANSIStripper.normalizeForLog(text)
            lock.lock()
            output += normalized
            if output.count > 8192 {
                output.removeFirst(output.count - 8192)
            }
            lock.unlock()
        }

        func snapshot() -> String {
            lock.lock()
            defer { lock.unlock() }
            return output
        }
    }

    private func runOpenCodePrompt(_ text: String, arguments: [String], cwd: String?) async throws -> OpenCodeRunResult {
        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        if let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, adapterValue in
            adapterValue
        }

        let stdin = Pipe()
        let outputPipe = Pipe()
        process.standardInput = stdin
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let outputBuffer = RunOutputBuffer()

        return try await withCheckedThrowingContinuation { continuation in
            let outputHandle = outputPipe.fileHandleForReading
            let outputReader = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    let data = outputHandle.availableData
                    guard !data.isEmpty else { break }
                    guard let text = String(data: data, encoding: .utf8) else { continue }
                    outputBuffer.append(text)
                }
                return outputBuffer.snapshot()
            }

            process.terminationHandler = { completed in
                Task {
                    let output = await outputReader.value
                    let termination = self.clearCurrentRunProcess(completed)
                    continuation.resume(returning: OpenCodeRunResult(
                        status: completed.terminationStatus,
                        interrupted: termination.interrupted,
                        stopped: termination.stopped,
                        output: output
                    ))
                }
            }
            do {
                setCurrentRunProcess(process)
                try process.run()
                if let data = "\(text)\n".data(using: .utf8) {
                    try? stdin.fileHandleForWriting.write(contentsOf: data)
                }
                try? stdin.fileHandleForWriting.close()
            } catch {
                outputReader.cancel()
                try? outputHandle.close()
                _ = clearCurrentRunProcess(process)
                continuation.resume(throwing: error)
            }
        }
    }

    private func setCurrentRunProcess(_ process: Process) {
        runProcessLock.lock()
        currentRunProcess = process
        currentRunInterrupted = false
        currentRunStopped = false
        runProcessLock.unlock()
    }

    private func clearCurrentRunProcess(_ process: Process) -> (interrupted: Bool, stopped: Bool) {
        runProcessLock.lock()
        let interrupted = currentRunProcess === process && currentRunInterrupted
        let stopped = currentRunProcess === process && currentRunStopped
        if currentRunProcess === process {
            currentRunProcess = nil
            currentRunInterrupted = false
            currentRunStopped = false
        }
        runProcessLock.unlock()
        return (interrupted, stopped)
    }

    private func interruptCurrentRunProcess() -> Bool {
        runProcessLock.lock()
        let process = currentRunProcess
        if process != nil {
            currentRunInterrupted = true
        }
        runProcessLock.unlock()

        guard let process else { return false }
        process.terminate()
        transitionTo(.idle, detail: "interrupted", forceEmit: true)
        return true
    }

    private func stopCurrentRunProcess() {
        runProcessLock.lock()
        let process = currentRunProcess
        if process != nil {
            currentRunStopped = true
        }
        runProcessLock.unlock()
        process?.terminate()
    }

    private func refreshOpenCodeSessions(preferredSessionId: String? = nil) {
        let summaries = OpenCodeSessionStore.loadSummaries(databaseURL: databaseURL)
        let messageBackedDefaultId = OpenCodeSessionStore
            .loadMostRecentSummaryWithMessages(databaseURL: databaseURL)?
            .sessionId
        let nextSelectedId = preferredSessionId
            ?? selectedSessionId
            ?? messageBackedDefaultId
            ?? summaries.first?.sessionId
        let selected = summaries.first { $0.sessionId == nextSelectedId } ?? summaries.first
        let messages = selected.map {
            OpenCodeSessionStore.loadMessages(
                sessionId: $0.sessionId,
                databaseURL: databaseURL,
                agentID: agentID,
                maxMessages: AgentHistoryLimits.snapshotMessageCount
            )
        } ?? []
        let latestMessageState = selected.flatMap {
            OpenCodeSessionStore.loadLatestMessageState(
                sessionId: $0.sessionId,
                databaseURL: databaseURL
            )
        }

        sessionLock.lock()
        sessionSummaries = summaries
        selectedSessionId = selected?.sessionId
        currentMessages = messages
        self.latestMessageState = latestMessageState
        sessionLock.unlock()
    }

    private func selectedSession() -> OpenCodeSessionSummary? {
        sessionLock.lock()
        let summaries = sessionSummaries
        let selectedId = selectedSessionId
        sessionLock.unlock()
        return summaries.first { $0.sessionId == selectedId } ?? summaries.first
    }

    private func displaySubtitle(_ summary: OpenCodeSessionSummary) -> String {
        let directory = summary.directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else {
            return summary.sessionId
        }
        return directory
    }

    private func displayProject(directory: String, fallback: String) -> String {
        guard !directory.isEmpty else { return fallback }
        let last = URL(fileURLWithPath: directory).lastPathComponent
        return last.isEmpty ? fallback : last
    }

    public static func executableCandidates() -> [String] {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        return [
            "opencode",
            "\(home)/.volta/bin/opencode",
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
            "\(home)/.local/bin/opencode",
            "\(home)/.cargo/bin/opencode",
            "\(home)/.bun/bin/opencode",
            "\(home)/.npm-global/bin/opencode",
            "/Applications/OpenCode.app/Contents/MacOS/opencode-cli",
            "\(home)/Applications/OpenCode.app/Contents/MacOS/opencode-cli",
        ]
    }

    private static func resolveExecutable() -> String {
        let candidates = executableCandidates()
        for candidate in candidates where canLaunch(candidate) {
            return candidate
        }
        return "opencode"
    }

    private static let modelCatalogIds = [
        "opencode/deepseek-v4-flash-free",
        "opencode/nemotron-3-ultra-free",
        "opencode/mimo-v2.5-free",
        "opencode/north-mini-code-free",
        "opencode/big-pickle",
        "opencode/deepseek-v4-flash",
        "opencode/deepseek-v4-pro",
        "opencode/gpt-5.5",
        "opencode/gpt-5.5-pro",
        "opencode/gpt-5.4",
        "opencode/gpt-5.4-pro",
        "opencode/gpt-5.4-mini",
        "opencode/gpt-5.4-nano",
        "opencode/gpt-5.3-codex",
        "opencode/gpt-5.3-codex-spark",
        "opencode/gpt-5.2",
        "opencode/gpt-5.2-codex",
        "opencode/gpt-5.1",
        "opencode/gpt-5.1-codex",
        "opencode/gpt-5.1-codex-max",
        "opencode/gpt-5.1-codex-mini",
        "opencode/gpt-5",
        "opencode/gpt-5-codex",
        "opencode/gpt-5-nano",
        "opencode/claude-sonnet-4-6",
        "opencode/claude-sonnet-4-5",
        "opencode/claude-sonnet-4",
        "opencode/claude-haiku-4-5",
        "opencode/claude-opus-4-8",
        "opencode/claude-opus-4-7",
        "opencode/claude-opus-4-6",
        "opencode/claude-opus-4-5",
        "opencode/claude-opus-4-1",
        "opencode/gemini-3.5-flash",
        "opencode/gemini-3.1-pro",
        "opencode/gemini-3-flash",
        "opencode/grok-build-0.1",
        "opencode/glm-5.2",
        "opencode/glm-5.1",
        "opencode/glm-5",
        "opencode/kimi-k2.6",
        "opencode/kimi-k2.5",
        "opencode/minimax-m2.7",
        "opencode/minimax-m2.5",
        "opencode/qwen3.6-plus",
        "opencode/qwen3.5-plus",
    ]

    private static let modelOptions: [AgentRuntimeOption] = [
        AgentRuntimeOption(id: "", label: "Default", description: "Use OpenCode default")
    ] + modelCatalogIds.map {
        AgentRuntimeOption(id: $0, label: modelDisplayName($0), description: "OpenCode model")
    }

    private static func modelLabel(_ modelId: String?) -> String {
        guard let modelId, !modelId.isEmpty else { return "Default" }
        return modelOptions.first { $0.id == modelId }?.label ?? modelId
    }

    private static func modelDisplayName(_ modelId: String) -> String {
        let slug = modelId
            .replacingOccurrences(of: "opencode/", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { token -> String in
                let lower = String(token)
                switch lower {
                case "gpt": return "GPT"
                case "glm": return "GLM"
                case "ai": return "AI"
                case "api": return "API"
                case "claude": return "Claude"
                case "codex": return "Codex"
                case "deepseek": return "DeepSeek"
                case "flash": return "Flash"
                case "free": return "Free"
                case "gemini": return "Gemini"
                case "grok": return "Grok"
                case "haiku": return "Haiku"
                case "kimi": return "Kimi"
                case "mimo": return "Mimo"
                case "minimax": return "MiniMax"
                case "nano": return "Nano"
                case "nemotron": return "Nemotron"
                case "north": return "North"
                case "opus": return "Opus"
                case "pickle": return "Pickle"
                case "pro": return "Pro"
                case "sonnet": return "Sonnet"
                case "spark": return "Spark"
                case "ultra": return "Ultra"
                case "qwen3.6": return "Qwen 3.6"
                case "qwen3.5": return "Qwen 3.5"
                default:
                    if lower.hasPrefix("k2.") || lower.hasPrefix("v4") || lower.hasPrefix("m2.") {
                        return lower.uppercased()
                    }
                    return lower.prefix(1).uppercased() + String(lower.dropFirst())
                }
            }
            .joined(separator: " ")
        return slug.isEmpty ? modelId : slug
    }

    private static func canLaunch(_ executable: String) -> Bool {
        if executable.contains("/") {
            return FileManager.default.isExecutableFile(atPath: executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", executable]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
