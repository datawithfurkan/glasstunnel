import Foundation
import GTProtocol

public final class TerminalAdapter: PTYAdapterBase, @unchecked Sendable {
    public override var idleThresholdSeconds: Double { 1.0 }
    public override var streamsOutputWhileWorking: Bool { true }

    private let screenSessionName: String
    private var sessionLabel: String
    private var sessionOptions: [TerminalSessionOption]

    public struct TerminalSessionOption: Sendable, Equatable {
        public let sessionName: String
        public let label: String

        public init(sessionName: String, label: String) {
            self.sessionName = sessionName
            self.label = label
        }
    }

    private static let continuationPrompts = [
        "dquote>",
        "quote>",
        "bquote>",
        "cmdsubst>",
        "heredoc>",
        "braceparam>",
        "array>",
        "mathsubst>",
        "select>",
    ]

    private static let commonPromptSuffixes = [
        "%",
        "$",
        "#",
    ]

    public init(
        agentID: AgentID = "terminal",
        label: String = "Terminal",
        executable: String? = nil,
        arguments: [String]? = nil,
        environment: [String: String] = [:],
        cwd: String? = nil,
        screenSessionName: String = TerminalSessionConfiguration.sharedSessionName,
        sessionLabel: String = "Default Terminal",
        sessionOptions: [TerminalSessionOption]? = nil
    ) {
        self.screenSessionName = screenSessionName
        self.sessionLabel = sessionLabel
        self.sessionOptions = sessionOptions ?? [
            TerminalSessionOption(sessionName: screenSessionName, label: sessionLabel),
        ]
        let shell = ProcessInfo.processInfo.environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultLaunch = TerminalSessionConfiguration.defaultLaunch(
            shell: shell,
            sessionName: screenSessionName
        )
        let resolvedExecutable = executable ?? defaultLaunch.executable
        super.init(
            agentID: agentID,
            kind: .terminal,
            label: label,
            executable: resolvedExecutable,
            arguments: arguments ?? (executable == nil ? defaultLaunch.arguments : ["-l"]),
            environment: environment,
            cwd: cwd
        )
    }

    public override func submittedInputFragments(_ text: String) -> [String] {
        Self.commandLines(from: text)
    }

    public override func shouldRecoverBeforeSubmittedInput(outputTail: String) -> Bool {
        Self.isContinuationPromptTail(outputTail)
    }

    public override func statusAfterOutputSilence(buffer: String, silenceDuration: TimeInterval) -> (status: AgentStatus, detail: String) {
        if Self.isContinuationPromptTail(buffer) {
            return (.working, "waiting for closing quote")
        }
        if Self.isReadyPromptTail(buffer) {
            return (.idle, "ready")
        }
        if buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (.idle, "ready")
        }
        return (.working, "running command")
    }

    public override func statusAfterInterrupt() -> (status: AgentStatus, detail: String) {
        (.working, "interrupt sent")
    }

    public override func snapshotAvailableTargets() -> [AgentTargetOption]? {
        let options = normalizedSessionOptions()
        return options.map { option in
            let selected = option.sessionName == screenSessionName
            return AgentTargetOption(
                targetId: Self.sessionTargetId(sessionName: option.sessionName),
                label: option.label,
                subtitle: selected ? "Current session" : "Switch session",
                selected: selected,
                threadId: Self.sessionTargetId(sessionName: option.sessionName),
                threadLabel: option.label,
                targetKind: "session",
                isActive: selected,
                supportsNewThread: true
            )
        }
    }

    public func setSessionLabel(_ label: String) {
        sessionLabel = label
        sessionOptions = normalizedSessionOptions().map { option in
            option.sessionName == screenSessionName
                ? TerminalSessionOption(sessionName: option.sessionName, label: label)
                : option
        }
    }

    public override func snapshotMessages(from buffer: String) -> [AgentChatMessage] {
        let visibleBuffer = Self.userVisibleBuffer(from: buffer)
        if visibleBuffer.isEmpty {
            return [
                AgentChatMessage(
                    messageId: "\(agentID)-ready",
                    role: .system,
                    text: "Terminal ready. Commands run on this Mac."
                ),
            ]
        }

        return super.snapshotMessages(from: visibleBuffer)
    }

    public static func commandLines(from text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        return lines.isEmpty ? [""] : lines
    }

    public static func sessionTargetId(sessionName: String) -> String {
        "terminal-session:\(sessionName)"
    }

    public static func sessionName(fromTargetId targetId: String) -> String? {
        let prefix = "terminal-session:"
        guard targetId.hasPrefix(prefix) else { return nil }
        let name = String(targetId.dropFirst(prefix.count))
        return name.isEmpty ? nil : name
    }

    public static func userVisibleBuffer(from buffer: String) -> String {
        let lines = buffer
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var result: [String] = []
        var droppingAmbiguousScreenBlock = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed == "There are several suitable screens on:" {
                droppingAmbiguousScreenBlock = true
                continue
            }

            if droppingAmbiguousScreenBlock {
                if trimmed.isEmpty ||
                    trimmed.hasPrefix("(") ||
                    trimmed.contains("glasstunnel-terminal") ||
                    trimmed.range(of: #"^\d+\.[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil {
                    continue
                }
                droppingAmbiguousScreenBlock = false
            }

            result.append(line)
        }

        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isReadyPromptTail(_ text: String) -> Bool {
        guard let lastLine = lastNonEmptyLine(in: text) else {
            return false
        }

        if commonPromptSuffixes.contains(lastLine) {
            return true
        }

        return commonPromptSuffixes.contains { suffix in
            lastLine.hasSuffix(" \(suffix)") || lastLine.hasSuffix(suffix)
        }
    }

    public static func isContinuationPromptTail(_ text: String) -> Bool {
        guard let lastLine = lastNonEmptyLine(in: text) else {
            return false
        }

        return continuationPrompts.contains { prompt in
            lastLine == prompt || lastLine.hasSuffix(" \(prompt)") || lastLine.hasPrefix(prompt)
        }
    }

    private static func lastNonEmptyLine(in text: String) -> String? {
        let normalized = text.replacingOccurrences(of: "\r", with: "\n")
        return normalized
            .components(separatedBy: "\n")
            .last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedSessionOptions() -> [TerminalSessionOption] {
        var seen = Set<String>()
        var result: [TerminalSessionOption] = []
        let options = sessionOptions.isEmpty
            ? [TerminalSessionOption(sessionName: screenSessionName, label: sessionLabel)]
            : sessionOptions

        for option in options {
            guard !option.sessionName.isEmpty, !seen.contains(option.sessionName) else { continue }
            seen.insert(option.sessionName)
            if option.sessionName == screenSessionName {
                result.append(TerminalSessionOption(sessionName: option.sessionName, label: sessionLabel))
            } else {
                result.append(option)
            }
        }

        if !seen.contains(screenSessionName) {
            result.insert(TerminalSessionOption(sessionName: screenSessionName, label: sessionLabel), at: 0)
        }
        return result
    }
}
