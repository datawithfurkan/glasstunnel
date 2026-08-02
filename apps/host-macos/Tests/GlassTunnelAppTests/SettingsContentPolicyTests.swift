import XCTest
@testable import GlassTunnelApp

final class SettingsContentPolicyTests: XCTestCase {
    func testNormalSettingsKeepsThePrimaryHierarchyVisible() {
        let normalText = SettingsContentPolicy.normalPathText

        for requiredSection in ["General", "Security", "Updates", "Advanced"] {
            XCTAssertTrue(
                normalText.contains(requiredSection),
                "Normal settings should keep the \(requiredSection) section visible"
            )
        }
    }

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
