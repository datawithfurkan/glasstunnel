import Foundation
import XCTest
@testable import GTAdapters
import GTProtocol

/// Opt-in diagnostic (`GT_CLAUDE_PROBE=1`): launches the real `claude` the way
/// the card does, answers the workspace-trust dialog from the adapter, and
/// prints the ANSI-stripped output tail every two seconds so a stuck startup
/// can be read. Never sends a prompt. `GT_CLAUDE_PROBE_CWD` picks the folder.
final class ClaudeCodeResumeProbeTests: XCTestCase {
    func testProbeStartupAfterTrust() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["GT_CLAUDE_PROBE"] == "1", "Set GT_CLAUDE_PROBE=1 to run the startup probe.")
        let cwd = env["GT_CLAUDE_PROBE_CWD"] ?? NSHomeDirectory()
        let adapter = ClaudeCodeAdapter(cwd: cwd)
        defer { Task { await adapter.stop() } }

        var lastDetail = ""
        let observer = Task {
            for await snapshot in adapter.observeState() {
                let detail = "\(snapshot.status) \(snapshot.statusDetail) pending=\(snapshot.pendingInputRequest?.requestId ?? "-")"
                if detail != lastDetail {
                    lastDetail = detail
                    print("PROBE state: \(detail)")
                }
            }
        }
        defer { observer.cancel() }

        try await adapter.start()
        for tick in 0..<25 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let tail = adapter.recentOutputTail(maxLength: 700)
                .replacingOccurrences(of: "\n", with: "⏎")
            print("PROBE t=\(tick * 2)s tail: \(tail.suffix(500))")
            // A relaunched fresh session asks again; answer every time it shows.
            if ClaudeCodeAdapter.isTrustPrompt(tail) {
                print("PROBE answering trust")
                try await adapter.respondToInputRequest(AgentInputRequestResponse(
                    agentId: adapter.agentID,
                    requestId: ClaudeCodeAdapter.trustPromptRequestId,
                    answers: [AgentInputRequestAnswer(
                        questionId: ClaudeCodeAdapter.trustPromptQuestionId,
                        choiceIds: [ClaudeCodeAdapter.trustChoiceId]
                    )]
                ))
            }
            if ClaudeCodeAdapter.showsComposer(tail) {
                print("PROBE composer visible")
                break
            }
        }
    }
}
