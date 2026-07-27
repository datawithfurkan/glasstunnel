import Foundation
import GTProtocol

struct ClaudeCodeSessionSummary: Equatable {
    let path: String
    let sessionId: String
    let modifiedAt: Date
    let workspaceRoot: String
    let threadName: String?
}

enum ClaudeCodeSessionStore {
    static func defaultProjectsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    static func loadSummaries(
        projectsRoot: URL = defaultProjectsRoot(),
        limit: Int = AgentHistoryLimits.sessionSummaryCount
    ) -> [ClaudeCodeSessionSummary] {
        sessionFiles(projectsRoot: projectsRoot)
            .compactMap { url -> ClaudeCodeSessionSummary? in
                let modifiedAt = modificationDate(url) ?? .distantPast
                return ClaudeCodeSessionParser.parseSummaryPreview(
                    at: url,
                    path: url.path,
                    modifiedAt: modifiedAt
                )
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(limit)
            .map { $0 }
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
        let messages: [AgentChatMessage]
    }

    private struct ParsedMetadata {
        let sessionId: String?
        let workspaceRoot: String?
        let threadName: String?
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
            messages: recent.messages
        )
    }

    static func parseSummaryPreview(at url: URL, path: String, modifiedAt: Date) -> ClaudeCodeSessionSummary? {
        guard let jsonl = readChunk(at: url, offset: 0, length: metadataPreviewByteCount) else {
            return nil
        }
        return parseSummary(jsonl: jsonl, path: path, modifiedAt: modifiedAt)
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
            threadName: parsed.threadName
        )
    }

    private static func parseMetadata(jsonl: String) -> ParsedMetadata {
        var sessionId: String?
        var workspaceRoot: String?
        var firstUserMessage: String?

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

        return ParsedMetadata(sessionId: sessionId, workspaceRoot: workspaceRoot, threadName: firstUserMessage)
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
