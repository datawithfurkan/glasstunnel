#if os(macOS)
import AppKit
#endif
import Foundation
import GTInput
import GTProtocol

/// Adapter for the Codex desktop app.
///
/// The GUI app already owns the real thread state and workspace context, so we
/// do not spawn a second Codex process. Instead we:
/// - focus the real app input via Accessibility, then type through keyboard events
/// - read the current thread history from Codex's local session JSONL files
/// - expose recently used Codex projects/threads as selectable targets
/// - switch the real Codex UI via Accessibility when the phone picks a target
public final class CodexDesktopAdapter: AgentAdapter, @unchecked Sendable {
    public static let bundleID = "com.openai.codex"
    private static let composerHints = [
        "Ask for follow-up changes",
        "Ask Codex",
        "Send a prompt",
        "Message",
        "Prompt",
    ]

    public let agentID: AgentID
    public let kind: AdapterKind = .mirror
    public let label: String

    private let targetPID: Int32
    private let keyboard: KeyboardInjector
    private let accessibility: AccessibilityInjector
    private let stateStream = StreamWriter<AgentStateSnapshot>()
    private let sessionsRoot: URL
    private let globalStateURL: URL
    private let sessionIndexURL: URL
    private let lock = NSLock()

    private var currentStatus: AgentStatus = .idle
    private var currentMessages: [AgentChatMessage] = []
    private var currentPendingInputRequest: AgentInputRequest?
    private var currentThreadName: String?
    private var currentActiveDesktopThreadName: String?
    private var currentWorkspaceRoot: String?
    private var currentTargets: [AgentTargetOption] = []
    private var targetDescriptors: [CodexTargetDescriptor] = []
    private var selectedWorkspaceRoot: String?
    private var selectedSessionPath: String?
    private var lastActivityUnixMs = Int64(Date().timeIntervalSince1970 * 1000)
    private var pollTask: Task<Void, Never>?
    private var lastResolvedSessionPath: String?
    private var lastResolvedSessionMTime: Date?
    private var lastCatalogRefresh = Date.distantPast
    private var lastSummariesRefresh = Date.distantPast
    private var sessionSummaries: [CodexSessionSummary] = []
    private var sessionSummaryCache: [String: CodexSessionSummary] = [:]

    public init(
        agentID: AgentID,
        label: String,
        targetPID: Int32,
        keyboard: KeyboardInjector = KeyboardInjector(),
        accessibility: AccessibilityInjector = AccessibilityInjector(),
        sessionsRoot: URL? = nil,
        globalStateURL: URL? = nil,
        sessionIndexURL: URL? = nil
    ) {
        self.agentID = agentID
        self.label = label
        self.targetPID = targetPID
        self.keyboard = keyboard
        self.accessibility = accessibility
        self.sessionsRoot = sessionsRoot ?? Self.defaultSessionsRoot()
        self.globalStateURL = globalStateURL ?? Self.defaultGlobalStateURL()
        self.sessionIndexURL = sessionIndexURL ?? Self.defaultSessionIndexURL()
    }

    public func observeState() -> AsyncStream<AgentStateSnapshot> {
        stateStream.make()
    }

    public func runtimeControls() -> AgentRuntimeControls? {
        CodexRuntimeCatalog.controls(
            selection: CodexRuntimeCatalog.defaultSelection(),
            editable: false,
            appliesOn: .managedLocally,
            note: "Managed in Codex"
        )
    }

    public func start() async throws {
        emitSnapshot(status: .working, detail: "loading Codex context")
        refreshCatalog(force: true)
        emitSnapshot(status: .working, detail: "loading message history")
        refreshSnapshot(force: true, detail: "linked to Codex desktop")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.throttledRefreshSnapshot()
            }
        }
    }

    public func stop() async {
        pollTask?.cancel()
        pollTask = nil
        emitSnapshot(status: .disconnected, detail: "stopped")
    }

    public func sendInput(_ text: String, submit: Bool) async throws {
        if let target = selectedTargetDescriptor(), let url = target.desktopThreadURL {
            try openCodexThread(url, label: target.label)
            try? await Task.sleep(nanoseconds: 450_000_000)
        }
        try deliverInputToCodex(text, submit: submit)

        let optimistic = AgentChatMessage(
            messageId: "\(agentID)-local-\(Int(Date().timeIntervalSince1970 * 1000))",
            role: .user,
            text: text
        )

        applyOptimisticMessage(optimistic)
        emitCurrentSnapshot(detail: selectedWorkspaceDetail())
    }

    public func respondToInputRequest(_ response: AgentInputRequestResponse) async throws {
        try await deliverInputRequestResponse(response)

        let optimistic = AgentChatMessage(
            messageId: "\(agentID)-choice-\(Int(Date().timeIntervalSince1970 * 1000))",
            role: .user,
            text: planningResponseSummary(response)
        )

        clearPendingInputRequest()

        applyOptimisticMessage(optimistic)
        emitCurrentSnapshot(detail: "planning choices submitted")
    }

    private func deliverInputToCodex(_ text: String, submit: Bool) throws {
        var accessibilityError: Error?
        for hint in Self.composerHints {
            do {
                try accessibility.deliver(
                    bundleID: Self.bundleID,
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
            let pid = try currentCodexPID()
            try focusCodexComposer()
            keyboard.pressCommandA(targetPID: pid)
            keyboard.pressDelete(targetPID: pid)
            keyboard.typeString(text, targetPID: pid)
            if submit { keyboard.pressReturn(targetPID: pid) }
        } catch {
            let axDescription = accessibilityError.map { String(describing: $0) } ?? "not attempted"
            throw NSError(
                domain: "CodexDesktopAdapter",
                code: 502,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Could not deliver prompt to Codex. Accessibility path failed: \(axDescription). Keyboard path failed: \(error)."
                ]
            )
        }
    }

    private func deliverInputRequestResponse(_ response: AgentInputRequestResponse) async throws {
        let request = pendingInputRequest()
        guard let request, request.requestId == response.requestId else {
            throw NSError(
                domain: "CodexDesktopAdapter",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Codex is not waiting for that planning request"]
            )
        }

        let answerByQuestion = Dictionary(uniqueKeysWithValues: response.answers.map { ($0.questionId, $0.choiceIds) })
        let pid = try currentCodexPID()
        keyboard.focusApplication(pid: pid)

        for (questionIndex, question) in request.questions.enumerated() {
            guard let selectedChoiceId = answerByQuestion[question.questionId]?.first,
                  let choice = question.choices.first(where: { $0.choiceId == selectedChoiceId }) else {
                continue
            }

            try pressPlanningChoice(choice, fallbackNumber: selectedChoiceId, pid: pid)
            try await Task.sleep(nanoseconds: 120_000_000)
            pressPlanningContinue(pid: pid)

            if questionIndex < request.questions.count - 1 {
                try await Task.sleep(nanoseconds: 180_000_000)
            }
        }
    }

    private func pressPlanningChoice(_ choice: AgentInputRequestChoice, fallbackNumber: String, pid: pid_t) throws {
        do {
            try accessibility.press(bundleID: Self.bundleID, matching: choice.label, exact: false)
        } catch {
            keyboard.typeString(fallbackNumber, targetPID: pid)
        }
    }

    private func pressPlanningContinue(pid: pid_t) {
        do {
            try accessibility.press(bundleID: Self.bundleID, matching: "Continue", exact: false)
        } catch {
            keyboard.pressReturn(targetPID: pid)
        }
    }

    private func planningResponseSummary(_ response: AgentInputRequestResponse) -> String {
        let request = pendingInputRequest()

        guard let request else {
            return "Submitted planning choices"
        }

        let answerByQuestion = Dictionary(uniqueKeysWithValues: response.answers.map { ($0.questionId, $0.choiceIds) })
        let lines = request.questions.compactMap { question -> String? in
            guard let selectedChoiceId = answerByQuestion[question.questionId]?.first,
                  let choice = question.choices.first(where: { $0.choiceId == selectedChoiceId }) else {
                return nil
            }
            let label = question.header.isEmpty ? question.question : question.header
            return "\(label): \(choice.label)"
        }

        return lines.isEmpty
            ? "Submitted planning choices"
            : "Submitted planning choices:\n" + lines.map { "- \($0)" }.joined(separator: "\n")
    }

    private func pendingInputRequest() -> AgentInputRequest? {
        lock.lock()
        defer { lock.unlock() }
        return currentPendingInputRequest
    }

    private func clearPendingInputRequest() {
        lock.lock()
        currentPendingInputRequest = nil
        lock.unlock()
    }

    public func interrupt() async throws {
        keyboard.focusApplication(pid: (try? currentCodexPID()) ?? targetPID)
        keyboard.pressEscape()
        setStatus(.working)
        emitCurrentSnapshot(detail: "Stopping")
    }

    private func focusCodexComposer() throws {
        var lastError: Error?
        for hint in Self.composerHints {
            do {
                try accessibility.focusInput(
                    bundleID: Self.bundleID,
                    targetHint: hint,
                    allowFallback: false
                )
                return
            } catch {
                lastError = error
            }
        }

        do {
            try focusCodexComposerByClick()
            return
        } catch {
            lastError = lastError ?? error
        }

        do {
            try accessibility.focusInput(bundleID: Self.bundleID, targetHint: nil, allowFallback: false)
        } catch {
            throw lastError ?? error
        }
    }

    private func focusCodexComposerByClick() throws {
        // Electron sometimes exposes only the native window shell through AX.
        // In that case, click the composer strip near the bottom of the front
        // Codex window and let KeyboardInjector type into the focused field.
        try accessibility.clickFrontWindow(
            bundleID: Self.bundleID,
            xFraction: 0.52,
            yFromBottom: 58
        )
        Thread.sleep(forTimeInterval: 0.16)
    }

    private func currentCodexPID() throws -> pid_t {
        #if os(macOS)
        guard let runningApp = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.bundleID)
            .first
        else {
            throw AccessibilityInjector.InjectionError.appNotRunning(Self.bundleID)
        }
        return runningApp.processIdentifier
        #else
        return targetPID
        #endif
    }

    public func selectTarget(_ targetID: String) async throws {
        guard let target = targetDescriptor(for: targetID) else { return }

        beginTargetSelection(target)
        emitCurrentSnapshot(detail: "opening \(target.label)")

        do {
            try selectTargetInDesktop(target)
        } catch {
            emitSnapshot(status: .error, detail: "couldn't open \(target.label)")
            throw error
        }

        try? await Task.sleep(nanoseconds: 700_000_000)
        refreshCatalog(force: true)
        refreshSnapshot(force: true)
    }

    private func selectTargetInDesktop(_ target: CodexTargetDescriptor) throws {
        if let url = target.desktopThreadURL {
            try openCodexThread(url, label: target.label)
            return
        }

        if let threadName = target.recentThreadName, !threadName.isEmpty {
            if (try? accessibility.press(bundleID: Self.bundleID, matching: threadName, exact: true)) != nil {
                return
            }
            if (try? accessibility.press(bundleID: Self.bundleID, matching: threadName, exact: false)) != nil {
                return
            }
        }

        let newChatLabel = "Start new chat in \(target.label)"
        if (try? accessibility.press(bundleID: Self.bundleID, matching: newChatLabel, exact: true)) != nil {
            return
        }

        try accessibility.press(bundleID: Self.bundleID, matching: target.label, exact: true)
    }

    private func openCodexThread(_ url: URL, label: String) throws {
        #if os(macOS)
        let opened: Bool
        if Thread.isMainThread {
            opened = NSWorkspace.shared.open(url)
        } else {
            opened = DispatchQueue.main.sync {
                NSWorkspace.shared.open(url)
            }
        }
        guard opened else {
            throw NSError(
                domain: "CodexDesktopAdapter",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "Could not open \(label) in Codex"]
            )
        }
        #else
        throw NSError(
            domain: "CodexDesktopAdapter",
            code: 503,
            userInfo: [NSLocalizedDescriptionKey: "Opening Codex threads is only available on macOS"]
        )
        #endif
    }

    private var lastRefreshAt = Date.distantPast

    private func throttledRefreshSnapshot() {
        let now = Date()
        // Coalesce rapid refresh calls to at most once every 2 seconds.
        if now.timeIntervalSince(lastRefreshAt) < 2 { return }
        lastRefreshAt = now
        refreshSnapshot(force: false)
    }

    private func refreshSnapshot(force: Bool, detail: String = "") {
        refreshCatalog(force: force)

        let desiredWorkspaceRoot: String? = {
            lock.lock()
            defer { lock.unlock() }
            return selectedWorkspaceRoot
        }()
        let desiredSessionPath: String? = {
            lock.lock()
            defer { lock.unlock() }
            return selectedSessionPath
        }()

        guard let session = latestSessionSummary(for: desiredWorkspaceRoot, sessionPath: desiredSessionPath) else {
            if force {
                emitSnapshot(status: .idle, detail: detail.isEmpty ? "waiting for Codex session" : detail)
            }
            return
        }

        if !force,
           session.path == lastResolvedSessionPath,
           session.modifiedAt == lastResolvedSessionMTime {
            return
        }

        lastResolvedSessionPath = session.path
        lastResolvedSessionMTime = session.modifiedAt

        guard let parsed = CodexDesktopSessionParser.parseRecentFile(
            at: URL(fileURLWithPath: session.path),
            agentID: agentID,
            maxMessages: AgentHistoryLimits.snapshotMessageCount
        ) else {
            return
        }

        let liveThreadName = activeDesktopThreadName()
        let resolvedThreadName = parsed.threadName ?? session.threadName

        lock.lock()
        currentMessages = parsed.messages
        currentPendingInputRequest = parsed.pendingInputRequest
        currentThreadName = resolvedThreadName
        currentActiveDesktopThreadName = liveThreadName
        currentWorkspaceRoot = parsed.workspaceRoot ?? session.workspaceRoot
        if selectedWorkspaceRoot == nil {
            selectedWorkspaceRoot = currentWorkspaceRoot
        }
        if selectedSessionPath == nil {
            selectedSessionPath = session.path
        }
        currentStatus = parsed.status
        lastActivityUnixMs = parsed.messages.last?.atUnixMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        currentTargets = makeProtocolTargets(
            from: targetDescriptors,
            selectedWorkspaceRoot: selectedWorkspaceRoot,
            selectedSessionPath: selectedSessionPath,
            activeDesktopThreadName: liveThreadName
        )
        lock.unlock()

        let nextDetail: String
        if !parsed.statusDetail.isEmpty {
            nextDetail = parsed.statusDetail
        } else if !detail.isEmpty {
            nextDetail = detail
        } else {
            nextDetail = Self.displayWorkspace(parsed.workspaceRoot ?? session.workspaceRoot)
        }
        emitCurrentSnapshot(detail: nextDetail)
    }

    private func refreshCatalog(force: Bool) {
        lock.lock()
        let shouldRefresh = force || targetDescriptors.isEmpty || Date().timeIntervalSince(lastCatalogRefresh) >= 5
        lock.unlock()
        guard shouldRefresh else { return }

        let summaries = refreshSessionSummaries(force: force || Date().timeIntervalSince(lastSummariesRefresh) >= 5)
        let catalog = CodexProjectCatalog.build(globalStateURL: globalStateURL, sessionSummaries: summaries)

        lock.lock()
        lastCatalogRefresh = Date()
        let selectedTargetStillExists = catalog.descriptors.contains { descriptor in
            if let selectedSessionPath {
                return descriptor.sessionPath == selectedSessionPath
            }
            return descriptor.workspaceRoot == selectedWorkspaceRoot
        }
        if !selectedTargetStillExists {
            let preferredDescriptor =
                catalog.descriptors.first { $0.workspaceRoot == catalog.activeWorkspaceRoot } ??
                catalog.descriptors.first
            selectedWorkspaceRoot = preferredDescriptor?.workspaceRoot
            selectedSessionPath = preferredDescriptor?.sessionPath
        }
        targetDescriptors = catalog.descriptors
        currentTargets = makeProtocolTargets(
            from: catalog.descriptors,
            selectedWorkspaceRoot: selectedWorkspaceRoot,
            selectedSessionPath: selectedSessionPath,
            activeDesktopThreadName: currentActiveDesktopThreadName
        )
        lock.unlock()
    }

    private func latestSessionSummary(for workspaceRoot: String?, sessionPath: String?) -> CodexSessionSummary? {
        let summaries = refreshSessionSummaries(force: false)
        if let sessionPath,
           let session = summaries.first(where: { $0.path == sessionPath }) {
            return session
        }
        if let workspaceRoot {
            return summaries
                .filter { $0.workspaceRoot == workspaceRoot }
                .max(by: { $0.modifiedAt < $1.modifiedAt })
        }
        return summaries.max(by: { $0.modifiedAt < $1.modifiedAt })
    }

    @discardableResult
    private func refreshSessionSummaries(force: Bool) -> [CodexSessionSummary] {
        lock.lock()
        let cachedSummaryList = sessionSummaries
        let shouldRefresh = force || cachedSummaryList.isEmpty
        lock.unlock()
        guard shouldRefresh else { return cachedSummaryList }

        let fm = FileManager.default
        lock.lock()
        let cachedSummaryMap = sessionSummaryCache
        lock.unlock()
        let indexedThreadNames = CodexSessionIndex.loadThreadNames(from: sessionIndexURL)
        guard let enumerator = fm.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return cachedSummaryList
        }

        var summaries: [CodexSessionSummary] = []
        var nextCache: [String: CodexSessionSummary] = [:]

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                values.isRegularFile == true,
                let modifiedAt = values.contentModificationDate
            else {
                continue
            }

            let path = url.path
            if let cached = cachedSummaryMap[path], cached.modifiedAt == modifiedAt {
                summaries.append(cached)
                nextCache[path] = cached
                continue
            }

            guard let parsed = CodexDesktopSessionParser.parseSummaryPreview(
                at: url,
                path: path,
                modifiedAt: modifiedAt
            ) else {
                continue
            }

            let resolved = CodexSessionIndex.applyingIndexedThreadName(
                to: parsed,
                indexedThreadNames: indexedThreadNames
            )

            summaries.append(resolved)
            nextCache[path] = resolved
        }

        lock.lock()
        lastSummariesRefresh = Date()
        sessionSummaries = summaries
        sessionSummaryCache = nextCache
        lock.unlock()
        return summaries
    }

    private func makeProtocolTargets(
        from descriptors: [CodexTargetDescriptor],
        selectedWorkspaceRoot: String?,
        selectedSessionPath: String?,
        activeDesktopThreadName: String? = nil
    ) -> [AgentTargetOption] {
        descriptors.map { descriptor in
            let selected: Bool
            if let selectedSessionPath {
                selected = descriptor.sessionPath == selectedSessionPath
            } else {
                selected = descriptor.workspaceRoot == selectedWorkspaceRoot && descriptor.workspaceRoot != nil
            }
            return descriptor.protocolTarget(
                selected: selected,
                activeDesktopThreadName: activeDesktopThreadName
            )
        }
    }

    private func targetDescriptor(for targetID: String) -> CodexTargetDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        return targetDescriptors.first { $0.targetId == targetID }
    }

    private func selectedTargetDescriptor() -> CodexTargetDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        if let selectedSessionPath {
            return targetDescriptors.first { $0.sessionPath == selectedSessionPath }
        }
        if let selectedWorkspaceRoot {
            return targetDescriptors.first { $0.workspaceRoot == selectedWorkspaceRoot }
        }
        return nil
    }

    private func emitCurrentSnapshot(detail: String) {
        lock.lock()
        let status = currentStatus
        let messages = currentMessages
        let pendingInputRequest = currentPendingInputRequest
        let threadName = currentThreadName
        let activity = lastActivityUnixMs
        let targets = currentTargets
        lock.unlock()

        let snap = AgentStateSnapshot(
            agentId: agentID,
            agentLabel: threadName ?? label,
            adapterKind: .mirror,
            status: status,
            statusDetail: detail,
            recentMessages: messages,
            lastActivityUnixMs: activity,
            hasVideoTrack: true,
            availableTargets: targets,
            pendingInputRequest: pendingInputRequest,
            runtimeControls: runtimeControls()
        )
        stateStream.yield(snap)
    }

    private func emitSnapshot(status: AgentStatus, detail: String) {
        lock.lock()
        currentStatus = status
        lock.unlock()
        emitCurrentSnapshot(detail: detail)
    }

    private func applyOptimisticMessage(_ optimistic: AgentChatMessage) {
        lock.lock()
        currentMessages.append(optimistic)
        if currentMessages.count > 24 {
            currentMessages.removeFirst(currentMessages.count - 24)
        }
        currentStatus = .working
        lastActivityUnixMs = optimistic.atUnixMs
        lock.unlock()
    }

    private func setStatus(_ status: AgentStatus) {
        lock.lock()
        currentStatus = status
        lock.unlock()
    }

    private func beginTargetSelection(_ target: CodexTargetDescriptor) {
        lock.lock()
        selectedWorkspaceRoot = target.workspaceRoot
        selectedSessionPath = target.sessionPath
        currentTargets = makeProtocolTargets(
            from: targetDescriptors,
            selectedWorkspaceRoot: target.workspaceRoot,
            selectedSessionPath: target.sessionPath,
            activeDesktopThreadName: currentActiveDesktopThreadName
        )
        currentStatus = .working
        lock.unlock()
    }

    private func activeDesktopThreadName() -> String? {
        let rawTitle = try? accessibility.frontWindowTitle(bundleID: Self.bundleID)
        guard var title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }

        for suffix in [" - Codex"] where title.hasSuffix(suffix) {
            title.removeLast(suffix.count)
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !title.isEmpty, title != "Codex", title != "ChatGPT", title != label else {
            return nil
        }

        return title
    }

    private func selectedWorkspaceDetail() -> String {
        lock.lock()
        let root = selectedWorkspaceRoot ?? currentWorkspaceRoot
        lock.unlock()
        return Self.displayWorkspace(root)
    }

    static func defaultSessionsRoot() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    static func defaultGlobalStateURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent(".codex-global-state.json")
    }

    static func defaultSessionIndexURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("session_index.jsonl")
    }

    static func displayWorkspace(_ workspaceRoot: String?) -> String {
        guard let workspaceRoot, !workspaceRoot.isEmpty else { return "Codex desktop" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if workspaceRoot.hasPrefix(home) {
            return "~" + workspaceRoot.dropFirst(home.count)
        }
        return workspaceRoot
    }
}

enum CodexSessionIndex {
    private struct ThreadNameRecord {
        let threadName: String
        let updatedAt: Date?
    }

    static func loadThreadNames(from url: URL) -> [String: String] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }

        var records: [String: ThreadNameRecord] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            guard
                let data = line.data(using: .utf8),
                let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let id = (raw["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !id.isEmpty,
                let threadName = (raw["thread_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !threadName.isEmpty
            else {
                continue
            }

            let updatedAt = parseUpdatedAt(raw["updated_at"])
            if let existing = records[id],
               !isNewerOrEqual(updatedAt, than: existing.updatedAt) {
                continue
            }
            records[id] = ThreadNameRecord(threadName: threadName, updatedAt: updatedAt)
        }

        return records.mapValues(\.threadName)
    }

    static func applyingIndexedThreadName(
        to summary: CodexSessionSummary,
        indexedThreadNames: [String: String]
    ) -> CodexSessionSummary {
        guard
            let sessionID = sessionID(fromPath: summary.path),
            let indexedThreadName = indexedThreadNames[sessionID]
        else {
            return summary
        }

        return CodexSessionSummary(
            path: summary.path,
            modifiedAt: summary.modifiedAt,
            workspaceRoot: summary.workspaceRoot,
            threadName: indexedThreadName
        )
    }

    static func sessionID(fromPath path: String) -> String? {
        let filename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        guard
            let match = regex.firstMatch(in: filename, range: range),
            let swiftRange = Range(match.range, in: filename)
        else {
            return nil
        }
        return String(filename[swiftRange]).lowercased()
    }

    private static func parseUpdatedAt(_ raw: Any?) -> Date? {
        guard let rawString = raw as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: rawString) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: rawString)
    }

    private static func isNewerOrEqual(_ candidate: Date?, than existing: Date?) -> Bool {
        switch (candidate, existing) {
        case let (candidate?, existing?):
            return candidate >= existing
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return true
        }
    }
}

struct CodexTargetDescriptor: Equatable {
    let targetId: String
    let workspaceRoot: String?
    let sessionPath: String?
    let label: String
    let subtitle: String
    let recentThreadName: String?
    let recentActivityUnixMs: Int64?
    let targetKind: String

    var desktopThreadURL: URL? {
        guard
            let sessionPath,
            let sessionID = CodexSessionIndex.sessionID(fromPath: sessionPath)
        else {
            return nil
        }
        return URL(string: "codex://threads/\(sessionID)")
    }

    func protocolTarget(selected: Bool, activeDesktopThreadName: String? = nil) -> AgentTargetOption {
        let threadLabel = recentThreadName
        let targetLabel = targetKind == "thread"
            ? threadLabel ?? label
            : label
        let active = selected && (
            Self.sameThreadName(recentThreadName, activeDesktopThreadName) || desktopThreadURL != nil
        )
        return AgentTargetOption(
            targetId: targetId,
            label: targetLabel,
            subtitle: subtitle,
            selected: selected,
            projectId: workspaceRoot,
            projectLabel: workspaceRoot == nil ? nil : label,
            projectPath: workspaceRoot,
            threadId: sessionPath ?? targetId,
            threadLabel: threadLabel,
            targetKind: targetKind,
            lastActivityUnixMs: recentActivityUnixMs,
            isActive: active,
            supportsNewThread: false
        )
    }

    private static func sameThreadName(_ lhs: String?, _ rhs: String?) -> Bool {
        guard
            let lhs = lhs?.trimmingCharacters(in: .whitespacesAndNewlines),
            let rhs = rhs?.trimmingCharacters(in: .whitespacesAndNewlines),
            !lhs.isEmpty,
            !rhs.isEmpty
        else {
            return false
        }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}

struct CodexSessionSummary: Equatable {
    let path: String
    let modifiedAt: Date
    let workspaceRoot: String?
    let threadName: String?
}

enum CodexProjectCatalog {
    struct Catalog {
        let descriptors: [CodexTargetDescriptor]
        let activeWorkspaceRoot: String?
    }

    static func build(globalStateURL: URL, sessionSummaries: [CodexSessionSummary]) -> Catalog {
        let globalState = loadGlobalState(from: globalStateURL)
        let classifiedSummaries = sessionSummaries.map { summary in
            guard
                let sessionID = CodexSessionIndex.sessionID(fromPath: summary.path),
                globalState.projectlessThreadIDs.contains(sessionID)
            else {
                return summary
            }
            return CodexSessionSummary(
                path: summary.path,
                modifiedAt: summary.modifiedAt,
                workspaceRoot: nil,
                threadName: summary.threadName
            )
        }

        var orderedRoots: [String] = []
        var seen = Set<String>()
        for root in globalState.projectOrder + globalState.savedWorkspaceRoots {
            guard !root.isEmpty, seen.insert(root).inserted else { continue }
            orderedRoots.append(root)
        }

        let projectSummaries = classifiedSummaries.compactMap { summary -> CodexSessionSummary? in
            guard let workspaceRoot = summary.workspaceRoot, !workspaceRoot.isEmpty else { return nil }
            return summary
        }
        let summariesByWorkspace = Dictionary(grouping: projectSummaries, by: { $0.workspaceRoot! })

        let recentUnknownRoots = projectSummaries
            .sorted(by: { $0.modifiedAt > $1.modifiedAt })
            .compactMap(\.workspaceRoot)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        orderedRoots.append(contentsOf: recentUnknownRoots)

        var descriptors: [CodexTargetDescriptor] = []
        var seenSessionPaths = Set<String>()

        for root in orderedRoots {
            let summaries = (summariesByWorkspace[root] ?? []).sorted(by: { $0.modifiedAt > $1.modifiedAt })
            if summaries.isEmpty {
                descriptors.append(projectDescriptor(root: root))
                continue
            }

            for summary in summaries where seenSessionPaths.insert(summary.path).inserted {
                descriptors.append(sessionDescriptor(summary: summary))
            }
        }

        let standaloneSummaries = classifiedSummaries
            .filter { ($0.workspaceRoot ?? "").isEmpty }
            .sorted(by: { $0.modifiedAt > $1.modifiedAt })
        for summary in standaloneSummaries where seenSessionPaths.insert(summary.path).inserted {
            descriptors.append(sessionDescriptor(summary: summary))
        }

        return Catalog(
            descriptors: descriptors,
            activeWorkspaceRoot: globalState.activeWorkspaceRoots.first
        )
    }

    private static func projectDescriptor(root: String) -> CodexTargetDescriptor {
        let projectLabel = URL(fileURLWithPath: root).lastPathComponent
        return CodexTargetDescriptor(
            targetId: root,
            workspaceRoot: root,
            sessionPath: nil,
            label: projectLabel,
            subtitle: CodexDesktopAdapter.displayWorkspace(root),
            recentThreadName: nil,
            recentActivityUnixMs: nil,
            targetKind: "project"
        )
    }

    private static func sessionDescriptor(summary: CodexSessionSummary) -> CodexTargetDescriptor {
        let threadName = summary.threadName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasThreadName = threadName?.isEmpty == false
        if let root = summary.workspaceRoot, !root.isEmpty {
            let projectLabel = URL(fileURLWithPath: root).lastPathComponent
            return CodexTargetDescriptor(
                targetId: summary.path,
                workspaceRoot: root,
                sessionPath: summary.path,
                label: projectLabel,
                subtitle: CodexDesktopAdapter.displayWorkspace(root),
                recentThreadName: hasThreadName ? threadName : projectLabel,
                recentActivityUnixMs: Int64(summary.modifiedAt.timeIntervalSince1970 * 1000),
                targetKind: "thread"
            )
        }

        let label = hasThreadName ? threadName! : "Codex chat"
        return CodexTargetDescriptor(
            targetId: summary.path,
            workspaceRoot: nil,
            sessionPath: summary.path,
            label: label,
            subtitle: "Standalone chat",
            recentThreadName: label,
            recentActivityUnixMs: Int64(summary.modifiedAt.timeIntervalSince1970 * 1000),
            targetKind: "thread"
        )
    }

    private struct GlobalState {
        var projectOrder: [String]
        var savedWorkspaceRoots: [String]
        var activeWorkspaceRoots: [String]
        var projectlessThreadIDs: Set<String>
    }

    private static func loadGlobalState(from url: URL) -> GlobalState {
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return GlobalState(
                projectOrder: [],
                savedWorkspaceRoots: [],
                activeWorkspaceRoots: [],
                projectlessThreadIDs: []
            )
        }

        var rootsByLocalProjectID: [String: [String]] = [:]
        for (projectID, rawProject) in json["local-projects"] as? [String: Any] ?? [:] {
            guard let project = rawProject as? [String: Any] else { continue }
            let roots = (project["rootPaths"] as? [String] ?? []).filter { !$0.isEmpty }
            guard !roots.isEmpty else { continue }
            rootsByLocalProjectID[projectID] = roots
            if let embeddedID = project["id"] as? String, !embeddedID.isEmpty {
                rootsByLocalProjectID[embeddedID] = roots
            }
        }

        func resolveRoots(_ values: [String]) -> [String] {
            values.flatMap { rootsByLocalProjectID[$0] ?? [$0] }
        }

        let selectedProject = json["selected-project"] as? [String: Any]
        let selectedProjectID = selectedProject?["projectId"] as? String
        let selectedProjectRoots = selectedProjectID.flatMap { rootsByLocalProjectID[$0] } ?? []
        let legacyActiveRoots = resolveRoots(json["active-workspace-roots"] as? [String] ?? [])

        return GlobalState(
            projectOrder: resolveRoots(json["project-order"] as? [String] ?? []),
            savedWorkspaceRoots: resolveRoots(json["electron-saved-workspace-roots"] as? [String] ?? []),
            activeWorkspaceRoots: selectedProjectRoots.isEmpty ? legacyActiveRoots : selectedProjectRoots,
            projectlessThreadIDs: Set(
                (json["projectless-thread-ids"] as? [String] ?? []).map { $0.lowercased() }
            )
        )
    }
}

enum CodexDesktopSessionParser {
    struct ParsedSession {
        let workspaceRoot: String?
        let threadName: String?
        let messages: [AgentChatMessage]
        let pendingInputRequest: AgentInputRequest?
        let status: AgentStatus
        let statusDetail: String
    }

    private struct ParsedMetadata {
        let workspaceRoot: String?
        let threadName: String?
        let isSubagent: Bool
        let isDesktopUserThread: Bool
    }

    private static let metadataPreviewByteCount = 256 * 1024
    private static let recentMessagesTailByteCount = AgentHistoryLimits.jsonlTailByteCount

    static func parseRecentFile(at url: URL, agentID: AgentID, maxMessages: Int) -> ParsedSession? {
        guard let fileSize = fileSize(at: url) else { return nil }

        if fileSize <= UInt64(metadataPreviewByteCount + recentMessagesTailByteCount),
           let jsonl = readChunk(at: url, offset: 0, length: Int(fileSize)) {
            return parse(jsonl: jsonl, agentID: agentID, maxMessages: maxMessages)
        }

        let head = readChunk(at: url, offset: 0, length: metadataPreviewByteCount) ?? ""
        let tailOffset = fileSize > UInt64(recentMessagesTailByteCount)
            ? fileSize - UInt64(recentMessagesTailByteCount)
            : 0
        let tail = readChunk(at: url, offset: tailOffset, length: recentMessagesTailByteCount) ?? ""

        guard !head.isEmpty || !tail.isEmpty else { return nil }

        let metadata = parseMetadata(jsonl: head + "\n" + tail)
        let recent = parse(jsonl: tail, agentID: agentID, maxMessages: maxMessages)
        return ParsedSession(
            workspaceRoot: metadata.workspaceRoot ?? recent.workspaceRoot,
            threadName: metadata.threadName ?? recent.threadName,
            messages: recent.messages,
            pendingInputRequest: recent.pendingInputRequest,
            status: recent.status,
            statusDetail: recent.statusDetail
        )
    }

    static func parseSummaryPreview(at url: URL, path: String, modifiedAt: Date) -> CodexSessionSummary? {
        guard let fileSize = fileSize(at: url) else { return nil }

        if fileSize <= UInt64(metadataPreviewByteCount + recentMessagesTailByteCount),
           let jsonl = readChunk(at: url, offset: 0, length: Int(fileSize)) {
            return parseSummary(jsonl: jsonl, path: path, modifiedAt: modifiedAt)
        }

        let head = readChunk(at: url, offset: 0, length: metadataPreviewByteCount) ?? ""
        let tailOffset = fileSize > UInt64(recentMessagesTailByteCount)
            ? fileSize - UInt64(recentMessagesTailByteCount)
            : 0
        let tail = readChunk(at: url, offset: tailOffset, length: recentMessagesTailByteCount) ?? ""
        guard !head.isEmpty || !tail.isEmpty else { return nil }
        return parseSummary(jsonl: head + "\n" + tail, path: path, modifiedAt: modifiedAt)
    }

    static func parse(jsonl: String, agentID: AgentID, maxMessages: Int) -> ParsedSession {
        let metadata = parseMetadata(jsonl: jsonl)
        var messages: [AgentChatMessage] = []
        var pendingInputRequest: AgentInputRequest?
        var status: AgentStatus = .idle
        var statusDetail = ""

        for (index, line) in jsonl.split(whereSeparator: \.isNewline).enumerated() {
            guard
                let data = line.data(using: .utf8),
                let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let recordType = raw["type"] as? String
            else {
                continue
            }

            if recordType == "event_msg",
               let payload = raw["payload"] as? [String: Any],
               let eventType = payload["type"] as? String {
                switch eventType {
                case "task_started":
                    status = .working
                    statusDetail = "Codex is working"
                case "task_complete":
                    status = .done
                    statusDetail = "Response ready"
                case "turn_aborted":
                    status = .idle
                    statusDetail = "Stopped"
                default:
                    break
                }
                continue
            }

            guard recordType == "response_item",
                  let payload = raw["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String else {
                continue
            }

            if payloadType == "function_call",
               payload["name"] as? String == "request_user_input",
               let callID = payload["call_id"] as? String,
               let arguments = payload["arguments"] as? String,
               let request = parseInputRequest(callID: callID, arguments: arguments) {
                pendingInputRequest = request
                continue
            }

            if payloadType == "function_call_output",
               let callID = payload["call_id"] as? String,
               callID == pendingInputRequest?.requestId {
                pendingInputRequest = nil
                continue
            }

            guard
                payloadType == "message",
                let roleString = payload["role"] as? String,
                let role = role(for: roleString)
            else {
                continue
            }

            let text = extractText(from: payload["content"])
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            messages.append(
                AgentChatMessage(
                    messageId: "\(agentID)-codex-\(index)",
                    role: role,
                    text: trimmed,
                    atUnixMs: parseTimestamp(raw["timestamp"])
                )
            )
        }

        if messages.count > maxMessages {
            messages = Array(messages.suffix(maxMessages))
        }

        if pendingInputRequest != nil {
            status = .waitingInput
            statusDetail = "Waiting for your answer"
        }

        return ParsedSession(
            workspaceRoot: metadata.workspaceRoot,
            threadName: metadata.threadName,
            messages: messages,
            pendingInputRequest: pendingInputRequest,
            status: status,
            statusDetail: statusDetail
        )
    }

    static func parseSummary(jsonl: String, path: String, modifiedAt: Date) -> CodexSessionSummary? {
        let metadata = parseMetadata(jsonl: jsonl)
        guard !metadata.isSubagent, metadata.isDesktopUserThread else { return nil }
        guard metadata.workspaceRoot != nil || metadata.threadName != nil else { return nil }
        return CodexSessionSummary(
            path: path,
            modifiedAt: modifiedAt,
            workspaceRoot: metadata.workspaceRoot,
            threadName: metadata.threadName
        )
    }

    private static func parseMetadata(jsonl: String) -> ParsedMetadata {
        var workspaceRoot: String?
        var threadName: String?
        var isSubagent = false
        var originator: String?
        var source: String?

        for line in jsonl.split(whereSeparator: \.isNewline) {
            guard
                let data = line.data(using: .utf8),
                let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let recordType = raw["type"] as? String
            else {
                continue
            }

            if recordType == "session_meta",
               let payload = raw["payload"] as? [String: Any] {
                if isSubagentMetadata(payload) {
                    isSubagent = true
                }
                originator = payload["originator"] as? String
                source = payload["source"] as? String
                if let cwd = payload["cwd"] as? String,
                   !cwd.isEmpty {
                    workspaceRoot = cwd
                }
                continue
            }

            if recordType == "event_msg",
               let payload = raw["payload"] as? [String: Any],
               payload["type"] as? String == "thread_name_updated",
               let nextThreadName = payload["thread_name"] as? String,
               !nextThreadName.isEmpty {
                threadName = nextThreadName
            }
        }

        let isDesktopUserThread = originator == "Codex Desktop" && source == "vscode"
        return ParsedMetadata(
            workspaceRoot: workspaceRoot,
            threadName: threadName,
            isSubagent: isSubagent,
            isDesktopUserThread: isDesktopUserThread
        )
    }

    private static func isSubagentMetadata(_ payload: [String: Any]) -> Bool {
        if (payload["thread_source"] as? String)?.caseInsensitiveCompare("subagent") == .orderedSame {
            return true
        }
        if let parentThreadID = payload["parent_thread_id"] as? String,
           !parentThreadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if let source = payload["source"] as? [String: Any],
           source["subagent"] != nil {
            return true
        }
        return false
    }

    private static func fileSize(at url: URL) -> UInt64? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else {
            return nil
        }
        return size.uint64Value
    }

    private static func readChunk(at url: URL, offset: UInt64, length: Int) -> String? {
        guard length > 0, let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: length), !data.isEmpty else {
                return ""
            }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private static func extractText(from rawContent: Any?) -> String {
        guard let parts = rawContent as? [[String: Any]] else { return "" }
        let texts = parts.compactMap { part -> String? in
            guard let type = part["type"] as? String else { return nil }
            switch type {
            case "input_text", "output_text":
                return part["text"] as? String
            default:
                return nil
            }
        }
        return texts.joined(separator: "\n\n")
    }

    private static func parseInputRequest(callID: String, arguments: String) -> AgentInputRequest? {
        guard
            let data = arguments.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let questions = raw["questions"] as? [[String: Any]]
        else {
            return nil
        }

        let parsedQuestions = questions.enumerated().compactMap { questionIndex, rawQuestion -> AgentInputRequestQuestion? in
            let questionID = (rawQuestion["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let question = (rawQuestion["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let questionID, !questionID.isEmpty, !question.isEmpty else {
                return nil
            }

            let choices = (rawQuestion["options"] as? [[String: Any]] ?? []).enumerated().compactMap {
                optionIndex,
                rawChoice -> AgentInputRequestChoice? in
                let label = (rawChoice["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !label.isEmpty else { return nil }
                let description = (rawChoice["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return AgentInputRequestChoice(
                    choiceId: "\(optionIndex + 1)",
                    label: label,
                    description: description,
                    recommended: label.localizedCaseInsensitiveContains("(Recommended)")
                )
            }

            guard !choices.isEmpty else { return nil }
            return AgentInputRequestQuestion(
                questionId: questionID,
                header: (rawQuestion["header"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "Question \(questionIndex + 1)",
                question: question,
                choices: choices
            )
        }

        guard !parsedQuestions.isEmpty else { return nil }
        return AgentInputRequest(requestId: callID, questions: parsedQuestions)
    }

    private static func parseTimestamp(_ raw: Any?) -> Int64 {
        guard let rawString = raw as? String else {
            return Int64(Date().timeIntervalSince1970 * 1000)
        }
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso8601.date(from: rawString) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        return Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func role(for rawRole: String) -> ChatRole? {
        switch rawRole {
        case "user":
            return .user
        case "assistant":
            return .assistant
        case "system":
            return .system
        default:
            return nil
        }
    }
}
