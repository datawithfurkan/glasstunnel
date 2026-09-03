import Foundation
import GTProtocol

/// Minimal protobuf reading: enough to list the length-delimited values of one
/// field in order. Cursor's conversation snapshots are protobuf messages whose
/// repeated field 1 holds the 32-byte ids of the message blobs, and nothing
/// else in them is needed.
enum CursorProtobuf {
    static func lengthDelimitedValues(in data: Data, field wantedField: Int) -> [Data] {
        let bytes = [UInt8](data)
        var index = 0
        var values: [Data] = []

        func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }

        while index < bytes.count {
            guard let tag = readVarint() else { break }
            let field = Int(tag >> 3)
            switch Int(tag & 7) {
            case 0:
                guard readVarint() != nil else { return values }
            case 1:
                index += 8
            case 5:
                index += 4
            case 2:
                guard let length = readVarint(), length <= UInt64(bytes.count - index) else { return values }
                let end = index + Int(length)
                if field == wantedField {
                    values.append(Data(bytes[index..<end]))
                }
                index = end
            default:
                // Groups and corrupt tags: stop rather than guess.
                return values
            }
        }
        return values
    }

    static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func data(fromHex hex: String) -> Data? {
        let characters = Array(hex.utf8)
        guard characters.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            guard
                let high = hexValue(characters[index]),
                let low = hexValue(characters[index + 1])
            else {
                return nil
            }
            bytes.append(high << 4 | low)
            index += 2
        }
        return Data(bytes)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}

/// One message as Cursor stores it (the Vercel AI SDK shape shared by the
/// desktop app's `agentKv` blobs and the CLI's `store.db` blobs), reduced to
/// what the transcript needs.
struct CursorStoredMessage {
    enum Role: String {
        case system
        case user
        case assistant
        case tool
        case unknown
    }

    struct ToolCall {
        let id: String
        let name: String
        /// One-line label from the arguments (a command, a file, a pattern).
        let title: String
        /// Cursor's `AskQuestion` tool turned into a structured question.
        let question: AgentInputRequest?
    }

    struct ToolResult {
        let id: String
        let name: String
        let text: String
        let isError: Bool
    }

    let role: Role
    /// Text the person typed or the model wrote; empty for pure tool messages.
    let text: String
    let toolCalls: [ToolCall]
    let toolResults: [ToolResult]
    /// True for the context block Cursor injects ahead of the typed prompt
    /// (`<user_info>`, `<rules>`, skills, MCP listings); never shown.
    let isInjectedContext: Bool
}

/// A decoded conversation, ready for a snapshot.
struct CursorConversation {
    let messages: [AgentChatMessage]
    /// Full tool output for messages whose snapshot text is a preview.
    let messageDetails: [MessageID: String]
    let status: AgentStatus
    let statusDetail: String
    let pendingInputRequest: AgentInputRequest?
    let lastActivityUnixMs: Int64?

    static let empty = CursorConversation(
        messages: [],
        messageDetails: [:],
        status: .idle,
        statusDetail: "",
        pendingInputRequest: nil,
        lastActivityUnixMs: nil
    )
}

enum CursorMessageCodec {
    static let askQuestionToolNames: Set<String> = ["AskQuestion", "ask_question", "AskUserQuestion"]
    static let toolResultTextLimit = TranscriptPreview.detailByteCount

    static func decode(_ data: Data) -> CursorStoredMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return decode(object: object)
    }

    static func decode(object: [String: Any]) -> CursorStoredMessage? {
        let role = Role(rawValue: (object["role"] as? String)?.lowercased() ?? "") ?? .unknown
        let content = object["content"]

        if let text = content as? String {
            // A wrapped prompt is the person's own words; only an unwrapped
            // block of Cursor's tags is context.
            let unwrapped = userQuery(in: text)
            let injected = role == .user && unwrapped == text && isInjectedContext(text)
            return CursorStoredMessage(role: role, text: injected ? "" : unwrapped, toolCalls: [], toolResults: [], isInjectedContext: injected)
        }

        guard let parts = content as? [[String: Any]] else {
            return CursorStoredMessage(role: role, text: "", toolCalls: [], toolResults: [], isInjectedContext: false)
        }

        var texts: [String] = []
        var calls: [CursorStoredMessage.ToolCall] = []
        var results: [CursorStoredMessage.ToolResult] = []
        var droppedInjectedPart = false
        for part in parts {
            switch (part["type"] as? String) ?? "" {
            case "text":
                if let text = part["text"] as? String, !text.isEmpty {
                    // Cursor's own tagged blocks (the context block, mode
                    // reminders such as `<system_reminder>`) travel as parts
                    // of the same message as the typed prompt; only those
                    // parts are dropped.
                    if role == .user, isInjectedContext(text) {
                        droppedInjectedPart = true
                        continue
                    }
                    texts.append(userQuery(in: text))
                }
            case "tool-call", "tool_use", "tool-use":
                let name = (part["toolName"] as? String) ?? (part["name"] as? String) ?? "tool"
                let id = (part["toolCallId"] as? String) ?? (part["id"] as? String) ?? "\(name)-\(calls.count + 1)"
                let arguments = (part["args"] as? [String: Any]) ?? (part["input"] as? [String: Any]) ?? argumentsObject(part["args"] ?? part["input"])
                calls.append(CursorStoredMessage.ToolCall(
                    id: id,
                    name: name,
                    title: toolTitle(name: name, arguments: arguments),
                    question: askQuestionToolNames.contains(name) ? askQuestion(id: id, arguments: arguments) : nil
                ))
            case "tool-result", "tool_result":
                let name = (part["toolName"] as? String) ?? (part["name"] as? String) ?? ""
                let id = (part["toolCallId"] as? String) ?? (part["tool_use_id"] as? String) ?? (part["id"] as? String) ?? ""
                results.append(CursorStoredMessage.ToolResult(
                    id: id,
                    name: name,
                    text: toolResultText(part),
                    isError: toolResultIsError(part)
                ))
            case "image", "file":
                texts.append("[\((part["type"] as? String) ?? "image")]")
            default:
                // Reasoning (plain or redacted) and unknown parts are not shown.
                continue
            }
        }

        let joined = texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let injected = role == .user && calls.isEmpty && results.isEmpty
            && (isInjectedContext(joined) || (joined.isEmpty && droppedInjectedPart))
        return CursorStoredMessage(
            role: role,
            text: injected ? "" : joined,
            toolCalls: calls,
            toolResults: results,
            isInjectedContext: injected
        )
    }

    private typealias Role = CursorStoredMessage.Role

    /// Tool arguments sometimes arrive as a JSON string rather than an object.
    private static func argumentsObject(_ value: Any?) -> [String: Any] {
        guard let string = value as? String, let data = string.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Cursor prepends a block of tagged context (`<user_info>`, `<rules>`,
    /// `<agent_skills>`, `<mcp_file_system>`…) as its own user message; the
    /// prompt the person typed follows as the next message. Snake_case tags are
    /// Cursor's; HTML someone typed keeps its plain tag names.
    static func isInjectedContext(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<"), let close = trimmed.firstIndex(of: ">") else { return false }
        let name = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return false }
        let known: Set<String> = [
            "user_info", "rules", "user_rules", "always_applied_workspace_rules", "agent_skills", "available_skills",
            "mcp_file_system", "mcp_file_system_servers", "agent_transcripts", "additional_data", "attached_files",
            "environment_context", "system_reminder", "context",
        ]
        guard name.contains("_") || known.contains(String(name)) else { return false }
        // The block ends with a closing tag; a prompt that merely starts with a
        // tag keeps its own words after it.
        return trimmed.hasSuffix(">") && trimmed.range(of: "</", options: .backwards) != nil
    }

    /// Older Cursor builds wrap the typed prompt in `<user_query>`; unwrap it.
    static func userQuery(in text: String) -> String {
        guard
            let open = text.range(of: "<user_query>"),
            let close = text.range(of: "</user_query>", options: .backwards),
            open.upperBound <= close.lowerBound
        else {
            return text
        }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One-line label for a tool call, from the arguments Cursor passed it.
    /// Both clients name tools differently (`Shell` vs `run_terminal_cmd`,
    /// `Read` vs `ReadFile`), so the label comes from the argument keys.
    static func toolTitle(name: String, arguments: [String: Any]) -> String {
        func string(_ key: String) -> String? {
            guard let value = arguments[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func fileName(_ key: String) -> String? {
            string(key).map { ($0 as NSString).lastPathComponent }
        }
        if let command = string("command") ?? string("cmd") {
            return TranscriptPreview.singleLine(command)
        }
        if let pattern = string("pattern") ?? string("regex") {
            if let scope = fileName("path") ?? fileName("target_directory") ?? fileName("relative_workspace_path") {
                return TranscriptPreview.singleLine("\(pattern) in \(scope)")
            }
            return TranscriptPreview.singleLine(pattern)
        }
        if let file = fileName("path") ?? fileName("file_path") ?? fileName("target_file") ?? fileName("relative_workspace_path") ?? fileName("notebook_path") {
            return file
        }
        if let query = string("query") ?? string("search_term") {
            return TranscriptPreview.singleLine(query, limit: 80)
        }
        if let url = string("url"), let parsed = URL(string: url), let host = parsed.host {
            return TranscriptPreview.singleLine(host + parsed.path, limit: 80)
        }
        if let description = string("description") ?? string("task") ?? string("explanation") {
            return TranscriptPreview.singleLine(description, limit: 80)
        }
        switch name.lowercased() {
        case "todowrite", "todo_write", "update_todos", "updatetodos":
            return "Update todos"
        default:
            return ""
        }
    }

    /// Cursor's `AskQuestion` tool asks the person to choose; a call with
    /// options becomes a structured question the phone can answer.
    static func askQuestion(id: String, arguments: [String: Any]) -> AgentInputRequest? {
        var rawQuestions: [[String: Any]] = []
        if let list = arguments["questions"] as? [[String: Any]] {
            rawQuestions = list
        } else {
            rawQuestions = [arguments]
        }
        let questions = rawQuestions.enumerated().compactMap { index, raw -> AgentInputRequestQuestion? in
            let question = ((raw["question"] as? String) ?? (raw["prompt"] as? String) ?? (raw["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else { return nil }
            let header = ((raw["header"] as? String) ?? (raw["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let rawOptions = (raw["options"] as? [Any]) ?? (raw["choices"] as? [Any]) ?? []
            let choices = rawOptions.enumerated().compactMap { optionIndex, rawChoice -> AgentInputRequestChoice? in
                let label: String
                let description: String
                if let dict = rawChoice as? [String: Any] {
                    label = ((dict["label"] as? String) ?? (dict["title"] as? String) ?? (dict["value"] as? String) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    description = ((dict["description"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let string = rawChoice as? String {
                    label = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    description = ""
                } else {
                    return nil
                }
                guard !label.isEmpty else { return nil }
                return AgentInputRequestChoice(choiceId: "\(optionIndex + 1)", label: label, description: description)
            }
            guard !choices.isEmpty else { return nil }
            return AgentInputRequestQuestion(
                questionId: header.isEmpty ? "question-\(index + 1)" : header,
                header: header.isEmpty ? "Question \(index + 1)" : header,
                question: question,
                choices: choices
            )
        }
        guard !questions.isEmpty else { return nil }
        return AgentInputRequest(requestId: id, questions: questions)
    }

    private static func toolResultText(_ part: [String: Any]) -> String {
        var text = ""
        if let content = part["experimental_content"] as? [[String: Any]] {
            text = content.compactMap { item -> String? in
                guard item["type"] as? String == "text" else { return nil }
                return item["text"] as? String
            }.joined(separator: "\n")
        }
        if text.isEmpty {
            let raw = part["result"] ?? part["output"] ?? part["content"]
            text = flattenedText(raw)
        }
        if text.utf8.count > toolResultTextLimit {
            text = String(decoding: Array(text.utf8.prefix(toolResultTextLimit)), as: UTF8.self)
        }
        return text
    }

    private static func flattenedText(_ raw: Any?) -> String {
        switch raw {
        case let string as String:
            return string
        case let dict as [String: Any]:
            // AI SDK v5 outputs: {type: "text"|"json"|"error-text"|"error-json", value}.
            if let type = dict["type"] as? String, let value = dict["value"] {
                if type.hasSuffix("json") { return flattenedText(value) }
                return flattenedText(value)
            }
            if let text = dict["text"] as? String { return text }
            if let content = dict["content"] as? String { return content }
            if let output = dict["output"] as? String { return output }
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
                return String(decoding: data, as: UTF8.self)
            }
            return ""
        case let array as [Any]:
            let texts = array.compactMap { item -> String? in
                if let dict = item as? [String: Any] {
                    if let text = dict["text"] as? String { return text }
                    return nil
                }
                return item as? String
            }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
            if let data = try? JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted, .sortedKeys]) {
                return String(decoding: data, as: UTF8.self)
            }
            return ""
        case let number as NSNumber:
            return number.stringValue
        default:
            return ""
        }
    }

    private static func toolResultIsError(_ part: [String: Any]) -> Bool {
        if part["isError"] as? Bool == true || part["is_error"] as? Bool == true { return true }
        if let output = part["output"] as? [String: Any], let type = output["type"] as? String, type.hasPrefix("error") {
            return true
        }
        if let result = part["result"] as? [String: Any], result["error"] != nil { return true }
        return false
    }
}

/// Turns stored messages into the transcript rows both Cursor cards publish.
enum CursorConversationBuilder {
    static let workingDetail = "Cursor is working"
    static let doneDetail = "Response ready"
    static let waitingDetail = "Waiting for your answer"
    static let stoppedDetail = "Stopped"

    /// Message ids are derived from the message's position, so a re-read of an
    /// unchanged chat yields the same ids and the phone keeps its scroll.
    static func build(
        messages stored: [CursorStoredMessage],
        agentID: AgentID,
        maxMessages: Int,
        lastActivityUnixMs: Int64?
    ) -> CursorConversation {
        var messages: [AgentChatMessage] = []
        var details: [MessageID: String] = [:]
        var pendingCalls: [String: CursorStoredMessage.ToolCall] = [:]
        var pendingOrder: [String] = []
        var status: AgentStatus = .idle
        var statusDetail = ""
        var pendingQuestion: AgentInputRequest?

        for (index, message) in stored.enumerated() {
            if message.isInjectedContext || message.role == .system || message.role == .unknown { continue }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseId = "\(agentID)-cursor-\(index)"

            switch message.role {
            case .user:
                guard !text.isEmpty else { continue }
                messages.append(AgentChatMessage(messageId: baseId, role: .user, text: text, atUnixMs: 0, kind: .text))
                status = .working
                statusDetail = workingDetail
                pendingQuestion = nil
            case .assistant:
                if !text.isEmpty {
                    messages.append(AgentChatMessage(messageId: baseId, role: .assistant, text: text, atUnixMs: 0, kind: .text))
                }
                for (offset, call) in message.toolCalls.enumerated() {
                    pendingCalls[call.id] = call
                    pendingOrder.append(call.id)
                    messages.append(AgentChatMessage(
                        messageId: "\(baseId)-c\(offset)",
                        role: .tool,
                        text: "Using \(call.name)",
                        atUnixMs: 0,
                        pendingToolCalls: [PendingToolCall(toolName: call.name, toolCallId: call.id, summary: "Using \(call.name)")],
                        kind: .toolCall,
                        toolName: call.name,
                        toolCallId: call.id,
                        title: call.title
                    ))
                    if let question = call.question {
                        pendingQuestion = question
                    }
                }
                if message.toolCalls.isEmpty {
                    status = .done
                    statusDetail = doneDetail
                    pendingQuestion = nil
                } else {
                    status = .working
                    statusDetail = workingDetail
                }
            case .tool:
                for (offset, result) in message.toolResults.enumerated() {
                    let preview = TranscriptPreview.make(result.text)
                    let messageId = "\(baseId)-r\(offset)"
                    let call = pendingCalls.removeValue(forKey: result.id)
                    pendingOrder.removeAll { $0 == result.id }
                    if call?.question != nil || pendingQuestion?.requestId == result.id {
                        pendingQuestion = nil
                    }
                    messages.append(AgentChatMessage(
                        messageId: messageId,
                        role: .tool,
                        text: preview.text,
                        atUnixMs: 0,
                        kind: .toolResult,
                        toolName: result.name.isEmpty ? (call?.name ?? "") : result.name,
                        toolCallId: result.id,
                        outputLineCount: preview.lineCount,
                        isError: result.isError,
                        truncated: preview.truncated
                    ))
                    if preview.truncated {
                        details[messageId] = preview.detail
                    }
                }
                status = .working
                statusDetail = workingDetail
            case .system, .unknown:
                continue
            }
        }

        if messages.count > maxMessages {
            messages = Array(messages.suffix(maxMessages))
        }
        if let pendingQuestion, pendingCalls[pendingQuestion.requestId] != nil {
            status = .waitingInput
            statusDetail = waitingDetail
        } else {
            pendingQuestion = nil
        }
        // Give the newest message the store's clock so the card's activity
        // time is honest without inventing per-message stamps.
        if let lastActivityUnixMs, let last = messages.indices.last {
            messages[last].atUnixMs = lastActivityUnixMs
        }
        let kept = Set(messages.map(\.messageId))
        return CursorConversation(
            messages: messages,
            messageDetails: details.filter { kept.contains($0.key) },
            status: status,
            statusDetail: statusDetail,
            pendingInputRequest: pendingQuestion,
            lastActivityUnixMs: lastActivityUnixMs
        )
    }
}
