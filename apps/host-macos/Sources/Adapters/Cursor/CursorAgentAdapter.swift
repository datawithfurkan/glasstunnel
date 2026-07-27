import Foundation
import GTProtocol
import GTSecurity

/// Headless adapter for Cursor Agent CLI.
///
/// This is separate from `CursorAdapter`, which targets the desktop Cursor app
/// through Accessibility. Cursor Agent runs as a CLI command surface and is
/// intentionally ask-mode only until edit/tool behavior is verified.
public final class CursorAgentAdapter: PTYAdapterBase, @unchecked Sendable {
    public override var idleThresholdSeconds: Double { 1.0 }

    public static let defaultModel = "gpt-5.4-nano-none"
    public static let askModeNote = "Ask mode only; file edits are not enabled."

    private let runtimeLock = NSLock()
    private let processLock = NSLock()
    private let workspaceURL: URL
    private var runtimeModelId: String
    private var chatId: String?
    private var currentProcess: Process?
    private var currentMessages: [AgentChatMessage] = []
    private var currentOutput = ""

    public init(
        agentID: AgentID = "cursor-agent",
        label: String = "Cursor Agent",
        executable: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:],
        cwd: String? = nil,
        redactor: SecretRedactor = SecretRedactor()
    ) {
        self.runtimeModelId = Self.defaultModel
        self.workspaceURL = URL(fileURLWithPath: cwd ?? Self.defaultWorkspacePath(), isDirectory: true)
        super.init(
            agentID: agentID,
            kind: .cursorAgent,
            label: label,
            executable: executable ?? Self.resolveExecutable(),
            arguments: arguments,
            environment: environment,
            cwd: cwd,
            redactor: redactor
        )
    }

    public override func runtimeControls() -> AgentRuntimeControls? {
        let modelId = currentRuntimeModel()

        return AgentRuntimeControls(
            modelId: modelId,
            modelLabel: Self.modelLabel(for: modelId),
            modelOptions: [
                AgentRuntimeOption(id: Self.defaultModel, label: Self.modelLabel(for: Self.defaultModel)),
            ],
            reasoningEffortOptions: [],
            supportsModelSelection: true,
            editable: false,
            appliesOn: .managedLocally,
            note: Self.askModeNote
        )
    }

    public override func start() async throws {
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let id = try await createChat()
        resetReadyState(chatId: id)
        transitionTo(.done, detail: "ready", forceEmit: true)
    }

    public override func stop() async {
        let process = takeCurrentProcess()
        process?.terminate()
        setChatId(nil)
        transitionTo(.disconnected, detail: "stopped", forceEmit: true)
    }

    public override func sendInput(_ text: String, submit: Bool) async throws {
        guard submit else {
            throw NSError(
                domain: "CursorAgentAdapter",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Cursor Agent prompts must be submitted before they can run."]
            )
        }

        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw NSError(
                domain: "CursorAgentAdapter",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Cursor Agent prompt is empty."]
            )
        }

        guard !hasCurrentProcess() else {
            throw NSError(
                domain: "CursorAgentAdapter",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Cursor Agent is already running a prompt."]
            )
        }

        let id = try await ensureChatId()
        clearHeadlessOutput()
        transitionTo(.working, detail: "running prompt", forceEmit: true)

        do {
            let output = try await runPrompt(prompt, chatId: id)
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
        _ = update
        emitSnapshot(detail: "settings failed")
        throw NSError(
            domain: "CursorAgentAdapter",
            code: -5,
            userInfo: [
                NSLocalizedDescriptionKey: "Cursor Agent runs with the verified \(Self.defaultModel) ask-mode model in Glasstunnel.",
            ]
        )
    }

    public override func snapshotMessages(from buffer: String) -> [AgentChatMessage] {
        _ = buffer
        processLock.lock()
        let messages = currentMessages
        processLock.unlock()
        return messages
    }

    public static func executableCandidates() -> [String] {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        return [
            "cursor-agent",
            "\(home)/.local/bin/cursor-agent",
            "/opt/homebrew/bin/cursor-agent",
            "/usr/local/bin/cursor-agent",
            "\(home)/.bun/bin/cursor-agent",
            "\(home)/.npm-global/bin/cursor-agent",
            "\(home)/.volta/bin/cursor-agent",
        ]
    }

    static func normalizedModel(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "CursorAgentAdapter",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "Cursor Agent model is empty."]
            )
        }
        let forbiddenCharacters = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: "\"'`"))
        if trimmed.rangeOfCharacter(from: forbiddenCharacters) != nil {
            throw NSError(
                domain: "CursorAgentAdapter",
                code: -7,
                userInfo: [NSLocalizedDescriptionKey: "Cursor Agent model must be one value without spaces or quotes."]
            )
        }
        guard trimmed == Self.defaultModel else {
            throw NSError(
                domain: "CursorAgentAdapter",
                code: -8,
                userInfo: [NSLocalizedDescriptionKey: "Cursor Agent currently exposes only the verified \(Self.defaultModel) model in Glasstunnel."]
            )
        }
        return trimmed
    }

    private func createChat() async throws -> String {
        let output = try await runCommand(
            arguments: ["create-chat", "--workspace", workspaceURL.path, "--trust"],
            publishOutput: false
        )
        let id = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.range(of: #"^[0-9a-fA-F-]{20,}$"#, options: .regularExpression) != nil else {
            throw NSError(
                domain: "CursorAgentAdapter",
                code: -9,
                userInfo: [NSLocalizedDescriptionKey: "Cursor Agent did not return a usable chat id."]
            )
        }
        return id
    }

    private func ensureChatId() async throws -> String {
        if let existing = currentChatId() { return existing }
        let id = try await createChat()
        setChatId(id)
        return id
    }

    private func runPrompt(_ prompt: String, chatId: String) async throws -> String {
        let modelId = currentRuntimeModel()

        return try await runCommand(arguments: [
            "--print",
            "--mode", "ask",
            "--model", modelId,
            "--workspace", workspaceURL.path,
            "--trust",
            "--resume", chatId,
            prompt,
        ])
    }

    private func runCommand(arguments: [String], publishOutput: Bool = true) async throws -> String {
        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        process.environment = Self.commandEnvironment(overrides: environment)

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        setCurrentProcess(process)
        let commandOutput = CommandOutputBuffer()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let outputHandle = outputPipe.fileHandleForReading
                outputHandle.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    if let text = String(data: data, encoding: .utf8) {
                        let normalized = ANSIStripper.normalizeForLog(text)
                        commandOutput.append(normalized)
                        if publishOutput {
                            self?.appendHeadlessOutput(normalized)
                        }
                    }
                }

                process.terminationHandler = { [weak self] process in
                    outputHandle.readabilityHandler = nil
                    let remaining = outputHandle.readDataToEndOfFile()
                    if let text = String(data: remaining, encoding: .utf8), !text.isEmpty {
                        let normalized = ANSIStripper.normalizeForLog(text)
                        commandOutput.append(normalized)
                        if publishOutput {
                            self?.appendHeadlessOutput(normalized)
                        }
                    }

                    guard let self else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    let rawOutput = commandOutput.value()
                    self.processLock.lock()
                    let output = publishOutput ? self.currentOutput : rawOutput
                    let wasCurrentProcess = self.currentProcess === process
                    if wasCurrentProcess {
                        self.currentProcess = nil
                    }
                    self.processLock.unlock()

                    if !wasCurrentProcess {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: output)
                    } else {
                        continuation.resume(
                            throwing: NSError(
                                domain: "CursorAgentAdapter",
                                code: Int(process.terminationStatus),
                                userInfo: [NSLocalizedDescriptionKey: output.isEmpty ? "Cursor Agent exited with status \(process.terminationStatus)." : output]
                            )
                        )
                    }
                }

                do {
                    try process.run()
                } catch {
                    outputHandle.readabilityHandler = nil
                    self.processLock.lock()
                    if self.currentProcess === process {
                        self.currentProcess = nil
                    }
                    self.processLock.unlock()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }
    }

    private func currentRuntimeModel() -> String {
        runtimeLock.lock()
        defer { runtimeLock.unlock() }
        return runtimeModelId
    }

    private func setRuntimeModel(_ modelId: String) {
        runtimeLock.lock()
        runtimeModelId = modelId
        runtimeLock.unlock()
    }

    private func currentChatId() -> String? {
        processLock.lock()
        defer { processLock.unlock() }
        return chatId
    }

    private func setChatId(_ id: String?) {
        processLock.lock()
        chatId = id
        processLock.unlock()
    }

    private func resetReadyState(chatId id: String) {
        processLock.lock()
        chatId = id
        currentMessages = []
        currentOutput = ""
        processLock.unlock()
    }

    private func clearHeadlessOutput() {
        processLock.lock()
        currentOutput = ""
        currentMessages = []
        processLock.unlock()
        clearOutputBuffer()
    }

    private func setHeadlessOutput(_ output: String) {
        processLock.lock()
        currentOutput = output
        currentMessages = Self.messages(agentID: agentID, text: output)
        processLock.unlock()
    }

    private func appendHeadlessOutput(_ output: String) {
        let (redacted, _) = redactOutputForSnapshot(output)
        processLock.lock()
        currentOutput += redacted
        if currentOutput.count > 8192 {
            currentOutput.removeFirst(currentOutput.count - 8192)
        }
        currentMessages = Self.messages(agentID: agentID, text: currentOutput)
        processLock.unlock()
        emitSnapshot(detail: "output")
    }

    private func hasCurrentProcess() -> Bool {
        processLock.lock()
        let running = currentProcess != nil
        processLock.unlock()
        return running
    }

    private func setCurrentProcess(_ process: Process) {
        processLock.lock()
        currentProcess = process
        processLock.unlock()
    }

    private func takeCurrentProcess() -> Process? {
        processLock.lock()
        let process = currentProcess
        currentProcess = nil
        processLock.unlock()
        return process
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

    private static func resolveExecutable() -> String {
        for candidate in executableCandidates() where canLaunch(candidate) {
            return candidate
        }
        return "cursor-agent"
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

    private static func defaultWorkspacePath() -> String {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return directory
            .appendingPathComponent("Glasstunnel", isDirectory: true)
            .appendingPathComponent("CursorAgent", isDirectory: true)
            .path
    }

    private static func commandEnvironment(overrides: [String: String]) -> [String: String] {
        var merged = PTYWrapper.terminalEnvironment(overrides: overrides)
        merged["TERM"] = "xterm-256color"
        return merged
    }

    private static func modelLabel(for modelId: String) -> String {
        if modelId == Self.defaultModel {
            return "GPT 5.4 Nano"
        }
        return modelId
    }
}

private final class CommandOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ text: String) {
        lock.lock()
        storage += text
        lock.unlock()
    }

    func value() -> String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
