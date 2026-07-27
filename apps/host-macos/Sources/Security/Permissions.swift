#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

/// macOS permission gateway. Each permission has a `status` getter that
/// the onboarding UI polls, plus a `request` method that deep-links to the
/// right System Settings pane without repeatedly firing native prompts.
public enum Permissions {
    public enum Permission: String, CaseIterable, Sendable {
        case screenRecording
        case accessibility

        public var displayName: String {
            switch self {
            case .screenRecording: return "Screen Recording"
            case .accessibility: return "Accessibility"
            }
        }

        public var rationale: String {
            switch self {
            case .screenRecording:
                return "Glasstunnel streams this Mac's screen and coding-agent windows to your signed-in devices so you can monitor work remotely."
            case .accessibility:
                return "Required so prompts, clicks, and keyboard input from your phone land in Cursor, Codex, Claude Code, and other coding apps."
            }
        }
    }

    public enum Status: Sendable, Hashable {
        case unknown
        case denied
        case authorized
    }

    public struct RequiredState: Sendable, Equatable {
        public let screenRecording: Status
        public let accessibility: Status
        public let checked: Bool

        public static let unchecked = RequiredState(
            screenRecording: .unknown,
            accessibility: .unknown,
            checked: false
        )

        public var screenRecordingGranted: Bool {
            screenRecording == .authorized
        }

        public var accessibilityGranted: Bool {
            accessibility == .authorized
        }

        public var allGranted: Bool {
            screenRecordingGranted && accessibilityGranted
        }

        public func status(for permission: Permission) -> Status {
            switch permission {
            case .screenRecording:
                return screenRecording
            case .accessibility:
                return accessibility
            }
        }

        public func isGranted(_ permission: Permission) -> Bool {
            status(for: permission) == .authorized
        }
    }

    public static func status(_ permission: Permission) -> Status {
        switch permission {
        case .screenRecording:
            return screenRecordingStatus()
        case .accessibility:
            return accessibilityStatus()
        }
    }

    public static func requiredState() -> RequiredState {
        RequiredState(
            screenRecording: status(.screenRecording),
            accessibility: status(.accessibility),
            checked: true
        )
    }

    /// Route the user to the permission pane when access is not already usable.
    /// User-initiated requests first ask macOS to register the current app in
    /// Privacy & Security, then fall back to the relevant Settings pane.
    public static func request(_ permission: Permission) {
        switch permission {
        case .screenRecording:
            guard screenRecordingStatus() != .authorized else { return }
            let granted = CGRequestScreenCaptureAccess()
            if !granted {
                openSystemSettingsScreenRecording()
            }
        case .accessibility:
            guard accessibilityStatus() != .authorized else { return }
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [key: true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            if !trusted {
                openSystemSettingsAccessibility()
            }
        }
    }

    private static func screenRecordingStatus() -> Status {
        screenRecordingStatus(preflight: { CGPreflightScreenCaptureAccess() })
    }

    static func screenRecordingStatus(preflight: () -> Bool) -> Status {
        preflight() ? .authorized : .denied
    }

    private static func accessibilityStatus() -> Status {
        // AXIsProcessTrustedWithOptions with no prompt so polling doesn't spam dialogs.
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options) ? .authorized : .denied
    }

    public static func openSystemSettingsScreenRecording() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    public static func openSystemSettingsAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

#else
public enum Permissions {
    public enum Permission: String, CaseIterable, Sendable {
        case screenRecording
        case accessibility
    }
    public enum Status: Sendable, Hashable { case unknown, denied, authorized }
    public struct RequiredState: Sendable, Equatable {
        public let screenRecording: Status
        public let accessibility: Status
        public let checked: Bool
        public static let unchecked = RequiredState(screenRecording: .unknown, accessibility: .unknown, checked: false)
        public var screenRecordingGranted: Bool { screenRecording == .authorized }
        public var accessibilityGranted: Bool { accessibility == .authorized }
        public var allGranted: Bool { screenRecordingGranted && accessibilityGranted }
        public func status(for permission: Permission) -> Status {
            switch permission {
            case .screenRecording: return screenRecording
            case .accessibility: return accessibility
            }
        }
        public func isGranted(_ permission: Permission) -> Bool { status(for: permission) == .authorized }
    }
    public static func status(_: Permission) -> Status { .authorized }
    public static func requiredState() -> RequiredState {
        RequiredState(screenRecording: .authorized, accessibility: .authorized, checked: true)
    }
    public static func request(_: Permission) {}
}
#endif
