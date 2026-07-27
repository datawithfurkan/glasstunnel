#if os(macOS)
import AVFoundation
import CoreImage
import Foundation
import ScreenCaptureKit

/// Captures a single window via ScreenCaptureKit with adaptive frame rate.
///
/// - When the delegate is actively consuming frames (video track attached),
///   we stream at a target of ~20 fps.
/// - When nobody is looking (phone backgrounded), we drop to ~2 fps so we
///   barely touch the CPU.
///
/// The capturer emits CMSampleBuffer instances that the GTTransport layer
/// wraps into a WebRTC MediaStream track.
@available(macOS 13.0, *)
public final class WindowCapture: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    public enum State: Sendable {
        case idle
        case starting
        case running
        case stopping
        case error(String)
    }

    public struct Configuration: Sendable {
        public var activeFps: Int
        public var idleFps: Int
        public var maxDimension: Int
        public var pixelFormat: OSType
        public var showCursor: Bool

        public init(
            activeFps: Int = 20,
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

    public let windowID: CGWindowID
    public var configuration: Configuration
    public var onFrame: ((CMSampleBuffer) -> Void)?
    public var onState: ((State) -> Void)?

    private var stream: SCStream?
    private var currentIsActive: Bool = true
    private let queue = DispatchQueue(label: "io.glasstunnel.capture", qos: .userInitiated)

    public init(windowID: CGWindowID, configuration: Configuration = Configuration()) {
        self.windowID = windowID
        self.configuration = configuration
    }

    public func start() async throws {
        guard stream == nil else { return }
        onState?(.starting)
        do {
            let content = try await SCShareableContent.current
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                onState?(.error("window not found"))
                throw CaptureError.windowNotFound
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = streamConfiguration(for: window, active: currentIsActive)
            let s = SCStream(filter: filter, configuration: config, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            self.stream = s
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
        let placeholder = SCContentFilter()
        _ = placeholder
        // We rebuild the config for the new frame rate. SCStream supports
        // updateConfiguration on macOS 14+, so guard accordingly.
        if #available(macOS 14.0, *) {
            do {
                try await s.updateConfiguration(streamConfigurationLite(active: active))
            } catch {
                onState?(.error("updateConfiguration: \(error.localizedDescription)"))
            }
        } else {
            // On macOS 13, restart the stream with the new config.
            await stop()
            try? await start()
        }
    }

    private func streamConfiguration(for window: SCWindow, active: Bool) -> SCStreamConfiguration {
        let c = streamConfigurationLite(active: active)
        let dimensions = CaptureFrameSizing.scaledDimensions(
            width: Int(window.frame.width),
            height: Int(window.frame.height),
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

    // SCStreamOutput
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        onFrame?(sampleBuffer)
    }

    // SCStreamDelegate
    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onState?(.error(error.localizedDescription))
    }
}

public enum CaptureError: Error, CustomStringConvertible {
    case windowNotFound
    case displayNotFound
    case notAuthorized
    case unsupportedMacOS

    public var description: String {
        switch self {
        case .windowNotFound: return "Window not found"
        case .displayNotFound: return "Display not found"
        case .notAuthorized: return "Screen Recording permission denied"
        case .unsupportedMacOS: return "macOS 13+ required for window capture"
        }
    }
}
#endif
