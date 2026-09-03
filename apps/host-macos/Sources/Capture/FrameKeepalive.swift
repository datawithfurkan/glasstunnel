#if os(macOS)
import CoreVideo
import Foundation
import QuartzCore

/// Repeats the last captured frame while the source is idle.
///
/// ScreenCaptureKit only delivers a frame when pixels change, so a static Mac
/// screen and a dead capture look identical to the receiver: no packets, a
/// muted track, and on Safari a black picture. Re-sending the last frame at a
/// low cadence costs a few tiny P-frames per second and lets the phone treat
/// silence as a failure it can recover from.
public final class FrameKeepalive: @unchecked Sendable {
    public typealias Clock = @Sendable () -> TimeInterval

    public let interval: TimeInterval
    public var onRepeat: (@Sendable (CVPixelBuffer) -> Void)?

    private let lock = NSLock()
    private let clock: Clock
    private let queue: DispatchQueue
    private var lastFrame: CVPixelBuffer?
    private var lastFrameAt: TimeInterval = 0
    private var timer: DispatchSourceTimer?

    public init(
        interval: TimeInterval = 1.0,
        queue: DispatchQueue = DispatchQueue(label: "io.glasstunnel.frame-keepalive", qos: .userInitiated),
        clock: @escaping Clock = { CACurrentMediaTime() }
    ) {
        self.interval = interval
        self.queue = queue
        self.clock = clock
    }

    deinit {
        timer?.cancel()
    }

    /// Records a frame the source just delivered; it becomes the frame to repeat.
    public func noteFrame(_ buffer: CVPixelBuffer) {
        lock.lock()
        lastFrame = buffer
        lastFrameAt = clock()
        lock.unlock()
    }

    public func start() {
        cancelTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let period = max(interval / 2, 0.05)
        timer.schedule(deadline: .now() + period, repeating: period, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self, let frame = self.frameToRepeat(now: self.clock()) else { return }
            self.onRepeat?(frame)
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        cancelTimer()
        lock.lock()
        lastFrame = nil
        lock.unlock()
    }

    /// The frame to send when the source has been idle for a full interval, or
    /// nil while fresh frames are flowing. Repeating advances the idle clock so
    /// the next repeat happens one interval later.
    public func frameToRepeat(now: TimeInterval) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let lastFrame, now - lastFrameAt + Self.clockTolerance >= interval else { return nil }
        lastFrameAt = now
        return lastFrame
    }

    private static let clockTolerance: TimeInterval = 0.001

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
}
#endif
