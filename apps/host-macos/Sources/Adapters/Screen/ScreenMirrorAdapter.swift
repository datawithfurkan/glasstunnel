import Foundation
import GTInput
import GTProtocol

/// Full-screen remote-control adapter used by the dedicated Mac Screen tab.
public final class ScreenMirrorAdapter: AgentAdapter, @unchecked Sendable {
    public let agentID: AgentID
    public let kind: AdapterKind = .mirror
    public let label: String

    private let keyboard: KeyboardInjector
    private let pointer: PointerInjector
    private let stateStream = StreamWriter<AgentStateSnapshot>()
    private let lock = NSLock()
    private var running = false

    public init(
        agentID: AgentID,
        label: String,
        keyboard: KeyboardInjector = KeyboardInjector(),
        pointer: PointerInjector = PointerInjector()
    ) {
        self.agentID = agentID
        self.label = label
        self.keyboard = keyboard
        self.pointer = pointer
    }

    public func observeState() -> AsyncStream<AgentStateSnapshot> {
        stateStream.make()
    }

    public func start() async throws {
        setRunning(true)
        emit(status: .idle, detail: "Screen ready")
    }

    public func stop() async {
        setRunning(false)
        emit(status: .disconnected, detail: "Screen stopped")
    }

    public func sendInput(_ text: String, submit: Bool) async throws {
        guard isRunning else { throw adapterError("Mac Screen is not running.") }
        if !text.isEmpty {
            keyboard.typeString(text)
        }
        if submit {
            keyboard.pressReturn()
        }
        emit(status: .working, detail: submit ? "Typed and pressed Return" : "Typed on Mac")
        emit(status: .idle, detail: "Screen ready")
    }

    public func interrupt() async throws {
        guard isRunning else { throw adapterError("Mac Screen is not running.") }
        keyboard.pressEscape()
        emit(status: .idle, detail: "Pressed Escape")
    }

    public func pointerInput(_ input: ScreenPointerInput) async throws {
        guard isRunning else { throw adapterError("Mac Screen is not running.") }
        pointer.clickNormalized(
            x: input.x,
            y: input.y,
            doubleClick: input.action == .doubleClick
        )
        emit(status: .idle, detail: input.action == .doubleClick ? "Double clicked" : "Clicked")
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func setRunning(_ value: Bool) {
        lock.lock()
        running = value
        lock.unlock()
    }

    private func emit(status: AgentStatus, detail: String) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        stateStream.yield(AgentStateSnapshot(
            agentId: agentID,
            agentLabel: label,
            adapterKind: kind,
            status: status,
            statusDetail: detail,
            lastActivityUnixMs: now,
            hasVideoTrack: true,
            remoteAppId: "screen"
        ))
    }

    private func adapterError(_ message: String) -> NSError {
        NSError(domain: "ScreenMirrorAdapter", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
