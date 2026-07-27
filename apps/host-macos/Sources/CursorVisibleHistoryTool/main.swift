import AppKit
import ApplicationServices
import Foundation
import GTAdapters
import GTProtocol

let cursorBundleID = "com.todesktop.230313mzl4w4u92"
let timeoutSeconds = Double(ProcessInfo.processInfo.environment["GT_CURSOR_VISIBLE_HISTORY_TIMEOUT_SECONDS"] ?? "3") ?? 3
let targetLimit = Int(ProcessInfo.processInfo.environment["GT_CURSOR_VISIBLE_HISTORY_TARGET_LIMIT"] ?? "10") ?? 10
let messageLimit = Int(ProcessInfo.processInfo.environment["GT_CURSOR_VISIBLE_HISTORY_MESSAGE_LIMIT"] ?? "8") ?? 8
let minimumMessageLength = Int(ProcessInfo.processInfo.environment["GT_CURSOR_VISIBLE_HISTORY_MIN_MESSAGE_LENGTH"] ?? "16") ?? 16
let minimumMatches = Int(ProcessInfo.processInfo.environment["GT_CURSOR_VISIBLE_HISTORY_MIN_MATCHES"] ?? "2") ?? 2
let minimumTokenCoverage = Double(ProcessInfo.processInfo.environment["GT_CURSOR_VISIBLE_HISTORY_MIN_TOKEN_COVERAGE"] ?? "0.80") ?? 0.80
let artifactPath = ProcessInfo.processInfo.environment["GT_CURSOR_VISIBLE_HISTORY_ARTIFACT"]?
    .trimmingCharacters(in: .whitespacesAndNewlines)
let requireNonCurrentTruth = ["1", "true", "yes"].contains(
    ProcessInfo.processInfo.environment["GT_CURSOR_VISIBLE_HISTORY_REQUIRE_NON_CURRENT_TRUTH", default: ""].lowercased()
)

let watcher = CursorStateWatcher()
let semaphore = DispatchSemaphore(value: 0)

final class SnapshotBox: @unchecked Sendable {
    var snapshot: CursorStateWatcher.Snapshot?
}

struct TargetVisibilityResult {
    let targetId: String
    let candidateMessages: Int
    let candidateUserMessages: Int
    let candidateAssistantMessages: Int
    let matchedMessages: Int
    let matchedUserMessages: Int
    let matchedAssistantMessages: Int
    let strongTokenCoverageMessages: Int
    let bestTokenCoveragePercent: Int
    let visibleTextHash: Int
    let visibleTextNodeCount: Int
    let matchedRoles: Set<ChatRole>
    let visibleHistoryReady: Bool
}

struct WindowTextSnapshot {
    let text: String
    let nodeCount: Int
    let fingerprint: Int
}

struct VisibleHistoryArtifact: Encodable {
    let generatedAt: String
    let result: String
    let detail: String
    let requireNonCurrentTruth: Bool
    let thresholds: VisibleHistoryThresholds
    let selectedTargetPresent: Bool
    let targetsChecked: Int
    let targetsWithVisibleHistory: Int
    let nonCurrentTargetsChecked: Int
    let nonCurrentTargetsWithVisibleHistory: Int
    let selectedTargetVisibleHistoryReady: Bool
    let bestMatchIsSelectedTarget: Bool
    let bestCandidateMessagesChecked: Int
    let bestCandidateUserMessages: Int
    let bestCandidateAssistantMessages: Int
    let bestStrongTokenCoverageMessages: Int
    let bestTokenCoveragePercent: Int
    let accessibilityTrusted: Bool
    let cursorRunning: Bool
    let cursorWindowAvailable: Bool
    let visibleTextNodesScanned: Int
    let uniqueVisibleTextSnapshots: Int
    let visibleTextChangedAfterTargetSelection: Bool
    let visibleTextChangedAfterNonCurrentTargetSelection: Bool
    let nonCurrentTargetControlProven: Bool
    let nonCurrentTargetRemainsBrowseOnly: Bool
    let bestVisibleMessagesMatched: Int
    let bestVisibleUserMessagesMatched: Int
    let bestVisibleAssistantMessagesMatched: Int
    let targetResults: [VisibleHistoryTargetArtifact]
    let privacy: String
}

struct VisibleHistoryThresholds: Encodable {
    let targetLimit: Int
    let messageLimit: Int
    let minimumMessageLength: Int
    let minimumMatches: Int
    let minimumTokenCoverage: Double
}

struct VisibleHistoryTargetArtifact: Encodable {
    let index: Int
    let isInitialSelectedTarget: Bool
    let candidateMessages: Int
    let candidateUserMessages: Int
    let candidateAssistantMessages: Int
    let matchedMessages: Int
    let matchedUserMessages: Int
    let matchedAssistantMessages: Int
    let strongTokenCoverageMessages: Int
    let bestTokenCoveragePercent: Int
    let visibleTextNodeCount: Int
    let visibleTextChangedFromInitialSnapshot: Bool
    let visibleHistoryReady: Bool
}

let box = SnapshotBox()
watcher.onChange = { snapshot in
    box.snapshot = snapshot
    semaphore.signal()
}

func emitHeader() {
    print("Glasstunnel Cursor visible history smoke")
    print("Date: \(ISO8601DateFormatter().string(from: Date()))")
}

do {
    try watcher.start()
} catch {
    emitHeader()
    print("Result: failed; Cursor watcher could not start.")
    print("Error type: \(type(of: error))")
    exit(1)
}

let waitResult = semaphore.wait(timeout: .now() + timeoutSeconds)

guard waitResult == .success, let snapshot = box.snapshot else {
    watcher.stop()
    emitHeader()
    print("Result: failed; Cursor watcher did not publish a snapshot before timeout.")
    exit(1)
}

let selectedTargetPresent = snapshot.selectedTargetId != nil
let initialSelectedTargetID = snapshot.selectedTargetId
let targetIDs = Array(snapshot.availableTargets.prefix(max(0, targetLimit)).map(\.targetId))

guard AXIsProcessTrusted() else {
    watcher.stop()
    emitHeader()
    print("Selected target present: \(selectedTargetPresent ? "yes" : "no")")
    print("Targets checked: \(targetIDs.count)")
    print("Accessibility trusted: no")
    print("Result: blocked; Accessibility is not trusted for visible Cursor history inspection.")
    exit(1)
}

let runningCursor = NSRunningApplication.runningApplications(withBundleIdentifier: cursorBundleID).first
guard let runningCursor else {
    watcher.stop()
    emitHeader()
    print("Selected target present: \(selectedTargetPresent ? "yes" : "no")")
    print("Targets checked: \(targetIDs.count)")
    print("Accessibility trusted: yes")
    print("Cursor running: no")
    print("Result: blocked; Cursor is not running.")
    exit(1)
}

runningCursor.activate(options: [.activateIgnoringOtherApps])
Thread.sleep(forTimeInterval: 0.5)

let appElement = AXUIElementCreateApplication(runningCursor.processIdentifier)
guard let window = focusedWindow(of: appElement) ?? firstWindow(of: appElement) else {
    watcher.stop()
    emitHeader()
    print("Selected target present: \(selectedTargetPresent ? "yes" : "no")")
    print("Targets checked: \(targetIDs.count)")
    print("Accessibility trusted: yes")
    print("Cursor running: yes")
    print("Cursor window available: no")
    print("Result: blocked; Cursor has no accessible window.")
    exit(1)
}

let initialWindowText = windowTextSnapshot(from: window)
var targetResults: [TargetVisibilityResult] = []

if targetIDs.isEmpty, let selectedTargetID = snapshot.selectedTargetId {
    targetResults.append(evaluate(snapshot: snapshot, targetId: selectedTargetID, windowText: initialWindowText))
} else {
    for targetID in targetIDs {
        let selectedSnapshot: CursorStateWatcher.Snapshot
        if targetID == initialSelectedTargetID {
            selectedSnapshot = snapshot
        } else if let refreshed = refreshedSnapshot(afterSelecting: targetID) {
            selectedSnapshot = refreshed
        } else {
            continue
        }
        Thread.sleep(forTimeInterval: 0.15)
        let currentWindow = focusedWindow(of: appElement) ?? firstWindow(of: appElement) ?? window
        let currentWindowText = windowTextSnapshot(from: currentWindow)
        targetResults.append(evaluate(snapshot: selectedSnapshot, targetId: targetID, windowText: currentWindowText))
    }
}

watcher.stop()

let best = targetResults.sorted {
    if $0.matchedMessages != $1.matchedMessages { return $0.matchedMessages > $1.matchedMessages }
    if $0.matchedRoles.count != $1.matchedRoles.count { return $0.matchedRoles.count > $1.matchedRoles.count }
    return $0.candidateMessages > $1.candidateMessages
}.first
let selectedTargetResult = targetResults.first { $0.targetId == initialSelectedTargetID }
let nonCurrentResults = targetResults.filter { $0.targetId != initialSelectedTargetID }
let targetsWithVisibleHistory = targetResults.filter(\.visibleHistoryReady).count
let nonCurrentTargetsWithVisibleHistory = nonCurrentResults.filter(\.visibleHistoryReady).count
let visibleHistoryReady = best?.visibleHistoryReady == true
let selectedTargetVisibleHistoryReady = selectedTargetResult?.visibleHistoryReady == true
let uniqueVisibleTextSnapshots = Set(targetResults.map(\.visibleTextHash)).count
let visibleTextChangedAfterSelection = targetResults.contains {
    $0.visibleTextHash != initialWindowText.fingerprint
}
let nonCurrentVisibleTextChangedAfterSelection = nonCurrentResults.contains {
    $0.visibleTextHash != initialWindowText.fingerprint
}
let nonCurrentTargetControlProven = (best?.targetId != nil) &&
    best?.targetId != initialSelectedTargetID &&
    best?.visibleHistoryReady == true &&
    nonCurrentVisibleTextChangedAfterSelection
let nonCurrentTargetRemainsBrowseOnly = !nonCurrentResults.isEmpty &&
    selectedTargetVisibleHistoryReady &&
    best?.targetId == initialSelectedTargetID &&
    nonCurrentTargetsWithVisibleHistory == 0 &&
    !nonCurrentVisibleTextChangedAfterSelection

emitHeader()
print("Selected target present: \(selectedTargetPresent ? "yes" : "no")")
print("Targets checked: \(targetResults.count)")
print("Targets with visible history: \(targetsWithVisibleHistory)")
print("Non-current targets checked: \(nonCurrentResults.count)")
print("Non-current targets with visible history: \(nonCurrentTargetsWithVisibleHistory)")
print("Selected target visible history ready: \(selectedTargetVisibleHistoryReady ? "yes" : "no")")
print("Best match is selected target: \((best?.targetId == initialSelectedTargetID) ? "yes" : "no")")
print("Best candidate messages checked: \(best?.candidateMessages ?? 0)")
print("Best candidate user messages: \(best?.candidateUserMessages ?? 0)")
print("Best candidate assistant messages: \(best?.candidateAssistantMessages ?? 0)")
print("Best strong token coverage messages: \(best?.strongTokenCoverageMessages ?? 0)")
print("Best token coverage percent: \(best?.bestTokenCoveragePercent ?? 0)")
print("Accessibility trusted: yes")
print("Cursor running: yes")
print("Cursor window available: yes")
print("Visible text nodes scanned: \(best?.visibleTextNodeCount ?? initialWindowText.nodeCount)")
print("Unique visible text snapshots: \(uniqueVisibleTextSnapshots)")
print("Visible text changed after target selection: \(visibleTextChangedAfterSelection ? "yes" : "no")")
print("Visible text changed after non-current target selection: \(nonCurrentVisibleTextChangedAfterSelection ? "yes" : "no")")
print("Non-current target control proven: \(nonCurrentTargetControlProven ? "yes" : "no")")
print("Non-current target remains browse-only: \(nonCurrentTargetRemainsBrowseOnly ? "yes" : "no")")
print("Best visible messages matched: \(best?.matchedMessages ?? 0)")
print("Best visible user messages matched: \(best?.matchedUserMessages ?? 0)")
print("Best visible assistant messages matched: \(best?.matchedAssistantMessages ?? 0)")

let result: String
let detail: String
let exitCode: Int

if requireNonCurrentTruth && nonCurrentTargetRemainsBrowseOnly {
    result = "passed"
    detail = "non-current Cursor targets remain browse-only because local selection did not switch the real Cursor window."
    exitCode = 0
} else if requireNonCurrentTruth {
    result = "partial"
    detail = "non-current Cursor target truth was not proven by the visible-window diagnostic."
    exitCode = 1
} else if visibleHistoryReady {
    result = "passed"
    detail = "parsed Cursor history is visible in the real Cursor window without printing message text."
    exitCode = 0
} else {
    result = "partial"
    detail = "Cursor history was parsed but no checked target had enough visible messages in the real Cursor window."
    exitCode = 1
}

writeArtifactIfRequested(result: result, detail: detail)
print("Result: \(result); \(detail)")
if exitCode != 0 {
    exit(Int32(exitCode))
}

func refreshedSnapshot(afterSelecting targetID: String) -> CursorStateWatcher.Snapshot? {
    watcher.selectTarget(targetID)
    let waitResult = semaphore.wait(timeout: .now() + timeoutSeconds)
    guard waitResult == .success,
          let snapshot = box.snapshot,
          snapshot.selectedTargetId == targetID else {
        return nil
    }
    return snapshot
}

func evaluate(
    snapshot: CursorStateWatcher.Snapshot,
    targetId: String,
    windowText: WindowTextSnapshot
) -> TargetVisibilityResult {
    let selectedMessages = Array(snapshot.recentMessages.prefix(max(0, messageLimit)))
    let candidateMessages = selectedMessages.filter {
        normalizedMessageText($0.text).count >= minimumMessageLength
    }
    let visibleText = windowText.text
    let matchedMessages = candidateMessages.filter {
        let normalized = normalizedMessageText($0.text)
        return !normalized.isEmpty && visibleText.contains(normalized)
    }
    let tokenCoverages = candidateMessages.map {
        tokenCoveragePercent(message: $0.text, visibleText: visibleText)
    }
    let strongTokenCoverageMessages = tokenCoverages.filter { $0 >= Int(minimumTokenCoverage * 100) }.count
    let bestTokenCoveragePercent = tokenCoverages.max() ?? 0
    let matchedRoles = Set(matchedMessages.map(\.role))
    let candidateRoles = Set(candidateMessages.map(\.role))
    let ready = !selectedMessages.isEmpty &&
        matchedMessages.count >= min(minimumMatches, max(1, candidateMessages.count)) &&
        (!candidateRoles.contains(.user) || matchedRoles.contains(.user)) &&
        (!candidateRoles.contains(.assistant) || matchedRoles.contains(.assistant))

    return TargetVisibilityResult(
        targetId: targetId,
        candidateMessages: candidateMessages.count,
        candidateUserMessages: candidateMessages.filter { $0.role == .user }.count,
        candidateAssistantMessages: candidateMessages.filter { $0.role == .assistant }.count,
        matchedMessages: matchedMessages.count,
        matchedUserMessages: matchedMessages.filter { $0.role == .user }.count,
        matchedAssistantMessages: matchedMessages.filter { $0.role == .assistant }.count,
        strongTokenCoverageMessages: strongTokenCoverageMessages,
        bestTokenCoveragePercent: bestTokenCoveragePercent,
        visibleTextHash: windowText.fingerprint,
        visibleTextNodeCount: windowText.nodeCount,
        matchedRoles: matchedRoles,
        visibleHistoryReady: ready
    )
}

func normalizedMessageText(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\u{00a0}", with: " ")
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
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

func visibleTextSnapshot(from root: AXUIElement) -> String {
    var values: [String] = []
    walkVisibleText(root, values: &values)
    return values.joined(separator: " ")
}

func visibleTextNodeCount(from root: AXUIElement) -> Int {
    var values: [String] = []
    walkVisibleText(root, values: &values)
    return values.count
}

func windowTextSnapshot(from root: AXUIElement) -> WindowTextSnapshot {
    let values = visibleTextValues(from: root)
    let normalized = normalizedMessageText(values.joined(separator: " "))
    return WindowTextSnapshot(
        text: normalized,
        nodeCount: values.count,
        fingerprint: normalized.hashValue
    )
}

func visibleTextValues(from root: AXUIElement) -> [String] {
    var values: [String] = []
    walkVisibleText(root, values: &values)
    return values
}

func tokenCoveragePercent(message: String, visibleText: String) -> Int {
    let messageTokens = tokenSet(message)
    guard !messageTokens.isEmpty else { return 0 }
    let visibleTokens = tokenSet(visibleText)
    guard !visibleTokens.isEmpty else { return 0 }
    let shared = messageTokens.intersection(visibleTokens).count
    return Int((Double(shared) / Double(messageTokens.count) * 100).rounded())
}

func tokenSet(_ text: String) -> Set<String> {
    let normalized = normalizedMessageText(text).lowercased()
    let rawTokens = normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
    return Set(rawTokens.filter { $0.count >= 4 })
}

func writeArtifactIfRequested(result: String, detail: String) {
    guard let artifactPath, !artifactPath.isEmpty else {
        return
    }

    let artifact = VisibleHistoryArtifact(
        generatedAt: ISO8601DateFormatter().string(from: Date()),
        result: result,
        detail: detail,
        requireNonCurrentTruth: requireNonCurrentTruth,
        thresholds: VisibleHistoryThresholds(
            targetLimit: targetLimit,
            messageLimit: messageLimit,
            minimumMessageLength: minimumMessageLength,
            minimumMatches: minimumMatches,
            minimumTokenCoverage: minimumTokenCoverage
        ),
        selectedTargetPresent: selectedTargetPresent,
        targetsChecked: targetResults.count,
        targetsWithVisibleHistory: targetsWithVisibleHistory,
        nonCurrentTargetsChecked: nonCurrentResults.count,
        nonCurrentTargetsWithVisibleHistory: nonCurrentTargetsWithVisibleHistory,
        selectedTargetVisibleHistoryReady: selectedTargetVisibleHistoryReady,
        bestMatchIsSelectedTarget: best?.targetId == initialSelectedTargetID,
        bestCandidateMessagesChecked: best?.candidateMessages ?? 0,
        bestCandidateUserMessages: best?.candidateUserMessages ?? 0,
        bestCandidateAssistantMessages: best?.candidateAssistantMessages ?? 0,
        bestStrongTokenCoverageMessages: best?.strongTokenCoverageMessages ?? 0,
        bestTokenCoveragePercent: best?.bestTokenCoveragePercent ?? 0,
        accessibilityTrusted: true,
        cursorRunning: true,
        cursorWindowAvailable: true,
        visibleTextNodesScanned: best?.visibleTextNodeCount ?? initialWindowText.nodeCount,
        uniqueVisibleTextSnapshots: uniqueVisibleTextSnapshots,
        visibleTextChangedAfterTargetSelection: visibleTextChangedAfterSelection,
        visibleTextChangedAfterNonCurrentTargetSelection: nonCurrentVisibleTextChangedAfterSelection,
        nonCurrentTargetControlProven: nonCurrentTargetControlProven,
        nonCurrentTargetRemainsBrowseOnly: nonCurrentTargetRemainsBrowseOnly,
        bestVisibleMessagesMatched: best?.matchedMessages ?? 0,
        bestVisibleUserMessagesMatched: best?.matchedUserMessages ?? 0,
        bestVisibleAssistantMessagesMatched: best?.matchedAssistantMessages ?? 0,
        targetResults: targetResults.enumerated().map { index, target in
            VisibleHistoryTargetArtifact(
                index: index,
                isInitialSelectedTarget: target.targetId == initialSelectedTargetID,
                candidateMessages: target.candidateMessages,
                candidateUserMessages: target.candidateUserMessages,
                candidateAssistantMessages: target.candidateAssistantMessages,
                matchedMessages: target.matchedMessages,
                matchedUserMessages: target.matchedUserMessages,
                matchedAssistantMessages: target.matchedAssistantMessages,
                strongTokenCoverageMessages: target.strongTokenCoverageMessages,
                bestTokenCoveragePercent: target.bestTokenCoveragePercent,
                visibleTextNodeCount: target.visibleTextNodeCount,
                visibleTextChangedFromInitialSnapshot: target.visibleTextHash != initialWindowText.fingerprint,
                visibleHistoryReady: target.visibleHistoryReady
            )
        },
        privacy: "No target ids, labels, message text, database paths, raw JSON, or raw Accessibility text are written."
    )

    let artifactURL = URL(fileURLWithPath: artifactPath)
    do {
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(artifact)
        try data.write(to: artifactURL, options: [.atomic])
        print("Artifact: \(artifactPath)")
    } catch {
        print("Artifact write failed: \(type(of: error))")
        exit(1)
    }
}

func walkVisibleText(_ root: AXUIElement, values: inout [String]) {
    var queue: [AXUIElement] = [root]
    var visited = 0
    while !queue.isEmpty && visited < 12_000 {
        visited += 1
        let element = queue.removeFirst()
        for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let value = copyString(element, attribute),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                values.append(value)
            }
        }
        queue.append(contentsOf: children(of: element))
    }
}
