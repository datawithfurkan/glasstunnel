#if os(macOS)
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
}
#endif
