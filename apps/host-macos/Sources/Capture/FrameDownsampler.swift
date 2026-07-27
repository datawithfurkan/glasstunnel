#if os(macOS)
import CoreImage
import CoreVideo
import Foundation

/// Utility that downsamples captured frames to a target max dimension so we
/// don't stream 5K pixels to a phone. The WebRTC layer does its own scaling,
/// but feeding it smaller frames up front saves CPU and power on both ends.
public final class FrameDownsampler: @unchecked Sendable {
    public var targetMaxDimension: Int
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    public init(targetMaxDimension: Int = 1280) {
        self.targetMaxDimension = targetMaxDimension
    }

    public func downsample(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let target = CaptureFrameSizing.scaledDimensions(
            width: width,
            height: height,
            maxDimension: targetMaxDimension
        )
        if width == target.width && height == target.height { return pixelBuffer }

        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let scaled = ci.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(target.width) / CGFloat(width),
                y: CGFloat(target.height) / CGFloat(height)
            )
        )

        var out: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            target.width,
            target.height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &out
        )
        guard let target = out else { return nil }
        ciContext.render(scaled, to: target)
        return target
    }
}

enum CaptureFrameSizing {
    static func scaledDimensions(width: Int, height: Int, maxDimension: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (width: 0, height: 0) }

        let safeMaxDimension = evenDimension(maxDimension)
        let sourceMaxDimension = max(width, height)
        let scale = sourceMaxDimension > safeMaxDimension
            ? Double(safeMaxDimension) / Double(sourceMaxDimension)
            : 1

        let scaledWidth = evenDimension(Int(Double(width) * scale))
        let scaledHeight = evenDimension(Int(Double(height) * scale))
        return (width: scaledWidth, height: scaledHeight)
    }

    private static func evenDimension(_ value: Int) -> Int {
        let clamped = max(2, value)
        return clamped.isMultiple(of: 2) ? clamped : clamped - 1
    }
}
#endif
