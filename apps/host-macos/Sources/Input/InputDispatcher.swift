import Foundation

/// Central dispatcher that routes user input from the phone to the correct
/// delivery mechanism. Honors the read-only mode flag from `AutoLock`.
public actor InputDispatcher {
    public enum Mode: Sendable {
        case keyboard(pid: Int32)
        case accessibility(bundleID: String, hint: String?)
        case pty(agentID: String)
    }

    public typealias PTYWrite = @Sendable (_ agentID: String, _ text: String, _ submit: Bool) async -> Void

    private let keyboard: KeyboardInjector
    private let accessibility: AccessibilityInjector
    private let readOnlyProvider: @Sendable () -> Bool
    private let ptyWriter: PTYWrite

    public init(
        keyboard: KeyboardInjector = KeyboardInjector(),
        accessibility: AccessibilityInjector = AccessibilityInjector(),
        readOnlyProvider: @escaping @Sendable () -> Bool = { false },
        ptyWriter: @escaping PTYWrite = { _, _, _ in }
    ) {
        self.keyboard = keyboard
        self.accessibility = accessibility
        self.readOnlyProvider = readOnlyProvider
        self.ptyWriter = ptyWriter
    }

    public func dispatch(_ text: String, submit: Bool, via mode: Mode) async throws {
        if readOnlyProvider() {
            throw DispatchError.readOnly
        }
        switch mode {
        case .keyboard(let pid):
            keyboard.focusApplication(pid: pid)
            keyboard.typeString(text)
            if submit { keyboard.pressReturn() }
        case .accessibility(let bundleID, let hint):
            try accessibility.deliver(bundleID: bundleID, text: text, submit: submit, targetHint: hint)
        case .pty(let agentID):
            await ptyWriter(agentID, text, submit)
        }
    }

    public func interrupt(via mode: Mode) async throws {
        if readOnlyProvider() {
            throw DispatchError.readOnly
        }
        switch mode {
        case .keyboard(let pid):
            keyboard.focusApplication(pid: pid)
            keyboard.pressControlC()
        case .accessibility(let bundleID, _):
            try accessibility.deliver(bundleID: bundleID, text: "", submit: false, targetHint: nil)
            keyboard.pressEscape()
        case .pty(let agentID):
            await ptyWriter(agentID, "\u{0003}", false) // Ctrl+C
        }
    }

    public enum DispatchError: Error, CustomStringConvertible, Sendable {
        case readOnly
        case noTarget(String)

        public var description: String {
            switch self {
            case .readOnly: return "Read-only mode is on; input was dropped."
            case .noTarget(let s): return "No target for input: \(s)"
            }
        }
    }
}
