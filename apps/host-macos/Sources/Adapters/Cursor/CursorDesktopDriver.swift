import Foundation
import GTInput

/// How the desktop adapter drives the real Cursor window. Production uses
/// Accessibility (with Electron's opt-in switch) and synthetic keystrokes;
/// tests substitute a fake.
protocol CursorDesktopUIDriving: Sendable {
    /// Writes into the composer of the chat in front and, when asked,
    /// submits it. Throws when no composer can be verified.
    func deliver(text: String, submit: Bool) throws
    /// The title of the chat the window shows, nil when it cannot be read.
    /// `candidates` are the titles the store knows, so a driver that can only
    /// see selection state can still answer.
    func frontChatTitle(candidates: [String]) -> String?
    /// Presses the chat's entry in the sidebar or tab strip.
    func showChat(titled title: String) throws
    /// Presses "New Chat".
    func newChat() throws
    /// Presses the Stop control of a running turn, else sends Escape.
    func interrupt() throws
    /// Presses a control by its exact label inside the chat pane.
    func press(label: String) throws
}

#if os(macOS)
import AppKit
import ApplicationServices

/// Accessibility driver for Cursor 3.x. Electron exposes the web content to
/// assistive clients only after `AXManualAccessibility` is set on the
/// application, and the tree takes a few seconds to appear; every entry
/// point enables it and waits for the web area. The composer is the settable
/// text area whose empty value is Cursor's placeholder (the placeholder
/// attribute itself is empty on this build) or that sits next to the
/// "Add agents, context, tools" toolbar; a code editor is never picked.
struct CursorAccessibilityDriver: CursorDesktopUIDriving {
    static let bundleID = "com.todesktop.230313mzl4w4u92"
    static let composerPlaceholders = [
        "Plan, Build, / for skills, @ for context",
        "Send follow-up",
        "Ask anything",
        "Ask Cursor",
        "Plan, search, build anything",
    ]
    static let composerToolbarHints = ["Add agents, context, tools", "Add context"]
    static let stopLabels = ["Stop", "Stop generating", "Cancel generation", "Stop generation"]
    static let newChatLabels = ["New Chat", "New chat"]
    /// Window titles that name no chat.
    static let genericWindowTitles: Set<String> = ["cursor", "cursor agents", ""]
    static let treeWaitSeconds: TimeInterval = 6

    let keyboard = KeyboardInjector()

    enum DriverError: Error, CustomStringConvertible {
        case appNotRunning
        case noWindow
        case noComposer
        case noControl(String)
        case unverifiedWrite

        var description: String {
            switch self {
            case .appNotRunning: return "Cursor is not running"
            case .noWindow: return "Cursor has no window"
            case .noComposer: return "Cursor's composer could not be found"
            case .noControl(let label): return "Cursor shows no control named \(label)"
            case .unverifiedWrite: return "Cursor did not take the text"
            }
        }
    }

    // MARK: - CursorDesktopUIDriving

    func deliver(text: String, submit: Bool) throws {
        let (app, window) = try frontWindow(activate: true)
        guard let composer = findComposer(in: window) else { throw DriverError.noComposer }
        let pid = app.processIdentifier
        _ = AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try replaceValue(text, in: composer, targetPID: pid)
        if submit {
            keyboard.pressReturn(targetPID: pid)
        }
    }

    func frontChatTitle(candidates: [String]) -> String? {
        guard let (_, window) = try? frontWindow(activate: false) else { return nil }
        // 1. A window title that names a chat.
        let title = (Self.string(window, kAXTitleAttribute)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !Self.genericWindowTitles.contains(title.lowercased()) {
            if let match = candidates.first(where: { Self.titlesMatch(title, $0) }) { return match }
            if candidates.isEmpty { return title }
        }
        // 2. A selected sidebar entry or tab carrying a known title.
        var selectedTexts: [String] = []
        Self.walk(window) { element, _ in
            let role = Self.string(element, kAXRoleAttribute)
            guard ["AXRow", "AXTab", "AXButton", "AXLink", "AXCell", "AXRadioButton", "AXCheckBox"].contains(role) else { return true }
            let selected = (Self.attribute(element, kAXSelectedAttribute) as? Bool) == true
                || (Self.attribute(element, kAXValueAttribute) as? Int) == 1 && role == "AXRadioButton"
            guard selected else { return true }
            selectedTexts.append(contentsOf: Self.labels(of: element))
            return true
        }
        for candidate in candidates {
            if selectedTexts.contains(where: { Self.titlesMatch($0, candidate) }) { return candidate }
        }
        // 3. A heading inside the chat pane.
        var headings: [String] = []
        Self.walk(window) { element, _ in
            if Self.string(element, kAXRoleAttribute) == "AXHeading" {
                headings.append(contentsOf: Self.labels(of: element))
            }
            return true
        }
        for candidate in candidates {
            if headings.contains(where: { Self.titlesMatch($0, candidate) }) { return candidate }
        }
        return nil
    }

    func showChat(titled title: String) throws {
        let (_, window) = try frontWindow(activate: true)
        // Prefer navigation controls; the newest match sits lowest in the
        // sidebar, and message bubbles that merely quote the title are text.
        var matches: [AXUIElement] = []
        Self.walk(window) { element, ancestors in
            let role = Self.string(element, kAXRoleAttribute)
            guard ["AXRow", "AXTab", "AXButton", "AXLink", "AXCell", "AXStaticText"].contains(role) else { return true }
            guard Self.labels(of: element).contains(where: { Self.titlesMatch($0, title) }) else { return true }
            if Self.isPressable(element) {
                matches.append(element)
            } else if let ancestor = ancestors.reversed().first(where: Self.isPressable) {
                matches.append(ancestor)
            }
            return true
        }
        guard let target = matches.last else { throw DriverError.noControl(title) }
        let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
        guard result == .success else { throw DriverError.noControl(title) }
    }

    func newChat() throws {
        let (_, window) = try frontWindow(activate: true)
        guard let button = Self.firstPressable(in: window, where: { labels in
            labels.contains { label in Self.newChatLabels.contains { label.hasPrefix($0) } }
        }) else {
            throw DriverError.noControl("New Chat")
        }
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { throw DriverError.noControl("New Chat") }
    }

    func interrupt() throws {
        let (app, window) = try frontWindow(activate: true)
        if let stop = Self.lastPressable(in: window, where: { labels in
            labels.contains { label in Self.stopLabels.contains { $0.caseInsensitiveCompare(label) == .orderedSame } }
        }) {
            guard AXUIElementPerformAction(stop, kAXPressAction as CFString) == .success else { throw DriverError.noControl("Stop") }
            return
        }
        keyboard.focusApplication(pid: app.processIdentifier)
        keyboard.pressEscape()
    }

    func press(label: String) throws {
        let (_, window) = try frontWindow(activate: true)
        guard let control = Self.lastPressable(in: window, where: { labels in
            labels.contains { $0.caseInsensitiveCompare(label) == .orderedSame }
        }) else {
            throw DriverError.noControl(label)
        }
        guard AXUIElementPerformAction(control, kAXPressAction as CFString) == .success else { throw DriverError.noControl(label) }
    }

    // MARK: - Window and tree

    private func frontWindow(activate: Bool) throws -> (NSRunningApplication, AXUIElement) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            throw DriverError.appNotRunning
        }
        if activate {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let deadline = Date().addingTimeInterval(Self.treeWaitSeconds)
        var window: AXUIElement?
        repeat {
            window = (Self.attribute(axApp, kAXFocusedWindowAttribute).map { $0 as! AXUIElement })
                ?? (Self.attribute(axApp, kAXWindowsAttribute) as? [AXUIElement])?.first
            if let window, Self.hasWebArea(window) { return (app, window) }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        guard let window else { throw DriverError.noWindow }
        return (app, window)
    }

    private static func hasWebArea(_ window: AXUIElement) -> Bool {
        var found = false
        walk(window, maxDepth: 12) { element, _ in
            if string(element, kAXRoleAttribute) == "AXWebArea" { found = true; return false }
            return true
        }
        return found
    }

    /// The composer: a settable text area showing a known placeholder, or the
    /// one closest to the composer toolbar; never a text area with code in it.
    func findComposer(in window: AXUIElement) -> AXUIElement? {
        var byPlaceholder: AXUIElement?
        var byToolbar: AXUIElement?
        var textAreas: [(AXUIElement, [AXUIElement])] = []
        Self.walk(window) { element, ancestors in
            guard Self.isSettableTextArea(element) else { return true }
            textAreas.append((element, ancestors))
            let value = (Self.attribute(element, kAXValueAttribute) as? String) ?? ""
            let placeholder = Self.string(element, kAXPlaceholderValueAttribute)
            let childTexts = Self.children(element).flatMap(Self.labels)
            let texts = [value, placeholder] + childTexts
            if texts.contains(where: { text in Self.composerPlaceholders.contains { Self.titlesMatch(text, $0) } }) {
                byPlaceholder = byPlaceholder ?? element
            }
            return true
        }
        if let byPlaceholder { return byPlaceholder }
        // A composer with a draft shows no placeholder; find the toolbar and
        // take the text area that shares its container.
        var toolbarPath: [AXUIElement]?
        Self.walk(window) { element, ancestors in
            let labels = Self.labels(of: element)
            if labels.contains(where: { label in Self.composerToolbarHints.contains { label.localizedCaseInsensitiveContains($0) } }) {
                toolbarPath = ancestors
                return false
            }
            return true
        }
        if let toolbarPath {
            for (area, ancestors) in textAreas {
                let shared = zip(ancestors, toolbarPath).prefix { CFEqual($0.0, $0.1) }.count
                // Share everything but the last few containers.
                if shared >= max(1, min(ancestors.count, toolbarPath.count) - 4) {
                    byToolbar = area
                }
            }
        }
        if let byToolbar { return byToolbar }
        // A single settable text area in the window is the composer (the
        // Agents window has exactly one); an editor window is ambiguous.
        return textAreas.count == 1 ? textAreas[0].0 : nil
    }

    private static func isSettableTextArea(_ element: AXUIElement) -> Bool {
        let role = string(element, kAXRoleAttribute)
        guard role == "AXTextArea" || role == "AXTextField" else { return false }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return settable.boolValue
    }

    private func replaceValue(_ text: String, in element: AXUIElement, targetPID pid: pid_t) throws {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        if waitForValue(text, in: element, timeout: 0.4) { return }

        // Chromium ignores AX writes on some builds: focus, select all, type.
        if let frame = Self.frame(of: element) {
            Self.click(at: CGPoint(x: frame.midX, y: frame.midY), targetPID: pid)
            Thread.sleep(forTimeInterval: 0.2)
        }
        keyboard.pressCommandA(targetPID: pid)
        keyboard.pressDelete(targetPID: pid)
        keyboard.typeString(text, targetPID: pid)
        if waitForValue(text, in: element, timeout: 1.0) { return }

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        keyboard.pressCommandA(targetPID: pid)
        keyboard.pressDelete(targetPID: pid)
        keyboard.pressCommandV(targetPID: pid)
        let pasted = waitForValue(text, in: element, timeout: 1.0)
        pasteboard.clearContents()
        if let previous { pasteboard.setString(previous, forType: .string) }
        guard pasted else { throw DriverError.unverifiedWrite }
    }

    private func waitForValue(_ expected: String, in element: AXUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let wanted = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        repeat {
            let actual = ((Self.attribute(element, kAXValueAttribute) as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if actual == wanted { return true }
            // Chromium exposes a contenteditable's text through its children.
            let childText = Self.children(element).flatMap(Self.labels).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if childText == wanted { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }

    // MARK: - AX helpers

    static func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String {
        (attribute(element, name) as? String) ?? ""
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    /// Title, description, value, placeholder, and help, non-empty.
    static func labels(of element: AXUIElement) -> [String] {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute]
            .compactMap { attribute(element, $0) as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func isPressable(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let actions = names as? [String] else { return false }
        return actions.contains(kAXPressAction as String)
    }

    /// Depth-first walk; the visitor returns false to stop.
    @discardableResult
    static func walk(_ root: AXUIElement, maxDepth: Int = 60, _ visit: (AXUIElement, [AXUIElement]) -> Bool) -> Bool {
        var stack: [(AXUIElement, [AXUIElement])] = [(root, [])]
        var visited = 0
        while let (element, ancestors) = stack.popLast() {
            visited += 1
            if visited > 20_000 { return false }
            if !visit(element, ancestors) { return false }
            guard ancestors.count < maxDepth else { continue }
            let next = ancestors + [element]
            for child in children(element).reversed() {
                stack.append((child, next))
            }
        }
        return true
    }

    static func firstPressable(in root: AXUIElement, where matches: ([String]) -> Bool) -> AXUIElement? {
        var found: AXUIElement?
        walk(root) { element, ancestors in
            guard matches(labels(of: element)) else { return true }
            if isPressable(element) { found = element; return false }
            if let ancestor = ancestors.reversed().first(where: isPressable) { found = ancestor; return false }
            return true
        }
        return found
    }

    static func lastPressable(in root: AXUIElement, where matches: ([String]) -> Bool) -> AXUIElement? {
        var found: AXUIElement?
        walk(root) { element, ancestors in
            guard matches(labels(of: element)) else { return true }
            if isPressable(element) { found = element } else if let ancestor = ancestors.reversed().first(where: isPressable) { found = ancestor }
            return true
        }
        return found
    }

    static func titlesMatch(_ shown: String, _ wanted: String) -> Bool {
        let a = shown.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
        let b = wanted.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.hasPrefix(b) || a.hasSuffix(b)
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else { return nil }
        guard CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID(), CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
        return CGRect(origin: point, size: dimensions)
    }

    static func click(at point: CGPoint, targetPID pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}
#endif
