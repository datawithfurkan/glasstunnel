#if os(macOS)
import AppKit
import AVFoundation
import CoreImage
import Foundation
import GTCapture
import GTProtocol

/// Low-FPS screen transport used when a phone cannot establish the WebRTC
/// media path. Commands still use the authenticated relay; this only carries
/// reduced JPEG frames so mobile Safari has a reliable fallback view.
public protocol RelayScreenCapturing: AnyObject, Sendable {
    func uses(relay: RelayClient, quality: RemoteAppActionRequest.ScreenQuality) -> Bool
    func start() async throws
    func stop() async
}

public typealias RelayScreenCaptureFactory = @MainActor (
    _ agentId: AgentID,
    _ relay: RelayClient,
    _ quality: RemoteAppActionRequest.ScreenQuality
) -> any RelayScreenCapturing

final class RelayScreenCapture: RelayScreenCapturing, @unchecked Sendable {
    struct Configuration: Sendable, Equatable {
        let quality: RemoteAppActionRequest.ScreenQuality
        let fps: Int
        let maxDimension: Int
        let compression: CGFloat

        var minFrameIntervalMs: Int64 {
            Int64(1_000 / max(fps, 1))
        }

        static func preset(_ quality: RemoteAppActionRequest.ScreenQuality) -> Configuration {
            switch quality {
            case .fast:
                return Configuration(quality: .fast, fps: 2, maxDimension: 720, compression: 0.42)
            case .readable:
                return Configuration(quality: .readable, fps: 2, maxDimension: 1280, compression: 0.72)
            }
        }
    }

    private let agentId: AgentID
    private let relay: RelayClient
    private let capture: DisplayCapture
    private let encoder: RelayScreenFrameEncoder
    private let configuration: Configuration
    private let stateLock = NSLock()
    private var lastSentAtUnixMs: Int64 = 0
    private var sequence: Int64 = 0
    private var generation: UInt64 = 0
    private var isRunning = false

    init(
        agentId: AgentID,
        relay: RelayClient,
        quality: RemoteAppActionRequest.ScreenQuality = .readable
    ) {
        let configuration = Configuration.preset(quality)
        self.agentId = agentId
        self.relay = relay
        self.configuration = configuration
        self.encoder = RelayScreenFrameEncoder(
            maxDimension: configuration.maxDimension,
            compression: configuration.compression
        )
        self.capture = DisplayCapture(configuration: .init(
            activeFps: configuration.fps,
            idleFps: configuration.fps,
            maxDimension: configuration.maxDimension,
            showCursor: true
        ))
    }

    func uses(relay: RelayClient, quality: RemoteAppActionRequest.ScreenQuality) -> Bool {
        self.relay === relay && configuration.quality == quality
    }

    func start() async throws {
        guard let activeGeneration = beginRunningGeneration() else { return }

        capture.onFrame = { [weak self] sampleBuffer in
            self?.handleFrame(sampleBuffer, generation: activeGeneration)
        }
        do {
            try await capture.start()
        } catch {
            invalidate(generation: activeGeneration)
            capture.onFrame = nil
            await capture.stop()
            throw error
        }
    }

    func stop() async {
        let shouldStop = markStopped()
        capture.onFrame = nil
        guard shouldStop else { return }
        await capture.stop()
    }

    private func handleFrame(_ sampleBuffer: CMSampleBuffer, generation: UInt64) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        guard let sequence = reserveFrame(at: now, generation: generation) else { return }
        guard let frame = encoder.encode(sampleBuffer) else { return }
        guard isCurrent(generation: generation) else { return }

        let message = RelayScreenFrameMessage(
            agentId: agentId,
            mimeType: frame.mimeType,
            width: frame.width,
            height: frame.height,
            bytes: frame.bytes,
            sequence: sequence,
            atUnixMs: now
        )
        Task { [weak self, relay] in
            guard self?.isCurrent(generation: generation) == true else { return }
            try? await relay.publishScreenFrame(message)
        }
    }

    private func reserveFrame(at now: Int64, generation: UInt64) -> Int64? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isRunning, self.generation == generation else { return nil }
        guard now - lastSentAtUnixMs >= configuration.minFrameIntervalMs else { return nil }
        lastSentAtUnixMs = now
        sequence += 1
        return sequence
    }

    private func beginRunningGeneration() -> UInt64? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isRunning else { return nil }
        isRunning = true
        generation &+= 1
        return generation
    }

    private func markStopped() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let wasRunning = isRunning
        isRunning = false
        generation &+= 1
        return wasRunning
    }

    private func isCurrent(generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRunning && self.generation == generation
    }

    private func invalidate(generation: UInt64) {
        stateLock.lock()
        if self.generation == generation {
            isRunning = false
            self.generation &+= 1
        }
        stateLock.unlock()
    }
}

private struct RelayEncodedFrame {
    let mimeType: String
    let width: Int
    let height: Int
    let bytes: Data
}

private final class RelayScreenFrameEncoder: @unchecked Sendable {
    private let downsampler: FrameDownsampler
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let compression: CGFloat

    init(maxDimension: Int, compression: CGFloat) {
        self.downsampler = FrameDownsampler(targetMaxDimension: maxDimension)
        self.compression = compression
    }

    func encode(_ sampleBuffer: CMSampleBuffer) -> RelayEncodedFrame? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let frameBuffer = downsampler.downsample(pixelBuffer) ?? pixelBuffer
        let width = CVPixelBufferGetWidth(frameBuffer)
        let height = CVPixelBufferGetHeight(frameBuffer)
        guard width > 0, height > 0 else { return nil }

        let image = CIImage(cvPixelBuffer: frameBuffer)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let cgImage = context.createCGImage(image, from: rect) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let bytes = bitmap.representation(using: .jpeg, properties: [
            .compressionFactor: compression,
        ]) else {
            return nil
        }
        return RelayEncodedFrame(
            mimeType: "image/jpeg",
            width: width,
            height: height,
            bytes: bytes
        )
    }
}
#endif
