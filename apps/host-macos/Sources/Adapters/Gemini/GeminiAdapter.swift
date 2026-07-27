import Foundation
import GTProtocol
import GTSecurity

/// Adapter for Google's Gemini CLI. This is intentionally conservative until
/// real installed/authenticated Gemini CLI behavior is verified.
public final class GeminiAdapter: PTYAdapterBase, @unchecked Sendable {
    public override var idleThresholdSeconds: Double { 2.0 }
    public override var collapsesTerminalRewritesForLog: Bool { true }

    private let runtimeLock = NSLock()
    private let headlessLock = NSLock()
    private let initialArguments: [String]
    private var runtimeModelId: String?
    private var currentProcess: Process?
    private var currentOutput = ""
    private var currentMessages: [AgentChatMessage] = []

    public init(
        agentID: AgentID = "gemini-cli",
        label: String = "Gemini CLI",
        executable: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:],
        cwd: String? = nil,
        redactor: SecretRedactor = SecretRedactor()
    ) {
        let launchArguments = Self.trustCurrentWorkspaceForSession(arguments)
        self.initialArguments = launchArguments
        super.init(
            agentID: agentID,
            kind: .geminiCli,
            label: label,
            executable: executable ?? GeminiAdapter.resolveExecutable(),
            arguments: launchArguments,
            environment: environment,
            cwd: cwd,
            redactor: redactor
        )
    }

    public override func runtimeControls() -> AgentRuntimeControls? {
        runtimeLock.lock()
        let modelId = runtimeModelId
        runtimeLock.unlock()

        return AgentRuntimeControls(
            modelId: modelId ?? "",
            modelLabel: modelId?.isEmpty == false ? modelId : "Default",
            modelOptions: [],
            reasoningEffortOptions: [],
            supportsModelSelection: true,
            editable: true,
            appliesOn: .nextStart,
            note: "Applies to next prompt"
        )
    }

    public override func start() async throws {
        clearHeadlessOutput()
        transitionTo(.done, detail: "ready", forceEmit: true)
    }

    public override func stop() async {
        let process = takeCurrentProcess()
        process?.terminate()
        transitionTo(.disconnected, detail: "stopped", forceEmit: true)
    }

    public override func sendInput(_ text: String, submit: Bool) async throws {
        guard submit else {
            throw NSError(
                domain: "GeminiAdapter",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Gemini CLI prompts must be submitted before they can run."]
            )
        }

        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw NSError(
                domain: "GeminiAdapter",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Gemini CLI prompt is empty."]
            )
        }

        guard !hasCurrentProcess() else {
            throw NSError(
                domain: "GeminiAdapter",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Gemini CLI is already running a prompt."]
            )
        }

        clearHeadlessOutput()
        transitionTo(.working, detail: "running prompt", forceEmit: true)

        do {
            let output = try await runHeadlessPrompt(prompt)
            setHeadlessOutput(output)
            transitionTo(.done, detail: "prompt returned", forceEmit: true)
        } catch is CancellationError {
            transitionTo(.idle, detail: "interrupted", forceEmit: true)
        } catch {
            appendHeadlessOutput("\n\(error.localizedDescription)\n")
            transitionTo(.error, detail: "prompt failed", forceEmit: true)
            throw error
        }
    }

    public override func interrupt() async throws {
        let process = takeCurrentProcess()
        process?.terminate()
        transitionTo(.idle, detail: "interrupted", forceEmit: true)
    }

    public override func updateRuntimeSettings(_ update: AgentRuntimeSettingsUpdate) async throws {
        if hasCurrentProcess() {
            emitSnapshot(detail: "settings failed")
            throw NSError(
                domain: "GeminiAdapter",
                code: -5,
                userInfo: [
                    NSLocalizedDescriptionKey: "Gemini CLI is already running a prompt. Change model after it finishes or stop it first.",
                ]
            )
        }

        do {
            try applyRuntimeUpdate(update)
        } catch {
            emitSnapshot(detail: "settings failed")
            throw error
        }
        emitSnapshot(detail: "settings updated")
    }

    private func applyRuntimeUpdate(_ update: AgentRuntimeSettingsUpdate) throws {
        if let modelId = update.modelId {
            let normalized = try Self.normalizedRuntimeValue(modelId)
            runtimeLock.lock()
            runtimeModelId = normalized
            runtimeLock.unlock()
        }
    }

    public override func snapshotMessages(from buffer: String) -> [AgentChatMessage] {
        headlessLock.lock()
        let messages = currentMessages
        headlessLock.unlock()
        if !messages.isEmpty {
            return messages
        }

        return super.snapshotMessages(from: buffer)
    }

    public override func statusAfterOutputSilence(buffer: String, silenceDuration: TimeInterval) -> (status: AgentStatus, detail: String) {
        let tail = buffer.suffix(4096)
        if tail.localizedCaseInsensitiveContains("Waiting for authentication") {
            return (.working, "authenticating")
        }
        if tail.localizedCaseInsensitiveContains("Thinking...") ||
            tail.localizedCaseInsensitiveContains("esc to cancel") {
            return (.working, "running prompt")
        }
        return (.done, "idle for \(Int(silenceDuration))s")
    }

    public static func executableCandidates() -> [String] {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        return [
            "gemini",
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini",
            "\(home)/.local/bin/gemini",
            "\(home)/.cargo/bin/gemini",
            "\(home)/.bun/bin/gemini",
            "\(home)/.npm-global/bin/gemini",
            "\(home)/.volta/bin/gemini",
        ]
    }

    static func normalizedRuntimeValue(_ value: String) throws -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let forbiddenCharacters = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: "\"'`"))
        if trimmed.rangeOfCharacter(from: forbiddenCharacters) != nil {
            throw NSError(
                domain: "GeminiAdapter",
                code: -2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Gemini model must be one value without spaces or quotes.",
                ]
            )
        }

        return trimmed
    }

    static func trustCurrentWorkspaceForSession(_ arguments: [String]) -> [String] {
        if arguments.contains("--skip-trust") {
            return arguments
        }
        return ["--skip-trust"] + arguments
    }

    private func launchArguments() -> [String] {
        runtimeLock.lock()
        let modelId = runtimeModelId
        runtimeLock.unlock()

        guard let modelId, !modelId.isEmpty else { return initialArguments }
        return ["--model", modelId] + initialArguments
    }

    private func headlessArguments(prompt: String) -> [String] {
        launchArguments() + ["--prompt", prompt]
    }

    private static func headlessEnvironment(overrides: [String: String]) -> [String: String] {
        var merged = PTYWrapper.terminalEnvironment(overrides: overrides)
        let colorTerm = merged["COLORTERM"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if colorTerm == nil || colorTerm == "" {
            merged["COLORTERM"] = "truecolor"
        }
        return merged
    }

    private func runHeadlessPrompt(_ prompt: String) async throws -> String {
        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = headlessArguments(prompt: prompt)
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + headlessArguments(prompt: prompt)
        }
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }
        process.environment = Self.headlessEnvironment(overrides: environment)

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        setCurrentProcess(process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let outputHandle = outputPipe.fileHandleForReading
                outputHandle.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    if let text = String(data: data, encoding: .utf8) {
                        self?.appendHeadlessOutput(ANSIStripper.normalizeForLog(text))
                    }
                }

                process.terminationHandler = { [weak self] process in
                    outputHandle.readabilityHandler = nil
                    let remaining = outputHandle.readDataToEndOfFile()
                    if let text = String(data: remaining, encoding: .utf8), !text.isEmpty {
                        self?.appendHeadlessOutput(ANSIStripper.normalizeForLog(text))
                    }

                    guard let self else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    self.headlessLock.lock()
                    let output = self.currentOutput
                    let wasCurrentProcess = self.currentProcess === process
                    if wasCurrentProcess {
                        self.currentProcess = nil
                    }
                    self.headlessLock.unlock()

                    if !wasCurrentProcess {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: output)
                    } else {
                        continuation.resume(
                            throwing: NSError(
                                domain: "GeminiAdapter",
                                code: Int(process.terminationStatus),
                                userInfo: [NSLocalizedDescriptionKey: output.isEmpty ? "Gemini CLI exited with status \(process.terminationStatus)." : output]
                            )
                        )
                    }
                }

                do {
                    try process.run()
                } catch {
                    outputHandle.readabilityHandler = nil
                    self.headlessLock.lock()
                    if self.currentProcess === process {
                        self.currentProcess = nil
                    }
                    self.headlessLock.unlock()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }
    }

    private func clearHeadlessOutput() {
        headlessLock.lock()
        currentOutput = ""
        currentMessages = []
        headlessLock.unlock()
        clearOutputBuffer()
    }

    private func setHeadlessOutput(_ output: String) {
        headlessLock.lock()
        currentOutput = output
        currentMessages = Self.messages(agentID: agentID, text: output)
        headlessLock.unlock()
    }

    private func appendHeadlessOutput(_ output: String) {
        let (redacted, _) = redactOutputForSnapshot(output)
        headlessLock.lock()
        currentOutput += redacted
        if currentOutput.count > 8192 {
            currentOutput.removeFirst(currentOutput.count - 8192)
        }
        currentMessages = Self.messages(agentID: agentID, text: currentOutput)
        headlessLock.unlock()
        emitSnapshot(detail: "output")
    }

    private static func messages(agentID: AgentID, text: String) -> [AgentChatMessage] {
        let tail = String(text.suffix(4096))
        guard !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let reasons = SecretRedactor.placeholderReasons(in: tail)
        return [
            AgentChatMessage(
                messageId: "\(agentID)-headless-tail",
                role: .assistant,
                text: tail,
                redacted: !reasons.isEmpty,
                redactionReasons: reasons
            ),
        ]
    }

    private func hasCurrentProcess() -> Bool {
        headlessLock.lock()
        let running = currentProcess != nil
        headlessLock.unlock()
        return running
    }

    private func setCurrentProcess(_ process: Process) {
        headlessLock.lock()
        currentProcess = process
        headlessLock.unlock()
    }

    private func takeCurrentProcess() -> Process? {
        headlessLock.lock()
        let process = currentProcess
        currentProcess = nil
        headlessLock.unlock()
        return process
    }

    private static func resolveExecutable() -> String {
        let candidates = executableCandidates()
        for candidate in candidates where canLaunch(candidate) {
            return candidate
        }
        return "gemini"
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
