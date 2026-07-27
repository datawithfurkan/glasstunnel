import Foundation

/// Centralized auto-lock state for the Mac host. Auto-lock pauses the tunnel
/// (video off, input injection disabled, DataChannel messages dropped) when
/// the phone has been inactive for `idleTimeout` seconds.
///
/// The phone reports its activity heartbeats; the Mac flips to locked when
/// either (a) we haven't heard from the phone in > timeout or (b) the Mac
/// goes to sleep.
@MainActor
public final class AutoLock: Sendable {
    public struct State: Sendable, Hashable {
        public var locked: Bool
        public var lastHeartbeatAt: Date?
        public var readOnlyMode: Bool
        public init(locked: Bool = true, lastHeartbeatAt: Date? = nil, readOnlyMode: Bool = false) {
            self.locked = locked
            self.lastHeartbeatAt = lastHeartbeatAt
            self.readOnlyMode = readOnlyMode
        }
    }

    public var idleTimeout: TimeInterval
    public var onLock: (@Sendable () -> Void)?
    public var onUnlock: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var state = State()
    private var timer: Timer?

    nonisolated public init(idleTimeout: TimeInterval = 5 * 60) {
        self.idleTimeout = idleTimeout
    }

    public func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let autoLock = self else { return }
            Task { @MainActor [autoLock] in
                autoLock.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func heartbeat() {
        lock.lock()
        state.lastHeartbeatAt = Date()
        let wasLocked = state.locked
        if wasLocked {
            state.locked = false
        }
        lock.unlock()
        if wasLocked { onUnlock?() }
    }

    public func forceLock() {
        lock.lock()
        let wasLocked = state.locked
        state.locked = true
        lock.unlock()
        if !wasLocked { onLock?() }
    }

    public func forceUnlock() {
        lock.lock()
        let wasLocked = state.locked
        state.locked = false
        state.lastHeartbeatAt = Date()
        lock.unlock()
        if wasLocked { onUnlock?() }
    }

    public func setReadOnly(_ readOnly: Bool) {
        lock.lock()
        state.readOnlyMode = readOnly
        lock.unlock()
    }

    public func currentState() -> State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public var isLocked: Bool { currentState().locked }
    public var isReadOnly: Bool { currentState().readOnlyMode }

    private func tick() {
        lock.lock()
        let last = state.lastHeartbeatAt
        let wasLocked = state.locked
        let expired = last.map { Date().timeIntervalSince($0) > idleTimeout } ?? true
        if expired && !wasLocked {
            state.locked = true
        }
        let shouldFire = expired && !wasLocked
        lock.unlock()
        if shouldFire { onLock?() }
    }
}
