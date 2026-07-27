#if os(macOS)
import CoreGraphics
import Foundation

/// Posts normalized pointer input to the Mac's primary display.
///
/// Coordinates are expressed as 0...1 ratios of the display bounds so the web
/// app can send taps independent of phone/browser viewport size.
public final class PointerInjector: @unchecked Sendable {
    public init() {}

    public func clickNormalized(
        x: Double,
        y: Double,
        doubleClick: Bool = false,
        displayID: CGDirectDisplayID = CGMainDisplayID()
    ) {
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let clampedX = min(max(x, 0), 1)
        let clampedY = min(max(y, 0), 1)
        let point = CGPoint(
            x: bounds.minX + bounds.width * clampedX,
            y: bounds.minY + bounds.height * clampedY
        )

        post(.mouseMoved, point: point)
        postClick(at: point, clickState: 1)
        if doubleClick {
            postClick(at: point, clickState: 2)
        }
    }

    private func postClick(at point: CGPoint, clickState: Int64) {
        post(.leftMouseDown, point: point, clickState: clickState)
        post(.leftMouseUp, point: point, clickState: clickState)
    }

    private func post(_ type: CGEventType, point: CGPoint, clickState: Int64 = 0) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }
        if clickState > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        event.post(tap: .cghidEventTap)
    }
}
#else
public final class PointerInjector: @unchecked Sendable {
    public init() {}
    public func clickNormalized(x _: Double, y _: Double, doubleClick _: Bool = false, displayID _: UInt32 = 0) {}
}
#endif
