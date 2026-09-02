import XCTest
@testable import GTAdapters

private final class FakeHookSource: ClaudeHookEventSource, @unchecked Sendable {
    var onHook: (@Sendable (ClaudeCodeHookListener.Event) -> Void)?
    private let lock = NSLock()
    private var _startCount = 0
    private var _stopCount = 0
    var shouldThrowOnStart = false

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _startCount
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _stopCount
    }

    func start() throws {
        lock.lock()
        _startCount += 1
        let fail = shouldThrowOnStart
        lock.unlock()
        if fail {
            throw NSError(domain: "FakeHookSource", code: 1)
        }
    }

    func stop() {
        lock.lock()
        _stopCount += 1
        lock.unlock()
    }

    func fire(kind: ClaudeCodeHookListener.HookKind, session: String, summary: String = "summary") {
        onHook?(ClaudeCodeHookListener.Event(kind: kind, session: session, summary: summary))
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [ClaudeCodeHookListener.Event] = []

    var events: [ClaudeCodeHookListener.Event] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    func append(_ event: ClaudeCodeHookListener.Event) {
        lock.lock()
        _events.append(event)
        lock.unlock()
    }
}

final class ClaudeHookRouterTests: XCTestCase {
    func testRoutesEventsOnlyToOwningSubscriber() throws {
        let source = FakeHookSource()
        let router = ClaudeHookRouter(makeListener: { source })
        let cliEvents = EventRecorder()
        let desktopEvents = EventRecorder()

        _ = try router.subscribe(
            ownsSession: { $0 == "cli-session" || $0.isEmpty },
            handler: { cliEvents.append($0) }
        )
        _ = try router.subscribe(
            ownsSession: { $0 == "desktop-session" },
            handler: { desktopEvents.append($0) }
        )

        source.fire(kind: .stop, session: "cli-session")
        source.fire(kind: .notification, session: "desktop-session")
        source.fire(kind: .stop, session: "")
        source.fire(kind: .stop, session: "unowned-session")

        XCTAssertEqual(cliEvents.events.map(\.session), ["cli-session", ""])
        XCTAssertEqual(desktopEvents.events.map(\.session), ["desktop-session"])
    }

    func testListenerStartsOnceAndStopsWithLastSubscriber() throws {
        let source = FakeHookSource()
        let router = ClaudeHookRouter(makeListener: { source })

        let first = try router.subscribe(ownsSession: { _ in true }, handler: { _ in })
        let second = try router.subscribe(ownsSession: { _ in true }, handler: { _ in })
        XCTAssertEqual(source.startCount, 1, "The shared socket must only be bound once.")

        router.unsubscribe(first)
        XCTAssertEqual(source.stopCount, 0, "The listener must survive while a subscriber remains.")

        router.unsubscribe(second)
        XCTAssertEqual(source.stopCount, 1, "The last unsubscribe must release the socket.")
    }

    func testFailedListenerStartRemovesSubscriberAndAllowsRetry() {
        let source = FakeHookSource()
        source.shouldThrowOnStart = true
        let router = ClaudeHookRouter(makeListener: { source })
        let events = EventRecorder()

        XCTAssertThrowsError(
            try router.subscribe(ownsSession: { _ in true }, handler: { events.append($0) })
        )

        source.shouldThrowOnStart = false
        XCTAssertNoThrow(
            try router.subscribe(ownsSession: { _ in true }, handler: { events.append($0) })
        )
        source.fire(kind: .stop, session: "any")
        XCTAssertEqual(events.events.count, 1, "Only the successful subscription may receive events.")
    }
}
