import AppKit
import ApplicationServices
import Foundation

// Reads or switches the permission mode of the Claude desktop session shown in
// the app's front window, through Accessibility. Used by the phone-driven
// desktop lane to make the app show its permission dialog for one step.
//
//   swift claude-desktop-permission-mode.swift --session "<title>" --read
//   swift claude-desktop-permission-mode.swift --session "<title>" --set "<regex>"
//   swift claude-desktop-permission-mode.swift --session "<title>" --dump
//
// --dump lists the pressable controls of the front window (read-only), which
// is how the labels of the app's dialogs and menus were learned. Modes seen
// on build 1.40609.1: Manual (always ask), Accept edits, Auto, Bypass
// permissions, Plan.
//
// It refuses to touch the app unless the front window's "<title>, rename
// session" control names the given session, exactly as ClaudeDesktopAdapter
// does before typing. Exit codes: 0 done, 1 no control found, 2 blocked
// (not trusted, not running, another session in front), 3 no menu item
// matched, 4 the mode did not change after pressing.

let bundleID = "com.anthropic.claudefordesktop"
let renameSuffix = ", rename session"
let modePattern = "(?i)permission|^default$|^manual|accept edits|^plan|^auto|^ask"

var session = ""
var wanted: String?
var readOnly = false
var dump = false
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--session": session = arguments.isEmpty ? "" : arguments.removeFirst()
    case "--set": wanted = arguments.isEmpty ? nil : arguments.removeFirst()
    case "--read": readOnly = true
    case "--dump": dump = true
    default:
        print("fail: unknown argument \(argument)")
        exit(1)
    }
}
guard !session.isEmpty, readOnly || dump || wanted != nil else {
    print("fail: usage: --session <title> (--read | --set <regex> | --dump)")
    exit(1)
}

guard AXIsProcessTrusted() else {
    print("blocked: Accessibility is not trusted for this process")
    exit(2)
}
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    print("blocked: Claude is not running")
    exit(2)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func string(_ element: AXUIElement, _ name: String) -> String {
    (attribute(element, name) as? String) ?? ""
}

func children(of element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func frame(of element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else {
        return nil
    }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    AXValueGetValue(position as! AXValue, .cgPoint, &point)
    AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
    return CGRect(origin: point, size: dimensions)
}

func label(of element: AXUIElement) -> String {
    let title = string(element, kAXTitleAttribute)
    let description = string(element, kAXDescriptionAttribute)
    let value = (attribute(element, kAXValueAttribute) as? String) ?? ""
    return [title, description, value].first { !$0.isEmpty } ?? ""
}

func supportsPress(_ element: AXUIElement) -> Bool {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success, let actions = names as? [String] else { return false }
    return actions.contains(kAXPressAction as String)
}

struct Node {
    let element: AXUIElement
    let role: String
    let label: String
    let frame: CGRect?
    let ancestors: [AXUIElement]
}

func walk(_ element: AXUIElement, ancestors: [AXUIElement] = [], depth: Int = 0, into nodes: inout [Node]) {
    if depth > 60 { return }
    let role = string(element, kAXRoleAttribute)
    nodes.append(Node(element: element, role: role, label: label(of: element), frame: frame(of: element), ancestors: ancestors))
    for child in children(of: element) {
        walk(child, ancestors: ancestors + [element], depth: depth + 1, into: &nodes)
    }
}

func matches(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
}

let appElement = AXUIElementCreateApplication(app.processIdentifier)
let windows = (attribute(appElement, kAXWindowsAttribute) as? [AXUIElement]) ?? []
guard let window = (attribute(appElement, kAXFocusedWindowAttribute) as! AXUIElement?) ?? windows.first else {
    print("blocked: Claude has no accessible window")
    exit(2)
}

var nodes: [Node] = []
walk(window, into: &nodes)

// 1. The front window must show the session the caller named.
let renameControl = nodes.first { $0.role != "" && string($0.element, kAXDescriptionAttribute).hasSuffix(renameSuffix) }
let frontSession = renameControl.map { String(string($0.element, kAXDescriptionAttribute).dropLast(renameSuffix.count)) }
guard let frontSession, frontSession == session else {
    print("blocked: front session is '\(frontSession ?? "unknown")', expected '\(session)'")
    exit(2)
}

if dump {
    let pressables = nodes.filter { supportsPress($0.element) && !$0.label.isEmpty }
    for node in pressables {
        let y = node.frame.map { Int($0.origin.y) } ?? -1
        print("\(node.role) y=\(y) '\(node.label.prefix(80))'")
    }
    exit(0)
}

// 2. The permission-mode control is the lowest pop-up button whose title reads like a mode.
let popups = nodes.filter { $0.role == kAXPopUpButtonRole as String && matches($0.label, modePattern) }
    .sorted { ($0.frame?.origin.y ?? 0) > ($1.frame?.origin.y ?? 0) }
guard let popup = popups.first else {
    let seen = nodes.filter { $0.role == kAXPopUpButtonRole as String }.map(\.label).prefix(12)
    print("fail: no permission-mode control in the session pane; pop-ups: \(seen.joined(separator: " | "))")
    exit(1)
}
let currentMode = popup.label
if readOnly {
    print("mode: \(currentMode)")
    exit(0)
}
let wantedPattern = wanted!
if matches(currentMode, wantedPattern) {
    print("mode: \(currentMode) (unchanged)")
    exit(0)
}

// 3. Open the pop-up and look for the new items it revealed.
let before = Set(nodes.map { "\($0.role)|\($0.label)" })
AXUIElementPerformAction(popup.element, kAXPressAction as CFString)
Thread.sleep(forTimeInterval: 0.5)

var after: [Node] = []
for candidate in ((attribute(appElement, kAXWindowsAttribute) as? [AXUIElement]) ?? [window]) {
    walk(candidate, into: &after)
}
let items = after.filter { node in
    guard !node.label.isEmpty, !before.contains("\(node.role)|\(node.label)") else { return false }
    return [kAXMenuItemRole as String, kAXButtonRole as String, kAXRadioButtonRole as String, kAXCheckBoxRole as String, kAXStaticTextRole as String, "AXCell", "AXRow"].contains(node.role)
}

func pressable(_ node: Node) -> AXUIElement? {
    if supportsPress(node.element) { return node.element }
    for ancestor in node.ancestors.reversed() where supportsPress(ancestor) {
        return ancestor
    }
    return nil
}

func dismissMenu() {
    app.activate(options: [])
    Thread.sleep(forTimeInterval: 0.1)
    let source = CGEventSource(stateID: .combinedSessionState)
    if let down = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true),
       let up = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false) {
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

guard let target = items.first(where: { matches($0.label, wantedPattern) }), let control = pressable(target) else {
    dismissMenu()
    let labels = Array(Set(items.map(\.label))).sorted().prefix(16)
    print("fail: no menu item matched '\(wantedPattern)'; items: \(labels.joined(separator: " | "))")
    exit(3)
}
AXUIElementPerformAction(control, kAXPressAction as CFString)

// 4. The pop-up's title must now read the chosen mode.
for _ in 0..<20 {
    Thread.sleep(forTimeInterval: 0.15)
    let title = label(of: popup.element)
    if title != currentMode, matches(title, wantedPattern) {
        print("mode: \(title) (was \(currentMode))")
        exit(0)
    }
}
print("fail: the mode still reads '\(label(of: popup.element))' after pressing '\(target.label)'")
exit(4)
