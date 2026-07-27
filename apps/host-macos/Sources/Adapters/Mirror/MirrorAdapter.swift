import Foundation
import GTProtocol
import GTInput
import GTSecurity

/// Generic fallback adapter. Used when no tool-specific adapter is known for
/// the application the user dropped onto a grid cell.
///
/// The mirror adapter does no parsing; it relies on the video track from
/// `GTCapture.WindowCapture` for visual state and `GTInput.KeyboardInjector`
/// for dumb synthetic keystrokes targeted at the captured window's PID.
public final class MirrorAdapter: AgentAdapter, @unchecked Sendable {
    public let agentID: AgentID
    public let kind: AdapterKind = .mirror
    public let label: String

    private let targetPID: Int32
    private let targetBundleID: String
    private let keyboard: KeyboardInjector
    private let stateStream = StreamWriter<AgentStateSnapshot>()
    private var status: AgentStatus = .idle
    private let lock = NSLock()

    public init(agentID: AgentID, label: String, targetPID: Int32, targetBundleID: String, keyboard: KeyboardInjector = KeyboardInjector()) {
        self.agentID = agentID
        self.label = label
        self.targetPID = targetPID
        self.targetBundleID = targetBundleID
        self.keyboard = keyboard
    }

    public func observeState() -> AsyncStream<AgentStateSnapshot> {
        stateStream.make()
    }

    public func start() async throws {
        emit(status: .idle, detail: "mirror mode")
    }

    public func stop() async {
        emit(status: .disconnected, detail: "stopped")
    }

    public func sendInput(_ text: String, submit: Bool) async throws {
        keyboard.focusApplication(pid: targetPID)
        keyboard.typeString(text)
        if submit { keyboard.pressReturn() }
        emit(status: .working, detail: "input delivered")
    }

    public func interrupt() async throws {
        keyboard.focusApplication(pid: targetPID)
        keyboard.pressControlC()
        emit(status: .idle, detail: "interrupted")
    }

    private func emit(status: AgentStatus, detail: String) {
        lock.lock()
        self.status = status
        let snap = AgentStateSnapshot(
            agentId: agentID,
            agentLabel: label,
            adapterKind: .mirror,
            status: status,
            statusDetail: detail,
            hasVideoTrack: true
        )
        lock.unlock()
        stateStream.yield(snap)
    }
}
