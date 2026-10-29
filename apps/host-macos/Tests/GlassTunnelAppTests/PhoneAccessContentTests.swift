import XCTest
@testable import GlassTunnelApp

final class PhoneAccessContentTests: XCTestCase {
    func testDisplayAddressDropsSchemeAndTrailingSlash() {
        XCTAssertEqual(
            PhoneAccessContent.displayAddress(for: URL(string: "https://app.glasstunnel.io")!),
            "app.glasstunnel.io"
        )
        XCTAssertEqual(
            PhoneAccessContent.displayAddress(for: URL(string: "https://app.glasstunnel.io/")!),
            "app.glasstunnel.io"
        )
    }

    func testDisplayAddressKeepsPortAndPathForSelfHostedApps() {
        XCTAssertEqual(
            PhoneAccessContent.displayAddress(for: URL(string: "http://localhost:5179")!),
            "localhost:5179"
        )
        XCTAssertEqual(
            PhoneAccessContent.displayAddress(for: URL(string: "https://tunnel.example.com/glasstunnel/")!),
            "tunnel.example.com/glasstunnel"
        )
    }

    func testStepsNameTheAddressAccountAndMac() {
        let steps = PhoneAccessContent.steps(
            address: "app.glasstunnel.io",
            accountEmail: "owner@example.com",
            macName: "Studio Mac"
        )

        XCTAssertEqual(steps.count, 3)
        XCTAssertTrue(steps[0].contains("app.glasstunnel.io"))
        XCTAssertTrue(steps[1].contains("owner@example.com"))
        XCTAssertTrue(steps[2].contains("Studio Mac"))
    }

    func testStepsFallBackWhenTheAccountIsNotKnownYet() {
        let steps = PhoneAccessContent.steps(address: "app.glasstunnel.io", accountEmail: "", macName: nil)

        XCTAssertEqual(steps[1], "Sign in with the same account as this Mac.")
        XCTAssertEqual(steps[2], "Choose this Mac, then open an app or its screen.")
    }

    func testCopyAvoidsInternalTerms() {
        let text = [
            PhoneAccessContent.buttonTitle,
            PhoneAccessContent.buttonHelp,
            PhoneAccessContent.title,
            PhoneAccessContent.subtitle,
            PhoneAccessContent.signInNextStep(address: "app.glasstunnel.io")
        ]
        .joined(separator: " ")

        for internalTerm in OnboardingContentPolicy.blockedPrimaryPathTerms {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(internalTerm), "Phone access copy should not expose \(internalTerm)")
        }
    }

    func testQRCodeIsSquareAndSharp() throws {
        let image = try XCTUnwrap(PhoneAccessQRCode.cgImage(for: URL(string: "https://app.glasstunnel.io")!))

        XCTAssertEqual(image.width, image.height)
        XCTAssertGreaterThanOrEqual(image.width, 200)
        XCTAssertEqual(image.width % 10, 0, "Whole-pixel scaling keeps every module the same size")
    }
}
