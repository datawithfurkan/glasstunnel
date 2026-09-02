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
    private let lock = NSLock()
    private var entries: [String: (modifiedAt: Date, summary: ClaudeCodeSessionSummary?)] = [:]

    init() {}

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
        lock.unlock()
        return parsed
    }

    func retain(onlyPaths paths: Set<String>) {
        lock.lock()
        entries = entries.filter { paths.contains($0.key) }
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
    /// and reads only the metadata head. Returns nil when the session has no
    /// transcript yet or no record in the head carries an `entrypoint`, i.e.
    /// when the owner is genuinely unknown — callers must not guess.
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
    }

    private struct ParsedMetadata {
        let sessionId: String?
        let workspaceRoot: String?
        let threadName: String?
        let entrypoint: String?
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
            sessionId: metadata.sessionId ?? recent.sessionId,
            workspaceRoot: metadata.workspaceRoot ?? recent.workspaceRoot,
            threadName: metadata.threadName ?? recent.threadName,
            entrypoint: metadata.entrypoint ?? recent.entrypoint,
            messages: recent.messages
        )
    }

    static func parseSummaryPreview(at url: URL, path: String, modifiedAt: Date) -> ClaudeCodeSessionSummary? {
        guard let jsonl = readChunk(at: url, offset: 0, length: metadataPreviewByteCount) else {
            return nil
        }
        return parseSummary(jsonl: jsonl, path: path, modifiedAt: modifiedAt)
    }

    /// Reads only the metadata head to answer "which client wrote this
    /// transcript?" without requiring a workspace root or extracting messages.
    static func parseEntrypointPreview(at url: URL) -> String? {
        guard let jsonl = readChunk(at: url, offset: 0, length: metadataPreviewByteCount) else {
            return nil
        }
        return parseMetadata(jsonl: jsonl).entrypoint
    }

    static func parse(jsonl: String, agentID: AgentID, maxMessages: Int) -> ParsedSession {
        let metadata = parseMetadata(jsonl: jsonl)
        var messages: [AgentChatMessage] = []

        for (index, line) in jsonl.split(whereSeparator: \.isNewline).enumerated() {
            guard
                let data = line.data(using: .utf8),
                let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let recordType = raw["type"] as? String
            else {
                continue
            }

            guard let role = role(for: recordType) else { continue }
            let contentSource = (raw["message"] as? [String: Any])?["content"] ?? raw["content"]
            let extracted = extractTextAndTools(from: contentSource)
            let text = extracted.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty, extracted.tools.isEmpty { continue }

            messages.append(
                AgentChatMessage(
                    messageId: "\(agentID)-claude-\(index)",
                    role: text.isEmpty ? .tool : role,
                    text: text.isEmpty ? extracted.tools.map(\.summary).joined(separator: "\n") : text,
                    atUnixMs: parseTimestamp(raw["timestamp"]),
                    pendingToolCalls: extracted.tools
                )
            )
        }

        if messages.count > maxMessages {
            messages = Array(messages.suffix(maxMessages))
        }

        return ParsedSession(
            sessionId: metadata.sessionId,
            workspaceRoot: metadata.workspaceRoot,
            threadName: metadata.threadName,
            entrypoint: metadata.entrypoint,
            messages: messages
        )
    }

    static func parseSummary(jsonl: String, path: String, modifiedAt: Date) -> ClaudeCodeSessionSummary? {
        let parsed = parse(jsonl: jsonl, agentID: "claude-code", maxMessages: 8)
        guard let sessionId = parsed.sessionId, let workspaceRoot = parsed.workspaceRoot else {
            return nil
        }
        return ClaudeCodeSessionSummary(
            path: path,
            sessionId: sessionId,
            modifiedAt: modifiedAt,
            workspaceRoot: workspaceRoot,
            threadName: parsed.threadName,
            owner: ClaudeCodeSessionOwner(entrypoint: parsed.entrypoint)
        )
    }

    private static func parseMetadata(jsonl: String) -> ParsedMetadata {
        var sessionId: String?
        var workspaceRoot: String?
        var firstUserMessage: String?
        var entrypoint: String?

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
            if firstUserMessage == nil, recordType == "user" {
                let contentSource = (raw["message"] as? [String: Any])?["content"] ?? raw["content"]
                let text = extractTextAndTools(from: contentSource)
                    .text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    firstUserMessage = makeTitle(text)
                }
            }
        }

        return ParsedMetadata(
            sessionId: sessionId,
            workspaceRoot: workspaceRoot,
            threadName: firstUserMessage,
            entrypoint: entrypoint
        )
    }

    private static func extractTextAndTools(from rawContent: Any?) -> (text: String, tools: [PendingToolCall]) {
        if let text = rawContent as? String {
            return (text, [])
        }

        guard let parts = rawContent as? [[String: Any]] else {
            return ("", [])
        }

        var texts: [String] = []
        var tools: [PendingToolCall] = []

        for part in parts {
            guard let type = part["type"] as? String else { continue }
            switch type {
            case "text":
                if let text = part["text"] as? String, !text.isEmpty {
                    texts.append(text)
                }
            case "tool_use":
                let name = part["name"] as? String ?? "tool"
                let id = part["id"] as? String ?? "\(name)-\(tools.count + 1)"
                tools.append(PendingToolCall(toolName: name, toolCallId: id, summary: "Using \(name)"))
            case "tool_result":
                if let text = part["content"] as? String, !text.isEmpty {
                    texts.append(text)
                }
            default:
                continue
            }
        }

        return (texts.joined(separator: "\n\n"), tools)
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
