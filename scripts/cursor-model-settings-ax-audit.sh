#!/usr/bin/env bash
# Privacy-safe Cursor model/settings Accessibility audit.
#
# Activates Cursor, scans the focused window through macOS Accessibility, and
# reports only model/settings-shaped candidate counts plus explicitly safe short
# values. It never prints Cursor prompts, responses, database paths, or raw AX
# text dumps.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${GT_CURSOR_MODEL_AX_OUT_DIR:-/tmp/glasstunnel-cursor-model-settings-ax-audit}"
mkdir -p "$OUT_DIR"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Result: blocked; Cursor model/settings AX audit requires macOS." >&2
  exit 1
fi

probe_file="$(mktemp -t glasstunnel-cursor-model-settings-ax.XXXXXX.swift)"
trap 'rm -f "$probe_file"' EXIT

cat >"$probe_file" <<'SWIFT'
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let bundleID = "com.todesktop.230313mzl4w4u92"
let outPath = ProcessInfo.processInfo.environment["GT_CURSOR_MODEL_AX_ARTIFACT"] ?? ""

struct Candidate: Encodable, Hashable {
    let value: String
    let attribute: String
    let role: String?
}

struct AuditResult: Encodable {
    let axTrusted: Bool
    let appRunning: Bool
    let activated: Bool
    let activationMethod: String?
    let windowAvailable: Bool
    let scannedNodeCount: Int
    let stringNodeCount: Int
    let safeCandidateCount: Int
    let safeCandidates: [Candidate]
    let composerCandidateCount: Int
    let modelKeywordCandidateCount: Int
    let result: String
    let followUp: String
}

func emit(_ result: AuditResult) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try! encoder.encode(result)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    if !outPath.isEmpty {
        try? data.write(to: URL(fileURLWithPath: outPath))
    }
}

@discardableResult
func activateCursor() -> (Bool, String?) {
    if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
        running.activate(options: [.activateAllWindows])
        return (true, "NSRunningApplication.activate")
    }

    let url = URL(fileURLWithPath: "/Applications/Cursor.app")
    if FileManager.default.fileExists(atPath: url.path) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        return (true, "NSWorkspace.openApplication")
    }
    return (false, nil)
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
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else {
        return nil
    }
    return windows.first
}

func compact(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func allowedVisibleString(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 80 else { return false }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._/-")
    return value.unicodeScalars.allSatisfy { allowed.contains($0) }
}

func safeCandidate(from raw: String) -> String? {
    let value = compact(raw)
    guard allowedVisibleString(value) else { return nil }

    if value.range(of: "composer", options: .caseInsensitive) != nil {
        return value
    }

    let lower = value.lowercased()
    let keywords = [
        "claude", "sonnet", "opus", "haiku", "gpt", "o3", "o4",
        "gemini", "cursor", "auto", "fast", "slow", "thinking"
    ]
    guard keywords.contains(where: { lower.contains($0) }) else { return nil }
    guard value.split(separator: " ").count <= 5 else { return nil }

    let rejectedFragments = [
        "reply", "prompt", "message", "http", "www", "gt_cursor",
        "cursor hosted", "cursor chat", "cursor submit", "glasstunnel-cursor",
        "about cursor", "open cursor", "hide cursor", "quit cursor",
        "force quit cursor", "cursor agents", "autofill"
    ]
    guard !rejectedFragments.contains(where: { lower.contains($0) }) else { return nil }

    return value
}

let trusted = AXIsProcessTrusted()
guard trusted else {
    emit(AuditResult(axTrusted: false, appRunning: false, activated: false, activationMethod: nil, windowAvailable: false, scannedNodeCount: 0, stringNodeCount: 0, safeCandidateCount: 0, safeCandidates: [], composerCandidateCount: 0, modelKeywordCandidateCount: 0, result: "blocked", followUp: "Grant Accessibility to the runner before auditing Cursor."))
    exit(0)
}

let activation = activateCursor()
Thread.sleep(forTimeInterval: 1.0)

guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    emit(AuditResult(axTrusted: true, appRunning: false, activated: activation.0, activationMethod: activation.1, windowAvailable: false, scannedNodeCount: 0, stringNodeCount: 0, safeCandidateCount: 0, safeCandidates: [], composerCandidateCount: 0, modelKeywordCandidateCount: 0, result: "blocked", followUp: "Cursor is not running or could not be launched."))
    exit(0)
}

let app = AXUIElementCreateApplication(running.processIdentifier)
guard let root = focusedWindow(of: app) ?? firstWindow(of: app) else {
    emit(AuditResult(axTrusted: true, appRunning: true, activated: activation.0, activationMethod: activation.1, windowAvailable: false, scannedNodeCount: 0, stringNodeCount: 0, safeCandidateCount: 0, safeCandidates: [], composerCandidateCount: 0, modelKeywordCandidateCount: 0, result: "blocked", followUp: "Cursor is running but no Accessibility window is available."))
    exit(0)
}

let attributes = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute]
var queue: [AXUIElement] = [root]
var scanned = 0
var stringNodes = 0
var candidates = Set<Candidate>()

while !queue.isEmpty && scanned < 12_000 {
    scanned += 1
    let element = queue.removeFirst()
    let role = copyString(element, kAXRoleAttribute)

    for attribute in attributes {
        guard let raw = copyString(element, attribute), !raw.isEmpty else { continue }
        stringNodes += 1
        if let role, role == "AXApplication" || role.hasPrefix("AXMenu") || role == "AXWindow" {
            continue
        }
        if let value = safeCandidate(from: raw) {
            candidates.insert(Candidate(value: value, attribute: attribute, role: role))
        }
    }

    queue.append(contentsOf: children(of: element))
}

let sorted = candidates.sorted {
    if $0.value == $1.value {
        return $0.attribute < $1.attribute
    }
    return $0.value < $1.value
}
let composerCount = sorted.filter { $0.value.range(of: "composer", options: .caseInsensitive) != nil }.count
let modelKeywordCount = sorted.count - composerCount
let result = sorted.isEmpty ? "partial" : "passed"
let followUp = sorted.isEmpty
    ? "No safe pre-submit model/settings candidate was exposed through Cursor Accessibility."
    : "Review candidates and, if stable, reuse the matching extractor in hosted prompt preflight."

emit(AuditResult(
    axTrusted: true,
    appRunning: true,
    activated: activation.0,
    activationMethod: activation.1,
    windowAvailable: true,
    scannedNodeCount: scanned,
    stringNodeCount: stringNodes,
    safeCandidateCount: sorted.count,
    safeCandidates: Array(sorted.prefix(20)),
    composerCandidateCount: composerCount,
    modelKeywordCandidateCount: modelKeywordCount,
    result: result,
    followUp: followUp
))
SWIFT

timestamp="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
artifact="$OUT_DIR/cursor-model-settings-ax-$timestamp.json"
GT_CURSOR_MODEL_AX_ARTIFACT="$artifact" /usr/bin/swift "$probe_file"
echo "Artifact: $artifact"
