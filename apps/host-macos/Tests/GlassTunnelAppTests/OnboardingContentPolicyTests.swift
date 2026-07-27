import XCTest
@testable import GlassTunnelApp
@testable import GTSecurity

final class OnboardingContentPolicyTests: XCTestCase {
    func testFirstRunIntroComesBeforePermissionAccessEvenWhenPermissionsAreGranted() {
        let granted = Permissions.RequiredState(
            screenRecording: .authorized,
            accessibility: .authorized,
            checked: true
        )

        XCTAssertTrue(PermissionOnboardingGate.shouldShowPermissionOnboarding(
            introComplete: false,
            permissionOnboardingComplete: true,
            permissionState: granted
        ))
    }

    func testIntroCopyStatesCoreProductPurposeWithoutInternalTerms() {
        let introText = OnboardingContentPolicy.introPages
            .flatMap { [$0.title, $0.subtitle].compactMap { $0 } }
            .joined(separator: " ")
        let permissionText = [
            OnboardingContentPolicy.permissionTitle,
            OnboardingContentPolicy.permissionSubtitle
        ].joined(separator: " ")
        let primaryPathText = "\(introText) \(permissionText)"

        XCTAssertGreaterThanOrEqual(OnboardingContentPolicy.introPages.count, 2)
        XCTAssertTrue(primaryPathText.localizedCaseInsensitiveContains("coding agents"))
        XCTAssertTrue(primaryPathText.localizedCaseInsensitiveContains("phone"))
        XCTAssertTrue(primaryPathText.localizedCaseInsensitiveContains("prompts"))
        XCTAssertTrue(primaryPathText.localizedCaseInsensitiveContains("Mac screen"))

        for internalTerm in OnboardingContentPolicy.blockedPrimaryPathTerms {
            XCTAssertFalse(
                primaryPathText.localizedCaseInsensitiveContains(internalTerm),
                "First-run onboarding should not expose \(internalTerm)"
            )
        }
    }
}
