import Foundation
import GTProtocol
import GTSecurity

/// Shared base behavior for the CLI adapters (Claude Code, Codex, OpenCode).
///
/// Subclasses only need to override:
///   - `executable` / `arguments` for how to launch their CLI
///   - optionally `detectDoneMarkers()` to recognize when the agent has finished
///
/// Everything else (PTY lifecycle, ANSI stripping, chat message batching,
/// state streaming, redaction) lives here.
open class PTYAdapterBase: AgentAdapter, @unchecked Sendable {
    public let agentID: AgentID
    public let kind: AdapterKind
    public let label: String

    public let executable: String
    public private(set) var arguments: [String]
    public let environment: [String: String]
    public private(set) var cwd: String?
    open var idleThresholdSeconds: Double { 3.0 }
    open var streamsOutputWhileWorking: Bool { false }
    open var outputSnapshotIntervalSeconds: Double { 0.35 }
    open var collapsesTerminalRewritesForLog: Bool { false }
    open var submittedInputSettleNanoseconds: UInt64 { 0 }

    private var pty: PTYWrapper
    private let redactor: SecretRedactor
    private let stateStream: StreamWriter<AgentStateSnapshot>
    private var outputBuffer = ""
    /// Trailing bytes of a UTF-8 sequence split across PTY reads.
    private var pendingOutputBytes = Data()
    private var lastOutputAt: Date = .distantPast
    private var lastSnapshotAt: Date = .distantPast
    private var currentStatus: AgentStatus = .idle
    private var currentStatusDetail = ""
    private let lock = NSLock()
    private var idleTimerTask: Task<Void, Never>?

    public init(
        agentID: AgentID,
        kind: AdapterKind,
        label: String,
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        cwd: String? = nil,
        redactor: SecretRedactor = SecretRedactor()
    ) {
        self.agentID = agentID
        self.kind = kind
        self.label = label
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
        self.redactor = redactor
        self.stateStream = StreamWriter<AgentStateSnapshot>()
        self.pty = PTYWrapper(executable: executable, arguments: arguments, environment: environment, cwd: cwd)
    }

    public func observeState() -> AsyncStream<AgentStateSnapshot> {
        stateStream.make()
    }

    open func selectTarget(_ targetID: String) async throws {
        _ = targetID
    }

    open func runtimeControls() -> AgentRuntimeControls? {
        nil
    }

    open func updateRuntimeSettings(_ update: AgentRuntimeSettingsUpdate) async throws {
        _ = update
        throw NSError(
            domain: "AgentAdapter",
            code: -10,
            userInfo: [NSLocalizedDescriptionKey: "\(label) does not support remote model settings."]
        )
    }

    public func rejectRuntimeSettingsUpdateIfWorking() throws {
        lock.lock()
        let status = currentStatus
        let detail = currentStatusDetail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lock.unlock()

        guard status == .working && detail != "settings updated" else { return }
        throw NSError(
            domain: "PTYAdapterBase",
            code: -11,
            userInfo: [
                NSLocalizedDescriptionKey: "\(label) is running. Stop it before changing runtime settings.",
            ]
        )
    }

    open func respondToInputRequest(_ response: AgentInputRequestResponse) async throws {
        let summary = response.answers
            .map { "\($0.questionId): \($0.choiceIds.joined(separator: ", "))" }
            .joined(separator: "\n")
        try await sendInput(summary, submit: true)
    }

    open func start() async throws {
        configurePTYCallbacks()
        try pty.start()
        currentStatus = .idle
        currentStatusDetail = ""
        emitSnapshot(detail: "started")
        startIdleWatcher()
    }

    public func stop() async {
        idleTimerTask?.cancel()
        idleTimerTask = nil
        pty.onData = nil
        pty.onStateChange = nil
        pty.stop()
        currentStatus = .disconnected
        currentStatusDetail = "stopped"
        emitSnapshot(detail: "stopped")
    }

    public func shutdownImmediately() {
        idleTimerTask?.cancel()
        idleTimerTask = nil
        pty.onData = nil
        pty.onStateChange = nil
        pty.stopImmediately()
    }

    public func configureLaunch(arguments: [String]? = nil, cwd: String? = nil) {
        if let arguments {
            self.arguments = arguments
        }
        self.cwd = cwd
        self.pty = PTYWrapper(executable: executable, arguments: self.arguments, environment: environment, cwd: self.cwd)
    }

    public func restartProcess(arguments: [String]? = nil, cwd: String? = nil) throws {
        idleTimerTask?.cancel()
        idleTimerTask = nil

        pty.onData = nil
        pty.onStateChange = nil
        pty.stop()

        if let arguments {
            self.arguments = arguments
        }
        self.cwd = cwd

        lock.lock()
        outputBuffer = ""
        lastOutputAt = .distantPast
        lastSnapshotAt = .distantPast
        currentStatus = .idle
        currentStatusDetail = ""
        lock.unlock()

        pty = PTYWrapper(executable: executable, arguments: self.arguments, environment: environment, cwd: self.cwd)
        configurePTYCallbacks()
        try pty.start()
        emitSnapshot(detail: "started")
        startIdleWatcher()
    }

    public func sendInput(_ text: String, submit: Bool) async throws {
        if submit {
            let shouldRecover = shouldRecoverBeforeSubmittedInput(outputTail: recentOutputTail())
            if shouldRecover {
                pty.interrupt()
                try? await Task.sleep(nanoseconds: 80_000_000)
            }

            let fragments = submittedInputFragments(text)
            for (index, fragment) in fragments.enumerated() {
                pty.writeString(fragment)
                if submittedInputSettleNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: submittedInputSettleNanoseconds)
                }
                pty.writeString("\r")
                if index < fragments.count - 1 {
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
            }
            transitionTo(
                .working,
                detail: shouldRecover ? "recovered prompt and submitted input" : "user input submitted",
                forceEmit: true
            )
        } else {
            pty.writeString(text)
            transitionTo(.working, detail: "user input submitted", forceEmit: true)
        }
    }

    public func interrupt() async throws {
        pty.interrupt()
        let next = statusAfterInterrupt()
        transitionTo(next.status, detail: next.detail)
    }

    // MARK: - Output handling

    private func configurePTYCallbacks() {
        pty.onData = { [weak self] data in
            self?.handlePTYOutput(data)
        }
        pty.onStateChange = { [weak self] state in
            self?.handlePTYStateChange(state)
        }
    }

    private func handlePTYOutput(_ data: Data) {
        // Reads split UTF-8 sequences wherever the 4 KiB boundary falls; a
        // chunk that fails to decode as a whole must not be dropped, or the
        // process's last words (exit reasons, dialogs) vanish with it.
        lock.lock()
        pendingOutputBytes.append(data)
        let (str, remainder) = Self.decodeUTF8Prefix(pendingOutputBytes)
        pendingOutputBytes = remainder
        lock.unlock()
        guard !str.isEmpty else { return }
        handleDecodedPTYOutput(str)
    }

    /// Decodes the longest UTF-8 prefix of `data`, returning up to three
    /// trailing bytes of an unfinished sequence for the next chunk. Bytes that
    /// can never decode are replaced rather than dropped.
    static func decodeUTF8Prefix(_ data: Data) -> (String, Data) {
        if let whole = String(data: data, encoding: .utf8) {
            return (whole, Data())
        }
        for cut in 1...min(3, data.count) {
            let head = data.prefix(data.count - cut)
            if let text = String(data: head, encoding: .utf8) {
                return (text, Data(data.suffix(cut)))
            }
        }
        return (String(decoding: data, as: UTF8.self), Data())
    }

    /// Flushes bytes still waiting for the rest of a UTF-8 sequence, lossily;
    /// used when no more output can arrive.
    private func flushPendingOutputBytes() {
        lock.lock()
        let pending = pendingOutputBytes
        pendingOutputBytes = Data()
        lock.unlock()
        guard !pending.isEmpty else { return }
        handleDecodedPTYOutput(String(decoding: pending, as: UTF8.self))
    }

    private func handleDecodedPTYOutput(_ str: String) {
        let stripped = collapsesTerminalRewritesForLog ? ANSIStripper.normalizeForLog(str) : ANSIStripper.strip(str)
        let (redacted, hits) = redactor.redact(stripped)
        let now = Date()
        var shouldEmit = false
        lock.lock()
        if collapsesTerminalRewritesForLog {
            outputBuffer = ANSIStripper.collapseLineRewrites(outputBuffer + redacted)
        } else {
            outputBuffer.append(redacted)
        }
        if outputBuffer.count > 8192 {
            outputBuffer.removeFirst(outputBuffer.count - 8192)
        }
        lastOutputAt = now
        let wasIdle = currentStatus == .idle
        currentStatus = .working
        if wasIdle || (streamsOutputWhileWorking && now.timeIntervalSince(lastSnapshotAt) >= outputSnapshotIntervalSeconds) {
            shouldEmit = true
            lastSnapshotAt = now
        }
        let redactionDetail = hits.isEmpty ? "" : "(redacted: \(hits.joined(separator: ",")))"
        lock.unlock()
        if shouldEmit {
            emitSnapshot(detail: "output \(redactionDetail)")
        }
    }

    private func handlePTYStateChange(_ state: PTYWrapper.State) {
        switch state {
        case .idle, .running:
            break
        case .exited(let code):
            flushPendingOutputBytes()
            didExitProcess(status: code)
            transitionTo(code == 0 ? .done : .error, detail: "process exited (\(code))")
        case .error(let msg):
            transitionTo(.error, detail: msg)
        }
    }

    private func startIdleWatcher() {
        idleTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(1_000_000_000))
                } catch {
                    break
                }
                guard let self else { return }
                self.checkIdle()
            }
        }
    }

    private func checkIdle() {
        lock.lock()
        let since = Date().timeIntervalSince(lastOutputAt)
        let working = currentStatus == .working
        let current = currentStatus
        let buffer = outputBuffer
        lock.unlock()
        if working && since > idleThresholdSeconds {
            let next = statusAfterOutputSilence(buffer: buffer, silenceDuration: since)
            transitionTo(next.status, detail: next.detail, forceEmit: next.status != current)
        }
    }

    // MARK: - State transitions

    public func transitionTo(_ status: AgentStatus, detail: String = "", forceEmit: Bool = false) {
        lock.lock()
        let changed = currentStatus != status || currentStatusDetail != detail
        currentStatus = status
        currentStatusDetail = detail
        lock.unlock()
        if changed || forceEmit {
            emitSnapshot(detail: detail)
        }
    }

    public func emitSnapshot(detail: String = "") {
        lock.lock()
        let buffer = outputBuffer
        let status = currentStatus
        // The detail on the wire is the detail the surface reasons about
        // (for example "settings updated"), so it is also the detail we keep.
        currentStatusDetail = detail
        lastSnapshotAt = Date()
        lock.unlock()

        let recent = snapshotMessages(from: buffer)
        let snap = AgentStateSnapshot(
            agentId: agentID,
            agentLabel: label,
            adapterKind: kind,
            status: status,
            statusDetail: detail,
            recentMessages: recent,
            availableTargets: snapshotAvailableTargets(),
            pendingInputRequest: snapshotPendingInputRequest(),
            runtimeControls: runtimeControls()
        )
        stateStream.yield(snap)
    }

    /// Emit a fresh snapshot with the last published status detail. Use for
    /// background refreshes: the web/mobile surface keys behavior off details
    /// like "settings updated", which a periodic refresh must not overwrite.
    public func emitSnapshotKeepingDetail() {
        lock.lock()
        let detail = currentStatusDetail
        lock.unlock()
        emitSnapshot(detail: detail)
    }

    open func submittedInputFragments(_ text: String) -> [String] {
        [text]
    }

    open func shouldRecoverBeforeSubmittedInput(outputTail: String) -> Bool {
        false
    }

    open func statusAfterOutputSilence(buffer: String, silenceDuration: TimeInterval) -> (status: AgentStatus, detail: String) {
        (.done, "idle for \(Int(silenceDuration))s")
    }

    open func statusAfterInterrupt() -> (status: AgentStatus, detail: String) {
        (.idle, "interrupted")
    }

    open func didExitProcess(status: Int32) {
        _ = status
    }

    public func redactOutputForSnapshot(_ input: String) -> (String, [String]) {
        redactor.redact(input)
    }

    public func recentOutputTail(maxLength: Int = 512) -> String {
        lock.lock()
        let tail = String(outputBuffer.suffix(maxLength))
        lock.unlock()
        return tail
    }

    /// Seconds since the process last wrote to the PTY; huge when it has not
    /// written since the buffer was last reset.
    public func timeSinceLastOutput() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastOutputAt)
    }

    public func clearOutputBuffer() {
        lock.lock()
        outputBuffer = ""
        lastOutputAt = .distantPast
        lastSnapshotAt = .distantPast
        lock.unlock()
    }

    open func snapshotMessages(from buffer: String) -> [AgentChatMessage] {
        if buffer.isEmpty { return [] }
        let tail = String(buffer.suffix(4096))
        let (redactedTail, hits) = redactOutputForSnapshot(tail)
        let reasons = SecretRedactor.mergedReasons(hits, SecretRedactor.placeholderReasons(in: redactedTail))
        return [
            AgentChatMessage(
                messageId: "\(agentID)-tail",
                role: .assistant,
                text: redactedTail,
                redacted: !reasons.isEmpty,
                redactionReasons: reasons
            )
        ]
    }

    open func snapshotAvailableTargets() -> [AgentTargetOption]? {
        nil
    }

    open func snapshotPendingInputRequest() -> AgentInputRequest? {
        nil
    }
}

// A small helper that lets a single class own multiple concurrent subscribers.
public final class StreamWriter<Element: Sendable>: @unchecked Sendable {
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var latest: Element?
    private let lock = NSLock()

    public init() {}

    public func make() -> AsyncStream<Element> {
        AsyncStream { continuation in
            let id = UUID()
            let replay: Element?
            self.lock.lock()
            self.continuations[id] = continuation
            replay = self.latest
            self.lock.unlock()
            if let replay {
                continuation.yield(replay)
            }
            continuation.onTermination = { @Sendable _ in
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    public func yield(_ value: Element) {
        lock.lock()
        latest = value
        let cs = Array(continuations.values)
        lock.unlock()
        for c in cs { c.yield(value) }
    }

    public func finish() {
        lock.lock()
        latest = nil
        let cs = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for c in cs { c.finish() }
    }
}
