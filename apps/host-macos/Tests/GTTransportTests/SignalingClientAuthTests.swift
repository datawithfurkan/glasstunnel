import XCTest
@testable import GTTransport

final class SignalingClientAuthTests: XCTestCase {
    func testHostReportsItsAppVersionSoTheAccountCanShowIt() {
        let message = SignalingClient.clientAuthMessage(
            deviceID: "gt-0011223344556677",
            publicKeyB64: "cHVibGlj",
            signatureB64: "c2ln",
            role: "host",
            deviceInfo: "Studio Mac mini",
            appVersion: "0.1.11"
        )

        XCTAssertEqual(message["type"] as? String, "client_auth")
        XCTAssertEqual(message["device_id"] as? String, "gt-0011223344556677")
        XCTAssertEqual(message["role"] as? String, "host")
        XCTAssertEqual(message["device_info"] as? String, "Studio Mac mini")
        XCTAssertEqual(message["app_version"] as? String, "0.1.11")
    }

    func testAppVersionIsLeftOutWhenUnknownOrNotAHost() {
        let unknown = SignalingClient.clientAuthMessage(
            deviceID: "gt-0011223344556677",
            publicKeyB64: "cHVibGlj",
            signatureB64: "c2ln",
            role: "host",
            deviceInfo: "Studio Mac mini",
            appVersion: nil
        )
        XCTAssertNil(unknown["app_version"])

        let phone = SignalingClient.clientAuthMessage(
            deviceID: "gt-8899aabbccddeeff",
            publicKeyB64: "cHVibGlj",
            signatureB64: "c2ln",
            role: "client",
            deviceInfo: "Phone",
            appVersion: "0.1.11"
        )
        XCTAssertNil(phone["app_version"])
    }

    func testBundleAppVersionReadsTheMarketingVersionOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("signaling-client-auth-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plist: [String: Any] = ["CFBundleShortVersionString": " 0.1.11 ", "CFBundleVersion": "42"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: directory.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: directory))

        XCTAssertEqual(SignalingClient.bundleAppVersion(bundle), "0.1.11")

        let blankDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("signaling-client-auth-blank-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: blankDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: blankDirectory) }
        let blank = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "  "],
            format: .xml,
            options: 0
        )
        try blank.write(to: blankDirectory.appendingPathComponent("Info.plist"))
        XCTAssertNil(SignalingClient.bundleAppVersion(try XCTUnwrap(Bundle(url: blankDirectory))))
    }
}
