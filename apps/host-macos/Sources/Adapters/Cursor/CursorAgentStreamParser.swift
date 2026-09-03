import Foundation
import GTProtocol

/// Parses the newline-delimited JSON that `cursor-agent --print
/// --output-format stream-json --stream-partial-output` prints while a turn
/// runs, and keeps the turn's transcript rows up to date as events arrive.
///
/// Event vocabulary (Cursor Agent CLI 2026.06):
/// - `{"type":"system","subtype":"init","session_id":…,"model":…}`
/// - `{"type":"user","message":{"content":[{"type":"text","text":…}]}}` — the prompt echoed back
/// - `{"type":"assistant","message":{"content":[{"type":"text","text":…}]}}` — a text delta
/// - `{"type":"tool_call","subtype":"started"|"completed","call_id":…,"tool_call":{"<kind>ToolCall":{"args":…,"result":…}}}`
/// - `{"type":"result","subtype":"success"|"error","is_error":…,"result":…,"duration_ms":…}`
///
/// Unknown types are ignored, so a newer CLI adds rows it knows and nothing
/// breaks.
final class CursorAgentStreamParser {
    struct ToolRow {
        let callId: String
        let name: String
        let title: String
        let startedAtUnixMs: Int64
        var completed: Bool
        var resultText: String
        var isError: Bool
        var durationMs: Int64
    }

    struct Outcome: Equatable {
        let isError: Bool
        let text: String
        let durationMs: Int64
    }

    private let agentID: AgentID
    private let turnId: String
    private let now: () -> Int64
    private var buffer = ""

    /// The prompt's echo from the CLI; the adapter already shows the prompt
    /// optimistically, so this only confirms delivery.
    private(set) var promptEchoed = false
    private(set) var sessionId: String?
    private(set) var model: String?
    private(set) var assistantText = ""
    private var sawDelta = false
    /// Rows in arrival order; the dictionary keeps the index by call id.
    private(set) var rows: [ToolRow] = []
    private var rowIndex: [String: Int] = [:]
    private(set) var outcome: Outcome?
    /// Lines that were not JSON, for the failure tail (an auth error, a crash).
    private(set) var stray: [String] = []

    init(agentID: AgentID, turnId: String, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.agentID = agentID
        self.turnId = turnId
        self.now = now
    }

    /// Feeds raw output; returns true when at least one event changed the state.
    @discardableResult
    func feed(_ chunk: String) -> Bool {
        buffer += chunk
        var changed = false
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if handle(line: line) { changed = true }
        }
        return changed
    }

    /// Flushes a last line without a trailing newline.
    @discardableResult
    func finish() -> Bool {
        let remainder = buffer
        buffer = ""
        return handle(line: remainder)
    }

    var hasPendingRows: Bool {
        rows.contains { !$0.completed }
    }

    private func handle(line rawLine: String) -> Bool {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else {
            if stray.count < 40 { stray.append(line) }
            return false
        }

        switch type {
        case "system":
            if let session = object["session_id"] as? String, !session.isEmpty { sessionId = session }
            if let model = object["model"] as? String, !model.isEmpty { self.model = model }
            return sessionId != nil || model != nil
        case "user":
            promptEchoed = true
            return true
        case "assistant":
            let text = Self.textParts(of: object["message"]).joined()
            guard !text.isEmpty else { return false }
            // With --stream-partial-output every delta carries `timestamp_ms`;
            // the CLI then repeats the whole reply once more without it.
            let isDelta = object["timestamp_ms"] != nil
            if isDelta {
                sawDelta = true
                assistantText += text
            } else if sawDelta {
                assistantText = text
            } else {
                appendAssistant(text)
            }
            return true
        case "tool_call":
            return handleToolCall(object)
        case "result":
            let isError = object["is_error"] as? Bool == true || (object["subtype"] as? String)?.lowercased() == "error"
            let text = Self.stringOrJSON(object["result"] ?? object["error"])
            let duration = (object["duration_ms"] as? NSNumber)?.int64Value ?? 0
            outcome = Outcome(isError: isError, text: text, durationMs: duration)
            // A final result repeats the whole reply; keep the streamed text
            // unless nothing streamed.
            if !isError, assistantText.isEmpty, !text.isEmpty { assistantText = text }
            return true
        default:
            return false
        }
    }

    /// Deltas are appended; a repeated or growing full text replaces instead.
    private func appendAssistant(_ text: String) {
        if text == assistantText { return }
        if text.hasPrefix(assistantText), !assistantText.isEmpty, text.count > assistantText.count {
            assistantText = text
            return
        }
        assistantText += text
    }

    private func handleToolCall(_ object: [String: Any]) -> Bool {
        let subtype = (object["subtype"] as? String)?.lowercased() ?? ""
        let callId = (object["call_id"] as? String) ?? (object["tool_call_id"] as? String) ?? (object["id"] as? String) ?? ""
        let wrapper = (object["tool_call"] as? [String: Any]) ?? [:]
        // The wrapper is a one-key object naming the call's kind:
        // {"readToolCall": {"args": …, "result": …}}.
        let (kindKey, payload) = wrapper.first { $0.value is [String: Any] }.map { ($0.key, $0.value as? [String: Any] ?? [:]) } ?? ("", [:])
        let name = Self.toolName(fromCaseKey: kindKey, payload: payload, fallback: (object["tool_name"] as? String) ?? "")
        let arguments = (payload["args"] as? [String: Any]) ?? (payload["arguments"] as? [String: Any]) ?? (payload["input"] as? [String: Any]) ?? [:]
        let id = callId.isEmpty ? "\(name)-\(rows.count + 1)" : callId

        switch subtype {
        case "completed", "complete", "finished", "done", "failed", "error":
            let (text, isError) = Self.resultSummary(payload["result"] ?? payload["output"] ?? payload["error"], subtype: subtype)
            let stamp = now()
            if let index = rowIndex[id] {
                rows[index].completed = true
                rows[index].resultText = text
                rows[index].isError = isError
                rows[index].durationMs = max(0, stamp - rows[index].startedAtUnixMs)
                if rows[index].title.isEmpty {
                    rows[index] = ToolRow(
                        callId: id, name: rows[index].name, title: CursorMessageCodec.toolTitle(name: name, arguments: arguments),
                        startedAtUnixMs: rows[index].startedAtUnixMs, completed: true, resultText: text, isError: isError,
                        durationMs: rows[index].durationMs
                    )
                }
            } else {
                rows.append(ToolRow(
                    callId: id, name: name, title: CursorMessageCodec.toolTitle(name: name, arguments: arguments),
                    startedAtUnixMs: stamp, completed: true, resultText: text, isError: isError, durationMs: 0
                ))
                rowIndex[id] = rows.count - 1
            }
            return true
        default:
            // "started" and streamed partial arguments.
            if let index = rowIndex[id] {
                if rows[index].title.isEmpty {
                    let title = CursorMessageCodec.toolTitle(name: name, arguments: arguments)
                    if !title.isEmpty {
                        rows[index] = ToolRow(
                            callId: id, name: rows[index].name, title: title, startedAtUnixMs: rows[index].startedAtUnixMs,
                            completed: false, resultText: "", isError: false, durationMs: 0
                        )
                        return true
                    }
                }
                return false
            }
            rows.append(ToolRow(
                callId: id, name: name, title: CursorMessageCodec.toolTitle(name: name, arguments: arguments),
                startedAtUnixMs: now(), completed: false, resultText: "", isError: false, durationMs: 0
            ))
            rowIndex[id] = rows.count - 1
            return true
        }
    }

    /// `readToolCall` → "Read", `semSearchToolCall` → "SemSearch", `mcpToolCall`
    /// → the MCP tool's own name when the payload carries it.
    static func toolName(fromCaseKey key: String, payload: [String: Any], fallback: String) -> String {
        if key.hasPrefix("mcp"), let name = (payload["name"] as? String) ?? (payload["toolName"] as? String), !name.isEmpty {
            return name
        }
        var base = key
        if let range = base.range(of: "ToolCall") { base.removeSubrange(range) }
        if base.isEmpty { return fallback.isEmpty ? "tool" : fallback }
        return base.prefix(1).uppercased() + base.dropFirst()
    }

    /// The text of a tool result and whether it reports a failure. Results
    /// are `{"success": {...}}` or `{"error": …}` / `{"failure": …}` shapes,
    /// with the useful text under `content`, `stdout`, `output`, or `text`.
    static func resultSummary(_ raw: Any?, subtype: String) -> (String, Bool) {
        var isError = subtype == "failed" || subtype == "error"
        var value = raw
        if let dict = raw as? [String: Any] {
            if let success = dict["success"] {
                value = success
            } else if let error = dict["error"] ?? dict["failure"] ?? dict["rejected"] ?? dict["cancelled"] {
                value = error
                isError = true
            }
        }
        return (flattened(value), isError)
    }

    private static func flattened(_ value: Any?) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let dict as [String: Any]:
            var parts: [String] = []
            for key in ["content", "contents", "text", "message", "output", "stdout", "stderr", "reason", "summary"] {
                if let text = dict[key] as? String, !text.isEmpty { parts.append(text) }
            }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
            for key in ["files", "matches", "results", "lines", "entries", "paths"] {
                if let list = dict[key] as? [Any] {
                    let lines = list.compactMap { item -> String? in
                        if let string = item as? String { return string }
                        if let entry = item as? [String: Any] {
                            return (entry["path"] as? String) ?? (entry["file"] as? String) ?? (entry["text"] as? String) ?? (entry["line"] as? String)
                        }
                        return nil
                    }
                    if !lines.isEmpty { return lines.joined(separator: "\n") }
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
                return String(decoding: data, as: UTF8.self)
            }
            return ""
        case let array as [Any]:
            return array.map { flattened($0) }.filter { !$0.isEmpty }.joined(separator: "\n")
        default:
            return ""
        }
    }

    private static func textParts(of message: Any?) -> [String] {
        guard let message = message as? [String: Any] else { return [] }
        if let text = message["content"] as? String { return [text] }
        guard let parts = message["content"] as? [[String: Any]] else { return [] }
        return parts.compactMap { part in
            guard part["type"] as? String == "text" else { return nil }
            return part["text"] as? String
        }
    }

    private static func stringOrJSON(_ value: Any?) -> String {
        if let string = value as? String { return string }
        return flattened(value)
    }

    // MARK: - Transcript rows

    /// The live turn as transcript messages: the reply so far and one row per
    /// tool call, with results paired by call id. `promptAtUnixMs` stamps the
    /// turn's rows so the phone can show elapsed time.
    func messages(startedAtUnixMs: Int64) -> (messages: [AgentChatMessage], details: [MessageID: String]) {
        var messages: [AgentChatMessage] = []
        var details: [MessageID: String] = [:]
        let reply = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        for (offset, row) in rows.enumerated() {
            messages.append(AgentChatMessage(
                messageId: "\(agentID)-\(turnId)-c\(offset)",
                role: .tool,
                text: "Using \(row.name)",
                atUnixMs: row.startedAtUnixMs,
                pendingToolCalls: [PendingToolCall(toolName: row.name, toolCallId: row.callId, summary: "Using \(row.name)")],
                kind: .toolCall,
                toolName: row.name,
                toolCallId: row.callId,
                title: row.title
            ))
            guard row.completed else { continue }
            let preview = TranscriptPreview.make(row.resultText)
            let resultId = "\(agentID)-\(turnId)-r\(offset)"
            messages.append(AgentChatMessage(
                messageId: resultId,
                role: .tool,
                text: preview.text,
                atUnixMs: row.startedAtUnixMs + row.durationMs,
                kind: .toolResult,
                toolName: row.name,
                toolCallId: row.callId,
                outputLineCount: preview.lineCount,
                durationMs: row.durationMs,
                isError: row.isError,
                truncated: preview.truncated
            ))
            if preview.truncated { details[resultId] = preview.detail }
        }
        if !reply.isEmpty {
            messages.append(AgentChatMessage(
                messageId: "\(agentID)-\(turnId)-reply",
                role: .assistant,
                text: reply,
                atUnixMs: max(startedAtUnixMs, rows.last.map { $0.startedAtUnixMs + $0.durationMs } ?? startedAtUnixMs),
                kind: .text
            ))
        }
        return (messages, details)
    }
}
