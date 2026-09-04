import Foundation
import GTProtocol

/// What the phone's "Fast" / "Readable" choice means for the WebRTC screen
/// stream: the capture size, the frame rates, and the encoder's bitrate
/// ceiling. The same choice also sizes the JPEG relay fallback.
public struct ScreenStreamProfile: Sendable, Hashable {
    public var quality: RemoteAppActionRequest.ScreenQuality
    /// Longest side of the captured frame, in pixels.
    public var maxDimension: Int
    public var activeFps: Int
    public var idleFps: Int
    public var maxBitrateBps: Int

    /// The stream every release so far sent: a 720p-class picture of the display.
    public static let fast = ScreenStreamProfile(
        quality: .fast, maxDimension: 1280, activeFps: 12, idleFps: 2, maxBitrateBps: 2_500_000
    )
    /// A 1080p-class picture, so text stays legible when the phone zooms in.
    /// The encoder keeps this resolution under network pressure and lowers
    /// the frame rate instead.
    public static let readable = ScreenStreamProfile(
        quality: .readable, maxDimension: 1920, activeFps: 12, idleFps: 2, maxBitrateBps: 6_000_000
    )

    public static func profile(for quality: RemoteAppActionRequest.ScreenQuality) -> ScreenStreamProfile {
        switch quality {
        case .fast: return .fast
        case .readable: return .readable
        }
    }

    public var encodingLimits: VideoEncodingLimits {
        VideoEncodingLimits(maxBitrateBps: maxBitrateBps, maxFramerate: activeFps)
    }
}

/// Ceilings applied to a video sender's encoding parameters.
public struct VideoEncodingLimits: Sendable, Hashable {
    public var maxBitrateBps: Int
    public var maxFramerate: Int

    public init(maxBitrateBps: Int, maxFramerate: Int) {
        self.maxBitrateBps = maxBitrateBps
        self.maxFramerate = maxFramerate
    }
}
