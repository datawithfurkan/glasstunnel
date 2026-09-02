import Foundation

/// Abstraction over the Unix-socket hook listener so the router can be tested
/// without binding the real socket.
public protocol ClaudeHookEventSource: AnyObject, Sendable {
    var onHook: (@Sendable (ClaudeCodeHookListener.Event) -> Void)? { get set }
    func start() throws
    func stop()
}

extension ClaudeCodeHookListener: ClaudeHookEventSource {}

/// Routes Claude Code hook events from the single shared Unix socket to the
/// adapter that owns the session the event belongs to.
///
/// Claude Code hooks are installed user-globally in `~/.claude/settings.json`
/// and fire for every Claude Code session by any client — the CLI and the
/// Claude desktop app alike. Only one listener can bind the socket at a time,
/// so this router owns that listener process-wide; adapters subscribe with a
/// session-ownership predicate and only receive events for sessions they own.
/// An event whose session no subscriber owns is dropped rather than guessed at.
public final class ClaudeHookRouter: @unchecked Sendable {
    public typealias Event = ClaudeCodeHookListener.Event

    public static let shared = ClaudeHookRouter()

    private struct Subscriber {
        let ownsSession: @Sendable (String) -> Bool
        let handler: @Sendable (Event) -> Void
    }

    private let lock = NSLock()
    private let makeListener: @Sendable () -> any ClaudeHookEventSource
    private var listener: (any ClaudeHookEventSource)?
    private var subscribers: [UUID: Subscriber] = [:]

    public init(makeListener: @escaping @Sendable () -> any ClaudeHookEventSource = { ClaudeCodeHookListener() }) {
        self.makeListener = makeListener
    }

    /// Binding the socket happens inside the critical section and the
    /// subscriber is registered only once that succeeded, so no subscriber can
    /// ever observe a router whose listener failed to start.
    public func subscribe(
        ownsSession: @escaping @Sendable (String) -> Bool,
        handler: @escaping @Sendable (Event) -> Void
    ) throws -> UUID {
        lock.lock()
        defer { lock.unlock() }

        if listener == nil {
            let fresh = makeListener()
            fresh.onHook = { [weak self] event in
                self?.route(event)
            }
            try fresh.start()
            listener = fresh
        }
        let id = UUID()
        subscribers[id] = Subscriber(ownsSession: ownsSession, handler: handler)
        return id
    }

    public func unsubscribe(_ id: UUID) {
        lock.lock()
        subscribers.removeValue(forKey: id)
        let idle = subscribers.isEmpty
        let current = listener
        if idle { listener = nil }
        lock.unlock()
        if idle { current?.stop() }
    }

    func route(_ event: Event) {
        lock.lock()
        let all = Array(subscribers.values)
        lock.unlock()

        for subscriber in all where subscriber.ownsSession(event.session) {
            subscriber.handler(event)
        }
    }
}
