#if os(macOS)
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Captures the primary Mac display for the dedicated "Mac Screen" remote app.
///
/// This intentionally mirrors `WindowCapture`, but captures a full display
/// instead of a single app window so the web app can help users approve macOS
/// prompts, recover closed coding apps, or operate Terminal remotely.
@available(macOS 13.0, *)
public final class DisplayCapture: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var activeFps: Int
        public var idleFps: Int
        public var maxDimension: Int
        public var pixelFormat: OSType
        public var showCursor: Bool

        public init(
            activeFps: Int = 12,
            idleFps: Int = 2,
            maxDimension: Int = 1280,
            pixelFormat: OSType = kCVPixelFormatType_32BGRA,
            showCursor: Bool = true
        ) {
            self.activeFps = activeFps
            self.idleFps = idleFps
            self.maxDimension = maxDimension
            self.pixelFormat = pixelFormat
            self.showCursor = showCursor
        }
    }

    public let displayID: CGDirectDisplayID
    public var configuration: Configuration
    public var onFrame: ((CMSampleBuffer) -> Void)?
    public var onState: ((WindowCapture.State) -> Void)?

    private var stream: SCStream?
    private var currentIsActive = true
    private let queue = DispatchQueue(label: "io.glasstunnel.display-capture", qos: .userInitiated)

    public init(
        displayID: CGDirectDisplayID = CGMainDisplayID(),
        configuration: Configuration = Configuration()
    ) {
        self.displayID = displayID
        self.configuration = configuration
    }

    public func start() async throws {
        guard stream == nil else { return }
        onState?(.starting)
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                onState?(.error("display not found"))
                throw CaptureError.displayNotFound
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = streamConfiguration(for: display, active: currentIsActive)
            let s = SCStream(filter: filter, configuration: config, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            stream = s
            onState?(.running)
        } catch {
            onState?(.error(error.localizedDescription))
            throw error
        }
    }

    public func stop() async {
        onState?(.stopping)
        if let s = stream {
            try? await s.stopCapture()
            stream = nil
        }
        onState?(.idle)
    }

    public func setActive(_ active: Bool) async {
        guard currentIsActive != active else { return }
        currentIsActive = active
        guard let s = stream else { return }
        if #available(macOS 14.0, *) {
            do {
                try await s.updateConfiguration(streamConfigurationLite(active: active))
            } catch {
                onState?(.error("updateConfiguration: \(error.localizedDescription)"))
            }
        } else {
            await stop()
            try? await start()
        }
    }

    private func streamConfiguration(for display: SCDisplay, active: Bool) -> SCStreamConfiguration {
        let c = streamConfigurationLite(active: active)
        let dimensions = CaptureFrameSizing.scaledDimensions(
            width: display.width,
            height: display.height,
            maxDimension: configuration.maxDimension
        )
        c.width = dimensions.width
        c.height = dimensions.height
        return c
    }

    private func streamConfigurationLite(active: Bool) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.pixelFormat = configuration.pixelFormat
        c.showsCursor = configuration.showCursor
        c.minimumFrameInterval = CMTime(value: 1, timescale: Int32(active ? configuration.activeFps : configuration.idleFps))
        c.queueDepth = 3
        return c
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        onFrame?(sampleBuffer)
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onState?(.error(error.localizedDescription))
    }
}
#endif
