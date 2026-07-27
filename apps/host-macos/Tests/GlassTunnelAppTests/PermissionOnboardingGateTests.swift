import XCTest
@testable import GlassTunnelApp
@testable import GTSecurity

final class PermissionOnboardingGateTests: XCTestCase {
    func testUncheckedPermissionStateKeepsUserInPermissionOnboarding() {
        XCTAssertTrue(PermissionOnboardingGate.shouldShowPermissionOnboarding(
            introComplete: true,
            permissionOnboardingComplete: true,
            permissionState: .unchecked
        ))
    }

    func testStoredOnboardingCompletionDoesNotBypassMissingLivePermissions() {
        let missingScreenRecording = Permissions.RequiredState(
            screenRecording: .denied,
            accessibility: .authorized,
            checked: true
        )
        let missingAccessibility = Permissions.RequiredState(
            screenRecording: .authorized,
            accessibility: .denied,
            checked: true
        )

        XCTAssertTrue(PermissionOnboardingGate.shouldShowPermissionOnboarding(
            introComplete: true,
            permissionOnboardingComplete: true,
            permissionState: missingScreenRecording
        ))
        XCTAssertTrue(PermissionOnboardingGate.shouldShowPermissionOnboarding(
            introComplete: true,
            permissionOnboardingComplete: true,
            permissionState: missingAccessibility
        ))
    }

    func testAlreadyGrantedLivePermissionsCanContinuePastPermissionOnboarding() {
        let granted = Permissions.RequiredState(
            screenRecording: .authorized,
            accessibility: .authorized,
            checked: true
        )

        XCTAssertFalse(PermissionOnboardingGate.shouldShowPermissionOnboarding(
            introComplete: true,
            permissionOnboardingComplete: true,
            permissionState: granted
        ))
    }

    func testContinueRequiresFreshCheckedGrantedPermissions() {
        let granted = Permissions.RequiredState(
            screenRecording: .authorized,
            accessibility: .authorized,
            checked: true
        )
        let uncheckedGranted = Permissions.RequiredState(
            screenRecording: .authorized,
            accessibility: .authorized,
            checked: false
        )

        XCTAssertTrue(PermissionOnboardingGate.canContinueToAuth(permissionState: granted))
        XCTAssertFalse(PermissionOnboardingGate.canContinueToAuth(permissionState: uncheckedGranted))
        XCTAssertFalse(PermissionOnboardingGate.canContinueToAuth(permissionState: .unchecked))
    }
}
