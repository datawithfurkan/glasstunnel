#if os(macOS)
import CoreVideo
import XCTest
@testable import GTCapture

final class FrameKeepaliveTests: XCTestCase {
    func testRepeatsTheLastFrameOnlyAfterAFullIdleInterval() throws {
        let buffer = try makePixelBuffer()
        let keepalive = FrameKeepalive(interval: 1.0, clock: { 0 })

        XCTAssertNil(keepalive.frameToRepeat(now: 5), "nothing to repeat before any frame arrived")

        keepalive.noteFrame(buffer)
        XCTAssertNil(keepalive.frameToRepeat(now: 0.5))
        XCTAssertNotNil(keepalive.frameToRepeat(now: 1.0))
        XCTAssertNil(keepalive.frameToRepeat(now: 1.5), "a repeat restarts the idle clock")
        XCTAssertNotNil(keepalive.frameToRepeat(now: 2.0))
    }

    func testFreshFramesPostponeTheRepeat() throws {
        let buffer = try makePixelBuffer()
        let clock = ManualClock()
        let keepalive = FrameKeepalive(interval: 1.0, clock: { clock.now })

        keepalive.noteFrame(buffer)
        clock.now = 0.9
        keepalive.noteFrame(buffer)
        XCTAssertNil(keepalive.frameToRepeat(now: 1.5))
        XCTAssertNil(keepalive.frameToRepeat(now: 1.85))
        XCTAssertNotNil(keepalive.frameToRepeat(now: 1.9), "one interval after the newest frame")
    }

    func testStartKeepsAFrameNotedBeforeTheTimerRan() throws {
        let buffer = try makePixelBuffer()
        let keepalive = FrameKeepalive(interval: 1.0, clock: { 0 })

        keepalive.noteFrame(buffer)
        keepalive.start()
        defer { keepalive.stop() }

        XCTAssertNotNil(keepalive.frameToRepeat(now: 1.0))
    }

    func testStopForgetsTheFrame() throws {
        let buffer = try makePixelBuffer()
        let keepalive = FrameKeepalive(interval: 1.0, clock: { 0 })

        keepalive.noteFrame(buffer)
        keepalive.stop()

        XCTAssertNil(keepalive.frameToRepeat(now: 10))
    }

    func testTimerDeliversRepeatsWhileIdle() throws {
        let buffer = try makePixelBuffer()
        let keepalive = FrameKeepalive(interval: 0.05, clock: { CACurrentMediaTime() })
        let repeated = expectation(description: "idle frame repeated")
        repeated.assertForOverFulfill = false
        keepalive.onRepeat = { _ in repeated.fulfill() }

        keepalive.noteFrame(buffer)
        keepalive.start()
        wait(for: [repeated], timeout: 2)
        keepalive.stop()
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }
}

/// A clock the test advances by hand; a reference type so the keepalive's
/// `@Sendable` clock closure captures it without capturing a mutable local.
private final class ManualClock: @unchecked Sendable {
    var now: TimeInterval = 0
}
#endif
