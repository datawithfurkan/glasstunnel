import Foundation
import GTAdapters
import GTProtocol

let timeoutSeconds = Double(ProcessInfo.processInfo.environment["GT_CURSOR_STATE_SNAPSHOT_TIMEOUT_SECONDS"] ?? "3") ?? 3
let requireLabelTruth = ["1", "true", "yes"].contains(
    ProcessInfo.processInfo.environment["GT_CURSOR_STATE_REQUIRE_LABEL_TRUTH", default: ""].lowercased()
)
let watcher = CursorStateWatcher()
let semaphore = DispatchSemaphore(value: 0)

final class SnapshotBox: @unchecked Sendable {
    var snapshot: CursorStateWatcher.Snapshot?
}

let box = SnapshotBox()
watcher.onChange = { snapshot in
    box.snapshot = snapshot
    semaphore.signal()
}

do {
    try watcher.start()
} catch {
    print("Glasstunnel Cursor live state snapshot")
    print("Result: failed; Cursor watcher could not start.")
    print("Error type: \(type(of: error))")
    exit(1)
}

let waitResult = semaphore.wait(timeout: .now() + timeoutSeconds)
watcher.stop()

guard waitResult == .success, let snapshot = box.snapshot else {
    print("Glasstunnel Cursor live state snapshot")
    print("Result: failed; Cursor watcher did not publish a snapshot before timeout.")
    exit(1)
}

let userMessages = snapshot.recentMessages.filter { $0.role == .user }.count
let assistantMessages = snapshot.recentMessages.filter { $0.role == .assistant }.count
let systemMessages = snapshot.recentMessages.filter { $0.role == .system }.count
let toolMessages = snapshot.recentMessages.filter { $0.role == .tool }.count
let targetsWithLabels = snapshot.availableTargets.filter {
    !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}.count
let targetsWithSubtitles = snapshot.availableTargets.filter {
    !$0.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}.count
let targetsWithProjectLikeSubtitles = snapshot.availableTargets.filter {
    let subtitle = $0.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
    return subtitle.hasPrefix("/") || subtitle.hasPrefix("~")
}.count
let targetsWithProjectPaths = snapshot.availableTargets.filter {
    $0.projectPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
}.count
let genericLabelTargets = snapshot.availableTargets.filter {
    isGenericCursorTargetLabel($0.label)
}.count
let generatedFallbackLabelTargets = snapshot.availableTargets.filter {
    $0.labelSource == .generatedFallback
}.count
let cursorNameLabelTargets = snapshot.availableTargets.filter {
    $0.labelSource == .cursorName
}.count
let cursorSubtitleLabelTargets = snapshot.availableTargets.filter {
    $0.labelSource == .cursorSubtitle
}.count
let fallbackSubtitleTargets = snapshot.availableTargets.filter {
    isFallbackCursorTargetSubtitle($0.subtitle)
}.count
let targetsWithTimestamps = snapshot.availableTargets.filter {
    $0.lastUpdatedAtUnixMs > 0
}.count
let normalizedLabels = snapshot.availableTargets
    .map { normalizedTargetText($0.label) }
    .filter { !$0.isEmpty }
let labelCounts = Dictionary(grouping: normalizedLabels, by: { $0 }).mapValues(\.count)
let duplicateLabelGroups = labelCounts.values.filter { $0 > 1 }.count
let duplicateLabelTargets = labelCounts.values.filter { $0 > 1 }.reduce(0, +)
let selectedTargets = snapshot.availableTargets.filter(\.selected).count
let selectedTargetHasNonGenericLabel = snapshot.availableTargets.first(where: \.selected).map {
    !isGenericCursorTargetLabel($0.label)
} ?? false
let selectedTargetLabelSource = snapshot.availableTargets.first(where: \.selected)?.labelSource.rawValue ?? "none"
let uniqueMessageIds = Set(snapshot.recentMessages.map(\.messageId)).count
let messagesWithTimestamps = snapshot.recentMessages.filter { $0.atUnixMs > 0 }.count
let warning = snapshot.schemaWarning?.trimmingCharacters(in: .whitespacesAndNewlines)
let selectedTargetMessagesReadable = snapshot.selectedTargetId != nil && !snapshot.recentMessages.isEmpty
let selectedTargetHasConversationRoles = userMessages > 0 && assistantMessages > 0
let selectedTargetMessageIdsUnique = !snapshot.recentMessages.isEmpty && uniqueMessageIds == snapshot.recentMessages.count
let selectedTargetMessagesTimestamped = !snapshot.recentMessages.isEmpty && messagesWithTimestamps == snapshot.recentMessages.count
let selectedTargetHistoryReady = selectedTargetMessagesReadable &&
    selectedTargetHasConversationRoles &&
    selectedTargetMessageIdsUnique &&
    selectedTargetMessagesTimestamped
let labelSourceCoverageComplete = cursorNameLabelTargets + cursorSubtitleLabelTargets + generatedFallbackLabelTargets == snapshot.availableTargets.count
let unclassifiedGenericLabelTargets = max(0, genericLabelTargets - generatedFallbackLabelTargets)
let cursorDerivedLabelTargets = cursorNameLabelTargets + cursorSubtitleLabelTargets
let exactCursorNameLabelParityProven = !snapshot.availableTargets.isEmpty &&
    cursorNameLabelTargets == snapshot.availableTargets.count &&
    duplicateLabelGroups == 0
let fullProjectPathParityProven = !snapshot.availableTargets.isEmpty &&
    targetsWithProjectPaths == snapshot.availableTargets.count
let partialLabelTruthReady = !snapshot.availableTargets.isEmpty &&
    targetsWithLabels == snapshot.availableTargets.count &&
    targetsWithTimestamps == snapshot.availableTargets.count &&
    labelSourceCoverageComplete &&
    duplicateLabelGroups == 0

print("Glasstunnel Cursor live state snapshot")
print("Date: \(ISO8601DateFormatter().string(from: Date()))")
print("Target count: \(snapshot.availableTargets.count)")
print("Targets with labels: \(targetsWithLabels)")
print("Targets with subtitles: \(targetsWithSubtitles)")
print("Targets with project-like subtitles: \(targetsWithProjectLikeSubtitles)")
print("Targets with project paths: \(targetsWithProjectPaths)")
print("Targets with non-generic labels: \(snapshot.availableTargets.count - genericLabelTargets)")
print("Targets with generic labels: \(genericLabelTargets)")
print("Targets with Cursor-name labels: \(cursorNameLabelTargets)")
print("Targets with Cursor-subtitle labels: \(cursorSubtitleLabelTargets)")
print("Targets with generated fallback labels: \(generatedFallbackLabelTargets)")
print("Targets with Cursor-derived labels: \(cursorDerivedLabelTargets)")
print("Targets with fallback subtitles: \(fallbackSubtitleTargets)")
print("Targets with timestamps: \(targetsWithTimestamps)")
print("Label source coverage complete: \(labelSourceCoverageComplete ? "yes" : "no")")
print("Unique label count: \(labelCounts.count)")
print("Duplicate label groups: \(duplicateLabelGroups)")
print("Duplicate-labeled targets: \(duplicateLabelTargets)")
print("Unclassified generic label targets: \(unclassifiedGenericLabelTargets)")
print("Exact Cursor-name label parity proven: \(exactCursorNameLabelParityProven ? "yes" : "no")")
print("Full project-path parity proven: \(fullProjectPathParityProven ? "yes" : "no")")
print("Partial label truth ready: \(partialLabelTruthReady ? "yes" : "no")")
print("Selected targets: \(selectedTargets)")
print("Selected title present: \(snapshot.selectedTitle?.isEmpty == false ? "yes" : "no")")
print("Selected target has non-generic label: \(selectedTargetHasNonGenericLabel ? "yes" : "no")")
print("Selected target label source: \(selectedTargetLabelSource)")
print("Selected target messages readable: \(selectedTargetMessagesReadable ? "yes" : "no")")
print("Selected target has user and assistant messages: \(selectedTargetHasConversationRoles ? "yes" : "no")")
print("Selected target message ids unique: \(selectedTargetMessageIdsUnique ? "yes" : "no")")
print("Selected target messages timestamped: \(selectedTargetMessagesTimestamped ? "yes" : "no")")
print("Message count: \(snapshot.recentMessages.count)")
print("Unique message ids: \(uniqueMessageIds)")
print("Messages with timestamps: \(messagesWithTimestamps)")
print("User messages: \(userMessages)")
print("Assistant messages: \(assistantMessages)")
print("System messages: \(systemMessages)")
print("Tool messages: \(toolMessages)")
print("Schema warning present: \(warning?.isEmpty == false ? "yes" : "no")")

if requireLabelTruth {
    if partialLabelTruthReady {
        print("Result: passed; Cursor labels are uniquely classified, and fallback labels remain explicit instead of being overclaimed as exact Cursor names.")
    } else {
        print("Result: partial; Cursor label truth was not proven by the live-state diagnostic.")
        exit(1)
    }
} else if !snapshot.availableTargets.isEmpty && selectedTargetHistoryReady {
    print("Result: passed; Cursor watcher produced privacy-safe target metadata and selected-target user/assistant history counts.")
} else if !snapshot.availableTargets.isEmpty {
    print("Result: partial; Cursor watcher produced targets but selected-target history is not fully backed by parseable user/assistant messages.")
} else {
    print("Result: blocked; Cursor watcher produced no targets.")
}

func normalizedTargetText(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .lowercased()
}

func isGenericCursorTargetLabel(_ label: String) -> Bool {
    let value = normalizedTargetText(label)
    if value.isEmpty {
        return true
    }

    let exactGenericLabels: Set<String> = [
        "cursor",
        "cursor composer",
        "composer",
        "new chat",
        "untitled",
        "untitled composer"
    ]
    if exactGenericLabels.contains(value) {
        return true
    }
    if isGeneratedCursorFallbackLabel(value) {
        return true
    }

    let numberedFallbackPatterns = [
        #"^composer [0-9]+$"#,
        #"^cursor composer [0-9]+$"#,
        #"^untitled [0-9]+$"#
    ]
    return numberedFallbackPatterns.contains { pattern in
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

func isGeneratedCursorFallbackLabel(_ label: String) -> Bool {
    normalizedTargetText(label).range(of: #"^cursor chat [0-9]+$"#, options: .regularExpression) != nil
}

func isFallbackCursorTargetSubtitle(_ subtitle: String) -> Bool {
    let value = normalizedTargetText(subtitle)
    if value.isEmpty {
        return true
    }
    return value == "cursor" || value == "workspace composer"
}
