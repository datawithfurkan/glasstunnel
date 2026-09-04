import Foundation

/// Exponential backoff for a socket that keeps dropping.
///
/// The attempt counter grows with every drop and is reset only once a
/// connection has stayed up for `stableAfterSeconds`; a socket that
/// authenticates and then dies a second later therefore waits longer each
/// time instead of hammering the relay every second, which is what phones
/// saw as "Mac offline" flapping.
public struct ReconnectBackoff: Sendable, Equatable {
    public private(set) var attempt: Int = 0
    public var baseDelaySeconds: Double = 1
    public var maxDelaySeconds: Double = 5 * 60
    public var stableAfterSeconds: Double = 30

    public init(baseDelaySeconds: Double = 1, maxDelaySeconds: Double = 5 * 60, stableAfterSeconds: Double = 30) {
        self.baseDelaySeconds = baseDelaySeconds
        self.maxDelaySeconds = maxDelaySeconds
        self.stableAfterSeconds = stableAfterSeconds
    }

    /// The delay before the next attempt, without jitter; advances the counter.
    public mutating func nextDelaySeconds() -> Double {
        let delay = min(baseDelaySeconds * pow(2.0, Double(attempt)), maxDelaySeconds)
        attempt += 1
        return delay
    }

    /// Up to 20% of extra wait so several hosts do not retry in lockstep.
    public static func jittered(_ delaySeconds: Double) -> Double {
        delaySeconds + Double.random(in: 0...(delaySeconds * 0.2))
    }

    /// Call once a connection has been up for `stableAfterSeconds`.
    public mutating func noteStable() {
        attempt = 0
    }
}
