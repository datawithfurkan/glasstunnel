#if os(macOS)
import Foundation
import GTProtocol
import GTSecurity

struct AppVersionInfo: Equatable {
    let version: String
    let build: String

    var displayValue: String {
        "\(version) (\(build))"
    }

    static let releasesURL = URL(string: "https://github.com/datawithfurkan/glasstunnel/releases")!

    static func current(bundle: Bundle = .main) -> AppVersionInfo {
        AppVersionInfo(
            version: bundleValue("CFBundleShortVersionString", in: bundle) ?? "Development",
            build: bundleValue("CFBundleVersion", in: bundle) ?? "Local"
        )
    }

    private static func bundleValue(_ key: String, in bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) else { return nil }
        let string = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }
}

enum DiagnosticsPermissionStatus: String, Equatable {
    case allowed = "Allowed"
    case needsAccess = "Needs access"
    case notChecked = "Not checked"
}

enum DiagnosticsConnectionState: String, Equatable {
    case offline = "Offline"
    case connecting = "Connecting"
    case connected = "Connected"
    case reconnecting = "Reconnecting"

    init(sessionManagerState: String) {
        switch sessionManagerState {
        case "connected": self = .connected
        case "connecting": self = .connecting
        case "error": self = .reconnecting
        default: self = .offline
        }
    }
}

struct DiagnosticsReportInput: Equatable {
    let appVersion: AppVersionInfo
    let macOSVersion: String
    let protocolVersion: String
    let screenRecording: DiagnosticsPermissionStatus
    let accessibility: DiagnosticsPermissionStatus
    let connection: DiagnosticsConnectionState
    let accountLinked: Bool
}

enum DiagnosticsReportBuilder {
    static func build(
        _ input: DiagnosticsReportInput,
        secretRedactor: SecretRedactor = SecretRedactor()
    ) -> String {
        let report = """
        Glasstunnel Diagnostics
        App: \(input.appVersion.displayValue)
        macOS: \(input.macOSVersion)
        Protocol: \(input.protocolVersion)
        Screen Recording: \(input.screenRecording.rawValue)
        Accessibility: \(input.accessibility.rawValue)
        Connection: \(input.connection.rawValue)
        Account: \(input.accountLinked ? "Linked" : "Not linked")
        """
        let (secretRedacted, _) = secretRedactor.redact(report)
        return DiagnosticsPrivacyFilter.redactPrivateValues(in: secretRedacted)
    }

    static func currentInput(
        appVersion: AppVersionInfo = .current(),
        permissionsChecked: Bool,
        screenRecordingGranted: Bool,
        accessibilityGranted: Bool,
        sessionManagerState: String,
        accountLinked: Bool
    ) -> DiagnosticsReportInput {
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersion
        let macOSVersion = "\(operatingSystem.majorVersion).\(operatingSystem.minorVersion).\(operatingSystem.patchVersion)"
        return DiagnosticsReportInput(
            appVersion: appVersion,
            macOSVersion: macOSVersion,
            protocolVersion: GlasstunnelProtocol.version,
            screenRecording: permissionStatus(checked: permissionsChecked, granted: screenRecordingGranted),
            accessibility: permissionStatus(checked: permissionsChecked, granted: accessibilityGranted),
            connection: DiagnosticsConnectionState(sessionManagerState: sessionManagerState),
            accountLinked: accountLinked
        )
    }

    private static func permissionStatus(checked: Bool, granted: Bool) -> DiagnosticsPermissionStatus {
        guard checked else { return .notChecked }
        return granted ? .allowed : .needsAccess
    }
}

private enum DiagnosticsPrivacyFilter {
    private struct Rule {
        let pattern: String
        let replacement: String
        let options: NSRegularExpression.Options
    }

    private static let rules = [
        Rule(
            pattern: #"\b(?:https?|wss?)://[^\s]+"#,
            replacement: "<redacted:url>",
            options: [.caseInsensitive]
        ),
        Rule(
            pattern: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            replacement: "<redacted:email>",
            options: [.caseInsensitive]
        ),
        Rule(
            pattern: #"(?:~|/(?:Users|Volumes|private|home|tmp))(?:/[^\s]+)+"#,
            replacement: "<redacted:path>",
            options: []
        ),
    ]

    static func redactPrivateValues(in input: String) -> String {
        rules.reduce(input) { output, rule in
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else {
                return output
            }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            return regex.stringByReplacingMatches(
                in: output,
                options: [],
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: rule.replacement)
            )
        }
    }
}
#endif
