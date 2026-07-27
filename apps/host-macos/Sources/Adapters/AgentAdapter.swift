import Foundation
import GTProtocol

/// The contract every tool-specific adapter implements.
///
/// An adapter is responsible for:
///   - observing the tool's state (chat history, status, pending approvals)
///     and producing a stream of `AgentStateSnapshot` updates
///   - delivering user input to the tool
///   - requesting interrupts
///   - emitting agent-done signals for push notifications
///
/// Adapters are instantiated per grid cell. When a user drops a window onto
/// a cell, the `AdapterFactory` resolves the right adapter based on the
/// window's application bundle id.
public protocol AgentAdapter: AnyObject, Sendable {
    var agentID: AgentID { get }
    var kind: AdapterKind { get }
    var label: String { get }

    /// Returns a stream of snapshots. Subscribers should use `for await`.
    func observeState() -> AsyncStream<AgentStateSnapshot>

    /// Deliver user input. For CLI agents this writes to PTY stdin; for GUI
    /// agents this targets the chat input via Accessibility.
    func sendInput(_ text: String, submit: Bool) async throws

    /// Request an interrupt (Ctrl+C / Esc / "stop" depending on tool).
    func interrupt() async throws

    /// Switch the adapter's active target/context, for example a Codex project
    /// or thread shown in the desktop UI.
    func selectTarget(_ targetID: String) async throws

    /// Current runtime controls that can be shown on the web/mobile surface.
    func runtimeControls() -> AgentRuntimeControls?

    /// Apply a model/effort/fast-mode update from the web/mobile surface.
    func updateRuntimeSettings(_ update: AgentRuntimeSettingsUpdate) async throws

    /// Submit a structured planning-mode response when the underlying tool is
    /// waiting on a choice request rather than a normal chat prompt.
    func respondToInputRequest(_ response: AgentInputRequestResponse) async throws

    /// Start the adapter lifecycle. Called once when the agent is placed in
    /// the grid. Adapter can initialize watchers, open PTYs, etc.
    func start() async throws

    /// Shut down cleanly. Called when removed from the grid or on app quit.
    func stop() async
}

enum AgentHistoryLimits {
    /// Keep enough chat history for real project conversations without sending
    /// entire multi-month logs on every snapshot. Older pages can be added later
    /// with an explicit history request protocol.
    static let snapshotMessageCount = 250
    static let sessionSummaryCount = 40
    static let jsonlTailByteCount = 8 * 1024 * 1024
}

public extension AgentAdapter {
    func selectTarget(_ targetID: String) async throws {
        _ = targetID
    }

    func runtimeControls() -> AgentRuntimeControls? {
        nil
    }

    func updateRuntimeSettings(_ update: AgentRuntimeSettingsUpdate) async throws {
        _ = update
        throw NSError(
            domain: "AgentAdapter",
            code: -10,
            userInfo: [NSLocalizedDescriptionKey: "\(label) does not support remote model settings."]
        )
    }

    func respondToInputRequest(_ response: AgentInputRequestResponse) async throws {
        let summary = response.answers
            .map { "\($0.questionId): \($0.choiceIds.joined(separator: ", "))" }
            .joined(separator: "\n")
        try await sendInput(summary, submit: true)
    }
}

public enum AdapterFactory {
    /// Resolve an adapter for the given bundle id. Falls back to the mirror
    /// adapter for unrecognized apps.
    public static func resolveKind(forBundleID bundleID: String) -> AdapterKind {
        switch bundleID {
        case "com.todesktop.230313mzl4w4u92": // Cursor
            return .cursor
        case "com.anthropic.claudecode",
             "com.anthropic.claudecode.macos":
            return .claudeCode
        case "com.openai.codex.cli":
            return .codexCli
        case "com.google.gemini.cli",
             "com.google.gemini":
            return .geminiCli
        case "ai.opencode.app",
             "ai.opencode.desktop",
             "dev.opencode.cli":
            return .openCode
        default:
            return .mirror
        }
    }
}
