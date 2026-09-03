import Foundation
import GTProtocol
import GTSecurity

/// Headless adapter for the Cursor Agent CLI (`cursor-agent`).
///
/// This is separate from `CursorAdapter`, which drives the desktop app through
/// Accessibility. Cursor Agent runs one turn per `cursor-agent --print` call
/// on a chat the CLI can `--resume`, and streams its events as JSON lines
/// (`--output-format stream-json --stream-partial-output`), so the phone sees
/// the reply grow and one row per tool call while the turn runs. Between
/// turns the chat's own store (`~/.cursor/chats/<workspace>/<chat>/store.db`)
/// is the durable transcript, so history survives host restarts and matches
/// what the CLI shows.
///
/// Chats run in a workspace folder. The adapter uses the folder it was given,
/// else the host's own working directory when that is a real folder, else the
/// most recently trusted Cursor workspace, else a Glasstunnel-owned folder.
/// Ask mode is the default (read-only); plan mode can be chosen from the
/// phone; agent mode (file edits and shell) stays off until tool permissions
/// can be routed to the phone.
public final class CursorAgentAdapter: AgentAdapter, @unchecked Sendable {
    public static let defaultModel = "gpt-5.4-nano"
    public static let modes = ["ask", "plan", "agent"]
    public static let askModeNote = "Ask mode (read-only). Send /mode plan to plan; agent mode is not enabled yet."
    public static let planModeNote = "Plan mode (read-only). Send /mode ask to go back."
    public static let agentModeRefusal = "Agent mode (file edits and shell) is not enabled on the phone yet."
    public static let loginDetail = "Sign in with cursor-agent login on the Mac"
    public static let newChatTargetId = "cursor-agent-new-chat"

    public let agentID: AgentID
    public let kind: AdapterKind = .cursorAgent
    public let label: String

    private let executable: String
    private let environment: [String: String]
    private let cursorRoot: URL
    private let redactor: SecretRedactor
    private let hookInstaller: CursorHookInstaller
    private let hookRouter: CursorHookRouter
    private let stateStream = StreamWriter<AgentStateSnapshot>()
    private let lock = NSLock()

    private var workspace: String
    private var chats: [CursorCLIChatSummary] = []
    private var selectedChatId: String?
    /// Chats this adapter created or resumed; only their hook events are ours.
    private var ownedChatIds = Set<String>()
    private var historyMessages: [AgentChatMessage] = []
    private var historyDetails: [MessageID: String] = [:]
    private var liveMessages: [AgentChatMessage] = []
    private var liveDetails: [MessageID: String] = [:]
    private var parsedStore: (path: String, modifiedAt: Date)?
    private var currentStatus: AgentStatus = .idle
    private var currentDetail = ""
    private var lastActivityUnixMs = Int64(Date().timeIntervalSince1970 * 1000)
    private var runtimeModelId = CursorAgentAdapter.defaultModel
    private var mode = "ask"
    private var modelOptions: [AgentRuntimeOption] = [AgentRuntimeOption(id: CursorAgentAdapter.defaultModel, label: "GPT-5.4 Nano")]
    private var currentProcess: Process?
    private var interruptedTurn = false
    private var turnCounter = 0
    private var hookSubscription: UUID?
    private var refreshTask: Task<Void, Never>?
    private var lastEmitAt = Date.distantPast
    private var deferredEmitScheduled = false

    public init(
        agentID: AgentID = "cursor-agent",
        label: String = "Cursor Agent",
        executable: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:],
        cwd: String? = nil,
        redactor: SecretRedactor = SecretRedactor(),
        cursorRoot: URL? = nil,
        hookRouter: CursorHookRouter = .shared,
        hookInstaller: CursorHookInstaller = CursorHookInstaller()
    ) {
        _ = arguments
        self.agentID = agentID
        self.label = label
        self.executable = executable ?? Self.resolveExecutable()
        self.environment = environment
        self.redactor = redactor
        self.cursorRoot = cursorRoot ?? CursorCLIChatCatalog.defaultRoot()
        self.hookRouter = hookRouter
        self.hookInstaller = hookInstaller
        self.workspace = Self.resolveWorkspace(preferred: cwd, cursorRoot: self.cursorRoot)
    }

    public func observeState() -> AsyncStream<AgentStateSnapshot> {
        stateStream.make()
    }

    // MARK: - Lifecycle

    public func start() async throws {
        setStatus(.working, detail: "loading Cursor Agent chats")
        emitCurrentSnapshot()
        do {
            try hookInstaller.installIfNeeded()
        } catch {
            // Hooks only confirm what the stream already tells this adapter;
            // a user file that cannot be merged must not block the card.
            setStatus(.working, detail: "Cursor hooks not installed: \(error)")
        }
        hookSubscription = try? hookRouter.subscribe(
            ownsConversation: { [weak self] conversation in
                self?.ownsChat(conversation) ?? false
            },
            handler: { [weak self] event in
                self?.handleHook(event)
            }
        )
        try FileManager.default.createDirectory(atPath: currentWorkspace(), withIntermediateDirectories: true)
        refreshChats(selectNewest: true)
        loadHistoryIfNeeded()
        setStatus(.idle, detail: "ready")
        emitCurrentSnapshot()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                self.pollRefresh()
            }
        }
    }

    public func stop() async {
        refreshTask?.cancel()
        refreshTask = nil
        if let hookSubscription {
            hookRouter.unsubscribe(hookSubscription)
        }
        hookSubscription = nil
        terminateCurrentProcess()
        setStatus(.disconnected, detail: "stopped")
        emitCurrentSnapshot()
    }

    // MARK: - Prompts

    public func sendInput(_ text: String, submit: Bool) async throws {
        guard submit else {
            throw Self.error(-2, "Cursor Agent prompts must be submitted before they can run.")
        }
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw Self.error(-3, "Cursor Agent prompt is empty.")
        }
        if let command = Self.localCommand(in: prompt) {
            try await apply(command)
            return
        }
        guard !hasCurrentProcess() else {
            throw Self.error(-4, "Cursor Agent is already running a prompt.")
        }
        if currentMode() == "agent" {
            throw Self.error(-5, Self.agentModeRefusal)
        }
        let chatId = try await ensureChat()
        try await runTurn(prompt: prompt, chatId: chatId)
    }

    public func interrupt() async throws {
        lock.lock()
        interruptedTurn = currentProcess != nil
        lock.unlock()
        terminateCurrentProcess()
    }

    public func messageDetail(_ messageId: MessageID) -> AgentMessageDetail? {
        lock.lock()
        defer { lock.unlock() }
        guard let text = liveDetails[messageId] ?? historyDetails[messageId] else { return nil }
        return AgentMessageDetail(messageId: messageId, text: text, truncated: text.utf8.count >= TranscriptPreview.detailByteCount)
    }

    // MARK: - Targets

    public func selectTarget(_ targetID: String) async throws {
        if targetID == Self.newChatTargetId {
            let id = try await createChat()
            select(chatId: id)
            emitCurrentSnapshot()
            return
        }
        refreshChats(selectNewest: false)
        guard chatSummary(targetID) != nil else {
            throw Self.error(-6, "Cursor Agent chat \(targetID) was not found.")
        }
        select(chatId: targetID)
        emitCurrentSnapshot()
    }

    // MARK: - Runtime controls

    public func runtimeControls() -> AgentRuntimeControls? {
        lock.lock()
        let modelId = runtimeModelId
        let options = modelOptions
        let mode = self.mode
        lock.unlock()
        return AgentRuntimeControls(
            modelId: modelId,
            modelLabel: options.first { $0.id == modelId }?.label ?? Self.modelLabel(modelId),
            modelOptions: options,
            reasoningEffortOptions: [],
            supportsModelSelection: true,
            editable: true,
            appliesOn: .immediate,
            note: mode == "plan" ? Self.planModeNote : Self.askModeNote
        )
    }

    public func updateRuntimeSettings(_ update: AgentRuntimeSettingsUpdate) async throws {
        if hasCurrentProcess() {
            emitSnapshot(detail: "settings failed")
            throw Self.error(-11, "\(label) is running. Stop it before changing runtime settings.")
        }
        do {
            if let value = update.modelId {
                let normalized = try Self.normalizedModel(value)
                lock.lock()
                runtimeModelId = normalized
                if !modelOptions.contains(where: { $0.id == normalized }) {
                    modelOptions.append(AgentRuntimeOption(id: normalized, label: Self.modelLabel(normalized)))
                }
                lock.unlock()
            }
        } catch {
            emitSnapshot(detail: "settings failed")
            throw error
        }
        emitSnapshot(detail: "settings updated")
    }

    /// Slash commands the card handles itself instead of sending to the CLI.
    enum LocalCommand: Equatable {
        case mode(String)
        case model(String)
        case newChat
    }

    static func localCommand(in text: String) -> LocalCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let name = parts.first?.lowercased() ?? ""
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        switch name {
        case "/mode":
            return .mode(argument.lowercased())
        case "/model":
            return .model(argument)
        case "/new", "/new-chat", "/newchat":
            return .newChat
        default:
            return nil
        }
    }

    private func apply(_ command: LocalCommand) async throws {
        switch command {
        case .mode(let requested):
            guard Self.modes.contains(requested) else {
                throw Self.error(-7, "Cursor Agent mode must be one of ask, plan, or agent.")
            }
            guard requested != "agent" else {
                throw Self.error(-5, Self.agentModeRefusal)
            }
            lock.lock()
            mode = requested
            lock.unlock()
            appendEvent("Mode: \(requested)")
            emitSnapshot(detail: "settings updated")
        case .model(let requested):
            let normalized = try Self.normalizedModel(requested)
            lock.lock()
            runtimeModelId = normalized
            if !modelOptions.contains(where: { $0.id == normalized }) {
                modelOptions.append(AgentRuntimeOption(id: normalized, label: Self.modelLabel(normalized)))
            }
            lock.unlock()
            appendEvent("Model: \(normalized)")
            emitSnapshot(detail: "settings updated")
        case .newChat:
            let id = try await createChat()
            select(chatId: id)
            emitCurrentSnapshot()
        }
    }

    static func normalizedModel(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw error(-8, "Cursor Agent model is empty.")
        }
        let forbidden = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: "\"'`"))
        guard trimmed.rangeOfCharacter(from: forbidden) == nil else {
            throw error(-9, "Cursor Agent model must be one value without spaces or quotes.")
        }
        return trimmed
    }

    /// `cursor-agent --list-models` prints one model per line, the id first;
    /// anything after it is the label.
    static func parseModelList(_ output: String) -> [AgentRuntimeOption] {
        var options: [AgentRuntimeOption] = []
        var seen = Set<String>()
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = ANSIStripper.strip(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.lowercased().hasPrefix("available"), !line.lowercased().hasPrefix("models") else { continue }
            let cleaned = line.hasPrefix("-") || line.hasPrefix("*") ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces) : line
            let parts = cleaned.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let id = parts.first, Self.looksLikeModelId(id), seen.insert(id).inserted else { continue }
            let rest = parts.dropFirst().joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: " -–:()"))
            options.append(AgentRuntimeOption(id: id, label: rest.isEmpty ? Self.modelLabel(id) : rest))
        }
        return options
    }

    private static func looksLikeModelId(_ id: String) -> Bool {
        guard id.count <= 64, id.rangeOfCharacter(from: CharacterSet(charactersIn: "\"'`,;")) == nil else { return false }
        if id.lowercased() == "auto" { return true }
        return id.contains(where: \.isNumber) && id.contains(where: \.isLetter)
    }

    static func modelLabel(_ modelId: String) -> String {
        switch modelId {
        case defaultModel, "gpt-5.4-nano-none": return "GPT-5.4 Nano"
        default: return modelId
        }
    }

    /// The CLI prints this when its saved login is missing or rejected.
    static func isAuthenticationFailure(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return lowered.contains("authentication required") || lowered.contains("run 'agent login'") || lowered.contains("cursor_api_key")
    }

    // MARK: - Turns

    private func runTurn(prompt: String, chatId: String) async throws {
        let turnId = nextTurnId()
        let startedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let parser = CursorAgentStreamParser(agentID: agentID, turnId: turnId)
        let promptMessage = AgentChatMessage(messageId: "\(agentID)-\(turnId)-prompt", role: .user, text: prompt, atUnixMs: startedAt, kind: .text)

        lock.lock()
        interruptedTurn = false
        liveMessages = [promptMessage]
        liveDetails = [:]
        lastActivityUnixMs = startedAt
        currentStatus = .working
        currentDetail = "Cursor Agent is working"
        let modelId = runtimeModelId
        let mode = self.mode
        let workspace = self.workspace
        lock.unlock()
        emitCurrentSnapshot()

        var arguments = ["--print", "--output-format", "stream-json", "--stream-partial-output", "--trust", "--workspace", workspace, "--resume", chatId]
        if mode == "ask" || mode == "plan" {
            arguments += ["--mode", mode]
        }
        if !modelId.isEmpty {
            arguments += ["--model", modelId]
        }
        arguments.append(prompt)

        let result = await run(arguments: arguments, publish: { [weak self] chunk in
            guard let self else { return }
            if parser.feed(chunk) {
                self.publishLiveTurn(parser: parser, startedAt: startedAt, promptMessage: promptMessage)
            }
        })
        parser.finish()
        publishLiveTurn(parser: parser, startedAt: startedAt, promptMessage: promptMessage, force: true)

        lock.lock()
        let wasInterrupted = interruptedTurn
        interruptedTurn = false
        lock.unlock()

        if wasInterrupted {
            appendEvent(CursorConversationBuilder.stoppedDetail)
            setStatus(.idle, detail: CursorConversationBuilder.stoppedDetail)
        } else if let outcome = parser.outcome, !outcome.isError, result.status == 0 {
            setStatus(.done, detail: CursorConversationBuilder.doneDetail)
        } else {
            let tail = ANSIStripper.normalizeForLog(result.combinedOutput)
            if Self.isAuthenticationFailure(tail) {
                setStatus(.error, detail: Self.loginDetail)
            } else {
                let reason = parser.outcome?.text.isEmpty == false
                    ? parser.outcome!.text
                    : (parser.stray.suffix(3).joined(separator: " ").isEmpty ? "Cursor Agent exited with status \(result.status)" : parser.stray.suffix(3).joined(separator: " "))
                appendEvent(TranscriptPreview.singleLine(reason, limit: 200))
                setStatus(.error, detail: "prompt failed")
            }
        }
        // The chat's store is the durable transcript; it replaces the live rows
        // once it has caught up with the turn.
        reloadHistory(retainLiveIfShorter: true)
        refreshChats(selectNewest: false)
        emitCurrentSnapshot()

        if !wasInterrupted, parser.outcome == nil, result.status != 0 {
            throw Self.error(Int(result.status), Self.isAuthenticationFailure(result.combinedOutput) ? Self.loginDetail : "Cursor Agent exited with status \(result.status).")
        }
    }

    private func publishLiveTurn(parser: CursorAgentStreamParser, startedAt: Int64, promptMessage: AgentChatMessage, force: Bool = false) {
        let live = parser.messages(startedAtUnixMs: startedAt)
        lock.lock()
        liveMessages = [promptMessage] + live.messages
        liveDetails = live.details
        lastActivityUnixMs = Int64(Date().timeIntervalSince1970 * 1000)
        let throttled = !force && Date().timeIntervalSince(lastEmitAt) < 0.15
        let alreadyScheduled = deferredEmitScheduled
        if throttled { deferredEmitScheduled = true }
        lock.unlock()
        if !throttled {
            emitCurrentSnapshot()
        } else if !alreadyScheduled {
            // A burst of events must still end with the newest state on the
            // wire, or a tool row that arrived right after the turn started
            // stays hidden until the process ends.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.deferredEmitScheduled = false
                self.lock.unlock()
                self.emitCurrentSnapshot()
            }
        }
    }

    private struct RunResult {
        let status: Int32
        let combinedOutput: String
    }

    /// Runs the CLI once, feeding stdout to `publish` as it arrives. The
    /// process is tracked so an interrupt can end it.
    private func run(arguments: [String], publish: @escaping @Sendable (String) -> Void) async -> RunResult {
        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        process.environment = Self.commandEnvironment(overrides: environment)
        process.currentDirectoryURL = URL(fileURLWithPath: currentWorkspace(), isDirectory: true)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        let collected = OutputBuffer()

        setCurrentProcess(process)
        return await withCheckedContinuation { continuation in
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                collected.append(text)
                publish(text)
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                collected.append(String(decoding: data, as: UTF8.self))
            }
            process.terminationHandler = { [weak self] process in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                // Drain what is left, but never hang on a grandchild that
                // still holds the pipe after the CLI itself was ended.
                let drained = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .utility).async {
                    let restOut = stdout.fileHandleForReading.readDataToEndOfFile()
                    if !restOut.isEmpty {
                        let text = String(decoding: restOut, as: UTF8.self)
                        collected.append(text)
                        publish(text)
                    }
                    let restErr = stderr.fileHandleForReading.readDataToEndOfFile()
                    if !restErr.isEmpty { collected.append(String(decoding: restErr, as: UTF8.self)) }
                    drained.signal()
                }
                _ = drained.wait(timeout: .now() + 1.5)
                self?.clearCurrentProcess(process)
                continuation.resume(returning: RunResult(status: process.terminationStatus, combinedOutput: collected.value()))
            }
            do {
                try process.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                clearCurrentProcess(process)
                continuation.resume(returning: RunResult(status: -1, combinedOutput: "Could not start cursor-agent: \(error.localizedDescription)"))
            }
        }
    }

    /// Ends the running turn: SIGTERM first, SIGKILL if it lingers.
    private func terminateCurrentProcess() {
        lock.lock()
        let process = currentProcess
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    // MARK: - Chats

    private func ensureChat() async throws -> String {
        if let selected = currentSelectedChatId() { return selected }
        let id = try await createChat()
        select(chatId: id)
        return id
    }

    /// `create-chat` works offline and prints the new chat id.
    private func createChat() async throws -> String {
        let workspace = currentWorkspace()
        try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        let result = await run(arguments: ["create-chat", "--workspace", workspace, "--trust"], publish: { _ in })
        let output = ANSIStripper.strip(result.combinedOutput)
        let id = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { $0.range(of: #"^[0-9a-fA-F-]{20,}$"#, options: .regularExpression) != nil }
        guard result.status == 0, let id else {
            if Self.isAuthenticationFailure(output) {
                setStatus(.error, detail: Self.loginDetail)
                emitCurrentSnapshot()
                throw Self.error(-10, Self.loginDetail)
            }
            throw Self.error(-10, output.isEmpty ? "Cursor Agent did not return a usable chat id." : TranscriptPreview.singleLine(output, limit: 200))
        }
        lock.lock()
        ownedChatIds.insert(id)
        lock.unlock()
        refreshChats(selectNewest: false)
        return id
    }

    private func select(chatId: String) {
        lock.lock()
        let changed = selectedChatId != chatId
        selectedChatId = chatId
        ownedChatIds.insert(chatId)
        if changed {
            historyMessages = []
            historyDetails = [:]
            liveMessages = []
            liveDetails = [:]
            parsedStore = nil
            if let chat = chats.first(where: { $0.chatId == chatId }), let path = chat.workspacePath, !path.isEmpty {
                workspace = path
            }
        }
        lock.unlock()
        if changed {
            loadHistoryIfNeeded()
            setStatus(.idle, detail: "ready")
        }
    }

    /// Re-reads the chat list. With `selectNewest`, the newest chat in the
    /// current workspace (else the newest anywhere) becomes the selection when
    /// none is set. Returns true when the published list changed.
    @discardableResult
    private func refreshChats(selectNewest: Bool) -> Bool {
        let workspace = currentWorkspace()
        let listed = CursorCLIChatCatalog.chats(root: cursorRoot, knownWorkspaces: [workspace])
        lock.lock()
        let changed = listed != chats
        chats = listed
        if selectedChatId == nil, selectNewest {
            let hash = CursorCLIChatCatalog.workspaceHash(workspace)
            let candidate = listed.first { $0.workspaceHash == hash && $0.hasConversation } ?? listed.first { $0.hasConversation } ?? listed.first
            if let candidate {
                selectedChatId = candidate.chatId
                ownedChatIds.insert(candidate.chatId)
                if let path = candidate.workspacePath, !path.isEmpty { self.workspace = path }
            }
        }
        lock.unlock()
        return changed
    }

    private func loadHistoryIfNeeded() {
        reloadHistory(retainLiveIfShorter: false)
    }

    /// Parses the selected chat's store when it changed on disk.
    private func reloadHistory(retainLiveIfShorter: Bool) {
        lock.lock()
        guard let chatId = selectedChatId, let chat = chats.first(where: { $0.chatId == chatId }) else {
            lock.unlock()
            return
        }
        let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: chat.storePath)[.modificationDate] as? Date) ?? chat.modifiedAt
        let needsParse = parsedStore?.path != chat.storePath || parsedStore?.modifiedAt != modifiedAt
        lock.unlock()
        guard needsParse else { return }
        guard let conversation = CursorChatStoreReader(path: chat.storePath).conversation(agentID: agentID, maxMessages: AgentHistoryLimits.snapshotMessageCount) else {
            return
        }
        lock.lock()
        if selectedChatId == chatId {
            parsedStore = (chat.storePath, modifiedAt)
            let liveCount = liveMessages.count
            // A store that has not caught up with the finished turn would
            // blank the reply the phone just watched arrive.
            if retainLiveIfShorter, liveCount > 0, conversation.messages.count < historyMessages.count + liveCount {
                lock.unlock()
                return
            }
            historyMessages = conversation.messages
            historyDetails = conversation.messageDetails
            liveMessages = []
            liveDetails = [:]
            if let activity = conversation.lastActivityUnixMs { lastActivityUnixMs = max(lastActivityUnixMs, activity) }
        }
        lock.unlock()
    }

    private func pollRefresh() {
        guard !hasCurrentProcess() else { return }
        let listChanged = refreshChats(selectNewest: false)
        lock.lock()
        let before = historyMessages.count
        lock.unlock()
        reloadHistory(retainLiveIfShorter: false)
        lock.lock()
        let after = historyMessages.count
        lock.unlock()
        if listChanged || before != after {
            emitCurrentSnapshot()
        }
    }

    // MARK: - Hooks

    private func ownsChat(_ conversation: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !conversation.isEmpty && ownedChatIds.contains(conversation)
    }

    private func handleHook(_ event: CursorHookEvent) {
        // The stream already reports the turn; hooks only confirm that a chat
        // driven elsewhere (the same id in Terminal) moved, so refresh.
        guard event.conversation == currentSelectedChatId(), !hasCurrentProcess() else { return }
        if event.kind == .stop {
            reloadHistory(retainLiveIfShorter: false)
            emitCurrentSnapshot()
        }
    }

    // MARK: - Snapshot

    private func emitCurrentSnapshot() {
        lock.lock()
        let status = currentStatus
        let detail = currentDetail
        let messages = Array((historyMessages + liveMessages).suffix(AgentHistoryLimits.snapshotMessageCount))
        let activity = lastActivityUnixMs
        let targets = makeTargetsLocked()
        let title = chats.first { $0.chatId == selectedChatId }?.name
        lastEmitAt = Date()
        lock.unlock()

        stateStream.yield(AgentStateSnapshot(
            agentId: agentID,
            agentLabel: title.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? label,
            adapterKind: kind,
            status: status,
            statusDetail: detail,
            recentMessages: messages,
            lastActivityUnixMs: activity,
            hasVideoTrack: false,
            availableTargets: targets,
            runtimeControls: runtimeControls()
        ))
    }

    private func emitSnapshot(detail: String) {
        lock.lock()
        currentDetail = detail
        lock.unlock()
        emitCurrentSnapshot()
    }

    private func makeTargetsLocked() -> [AgentTargetOption] {
        let workspaceLabel = Self.folderLabel(workspace)
        var targets = chats.map { chat -> AgentTargetOption in
            let project = chat.workspacePath.map(Self.folderLabel) ?? "Cursor Agent"
            let selected = chat.chatId == selectedChatId
            return AgentTargetOption(
                targetId: chat.chatId,
                label: project,
                subtitle: chat.title,
                selected: selected,
                projectId: chat.workspacePath ?? chat.workspaceHash,
                projectLabel: project,
                projectPath: chat.workspacePath,
                threadId: chat.chatId,
                threadLabel: chat.title,
                targetKind: "thread",
                lastActivityUnixMs: chat.updatedAtUnixMs,
                isActive: selected,
                supportsNewThread: true
            )
        }
        targets.append(AgentTargetOption(
            targetId: Self.newChatTargetId,
            label: workspaceLabel,
            subtitle: "New chat",
            selected: false,
            projectId: workspace,
            projectLabel: workspaceLabel,
            projectPath: workspace,
            threadId: Self.newChatTargetId,
            threadLabel: "New chat",
            targetKind: "thread",
            isActive: false,
            supportsNewThread: true
        ))
        return targets
    }

    private func appendEvent(_ text: String) {
        lock.lock()
        let stamp = Int64(Date().timeIntervalSince1970 * 1000)
        liveMessages.append(AgentChatMessage(
            messageId: "\(agentID)-event-\(stamp)-\(liveMessages.count)",
            role: .system,
            text: text,
            atUnixMs: stamp,
            kind: .event
        ))
        lastActivityUnixMs = stamp
        lock.unlock()
    }

    // MARK: - State helpers

    private func setStatus(_ status: AgentStatus, detail: String) {
        lock.lock()
        currentStatus = status
        currentDetail = detail
        lock.unlock()
    }

    private func currentMode() -> String {
        lock.lock()
        defer { lock.unlock() }
        return mode
    }

    private func currentWorkspace() -> String {
        lock.lock()
        defer { lock.unlock() }
        return workspace
    }

    private func currentSelectedChatId() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return selectedChatId
    }

    private func chatSummary(_ chatId: String) -> CursorCLIChatSummary? {
        lock.lock()
        defer { lock.unlock() }
        return chats.first { $0.chatId == chatId }
    }

    private func nextTurnId() -> String {
        lock.lock()
        turnCounter += 1
        let id = "turn\(turnCounter)-\(Int(Date().timeIntervalSince1970))"
        lock.unlock()
        return id
    }

    private func hasCurrentProcess() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentProcess != nil
    }

    private func setCurrentProcess(_ process: Process) {
        lock.lock()
        currentProcess = process
        lock.unlock()
    }

    private func clearCurrentProcess(_ process: Process) {
        lock.lock()
        if currentProcess === process { currentProcess = nil }
        lock.unlock()
    }

    func selectedChatIdForTesting() -> String? { currentSelectedChatId() }
    func workspaceForTesting() -> String { currentWorkspace() }
    func modeForTesting() -> String { currentMode() }

    // MARK: - Environment

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
            if fileManager.isExecutableFile(atPath: (directory as NSString).appendingPathComponent(executable)) {
                return true
            }
        }
        return false
    }

    /// The folder chats run in: the caller's, else the host's own working
    /// directory when it is a real folder (the lab runs the host in the
    /// repository), else the most recently trusted Cursor workspace, else a
    /// Glasstunnel-owned folder.
    static func resolveWorkspace(preferred: String?, cursorRoot: URL) -> String {
        if let preferred, !preferred.isEmpty { return preferred }
        let cwd = FileManager.default.currentDirectoryPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if cwd != "/", cwd != home, !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd) {
            return cwd
        }
        let trusted = CursorCLIChatCatalog.trustedWorkspaces(root: cursorRoot)
        let newest = trusted.values
            .filter { FileManager.default.fileExists(atPath: $0) && !$0.hasPrefix("/private/var/folders") && !$0.hasPrefix("/var/folders") && !$0.hasPrefix(NSTemporaryDirectory()) }
            .max { lhs, rhs in
                let l = (try? FileManager.default.attributesOfItem(atPath: lhs)[.modificationDate] as? Date) ?? .distantPast
                let r = (try? FileManager.default.attributesOfItem(atPath: rhs)[.modificationDate] as? Date) ?? .distantPast
                return l < r
            }
        if let newest { return newest }
        return defaultWorkspacePath()
    }

    static func defaultWorkspacePath() -> String {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return directory
            .appendingPathComponent("Glasstunnel", isDirectory: true)
            .appendingPathComponent("CursorAgent", isDirectory: true)
            .path
    }

    static func folderLabel(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Cursor Agent" }
        let last = URL(fileURLWithPath: trimmed).lastPathComponent
        return last.isEmpty ? trimmed : last
    }

    private static func commandEnvironment(overrides: [String: String]) -> [String: String] {
        var merged = PTYWrapper.terminalEnvironment(overrides: overrides)
        merged["TERM"] = "xterm-256color"
        // A nested Cursor session must not inherit another agent's identity.
        merged["NO_COLOR"] = "1"
        return merged
    }

    private static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "CursorAgentAdapter", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ text: String) {
        lock.lock()
        storage += text
        if storage.count > 64 * 1024 {
            storage.removeFirst(storage.count - 64 * 1024)
        }
        lock.unlock()
    }

    func value() -> String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
