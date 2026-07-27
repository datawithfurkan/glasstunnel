#if os(macOS)
import AppKit
import Carbon
import Foundation

/// Synthetic keyboard event generation via CGEvent.
///
/// This is the fallback path used by the generic mirror adapter when no
/// tool-specific adapter is active. Keystrokes are posted globally at the
/// `cghidEventTap` location; callers should focus the target process first.
///
/// For Unicode text, we use `keyboardSetUnicodeString` so we don't have to
/// resolve keyboard layout mappings for every glyph.
public final class KeyboardInjector: @unchecked Sendable {
    public init() {}

    /// Type the given string into the currently focused application.
    public func typeString(_ text: String) {
        typeString(text, targetPID: nil)
    }

    /// Type the given string directly to a process after Accessibility focuses its input.
    public func typeString(_ text: String, targetPID: pid_t) {
        typeString(text, targetPID: targetPID > 0 ? targetPID : nil)
    }

    private func typeString(_ text: String, targetPID: pid_t?) {
        for char in text {
            let s = String(char)
            typeOne(s, targetPID: targetPID)
        }
    }

    /// Press Return.
    public func pressReturn() {
        pressKey(virtualKey: CGKeyCode(kVK_Return), targetPID: nil)
    }

    /// Press Return directly in a process.
    public func pressReturn(targetPID: pid_t) {
        pressKey(virtualKey: CGKeyCode(kVK_Return), targetPID: targetPID > 0 ? targetPID : nil)
    }

    /// Press Escape.
    public func pressEscape() {
        pressKey(virtualKey: CGKeyCode(kVK_Escape), targetPID: nil)
    }

    /// Press Command+A in the currently focused field.
    public func pressCommandA() {
        pressKey(virtualKey: CGKeyCode(kVK_ANSI_A), flags: .maskCommand, targetPID: nil)
    }

    /// Press Command+V in the currently focused field.
    public func pressCommandV() {
        pressKey(virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand, targetPID: nil)
    }

    /// Press Command+A directly in a process.
    public func pressCommandA(targetPID: pid_t) {
        pressKey(virtualKey: CGKeyCode(kVK_ANSI_A), flags: .maskCommand, targetPID: targetPID > 0 ? targetPID : nil)
    }

    /// Press Command+V directly in a process.
    public func pressCommandV(targetPID: pid_t) {
        pressKey(virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand, targetPID: targetPID > 0 ? targetPID : nil)
    }

    /// Press Delete / Backspace.
    public func pressDelete() {
        pressKey(virtualKey: CGKeyCode(kVK_Delete), targetPID: nil)
    }

    /// Press Delete / Backspace directly in a process.
    public func pressDelete(targetPID: pid_t) {
        pressKey(virtualKey: CGKeyCode(kVK_Delete), targetPID: targetPID > 0 ? targetPID : nil)
    }

    /// Press Ctrl+C-style interrupt (for CLI agents not wrapped in a PTY).
    public func pressControlC() {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        down?.flags = .maskControl
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        up?.flags = .maskControl
        up?.post(tap: .cghidEventTap)
    }

    /// Focus the given PID's frontmost window so subsequent key events land there.
    public func focusApplication(pid: pid_t) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func typeOne(_ s: String, targetPID: pid_t?) {
        let src = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(s.utf16)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        post(down, targetPID: targetPID)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        post(up, targetPID: targetPID)
    }

    private func pressKey(virtualKey: CGKeyCode, flags: CGEventFlags = [], targetPID: pid_t?) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true)
        down?.flags = flags
        post(down, targetPID: targetPID)
        let up = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false)
        up?.flags = flags
        post(up, targetPID: targetPID)
    }

    private func post(_ event: CGEvent?, targetPID: pid_t?) {
        guard let event else { return }
        if let targetPID, targetPID > 0 {
            event.postToPid(targetPID)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }
}
#else
public final class KeyboardInjector: @unchecked Sendable {
    public init() {}
    public func typeString(_: String) {}
    public func typeString(_: String, targetPID: Int32) {}
    public func pressReturn() {}
    public func pressReturn(targetPID: Int32) {}
    public func pressEscape() {}
    public func pressCommandA() {}
    public func pressCommandV() {}
    public func pressCommandA(targetPID: Int32) {}
    public func pressCommandV(targetPID: Int32) {}
    public func pressDelete() {}
    public func pressDelete(targetPID: Int32) {}
    public func pressControlC() {}
    public func focusApplication(pid: Int32) {}
}
#endif
