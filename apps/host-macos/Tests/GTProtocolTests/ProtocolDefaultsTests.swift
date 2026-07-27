import XCTest
@testable import GTProtocol

final class ProtocolDefaultsTests: XCTestCase {
    func testSignalingDefaultIsProductionWhenNoOverrideIsSet() throws {
        if ProcessInfo.processInfo.environment["GLASSTUNNEL_SIGNALING_URL"] != nil {
            throw XCTSkip("GLASSTUNNEL_SIGNALING_URL overrides the signaling default.")
        }

        XCTAssertEqual(
            GlasstunnelProtocol.defaultSignalingURL.absoluteString,
            "wss://signaling.glasstunnel.io/signal"
        )
    }

    func testHostedWebAppDefaultIsProductionWhenNoOverrideIsSet() throws {
        if ProcessInfo.processInfo.environment["GLASSTUNNEL_WEB_APP_URL"] != nil {
            throw XCTSkip("GLASSTUNNEL_WEB_APP_URL overrides the hosted web app default.")
        }

        XCTAssertEqual(
            GlasstunnelProtocol.defaultWebAppURL.absoluteString,
            "https://app.glasstunnel.io"
        )
    }
}
