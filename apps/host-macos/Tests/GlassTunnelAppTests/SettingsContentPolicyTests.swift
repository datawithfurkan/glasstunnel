import XCTest
@testable import GlassTunnelApp

final class SettingsContentPolicyTests: XCTestCase {
    @MainActor
    func testHostReadOnlyPreferenceSurvivesDefaultsReload() {
        let name = "SettingsContentPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(AppState.loadReadOnly(defaults: defaults))
        defaults.set(true, forKey: "app.hostReadOnly")
        XCTAssertTrue(AppState.loadReadOnly(defaults: UserDefaults(suiteName: name)!))
        defaults.set(false, forKey: "app.hostReadOnly")
        XCTAssertFalse(AppState.loadReadOnly(defaults: defaults))
    }

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
