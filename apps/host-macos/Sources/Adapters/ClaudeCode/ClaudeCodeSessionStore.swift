import Foundation
import GTProtocol

/// Which client created (and drives) a session in the shared
/// `~/.claude/projects` store. Sessions written by the Claude desktop app
/// stamp `entrypoint: "claude-desktop"` on their user/assistant records; the
/// CLI stamps its own values, and legacy transcripts may have none — those
/// count as CLI so older sessions keep working.
enum ClaudeCodeSessionOwner: Equatable {
    case cli
    case desktop

    static let desktopEntrypoint = "claude-desktop"

    init(entrypoint: String?) {
        self = entrypoint == Self.desktopEntrypoint ? .desktop : .cli
    }
}

struct ClaudeCodeSessionSummary: Equatable {
    let path: String
    let sessionId: String
    let modifiedAt: Date
    let workspaceRoot: String
    let threadName: String?
    let owner: ClaudeCodeSessionOwner
}

/// Memoizes summary previews by transcript path + modification date so a
/// periodic store scan only re-reads transcripts that actually changed.
final class ClaudeCodeSessionSummaryCache: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var registry: [String: ClaudeCodeSessionSummaryCache] = [:]

    private let lock = NSLock()
    private var entries: [String: (modifiedAt: Date, summary: ClaudeCodeSessionSummary?)] = [:]
    private var pathsBySessionId: [String: String] = [:]

    init() {}

    /// One cache per projects root, so every adapter reading the same store
    /// parses a changed transcript once rather than once per adapter.
    static func shared(for projectsRoot: URL) -> ClaudeCodeSessionSummaryCache {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[projectsRoot.path] {
            return existing
        }
        let cache = ClaudeCodeSessionSummaryCache()
        registry[projectsRoot.path] = cache
        return cache
    }

    func summary(
        for url: URL,
        modifiedAt: Date,
        parse: () -> ClaudeCodeSessionSummary?
    ) -> ClaudeCodeSessionSummary? {
        lock.lock()
        if let entry = entries[url.path], entry.modifiedAt == modifiedAt {
            lock.unlock()
            return entry.summary
        }
        lock.unlock()

        let parsed = parse()
        lock.lock()
        entries[url.path] = (modifiedAt, parsed)
        if let parsed {
            pathsBySessionId[parsed.sessionId] = url.path
        }
        lock.unlock()
        return parsed
    }

    /// Any transcript already seen by a scan, regardless of owner.
    func cachedSummary(forSessionId sessionId: String) -> ClaudeCodeSessionSummary? {
        lock.lock()
        defer { lock.unlock() }
        guard let path = pathsBySessionId[sessionId] else { return nil }
        return entries[path]?.summary
    }

    func retain(onlyPaths paths: Set<String>) {
        lock.lock()
        entries = entries.filter { paths.contains($0.key) }
        pathsBySessionId = pathsBySessionId.filter { paths.contains($0.value) }
        lock.unlock()
    }
}

enum ClaudeCodeSessionStore {
    static func defaultProjectsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    static func loadSummaries(
        projectsRoot: URL = defaultProjectsRoot(),
        limit: Int = AgentHistoryLimits.sessionSummaryCount,
        owner: ClaudeCodeSessionOwner? = nil,
        cache: ClaudeCodeSessionSummaryCache? = nil
    ) -> [ClaudeCodeSessionSummary] {
        let files = sessionFiles(projectsRoot: projectsRoot)
        cache?.retain(onlyPaths: Set(files.map(\.path)))
        return files
            .compactMap { url -> ClaudeCodeSessionSummary? in
                let modifiedAt = modificationDate(url) ?? .distantPast
                let parse = {
                    ClaudeCodeSessionParser.parseSummaryPreview(
                        at: url,
                        path: url.path,
                        modifiedAt: modifiedAt
                    )
                }
                return cache?.summary(for: url, modifiedAt: modifiedAt, parse: parse) ?? parse()
            }
            .filter { owner == nil || $0.owner == owner }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(limit)
            .map { $0 }
    }

    /// Targeted owner lookup. Session transcripts are named `<sessionId>.jsonl`
    /// inside one project directory, so this avoids scanning every transcript
    /// and reads the same head+tail window a summary scan uses. Returns nil
    /// when the session has no transcript yet or no record in that window
    /// carries an `entrypoint`, i.e. when the owner is genuinely unknown —
    /// callers must not guess.
    static func owner(
        ofSessionId sessionId: String,
        projectsRoot: URL = defaultProjectsRoot()
    ) -> ClaudeCodeSessionOwner? {
        guard !sessionId.isEmpty else { return nil }
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for dir in projectDirs {
            let candidate = dir.appendingPathComponent("\(sessionId).jsonl")
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            return ClaudeCodeSessionParser.parseEntrypointPreview(at: candidate)
                .map(ClaudeCodeSessionOwner.init(entrypoint:))
        }
        return nil
    }

    private static func sessionFiles(projectsRoot: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: projectsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if url.pathComponents.contains("subagents") {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension == "jsonl" else { continue }
            files.append(url)
        }
        return files
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }
}

enum ClaudeCodeSessionParser {
    struct ParsedSession {
        let sessionId: String?
        let workspaceRoot: String?
        let threadName: String?
        let entrypoint: String?
        let messages: [AgentChatMessage]
        /// Full tool output for messages whose snapshot text is a preview.
        let messageDetails: [MessageID: String]
        /// Turn state derived from the transcript: an assistant record with
        /// `stop_reason == end_turn` ends a turn, `tool_use` and tool results
        /// mean Claude is still working, and an unanswered `AskUserQuestion`
        /// means Claude is waiting on the user.
        let status: AgentStatus
        let statusDetail: String
        let pendingInputRequest: AgentInputRequest?
        /// Model stamped on the newest assistant record.
        let model: String?
        let lastActivityUnixMs: Int64?
        /// True when `threadName` came from a title record rather than the
        /// first prompt, so a tail-only parse can be trusted over the head.
        let titleIsExplicit: Bool
    }

    private struct ParsedMetadata {
        let sessionId: String?
        let workspaceRoot: String?
        /// `custom-title` / `ai-title`, newest record wins.
        let explicitTitle: String?
        let firstPrompt: String?
        let entrypoint: String?

        var threadName: String? { explicitTitle ?? firstPrompt }
    }

    private struct ExtractedContent {
        var text: String
        var tools: [PendingToolCall]
        var toolResultIds: [String]
        var hasHumanText: Bool
        let toolCalls: [ToolCallPart]
        let toolResults: [ToolResultPart]
    }

    static let interruptedMarkerPrefix = "[Request interrupted by user"
    static let askUserQuestionToolName = "AskUserQuestion"
    /// Local slash commands (`/model`, `/clear`, …) are logged as user records
    /// but never start a turn.
    private static let localCommandPrefixes = ["<command-", "<local-command-"]

    private static let metadataPreviewByteCount = 256 * 1024
    private static let recentMessagesTailByteCount = AgentHistoryLimits.jsonlTailByteCount
    /// Titles and the latest activity live at the end of a transcript, so a
    /// summary needs a small tail read in addition to the metadata head.
    private static let summaryTailByteCount = 64 * 1024
    private static let toolResultTextLimit = 4000

    /// The metadata head of a transcript plus, for files too large to read
    /// whole, its most recent bytes. `tail` is nil when `head` is the whole file.
    private struct TranscriptChunks {
        let head: String
        let tail: String?
    }

    private static func readChunks(at url: URL, tailByteCount: Int) -> TranscriptChunks? {
        guard let fileSize = fileSize(at: url) else { return nil }

        if fileSize <= UInt64(metadataPreviewByteCount + tailByteCount) {
            guard let whole = readChunk(at: url, offset: 0, length: Int(fileSize)) else { return nil }
            return TranscriptChunks(head: whole, tail: nil)
        }

        let head = readChunk(at: url, offset: 0, length: metadataPreviewByteCount) ?? ""
        let tail = readChunk(at: url, offset: fileSize - UInt64(tailByteCount), length: tailByteCount) ?? ""
        guard !head.isEmpty || !tail.isEmpty else { return nil }
        return TranscriptChunks(head: head, tail: tail)
    }

    static func parseRecentFile(at url: URL, agentID: AgentID, maxMessages: Int) -> ParsedSession? {
        guard let chunks = readChunks(at: url, tailByteCount: recentMessagesTailByteCount) else { return nil }
        guard let tail = chunks.tail else {
            return parse(jsonl: chunks.head, agentID: agentID, maxMessages: maxMessages)
        }

        // The head carries identity and the first prompt; the tail carries the
        // newest title records, which outrank anything in the head.
        let headMetadata = parseMetadata(jsonl: chunks.head)
        let recent = parse(jsonl: tail, agentID: agentID, maxMessages: maxMessages)
        let threadName = recent.titleIsExplicit
            ? recent.threadName
            : headMetadata.threadName ?? recent.threadName
        return ParsedSession(
            sessionId: headMetadata.sessionId ?? recent.sessionId,
            workspaceRoot: headMetadata.workspaceRoot ?? recent.workspaceRoot,
            threadName: threadName,
            entrypoint: headMetadata.entrypoint ?? recent.entrypoint,
            messages: recent.messages,
            messageDetails: recent.messageDetails,
            status: recent.status,
            statusDetail: recent.statusDetail,
            pendingInputRequest: recent.pendingInputRequest,
            model: recent.model,
            lastActivityUnixMs: recent.lastActivityUnixMs,
            titleIsExplicit: recent.titleIsExplicit || headMetadata.explicitTitle != nil
        )
    }

    static func parseSummaryPreview(at url: URL, path: String, modifiedAt: Date) -> ClaudeCodeSessionSummary? {
        guard let chunks = readChunks(at: url, tailByteCount: summaryTailByteCount) else { return nil }
        let jsonl = chunks.tail.map { chunks.head + "\n" + $0 } ?? chunks.head
        return parseSummary(jsonl: jsonl, path: path, modifiedAt: modifiedAt)
    }

    /// Answers "which client wrote this transcript?" from the same window a
    /// summary scan reads, so the two can never disagree about an owner.
    static func parseEntrypointPreview(at url: URL) -> String? {
        guard let chunks = readChunks(at: url, tailByteCount: summaryTailByteCount) else { return nil }
        let jsonl = chunks.tail.map { chunks.head + "\n" + $0 } ?? chunks.head
        return parseMetadata(jsonl: jsonl).entrypoint
    }

    static func parse(jsonl: String, agentID: AgentID, maxMessages: Int) -> ParsedSession {
        let metadata = parseMetadata(jsonl: jsonl)
        var messages: [AgentChatMessage] = []
        var status: AgentStatus = .idle
        var statusDetail = ""
        var pendingInputRequest: AgentInputRequest?
        var model: String?
        var lastActivityUnixMs: Int64?
        /// Set by the "[Request interrupted…]" record. The app then files the
        /// interrupted tool's result as one more user record; that record must
        /// not read as a new turn, or "Stopped" flips back to "working" until
        /// the next real prompt.
        var interruptedTurn = false
        var messageDetails: [MessageID: String] = [:]
        /// Tool calls still waiting for their result, for pairing and timing.
        var toolCallStartedAt: [String: Int64] = [:]
        var toolCallNames: [String: String] = [:]

        for (index, line) in jsonl.split(whereSeparator: \.isNewline).enumerated() {
            guard
                let data = line.data(using: .utf8),
                let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let recordType = raw["type"] as? String
            else {
                continue
            }
            // Sidechain records belong to subagent turns rendered elsewhere.
            if raw["isSidechain"] as? Bool == true { continue }
            guard let role = role(for: recordType) else { continue }
            let recordAt = parseTimestamp(raw["timestamp"])
            let message = raw["message"] as? [String: Any]
            let contentSource = message?["content"] ?? raw["content"]
            let extracted = extractContent(from: contentSource)
            let text = extracted.text.trimmingCharacters(in: .whitespacesAndNewlines)

            // Housekeeping records carry no conversation progress; only
            // user/assistant/system records move the activity clock.
            if let recordAt {
                lastActivityUnixMs = recordAt
            }

            switch recordType {
            case "user":
                if text.hasPrefix(interruptedMarkerPrefix) {
                    status = .idle
                    statusDetail = "Stopped"
                    pendingInputRequest = nil
                    interruptedTurn = true
                    messages.append(AgentChatMessage(
                        messageId: "\(agentID)-claude-\(index)",
                        role: .system,
                        text: "Stopped",
                        atUnixMs: recordAt ?? Int64(Date().timeIntervalSince1970 * 1000),
                        kind: .event
                    ))
                    continue
                }
                if raw["isMeta"] as? Bool == true || localCommandPrefixes.contains(where: { text.hasPrefix($0) }) {
                    continue
                }
                if interruptedTurn && !extracted.hasHumanText {
                    // The interrupted tool's own result: keep "Stopped".
                    break
                }
                interruptedTurn = false
                status = .working
                statusDetail = "Claude is working"
                // The answer clears the question; so does moving on without one.
                if pendingInputRequest != nil,
                   extracted.hasHumanText || extracted.toolResultIds.contains(pendingInputRequest!.requestId) {
                    pendingInputRequest = nil
                }
            case "assistant":
                interruptedTurn = false
                // A newer assistant record means any earlier question was
                // abandoned or answered outside the transcript.
                pendingInputRequest = nil
                // Placeholder records stamp "<synthetic>" rather than a model.
                if let stampedModel = message?["model"] as? String, !stampedModel.isEmpty, !stampedModel.hasPrefix("<") {
                    model = stampedModel
                }
                if let question = askUserQuestion(in: contentSource) {
                    pendingInputRequest = question
                }
                switch message?["stop_reason"] as? String {
                case "end_turn", "stop_sequence", "max_tokens":
                    status = .done
                    statusDetail = "Response ready"
                case "tool_use":
                    status = .working
                    statusDetail = "Claude is working"
                default:
                    break
                }
            default:
                break
            }

            if text.isEmpty, extracted.toolCalls.isEmpty, extracted.toolResults.isEmpty { continue }
            let at = recordAt ?? Int64(Date().timeIntervalSince1970 * 1000)
            if !text.isEmpty {
                messages.append(AgentChatMessage(
                    messageId: "\(agentID)-claude-\(index)",
                    role: role,
                    text: text,
                    atUnixMs: at,
                    kind: .text
                ))
            }
            // One row per tool call. `text` keeps the old "Using X" wording for
            // phones that predate the structured fields.
            for (offset, call) in extracted.toolCalls.enumerated() {
                toolCallStartedAt[call.id] = at
                toolCallNames[call.id] = call.name
                messages.append(AgentChatMessage(
                    messageId: "\(agentID)-claude-\(index)-c\(offset)",
                    role: .tool,
                    text: "Using \(call.name)",
                    atUnixMs: at,
                    pendingToolCalls: [PendingToolCall(toolName: call.name, toolCallId: call.id, summary: "Using \(call.name)")],
                    kind: .toolCall,
                    toolName: call.name,
                    toolCallId: call.id,
                    title: toolTitle(name: call.name, input: call.input)
                ))
            }
            // One row per result, paired with its call by id; the snapshot carries
            // a preview and the full output stays available on request.
            for (offset, result) in extracted.toolResults.enumerated() {
                let preview = TranscriptPreview.make(result.text)
                let messageId = "\(agentID)-claude-\(index)-r\(offset)"
                let startedAt = toolCallStartedAt.removeValue(forKey: result.id)
                messages.append(AgentChatMessage(
                    messageId: messageId,
                    role: .tool,
                    text: preview.text,
                    atUnixMs: at,
                    kind: .toolResult,
                    toolName: toolCallNames[result.id] ?? "",
                    toolCallId: result.id,
                    outputLineCount: preview.lineCount,
                    durationMs: startedAt.map { max(0, at - $0) } ?? 0,
                    isError: result.isError,
                    truncated: preview.truncated
                ))
                if preview.truncated {
                    messageDetails[messageId] = preview.detail
                }
            }
        }

        if messages.count > maxMessages {
            messages = Array(messages.suffix(maxMessages))
        }

        if pendingInputRequest != nil {
            status = .waitingInput
            statusDetail = "Waiting for your answer"
        }

        return ParsedSession(
            sessionId: metadata.sessionId,
            workspaceRoot: metadata.workspaceRoot,
            threadName: metadata.threadName,
            entrypoint: metadata.entrypoint,
            messages: messages,
            messageDetails: messageDetails.filter { detail in messages.contains { $0.messageId == detail.key } },
            status: status,
            statusDetail: statusDetail,
            pendingInputRequest: pendingInputRequest,
            model: model,
            lastActivityUnixMs: lastActivityUnixMs,
            titleIsExplicit: metadata.explicitTitle != nil
        )
    }

    static func parseSummary(jsonl: String, path: String, modifiedAt: Date) -> ClaudeCodeSessionSummary? {
        let metadata = parseMetadata(jsonl: jsonl)
        guard let sessionId = metadata.sessionId, let workspaceRoot = metadata.workspaceRoot else {
            return nil
        }
        return ClaudeCodeSessionSummary(
            path: path,
            sessionId: sessionId,
            modifiedAt: modifiedAt,
            workspaceRoot: workspaceRoot,
            threadName: metadata.threadName,
            owner: ClaudeCodeSessionOwner(entrypoint: metadata.entrypoint)
        )
    }

    private static func parseMetadata(jsonl: String) -> ParsedMetadata {
        var sessionId: String?
        var workspaceRoot: String?
        var firstUserMessage: String?
        var entrypoint: String?
        var customTitle: String?
        var aiTitle: String?

        for line in jsonl.split(whereSeparator: \.isNewline) {
            guard
                let data = line.data(using: .utf8),
                let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let recordType = raw["type"] as? String
            else {
                continue
            }

            if sessionId == nil, let rawSessionId = raw["sessionId"] as? String, !rawSessionId.isEmpty {
                sessionId = rawSessionId
            }
            if workspaceRoot == nil, let cwd = raw["cwd"] as? String, !cwd.isEmpty {
                workspaceRoot = cwd
            }
            if entrypoint == nil, let rawEntrypoint = raw["entrypoint"] as? String, !rawEntrypoint.isEmpty {
                entrypoint = rawEntrypoint
            }
            // Title records are appended after every turn. Within a type the
            // newest wins; a user-set custom title outranks any AI title.
            switch recordType {
            case "custom-title":
                if let title = raw["customTitle"] as? String, !title.isEmpty { customTitle = title }
            case "ai-title":
                if let title = raw["aiTitle"] as? String, !title.isEmpty { aiTitle = title }
            case "user" where firstUserMessage == nil:
                let contentSource = (raw["message"] as? [String: Any])?["content"] ?? raw["content"]
                let extracted = extractContent(from: contentSource)
                let text = extracted.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if extracted.hasHumanText, !text.isEmpty, !text.hasPrefix(interruptedMarkerPrefix) {
                    firstUserMessage = makeTitle(text)
                }
            default:
                break
            }
        }

        return ParsedMetadata(
            sessionId: sessionId,
            workspaceRoot: workspaceRoot,
            explicitTitle: customTitle ?? aiTitle,
            firstPrompt: firstUserMessage,
            entrypoint: entrypoint
        )
    }

    struct ToolCallPart {
        let id: String
        let name: String
        let input: [String: Any]
    }

    struct ToolResultPart {
        let id: String
        let text: String
        let isError: Bool
    }

    private static func extractContent(from rawContent: Any?) -> ExtractedContent {
        if let text = rawContent as? String {
            return ExtractedContent(text: text, tools: [], toolResultIds: [], hasHumanText: !text.isEmpty, toolCalls: [], toolResults: [])
        }

        guard let parts = rawContent as? [[String: Any]] else {
            return ExtractedContent(text: "", tools: [], toolResultIds: [], hasHumanText: false, toolCalls: [], toolResults: [])
        }

        var texts: [String] = []
        var tools: [PendingToolCall] = []
        var toolResultIds: [String] = []
        var toolCalls: [ToolCallPart] = []
        var toolResults: [ToolResultPart] = []
        var hasHumanText = false

        for part in parts {
            guard let type = part["type"] as? String else { continue }
            switch type {
            case "text":
                // Injected context blocks ride along with tool results and
                // prompts; they are not something the person typed.
                if let text = part["text"] as? String, !text.isEmpty, !text.hasPrefix("<system-reminder>") {
                    texts.append(text)
                    hasHumanText = true
                }
            case "tool_use":
                let name = part["name"] as? String ?? "tool"
                let id = part["id"] as? String ?? "\(name)-\(tools.count + 1)"
                tools.append(PendingToolCall(toolName: name, toolCallId: id, summary: "Using \(name)"))
                toolCalls.append(ToolCallPart(id: id, name: name, input: part["input"] as? [String: Any] ?? [:]))
            case "tool_result":
                let id = part["tool_use_id"] as? String ?? ""
                if !id.isEmpty {
                    toolResultIds.append(id)
                }
                let resultText = String(toolResultText(part["content"]).prefix(toolResultTextLimit))
                toolResults.append(ToolResultPart(id: id, text: resultText, isError: part["is_error"] as? Bool == true))
            default:
                continue
            }
        }

        return ExtractedContent(
            text: texts.joined(separator: "\n\n"),
            tools: tools,
            toolResultIds: toolResultIds,
            hasHumanText: hasHumanText,
            toolCalls: toolCalls,
            toolResults: toolResults
        )
    }

    /// One-line label for a tool call, from the arguments Claude passed it.
    static func toolTitle(name: String, input: [String: Any]) -> String {
        func string(_ key: String) -> String? {
            guard let value = input[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        func fileName(_ key: String) -> String? {
            string(key).map { ($0 as NSString).lastPathComponent }
        }
        switch name {
        case "Bash":
            return string("command").map { TranscriptPreview.singleLine($0) } ?? ""
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit":
            return fileName("file_path") ?? fileName("notebook_path") ?? ""
        case "Grep":
            guard let pattern = string("pattern") else { return "" }
            if let scope = fileName("path") { return TranscriptPreview.singleLine("\(pattern) in \(scope)") }
            return TranscriptPreview.singleLine(pattern)
        case "Glob":
            return string("pattern").map { TranscriptPreview.singleLine($0) } ?? ""
        case "WebFetch":
            guard let url = string("url"), let parsed = URL(string: url), let host = parsed.host else { return "" }
            return TranscriptPreview.singleLine(host + parsed.path, limit: 80)
        case "WebSearch":
            return string("query").map { TranscriptPreview.singleLine($0, limit: 80) } ?? ""
        case "Task":
            return string("description").map { TranscriptPreview.singleLine($0, limit: 80) } ?? ""
        case "TodoWrite":
            return "Update todos"
        default:
            return ""
        }
    }

    private static func toolResultText(_ rawContent: Any?) -> String {
        if let text = rawContent as? String { return text }
        guard let parts = rawContent as? [[String: Any]] else { return "" }
        return parts
            .compactMap { part -> String? in
                guard part["type"] as? String == "text" else { return nil }
                return part["text"] as? String
            }
            .joined(separator: "\n")
    }

    /// Claude's `AskUserQuestion` tool call is a structured choice request;
    /// its answer arrives as the matching `tool_result`.
    private static func askUserQuestion(in rawContent: Any?) -> AgentInputRequest? {
        guard let parts = rawContent as? [[String: Any]] else { return nil }
        for part in parts {
            guard
                part["type"] as? String == "tool_use",
                part["name"] as? String == askUserQuestionToolName,
                let requestId = part["id"] as? String,
                let input = part["input"] as? [String: Any],
                let rawQuestions = input["questions"] as? [[String: Any]]
            else {
                continue
            }

            let questions = rawQuestions.enumerated().compactMap { questionIndex, rawQuestion -> AgentInputRequestQuestion? in
                let question = (rawQuestion["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !question.isEmpty else { return nil }
                let header = (rawQuestion["header"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let choices = (rawQuestion["options"] as? [[String: Any]] ?? []).enumerated().compactMap {
                    optionIndex,
                    rawChoice -> AgentInputRequestChoice? in
                    let label = (rawChoice["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !label.isEmpty else { return nil }
                    return AgentInputRequestChoice(
                        choiceId: "\(optionIndex + 1)",
                        label: label,
                        description: (rawChoice["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                        recommended: label.localizedCaseInsensitiveContains("(Recommended)")
                    )
                }
                guard !choices.isEmpty else { return nil }
                return AgentInputRequestQuestion(
                    questionId: header.isEmpty ? "question-\(questionIndex + 1)" : header,
                    header: header.isEmpty ? "Question \(questionIndex + 1)" : header,
                    question: question,
                    choices: choices
                )
            }
            guard !questions.isEmpty else { continue }
            return AgentInputRequest(requestId: requestId, questions: questions)
        }
        return nil
    }

    private static func role(for recordType: String) -> ChatRole? {
        switch recordType {
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

    private static func makeTitle(_ text: String) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > 72 else { return singleLine }
        return String(singleLine.prefix(69)) + "..."
    }

    private static func parseTimestamp(_ raw: Any?) -> Int64? {
        guard let rawString = raw as? String else { return nil }
        if let fast = parseUTCTimestamp(rawString) {
            return fast
        }
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso8601.date(from: rawString) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        iso8601.formatOptions = [.withInternetDateTime]
        if let date = iso8601.date(from: rawString) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        return nil
    }

    /// Transcripts stamp every record as `YYYY-MM-DDTHH:MM:SS[.fff]Z`. A
    /// transcript tail holds thousands of records, and `ISO8601DateFormatter`
    /// costs roughly a hundred microseconds per call, so the fixed layout is
    /// decoded by hand and the formatter is only a fallback.
    static func parseUTCTimestamp(_ text: String) -> Int64? {
        let bytes = Array(text.utf8)
        let zero = UInt8(ascii: "0")
        guard
            bytes.count >= 20,
            bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
            bytes[10] == UInt8(ascii: "T"), bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
            bytes[bytes.count - 1] == UInt8(ascii: "Z")
        else {
            return nil
        }

        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let byte = bytes[index]
                guard byte >= zero, byte <= zero + 9 else { return nil }
                value = value * 10 + Int(byte - zero)
            }
            return value
        }

        guard
            let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
            let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
            (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else {
            return nil
        }

        var millis = 0
        if bytes.count > 20 {
            guard bytes[19] == UInt8(ascii: ".") else { return nil }
            var scale = 100
            for index in 20..<(bytes.count - 1) {
                let byte = bytes[index]
                guard byte >= zero, byte <= zero + 9 else { return nil }
                if scale > 0 {
                    millis += Int(byte - zero) * scale
                    scale /= 10
                }
            }
        }

        // Days since 1970-01-01 for a proleptic Gregorian civil date.
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468

        let seconds = Int64(days) * 86_400 + Int64(hour * 3_600 + minute * 60 + second)
        return seconds * 1_000 + Int64(millis)
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
}
