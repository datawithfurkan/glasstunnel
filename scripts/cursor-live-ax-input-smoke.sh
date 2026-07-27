#!/usr/bin/env bash
# Privacy-safe live Cursor Accessibility input targeting smoke.
#
# By default, this does not submit a prompt. It verifies CursorAdapter's
# targeting behavior: try a settable AX text field whose description or
# placeholder contains "chat", fall back to the only unlabeled settable input
# when Cursor exposes one, write a marker, verify readback, then restore the
# previous value. Set GT_CURSOR_LIVE_AX_SUBMIT=1 only for an intentional tiny
# live-submit smoke.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Result: blocked; Cursor live AX input smoke requires macOS."
  exit 1
fi

if [[ "${GT_CURSOR_LIVE_AX_INPUT_PROBE:-0}" != "1" ]]; then
  cat <<'MSG'
Result: skipped; set GT_CURSOR_LIVE_AX_INPUT_PROBE=1 to run the live Cursor AX input smoke.

This smoke writes a temporary marker into the real Cursor chat input, verifies
readback, and restores the previous value without submitting a prompt.
MSG
  exit 0
fi

swift_file="$(mktemp -t glasstunnel-cursor-live-ax.XXXXXX.swift)"
cleanup() {
  rm -f "$swift_file"
}
trap cleanup EXIT

cat >"$swift_file" <<'SWIFT'
import AppKit
import ApplicationServices
import Carbon
import Foundation

let bundleID = "com.todesktop.230313mzl4w4u92"
let marker = ProcessInfo.processInfo.environment["GT_CURSOR_LIVE_AX_MARKER"]
    ?? "GT_CURSOR_AX_INPUT_SMOKE_\(Int(Date().timeIntervalSince1970))"
let allowNonEmpty = ProcessInfo.processInfo.environment["GT_CURSOR_LIVE_AX_ALLOW_NONEMPTY"] == "1"
let submitPrompt = ProcessInfo.processInfo.environment["GT_CURSOR_LIVE_AX_SUBMIT"] == "1"
let submitWaitSeconds = TimeInterval(ProcessInfo.processInfo.environment["GT_CURSOR_LIVE_AX_SUBMIT_WAIT_SECONDS"] ?? "8") ?? 8

enum SmokeError: Error, CustomStringConvertible {
    case axNotTrusted
    case appNotInstalled
    case appNotRunning
    case noWindow
    case noChatInput(candidates: [String])
    case existingDraft
    case setFailed(String, AXError)
    case readbackMismatch
    case submitFailed

    var description: String {
        switch self {
        case .axNotTrusted:
            return "Accessibility is not trusted for this process."
        case .appNotInstalled:
            return "Cursor.app is not installed."
        case .appNotRunning:
            return "Cursor did not launch."
        case .noWindow:
            return "Cursor has no accessible window."
        case .noChatInput(let candidates):
            if candidates.isEmpty {
                return "No settable text input candidates were exposed by Cursor Accessibility."
            }
            return "No settable Cursor input candidate matched the chat hint and no safe single-input fallback was available. Candidates: \(candidates.joined(separator: " | "))"
        case .existingDraft:
            return "Cursor chat input already contains text; refusing to overwrite it without GT_CURSOR_LIVE_AX_ALLOW_NONEMPTY=1."
        case .setFailed(let op, let err):
            return "\(op) failed with AX error \(err.rawValue)."
        case .readbackMismatch:
            return "Cursor input did not contain the marker after AXValue write."
        case .submitFailed:
            return "Cursor input still contained the marker after Return submit."
        }
    }
}

func runningCursor() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
}

func launchCursorIfNeeded() throws -> NSRunningApplication {
    if let app = runningCursor() { return app }
    guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
        throw SmokeError.appNotInstalled
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-b", bundleID]
    try process.run()
    process.waitUntilExit()

    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        if let app = runningCursor() { return app }
        Thread.sleep(forTimeInterval: 0.25)
    }
    throw SmokeError.appNotRunning
}

func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value as? String
}

func children(of element: AXUIElement) -> [AXUIElement] {
    var childrenRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
          let children = childrenRef as? [AXUIElement] else {
        return []
    }
    return children
}

func frame(of element: AXUIElement) -> CGRect? {
    var positionRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let positionValue = positionRef,
          let sizeValue = sizeRef,
          CFGetTypeID(positionValue) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else {
        return nil
    }

    var position = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue((positionValue as! AXValue), .cgPoint, &position)
    AXValueGetValue((sizeValue as! AXValue), .cgSize, &size)
    return CGRect(origin: position, size: size)
}

func focusedWindow(of app: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
       let cf = value, CFGetTypeID(cf) == AXUIElementGetTypeID() {
        return (cf as! AXUIElement)
    }
    return nil
}

func firstWindow(of app: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else {
        return nil
    }
    return windows.first
}

func isSettableTextInput(_ element: AXUIElement) -> Bool {
    let role = copyString(element, kAXRoleAttribute) ?? ""
    guard role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String) else {
        return false
    }
    var settable = DarwinBoolean(false)
    AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
    return settable.boolValue
}

func sanitizedDescriptor(_ element: AXUIElement) -> String {
    let role = copyString(element, kAXRoleAttribute) ?? "unknown-role"
    let desc = copyString(element, kAXDescriptionAttribute) ?? ""
    let placeholder = copyString(element, kAXPlaceholderValueAttribute) ?? ""
    let title = copyString(element, kAXTitleAttribute) ?? ""
    let labels = [title, desc, placeholder]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    if labels.isEmpty { return role }
    return "\(role): " + labels.joined(separator: " / ")
}

func isPlaceholderValue(_ value: String, for element: AXUIElement) -> Bool {
    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedValue.isEmpty else { return false }
    let placeholder = (copyString(element, kAXPlaceholderValueAttribute) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if !placeholder.isEmpty && trimmedValue == placeholder {
        return true
    }

    // Cursor 3.8.x exposes the empty composer placeholder as AXValue without
    // also exposing kAXPlaceholderValueAttribute. Keep this allowlist narrow so
    // real drafts still stop the smoke unless GT_CURSOR_LIVE_AX_ALLOW_NONEMPTY=1.
    return [
        "Plan, Build, / for skills, @ for context",
        "Send follow-up",
    ].contains(trimmedValue)
}

func findChatInput(in root: AXUIElement) -> (AXUIElement?, [String], String) {
    var queue: [AXUIElement] = [root]
    var candidates: [(element: AXUIElement, descriptor: String)] = []
    var visited = 0
    while !queue.isEmpty && visited < 4000 {
        visited += 1
        let element = queue.removeFirst()
        if isSettableTextInput(element) {
            let descriptor = sanitizedDescriptor(element)
            candidates.append((element: element, descriptor: descriptor))
            let searchable = descriptor.lowercased()
            if searchable.contains("chat") {
                return (element, candidates.map(\.descriptor), "chat hint")
            }
        }
        queue.append(contentsOf: children(of: element))
    }
    if candidates.count == 1, let only = candidates.first {
        return (only.element, candidates.map(\.descriptor), "single settable input fallback")
    }
    return (nil, candidates.map(\.descriptor), "none")
}

func setValue(_ value: String, on element: AXUIElement, op: String) throws {
    let err = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
    guard err == .success else { throw SmokeError.setFailed(op, err) }
}

func waitForValue(_ value: String, on element: AXUIElement, timeout: TimeInterval = 0.6) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if valueMatches(value, on: element) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.03)
    }
    return valueMatches(value, on: element)
}

func valueMatches(_ expected: String, on element: AXUIElement) -> Bool {
    let actual = copyString(element, kAXValueAttribute) ?? ""
    if actual == expected {
        return true
    }
    return expected.isEmpty && isPlaceholderValue(actual, for: element)
}

func post(_ event: CGEvent?, targetPID: pid_t? = nil) {
    guard let event else { return }
    if let targetPID, targetPID > 0 {
        event.postToPid(targetPID)
    } else {
        event.post(tap: .cghidEventTap)
    }
}

struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) {
        self.items = (pasteboard.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    values[type] = data
                }
            }
            return values
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let rebuiltItems: [NSPasteboardItem] = items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        if !rebuiltItems.isEmpty {
            pasteboard.writeObjects(rebuiltItems)
        }
    }
}

func pressKey(_ key: CGKeyCode, flags: CGEventFlags = [], targetPID: pid_t? = nil) {
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
    down?.flags = flags
    post(down, targetPID: targetPID)
    let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
    up?.flags = flags
    post(up, targetPID: targetPID)
}

func typeString(_ text: String, targetPID: pid_t? = nil) {
    let source = CGEventSource(stateID: .hidSystemState)
    for char in text {
        let utf16 = Array(String(char).utf16)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        post(down, targetPID: targetPID)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        post(up, targetPID: targetPID)
    }
}

func click(at point: CGPoint, targetPID: pid_t) {
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(
        mouseEventSource: source,
        mouseType: .leftMouseDown,
        mouseCursorPosition: point,
        mouseButton: .left
    )
    post(down)
    let up = CGEvent(
        mouseEventSource: source,
        mouseType: .leftMouseUp,
        mouseCursorPosition: point,
        mouseButton: .left
    )
    post(up)
}

func waitUntilInputNoLongerContains(_ value: String, on element: AXUIElement, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !valueMatches(value, on: element) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return !valueMatches(value, on: element)
}

func replaceValue(_ value: String, on element: AXUIElement, op: String, targetPID: pid_t) throws {
    try setValue(value, on: element, op: op)
    if waitForValue(value, on: element, timeout: 0.2) {
        return
    }
    if let frame = frame(of: element) {
        click(at: CGPoint(x: frame.midX, y: frame.midY), targetPID: targetPID)
        Thread.sleep(forTimeInterval: 0.25)
    }
    pressKey(CGKeyCode(kVK_ANSI_A), flags: .maskCommand, targetPID: targetPID)
    pressKey(CGKeyCode(kVK_Delete), targetPID: targetPID)
    if value.isEmpty, waitForValue(value, on: element, timeout: 0.3) {
        return
    }
    typeString(value, targetPID: targetPID)
    if waitForValue(value, on: element) {
        return
    }

    let pasteboard = NSPasteboard.general
    let previousPasteboard = PasteboardSnapshot(pasteboard)
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
    pressKey(CGKeyCode(kVK_ANSI_A), flags: .maskCommand, targetPID: targetPID)
    pressKey(CGKeyCode(kVK_Delete), targetPID: targetPID)
    pressKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand, targetPID: targetPID)
    previousPasteboard.restore(to: pasteboard)

    guard waitForValue(value, on: element) else {
        throw SmokeError.readbackMismatch
    }
}

do {
    guard AXIsProcessTrusted() else { throw SmokeError.axNotTrusted }

    let cursor = try launchCursorIfNeeded()
    cursor.activate(options: [.activateIgnoringOtherApps])
    Thread.sleep(forTimeInterval: 1.0)

    let appElement = AXUIElementCreateApplication(cursor.processIdentifier)
    guard let window = focusedWindow(of: appElement) ?? firstWindow(of: appElement) else {
        throw SmokeError.noWindow
    }
    let (input, candidates, matchMode) = findChatInput(in: window)
    guard let input else { throw SmokeError.noChatInput(candidates: candidates) }
    let matchedInputDescriptor = sanitizedDescriptor(input)

    let rawPreviousValue = copyString(input, kAXValueAttribute) ?? ""
    let previousWasPlaceholder = isPlaceholderValue(rawPreviousValue, for: input)
    let previousValue = previousWasPlaceholder ? "" : rawPreviousValue
    if !previousValue.isEmpty && !allowNonEmpty {
        throw SmokeError.existingDraft
    }
    if submitPrompt && !previousValue.isEmpty {
        throw SmokeError.existingDraft
    }

    let focusErr = AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard focusErr == .success else { throw SmokeError.setFailed("focus input", focusErr) }

    try replaceValue(marker, on: input, op: "write marker", targetPID: cursor.processIdentifier)
    let readback = copyString(input, kAXValueAttribute) ?? ""

    guard readback == marker else { throw SmokeError.readbackMismatch }

    var submitAccepted = false
    if submitPrompt {
        pressKey(CGKeyCode(kVK_Return), targetPID: cursor.processIdentifier)
        submitAccepted = waitUntilInputNoLongerContains(marker, on: input, timeout: submitWaitSeconds)
        if !submitAccepted {
            try replaceValue(previousValue, on: input, op: "restore previous value", targetPID: cursor.processIdentifier)
            throw SmokeError.submitFailed
        }
    } else {
        try replaceValue(previousValue, on: input, op: "restore previous value", targetPID: cursor.processIdentifier)
    }

    print("Glasstunnel Cursor live AX input smoke")
    print("Date: \(ISO8601DateFormatter().string(from: Date()))")
    print("Cursor bundle id: \(bundleID)")
    print("Cursor pid: \(cursor.processIdentifier)")
    print("Match mode: \(matchMode)")
    print("Matched input: \(matchedInputDescriptor)")
    print("Submitted prompt: \(submitPrompt ? "yes" : "no")")
    print("Submit accepted: \(submitPrompt ? (submitAccepted ? "yes" : "no") : "not requested")")
    print("Placeholder value treated as empty: \(previousWasPlaceholder ? "yes" : "no")")
    print("Existing draft overwritten: \(previousValue.isEmpty ? "no" : "restored")")
    if submitPrompt {
        print("Result: passed; real Cursor chat input accepted and returned the AX marker, then Return cleared the composer.")
    } else {
        print("Result: passed; real Cursor chat input accepted and returned the AX marker, then previous value was restored.")
    }
} catch {
    print("Glasstunnel Cursor live AX input smoke")
    print("Date: \(ISO8601DateFormatter().string(from: Date()))")
    print("Cursor bundle id: \(bundleID)")
    print("Submitted prompt: no")
    print("Result: blocked; \(error)")
    exit(1)
}
SWIFT

swift "$swift_file"
