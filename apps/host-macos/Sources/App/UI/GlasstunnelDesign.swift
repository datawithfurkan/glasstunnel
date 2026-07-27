#if os(macOS)
import AppKit
import SwiftUI

enum GlasstunnelDesign {
    static let background = Color(red: 32 / 255, green: 29 / 255, blue: 29 / 255)
    static let surface = Color(red: 48 / 255, green: 44 / 255, blue: 44 / 255)
    static let surfaceAlt = Color(red: 63 / 255, green: 58 / 255, blue: 58 / 255)
    static let text = Color(red: 253 / 255, green: 252 / 255, blue: 252 / 255)
    static let muted = Color(red: 154 / 255, green: 152 / 255, blue: 152 / 255)
    static let border = Color(red: 15 / 255, green: 0 / 255, blue: 0 / 255).opacity(0.38)
    static let outline = Color(red: 100 / 255, green: 98 / 255, blue: 98 / 255)
    static let accent = Color(red: 0 / 255, green: 122 / 255, blue: 255 / 255)
    static let danger = Color(red: 1, green: 59 / 255, blue: 48 / 255)
    static let success = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
    static let warning = Color(red: 1, green: 159 / 255, blue: 10 / 255)

    static let panelRadius: CGFloat = 14
    static let microRadius: CGFloat = 8
}

extension View {
    func glasstunnelPanelStyle(radius: CGFloat = GlasstunnelDesign.panelRadius) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(GlasstunnelDesign.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(GlasstunnelDesign.border, lineWidth: 1)
            )
    }

    func pointingHandCursor(_ isEnabled: Bool = true) -> some View {
        modifier(PointingHandCursorModifier(isEnabled: isEnabled))
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    let isEnabled: Bool
    @State private var cursorIsActive = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                guard isEnabled else {
                    popCursorIfNeeded()
                    return
                }

                if hovering {
                    pushCursorIfNeeded()
                } else {
                    popCursorIfNeeded()
                }
            }
            .onDisappear {
                popCursorIfNeeded()
            }
            .onChange(of: isEnabled) { enabled in
                if !enabled {
                    popCursorIfNeeded()
                }
            }
    }

    private func pushCursorIfNeeded() {
        guard !cursorIsActive else { return }
        NSCursor.pointingHand.push()
        cursorIsActive = true
    }

    private func popCursorIfNeeded() {
        guard cursorIsActive else { return }
        NSCursor.pop()
        cursorIsActive = false
    }
}
#endif
