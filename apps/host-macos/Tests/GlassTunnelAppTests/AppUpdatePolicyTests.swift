import XCTest
@testable import GlassTunnelApp

final class AppUpdatePolicyTests: XCTestCase {
    private let appURL = URL(fileURLWithPath: "/Applications/Glasstunnel.app")
    private let releaseInfo: [String: Any] = [
        "SUFeedURL": "https://glasstunnel.io/appcast.xml",
        "SUPublicEDKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    ]

    func testReleaseBundleWithFeedAndKeyUpdatesInApp() {
        XCTAssertEqual(AppUpdatePolicy.mode(bundleURL: appURL, info: releaseInfo), .inApp)
    }

    func testSwiftRunBuildOpensReleases() {
        let binaryDirectory = URL(fileURLWithPath: "/tmp/glasstunnel/.build/debug")
        XCTAssertEqual(
            AppUpdatePolicy.mode(bundleURL: binaryDirectory, info: releaseInfo),
            .releasesPage(reason: AppUpdatePolicy.developmentBuildReason)
        )
    }

    func testBuildWithoutTheUpdateKeyOpensReleases() {
        var info = releaseInfo
        info["SUPublicEDKey"] = nil
        XCTAssertEqual(
            AppUpdatePolicy.mode(bundleURL: appURL, info: info),
            .releasesPage(reason: AppUpdatePolicy.unsignedBuildReason)
        )
        info["SUPublicEDKey"] = "  "
        XCTAssertEqual(
            AppUpdatePolicy.mode(bundleURL: appURL, info: info),
            .releasesPage(reason: AppUpdatePolicy.unsignedBuildReason)
        )
    }

    func testPlainHTTPFeedIsOnlyAcceptedFromThisMac() {
        var info = releaseInfo
        info["SUFeedURL"] = "http://glasstunnel.io/appcast.xml"
        XCTAssertEqual(
            AppUpdatePolicy.mode(bundleURL: appURL, info: info),
            .releasesPage(reason: AppUpdatePolicy.unsignedBuildReason)
        )
        info["SUFeedURL"] = "http://127.0.0.1:8123/appcast.xml"
        XCTAssertEqual(AppUpdatePolicy.mode(bundleURL: appURL, info: info), .inApp)
    }

    func testLastCheckedWording() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(AppUpdateCopy.lastChecked(nil, now: now), "Not checked yet")
        XCTAssertEqual(AppUpdateCopy.lastChecked(now.addingTimeInterval(-20), now: now), "Checked just now")
        XCTAssertTrue(AppUpdateCopy.lastChecked(now.addingTimeInterval(-7_200), now: now).hasPrefix("Checked "))
    }

    func testReleaseVersionShowsOnceWhenItIsAlsoTheBuildNumber() {
        XCTAssertEqual(AppVersionInfo(version: "0.1.11", build: "0.1.11").displayValue, "0.1.11")
        XCTAssertEqual(AppVersionInfo(version: "0.1.10", build: "5").displayValue, "0.1.10 (5)")
    }

    func testReleaseInfoPlistTurnsOnSignedChecks() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Metadata/Info.plist")
            .standardizedFileURL
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        XCTAssertEqual(plist["SUFeedURL"] as? String, "https://glasstunnel.io/appcast.xml")
        XCTAssertEqual(plist["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(plist["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertNil(plist["SUPublicEDKey"], "Only build-app.sh adds the key, and only to Developer ID builds")
    }
}
