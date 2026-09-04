import XCTest
@testable import GTTransport

final class ReconnectBackoffTests: XCTestCase {
    func testDelayDoublesUntilTheCapAndResetsOnlyOnceStable() {
        var backoff = ReconnectBackoff(baseDelaySeconds: 1, maxDelaySeconds: 60, stableAfterSeconds: 30)
        XCTAssertEqual([backoff.nextDelaySeconds(), backoff.nextDelaySeconds(), backoff.nextDelaySeconds(), backoff.nextDelaySeconds()], [1, 2, 4, 8])
        XCTAssertEqual(backoff.attempt, 4)
        for _ in 0..<10 { _ = backoff.nextDelaySeconds() }
        XCTAssertEqual(backoff.nextDelaySeconds(), 60, "capped")

        // A socket that authenticates and dies at once must keep waiting longer:
        // only a stable connection resets the counter.
        backoff.noteStable()
        XCTAssertEqual(backoff.attempt, 0)
        XCTAssertEqual(backoff.nextDelaySeconds(), 1)
    }

    func testJitterAddsAtMostTwentyPercent() {
        for _ in 0..<50 {
            let delay = ReconnectBackoff.jittered(10)
            XCTAssertGreaterThanOrEqual(delay, 10)
            XCTAssertLessThanOrEqual(delay, 12)
        }
    }
}
