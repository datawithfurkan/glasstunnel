#!/usr/bin/env bash
# Privacy-safe live Cursor deeplink prefill smoke.
#
# This verifies whether Cursor's prompt deeplink can prefill the visible Cursor
# composer without submitting a prompt. It does not press Return and should not
# call a Cursor model. The temporary marker is cleared/restored after readback.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${GT_CURSOR_DEEPLINK_PREFILL_OUT_DIR:-/tmp/glasstunnel-cursor-deeplink-prefill}"
mkdir -p "$OUT_DIR"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Result: blocked; Cursor deeplink prefill smoke requires macOS." >&2
  exit 1
fi

probe_file="$(mktemp -t glasstunnel-cursor-deeplink-prefill.XXXXXX.swift)"
trap 'rm -f "$probe_file"' EXIT

cat >"$probe_file" <<'SWIFT'
import AppKit
import ApplicationServices
import Foundation

let bundleID = "com.todesktop.230313mzl4w4u92"
let cursorCLI = "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
let marker = ProcessInfo.processInfo.environment["GT_CURSOR_DEEPLINK_PREFILL_MARKER"]
    ?? "GT_CURSOR_DEEPLINK_PREFILL_\(Int(Date().timeIntervalSince1970))"
let outPath = ProcessInfo.processInfo.environment["GT_CURSOR_DEEPLINK_PREFILL_ARTIFACT"] ?? ""
let openStandaloneChat = ProcessInfo.processInfo.environment["GT_CURSOR_DEEPLINK_PREFILL_OPEN_CHAT"] != "0"
let allowNonEmpty = ProcessInfo.processInfo.environment["GT_CURSOR_DEEPLINK_PREFILL_ALLOW_NONEMPTY"] == "1"

struct SmokeResult: Encodable {
    let axTrusted: Bool
    let appInstalled: Bool
    let appRunningBefore: Bool
    let standaloneChatRequested: Bool
    let standaloneChatExitCode: Int32?
    let windowCountBefore: Int
    let windowAvailableBefore: Bool
    let inputAvailableBefore: Bool
    let inputCandidateCountBefore: Int
    let inputWasEmptyOrPlaceholder: Bool
    let refusedExistingDraft: Bool
    let deeplinkURLHost: String
    let deeplinkOpenRequested: Bool
    let markerPrefilled: Bool
    let inputRestored: Bool
    let windowCountAfter: Int
    let windowAvailableAfter: Bool
    let inputAvailableAfter: Bool
    let inputCandidateCountAfter: Int
    let result: String
    let followUp: String
}

func emit(_ result: SmokeResult) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try! encoder.encode(result)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    if !outPath.isEmpty {
        try? data.write(to: URL(fileURLWithPath: outPath))
    }
}

func runningCursor() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
}

@discardableResult
func run(_ executable: String, _ arguments: [String]) -> Int32? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        return nil
    }
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

func focusedWindow(of app: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
       let cf = value, CFGetTypeID(cf) == AXUIElementGetTypeID() {
        return (cf as! AXUIElement)
    }
    return nil
}

func firstWindow(of app: AXUIElement) -> AXUIElement? {
    windows(of: app).first
}

func windows(of app: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else {
        return []
    }
    return windows
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

func descriptor(_ element: AXUIElement) -> String {
    [
        copyString(element, kAXTitleAttribute),
        copyString(element, kAXDescriptionAttribute),
        copyString(element, kAXPlaceholderValueAttribute),
    ]
    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }
    .joined(separator: " ")
}

func isPlaceholderValue(_ value: String, for element: AXUIElement) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    let placeholder = (copyString(element, kAXPlaceholderValueAttribute) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if !placeholder.isEmpty && trimmed == placeholder {
        return true
    }
    return [
        "Plan, Build, / for skills, @ for context",
        "Send follow-up",
    ].contains(trimmed)
}

func visibleWindowAndInput() -> (windowCount: Int, windowAvailable: Bool, input: AXUIElement?, inputCandidateCount: Int) {
    guard let running = runningCursor() else {
        return (0, false, nil, 0)
    }
    running.activate(options: [.activateAllWindows])
    Thread.sleep(forTimeInterval: 0.5)
    let app = AXUIElementCreateApplication(running.processIdentifier)
    let allWindows = windows(of: app)
    guard let root = focusedWindow(of: app) ?? allWindows.first else {
        return (allWindows.count, false, nil, 0)
    }

    var queue: [AXUIElement] = [root]
    var candidates: [AXUIElement] = []
    var textInputCount = 0
    var visited = 0
    while !queue.isEmpty && visited < 6000 {
        visited += 1
        let element = queue.removeFirst()
        if isSettableTextInput(element) {
            textInputCount += 1
            let searchable = descriptor(element).lowercased()
            if searchable.contains("chat") || searchable.contains("plan") || searchable.contains("follow-up") {
                return (allWindows.count, true, element, textInputCount)
            }
            candidates.append(element)
        }
        queue.append(contentsOf: children(of: element))
    }

    if candidates.count == 1 {
        return (allWindows.count, true, candidates[0], textInputCount)
    }
    return (allWindows.count, true, nil, textInputCount)
}

func waitForInput(containing marker: String, timeout: TimeInterval) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let state = visibleWindowAndInput()
        let input = state.input
        if let input, (copyString(input, kAXValueAttribute) ?? "").contains(marker) {
            return input
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    let state = visibleWindowAndInput()
    let input = state.input
    if let input, (copyString(input, kAXValueAttribute) ?? "").contains(marker) {
        return input
    }
    return nil
}

func setValue(_ value: String, on input: AXUIElement) -> Bool {
    AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, value as CFString) == .success
}

func emptyOrPlaceholder(_ input: AXUIElement) -> Bool {
    let value = copyString(input, kAXValueAttribute) ?? ""
    return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPlaceholderValue(value, for: input)
}

let appInstalled = FileManager.default.fileExists(atPath: "/Applications/Cursor.app")
let appRunningBefore = runningCursor() != nil
guard AXIsProcessTrusted() else {
    emit(SmokeResult(axTrusted: false, appInstalled: appInstalled, appRunningBefore: appRunningBefore, standaloneChatRequested: false, standaloneChatExitCode: nil, windowCountBefore: 0, windowAvailableBefore: false, inputAvailableBefore: false, inputCandidateCountBefore: 0, inputWasEmptyOrPlaceholder: false, refusedExistingDraft: false, deeplinkURLHost: "anysphere.cursor-deeplink", deeplinkOpenRequested: false, markerPrefilled: false, inputRestored: false, windowCountAfter: 0, windowAvailableAfter: false, inputAvailableAfter: false, inputCandidateCountAfter: 0, result: "blocked", followUp: "Grant Accessibility to the runner before auditing Cursor deeplink prefill."))
    exit(0)
}

var standaloneExit: Int32?
if openStandaloneChat && FileManager.default.isExecutableFile(atPath: cursorCLI) {
    standaloneExit = run(cursorCLI, ["--chat"])
    Thread.sleep(forTimeInterval: 2.5)
} else if !appRunningBefore {
    _ = run("/usr/bin/open", ["-b", bundleID])
    Thread.sleep(forTimeInterval: 2.5)
}

let before = visibleWindowAndInput()
let windowBefore = before.windowAvailable
let inputBefore = before.input
let inputAvailableBefore = inputBefore != nil
let inputWasEmpty = inputBefore.map(emptyOrPlaceholder) ?? false

if inputBefore != nil && !inputWasEmpty && !allowNonEmpty {
    emit(SmokeResult(axTrusted: true, appInstalled: appInstalled, appRunningBefore: appRunningBefore, standaloneChatRequested: openStandaloneChat, standaloneChatExitCode: standaloneExit, windowCountBefore: before.windowCount, windowAvailableBefore: windowBefore, inputAvailableBefore: inputAvailableBefore, inputCandidateCountBefore: before.inputCandidateCount, inputWasEmptyOrPlaceholder: inputWasEmpty, refusedExistingDraft: true, deeplinkURLHost: "anysphere.cursor-deeplink", deeplinkOpenRequested: false, markerPrefilled: false, inputRestored: false, windowCountAfter: before.windowCount, windowAvailableAfter: windowBefore, inputAvailableAfter: inputAvailableBefore, inputCandidateCountAfter: before.inputCandidateCount, result: "blocked", followUp: "Cursor composer already contains non-placeholder text; refusing to overwrite without GT_CURSOR_DEEPLINK_PREFILL_ALLOW_NONEMPTY=1."))
    exit(0)
}

let previousValue = inputBefore.flatMap { copyString($0, kAXValueAttribute) } ?? ""
var components = URLComponents()
components.scheme = "cursor"
components.host = "anysphere.cursor-deeplink"
components.path = "/prompt"
components.queryItems = [URLQueryItem(name: "text", value: marker)]
let deeplinkURL = components.url!
NSWorkspace.shared.open(deeplinkURL)

let matchedInput = waitForInput(containing: marker, timeout: 8)
let markerPrefilled = matchedInput != nil
var restored = false
if let matchedInput {
    restored = setValue(inputWasEmpty ? "" : previousValue, on: matchedInput)
    Thread.sleep(forTimeInterval: 0.25)
    let restoredValue = copyString(matchedInput, kAXValueAttribute) ?? ""
    if inputWasEmpty {
        restored = restored && !restoredValue.contains(marker)
    } else {
        restored = restored && restoredValue == previousValue
    }
}

let after = visibleWindowAndInput()
let windowAfter = after.windowAvailable
let inputAfter = after.input
let result: String
let followUp: String
if markerPrefilled && restored {
    result = "passed"
    followUp = "Cursor prompt deeplink prefilled the composer without submit; the marker was cleared/restored."
} else if markerPrefilled {
    result = "partial"
    followUp = "Cursor prompt deeplink prefilled the composer, but cleanup did not verify."
} else {
    result = "failed"
    followUp = "Cursor prompt deeplink did not produce a visible AX composer value containing the marker."
}

emit(SmokeResult(axTrusted: true, appInstalled: appInstalled, appRunningBefore: appRunningBefore, standaloneChatRequested: openStandaloneChat, standaloneChatExitCode: standaloneExit, windowCountBefore: before.windowCount, windowAvailableBefore: windowBefore, inputAvailableBefore: inputAvailableBefore, inputCandidateCountBefore: before.inputCandidateCount, inputWasEmptyOrPlaceholder: inputWasEmpty, refusedExistingDraft: false, deeplinkURLHost: "anysphere.cursor-deeplink", deeplinkOpenRequested: true, markerPrefilled: markerPrefilled, inputRestored: restored, windowCountAfter: after.windowCount, windowAvailableAfter: windowAfter, inputAvailableAfter: inputAfter != nil, inputCandidateCountAfter: after.inputCandidateCount, result: result, followUp: followUp))
SWIFT

timestamp="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
artifact="$OUT_DIR/cursor-deeplink-prefill-$timestamp.json"
GT_CURSOR_DEEPLINK_PREFILL_ARTIFACT="$artifact" /usr/bin/swift "$probe_file"
echo "Artifact: $artifact"
