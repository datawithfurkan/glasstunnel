#if os(macOS)
import AppKit
import SwiftUI

struct BrandMarkView: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(GlasstunnelDesign.accent.opacity(0.12))
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .stroke(GlasstunnelDesign.accent.opacity(0.26), lineWidth: 1)
            Canvas { context, canvasSize in
                let stroke = StrokeStyle(lineWidth: max(1.4, size * 0.055), lineCap: .round, lineJoin: .round)
                var tunnel = Path()
                tunnel.move(to: CGPoint(x: canvasSize.width * 0.30, y: canvasSize.height * 0.66))
                tunnel.addLine(to: CGPoint(x: canvasSize.width * 0.30, y: canvasSize.height * 0.38))
                tunnel.addCurve(
                    to: CGPoint(x: canvasSize.width * 0.72, y: canvasSize.height * 0.38),
                    control1: CGPoint(x: canvasSize.width * 0.30, y: canvasSize.height * 0.18),
                    control2: CGPoint(x: canvasSize.width * 0.72, y: canvasSize.height * 0.18)
                )
                tunnel.addLine(to: CGPoint(x: canvasSize.width * 0.72, y: canvasSize.height * 0.66))
                context.stroke(tunnel, with: .color(GlasstunnelDesign.accent), style: stroke)

                let lines: [(CGFloat, CGFloat)] = [(0.12, 0.48), (0.08, 0.58), (0.16, 0.68)]
                for (startX, y) in lines {
                    var line = Path()
                    line.move(to: CGPoint(x: canvasSize.width * startX, y: canvasSize.height * y))
                    line.addLine(to: CGPoint(x: canvasSize.width * 0.48, y: canvasSize.height * y))
                    context.stroke(line, with: .color(GlasstunnelDesign.accent.opacity(0.72)), style: stroke)
                }
            }
        }
        .frame(width: size, height: size)
    }

    /// The mark's tunnel and lines without the tile, as a template image so
    /// the menu bar can tint it for light, dark, and highlighted states.
    static let menuBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            // The strokes span x 0.08...0.72 and y 0.23...0.68 of the tile;
            // scale that box to about 14 pt wide and center it.
            let scale: CGFloat = 22
            let origin = CGPoint(x: (rect.width - 0.64 * scale) / 2 - 0.08 * scale,
                                 y: (rect.height - 0.45 * scale) / 2 - 0.23 * scale)
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
            }
            NSColor.black.setStroke()

            let tunnel = NSBezierPath()
            tunnel.move(to: point(0.30, 0.66))
            tunnel.line(to: point(0.30, 0.38))
            tunnel.curve(to: point(0.72, 0.38), controlPoint1: point(0.30, 0.18), controlPoint2: point(0.72, 0.18))
            tunnel.line(to: point(0.72, 0.66))

            let lines = NSBezierPath()
            for (startX, y) in [(0.12, 0.48), (0.08, 0.58), (0.16, 0.68)] as [(CGFloat, CGFloat)] {
                lines.move(to: point(startX, y))
                lines.line(to: point(0.48, y))
            }

            for path in [tunnel, lines] {
                path.lineWidth = 1.6
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Glasstunnel"
        return image
    }()
}
#endif
