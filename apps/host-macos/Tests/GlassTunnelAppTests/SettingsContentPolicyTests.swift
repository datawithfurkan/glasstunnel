import XCTest
@testable import GlassTunnelApp

final class SettingsContentPolicyTests: XCTestCase {
    func testNormalSettingsContentDoesNotExposeProtocolDetails() {
        let normalText = SettingsContentPolicy.normalPathText.joined(separator: " ")

        for internalTerm in SettingsContentPolicy.internalConnectivityTerms {
            XCTAssertFalse(
                normalText.localizedCaseInsensitiveContains(internalTerm),
                "Normal settings should not expose \(internalTerm)"
            )
        }
    }
}
