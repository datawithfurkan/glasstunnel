import XCTest
@testable import GlassTunnelApp

final class DiagnosticsReportTests: XCTestCase {
    func testReportContainsOnlyTheExpectedOperationalFacts() {
        let report = DiagnosticsReportBuilder.build(
            DiagnosticsReportInput(
                appVersion: AppVersionInfo(version: "0.1.4", build: "4"),
                macOSVersion: "26.5.0",
                protocolVersion: "0.2.0",
                screenRecording: .allowed,
                accessibility: .needsAccess,
                connection: .connected,
                accountLinked: true
            )
        )

        XCTAssertTrue(report.contains("App: 0.1.4 (4)"))
        XCTAssertTrue(report.contains("macOS: 26.5.0"))
        XCTAssertTrue(report.contains("Protocol: 0.2.0"))
        XCTAssertTrue(report.contains("Screen Recording: Allowed"))
        XCTAssertTrue(report.contains("Accessibility: Needs access"))
        XCTAssertTrue(report.contains("Connection: Connected"))
        XCTAssertTrue(report.contains("Account: Linked"))
        XCTAssertFalse(report.localizedCaseInsensitiveContains("device id"))
        XCTAssertFalse(report.localizedCaseInsensitiveContains("email"))
        XCTAssertFalse(report.localizedCaseInsensitiveContains("prompt"))
        XCTAssertFalse(report.localizedCaseInsensitiveContains("chat"))
    }

    func testReportRedactsSecretsEmailsPrivatePathsAndURLs() {
        let apiKey = "sk-" + String(repeating: "x", count: 40)
        let report = DiagnosticsReportBuilder.build(
            DiagnosticsReportInput(
                appVersion: AppVersionInfo(version: "user@example.com", build: apiKey),
                macOSVersion: "/Users/private/Library/Glasstunnel",
                protocolVersion: "https://example.com/private?token=value",
                screenRecording: .allowed,
                accessibility: .allowed,
                connection: .offline,
                accountLinked: false
            )
        )

        XCTAssertFalse(report.contains("user@example.com"))
        XCTAssertFalse(report.contains(apiKey))
        XCTAssertFalse(report.contains("/Users/private"))
        XCTAssertFalse(report.contains("https://example.com"))
        XCTAssertTrue(report.contains("<redacted:email>"))
        XCTAssertTrue(report.contains("<redacted:openai_api_key>"))
        XCTAssertTrue(report.contains("<redacted:path>"))
        XCTAssertTrue(report.contains("<redacted:url>"))
    }

    func testCurrentInputDoesNotTreatUncheckedPermissionsAsDenied() {
        let input = DiagnosticsReportBuilder.currentInput(
            appVersion: AppVersionInfo(version: "Development", build: "Local"),
            permissionsChecked: false,
            screenRecordingGranted: false,
            accessibilityGranted: false,
            sessionManagerState: "idle",
            accountLinked: false
        )

        XCTAssertEqual(input.screenRecording, .notChecked)
        XCTAssertEqual(input.accessibility, .notChecked)
        XCTAssertEqual(input.connection, .offline)
    }

    func testOfficialReleasesURLIsStable() {
        XCTAssertEqual(
            AppVersionInfo.releasesURL.absoluteString,
            "https://github.com/datawithfurkan/glasstunnel/releases"
        )
    }
}
