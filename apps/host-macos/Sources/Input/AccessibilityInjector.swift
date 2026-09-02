public struct AccessibilityDeliveryResult: Equatable, Sendable {
    public var verified: Bool
    public var targetHint: String?

    public init(verified: Bool, targetHint: String?) {
        self.verified = verified
        self.targetHint = targetHint
    }
}

#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

/// Accessibility-driven input delivery. Finds the specified application's
/// front window, locates a text input element (typically an AXTextArea in
/// the chat pane for tools like Cursor), sets its AXValue, and optionally
/// posts a Return key to submit.
///
/// This is the cleaner path for GUI coding tools than dumb keyboard events,
/// because it does not depend on the keyboard being focused correctly and
/// works even if the tool is in the background (by raising it first).
public final class AccessibilityInjector: @unchecked Sendable {
    public enum InjectionError: Error, CustomStringConvertible {
        case appNotRunning(String)
        case noFrontWindow
        case noInputField(String)
        case noMatchingElement(String)
        case axFailed(String, AXError)

        public var description: String {
            switch self {
            case .appNotRunning(let b): return "application with bundle id \(b) not running"
            case .noFrontWindow: return "app has no front window"
            case .noInputField(let b): return "could not find input field in \(b)"
            case .noMatchingElement(let q): return "could not find matching Accessibility element for '\(q)'"
            case .axFailed(let op, let err): return "AX operation '\(op)' failed: \(err.rawValue)"
            }
        }
    }

    public init() {}

    /// Main entry point. `targetHint` is an adapter-specific hint used to
    /// narrow the search, e.g. "chat input" or "prompt".
    @discardableResult public func deliver(
        bundleID: String,
        text: String,
        submit: Bool = true,
        targetHint: String? = nil
    ) throws -> AccessibilityDeliveryResult {
        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            throw InjectionError.appNotRunning(bundleID)
        }
        runningApp.activate(options: [.activateIgnoringOtherApps])

        let app = AXUIElementCreateApplication(runningApp.processIdentifier)
        guard let window = focusedWindow(of: app) ?? firstWindow(of: app) else {
            throw InjectionError.noFrontWindow
        }

        let input = findFirstInputField(in: window, hint: targetHint)
        guard let input else {
            throw InjectionError.noInputField(bundleID)
        }

        try set(element: input, attribute: kAXFocusedAttribute, to: kCFBooleanTrue as CFTypeRef)
        try replaceValue(text, in: input, targetPID: runningApp.processIdentifier)

        if submit {
            postReturn(toPID: runningApp.processIdentifier)
        }

        return AccessibilityDeliveryResult(verified: true, targetHint: targetHint)
    }

    public func focusInput(
        bundleID: String,
        targetHint: String? = nil,
        allowFallback: Bool = true
    ) throws {
        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            throw InjectionError.appNotRunning(bundleID)
        }
        runningApp.activate(options: [.activateIgnoringOtherApps])

        let app = AXUIElementCreateApplication(runningApp.processIdentifier)
        guard let window = focusedWindow(of: app) ?? firstWindow(of: app) else {
            throw InjectionError.noFrontWindow
        }

        let input = findFirstInputField(in: window, hint: targetHint)
            ?? (allowFallback && targetHint != nil ? findFirstInputField(in: window, hint: nil) : nil)
        guard let input else {
            throw InjectionError.noInputField(bundleID)
        }

        try set(element: input, attribute: kAXFocusedAttribute, to: kCFBooleanTrue as CFTypeRef)
    }

    public func press(
        bundleID: String,
        matching query: String,
        exact: Bool = true
    ) throws {
        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            throw InjectionError.appNotRunning(bundleID)
        }
        runningApp.activate(options: [.activateIgnoringOtherApps])

        let app = AXUIElementCreateApplication(runningApp.processIdentifier)
        guard let window = focusedWindow(of: app) ?? firstWindow(of: app) else {
            throw InjectionError.noFrontWindow
        }

        guard let element = findFirstPressMatch(in: window, query: query, exact: exact) else {
            throw InjectionError.noMatchingElement(query)
        }

        let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if err != .success {
            throw InjectionError.axFailed("press \(query)", err)
        }
    }

    public func frontWindowTitle(bundleID: String) throws -> String? {
        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            throw InjectionError.appNotRunning(bundleID)
        }

        let app = AXUIElementCreateApplication(runningApp.processIdentifier)
        guard let window = focusedWindow(of: app) ?? firstWindow(of: app) else {
            throw InjectionError.noFrontWindow
        }

        return copyStringAttribute(window, kAXTitleAttribute)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The full accessibility description of the first element in the front
    /// window whose description ends with `suffix`; nil when none does.
    /// Web-based apps often expose a control such as "Thread title, rename"
    /// whose description carries state the window title does not.
    public func frontWindowDescription(bundleID: String, endingWith suffix: String) throws -> String? {
        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            throw InjectionError.appNotRunning(bundleID)
        }

        let app = AXUIElementCreateApplication(runningApp.processIdentifier)
        guard let window = focusedWindow(of: app) ?? firstWindow(of: app) else {
            throw InjectionError.noFrontWindow
        }
        return findFirstDescription(in: window, endingWith: suffix, depth: 0)
    }

    public func clickFrontWindow(
        bundleID: String,
        xFraction: CGFloat,
        yFromBottom: CGFloat
    ) throws {
        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            throw InjectionError.appNotRunning(bundleID)
        }
        runningApp.activate(options: [.activateIgnoringOtherApps])

        let app = AXUIElementCreateApplication(runningApp.processIdentifier)
        guard let window = focusedWindow(of: app) ?? firstWindow(of: app) else {
            throw InjectionError.noFrontWindow
        }
        guard let frame = frame(of: window) else {
            throw InjectionError.axFailed("read window frame", .failure)
        }

        let clampedX = min(max(xFraction, 0.0), 1.0)
        let point = CGPoint(
            x: frame.minX + frame.width * clampedX,
            y: frame.maxY - yFromBottom
        )
        click(at: point, targetPID: runningApp.processIdentifier)
    }

    // MARK: - AX helpers

    private func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
           let cf = value, CFGetTypeID(cf) == AXUIElementGetTypeID() {
            return (cf as! AXUIElement)
        }
        return nil
    }

    private func firstWindow(of app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else {
            return nil
        }
        guard let arr = value as? [AXUIElement], let first = arr.first else { return nil }
        return first
    }

    private func findFirstInputField(in element: AXUIElement, hint: String?) -> AXUIElement? {
        if isEditableField(element) {
            if hint == nil || elementMatchesHint(element, hint: hint!) {
                return element
            }
        }
        for child in children(of: element) {
            if let found = findFirstInputField(in: child, hint: hint) {
                return found
            }
        }
        return nil
    }

    private func findFirstPressMatch(
        in element: AXUIElement,
        query: String,
        exact: Bool,
        ancestors: [AXUIElement] = []
    ) -> AXUIElement? {
        if matchesQuery(element, query: query, exact: exact) {
            if isPressable(element) {
                return element
            }
            if let ancestor = ancestors.reversed().first(where: isPressable) {
                return ancestor
            }
        }

        let nextAncestors = ancestors + [element]
        for child in children(of: element) {
            if let found = findFirstPressMatch(in: child, query: query, exact: exact, ancestors: nextAncestors) {
                return found
            }
        }
        return nil
    }

    private func findFirstDescription(in element: AXUIElement, endingWith suffix: String, depth: Int) -> String? {
        guard depth <= 60 else { return nil }
        if let description = copyStringAttribute(element, kAXDescriptionAttribute),
           description.hasSuffix(suffix), description.count > suffix.count {
            return description
        }
        for child in children(of: element) {
            if let found = findFirstDescription(in: child, endingWith: suffix, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private func isEditableField(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""
        if role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String) {
            var settable: DarwinBoolean = false
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
            return settable.boolValue
        }
        return false
    }

    private func elementMatchesHint(_ element: AXUIElement, hint: String) -> Bool {
        var desc: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &desc)
        var placeholder: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPlaceholderValueAttribute as CFString, &placeholder)
        let combined = [(desc as? String) ?? "", (placeholder as? String) ?? ""].joined(separator: " ")
        return combined.lowercased().contains(hint.lowercased())
    }

    private func matchesQuery(_ element: AXUIElement, query: String, exact: Bool) -> Bool {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return false }
        return elementStrings(element).contains { candidate in
            let normalizedCandidate = normalize(candidate)
            guard !normalizedCandidate.isEmpty else { return false }
            if exact {
                return normalizedCandidate == normalizedQuery
            }
            return normalizedCandidate.contains(normalizedQuery)
        }
    }

    private func elementStrings(_ element: AXUIElement) -> [String] {
        [
            copyStringAttribute(element, kAXTitleAttribute),
            copyStringAttribute(element, kAXDescriptionAttribute),
            copyStringAttribute(element, kAXValueAttribute),
            copyStringAttribute(element, kAXPlaceholderValueAttribute),
            copyStringAttribute(element, kAXHelpAttribute),
        ].compactMap { $0 }
    }

    private func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return []
        }
        return children
    }

    private func frame(of element: AXUIElement) -> CGRect? {
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

    private func isPressable(_ element: AXUIElement) -> Bool {
        var actionsRef: CFArray?
        guard AXUIElementCopyActionNames(element, &actionsRef) == .success,
              let actions = actionsRef as? [String] else {
            return false
        }
        return actions.contains(kAXPressAction as String)
    }

    private func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func set(element: AXUIElement, attribute: String, to value: CFTypeRef) throws {
        let err = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        if err != .success {
            throw InjectionError.axFailed("set \(attribute)", err)
        }
    }

    private func replaceValue(_ text: String, in element: AXUIElement, targetPID pid: pid_t) throws {
        try set(element: element, attribute: kAXValueAttribute, to: text as CFString)
        if waitForValue(text, in: element, timeout: 0.2) {
            return
        }

        let keyboard = KeyboardInjector()
        if let frame = frame(of: element) {
            click(at: CGPoint(x: frame.midX, y: frame.midY), targetPID: pid)
            Thread.sleep(forTimeInterval: 0.25)
        }
        keyboard.pressCommandA(targetPID: pid)
        keyboard.pressDelete(targetPID: pid)
        if text.isEmpty, waitForValue(text, in: element, timeout: 0.3) {
            return
        }
        keyboard.typeString(text, targetPID: pid)
        if waitForValue(text, in: element) {
            return
        }

        let pasteboard = NSPasteboard.general
        let previousPasteboard = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        keyboard.pressCommandA(targetPID: pid)
        keyboard.pressDelete(targetPID: pid)
        keyboard.pressCommandV(targetPID: pid)
        previousPasteboard.restore(to: pasteboard)

        guard waitForValue(text, in: element) else {
            throw InjectionError.axFailed("verify \(kAXValueAttribute)", .failure)
        }
    }

    private func waitForValue(_ value: String, in element: AXUIElement, timeout: TimeInterval = 0.6) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if valueMatches(value, in: element) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        return valueMatches(value, in: element)
    }

    private func valueMatches(_ expected: String, in element: AXUIElement) -> Bool {
        let actual = copyStringAttribute(element, kAXValueAttribute) ?? ""
        if actual == expected {
            return true
        }
        return expected.isEmpty && isPlaceholderValue(actual, in: element)
    }

    private func isPlaceholderValue(_ value: String, in element: AXUIElement) -> Bool {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return false }

        let placeholder = (copyStringAttribute(element, kAXPlaceholderValueAttribute) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !placeholder.isEmpty && trimmedValue == placeholder {
            return true
        }

        return [
            "Plan, Build, / for skills, @ for context",
            "Send follow-up",
        ].contains(trimmedValue)
    }

    private func postReturn(toPID pid: pid_t) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: true) // kVK_Return
        down?.postToPid(pid)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: false)
        up?.postToPid(pid)
    }

    private func click(at point: CGPoint, targetPID pid: pid_t) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(
            mouseEventSource: src,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(
            mouseEventSource: src,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        up?.post(tap: .cghidEventTap)
    }
}

private struct PasteboardSnapshot {
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
#else
public final class AccessibilityInjector: @unchecked Sendable {
    public init() {}
    @discardableResult public func deliver(
        bundleID: String,
        text: String,
        submit: Bool = true,
        targetHint: String? = nil
    ) throws -> AccessibilityDeliveryResult {
        AccessibilityDeliveryResult(verified: true, targetHint: targetHint)
    }
    public func focusInput(bundleID: String, targetHint: String? = nil, allowFallback: Bool = true) throws {}
    public func frontWindowTitle(bundleID: String) throws -> String? { nil }
    public func frontWindowDescription(bundleID: String, endingWith suffix: String) throws -> String? { nil }
    public func clickFrontWindow(bundleID: String, xFraction: Double, yFromBottom: Double) throws {}
    public func press(bundleID: String, matching query: String, exact: Bool = true) throws {}
}
#endif
