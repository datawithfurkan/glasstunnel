#if os(macOS)
import GTSecurity

enum PermissionOnboardingGate {
    static func shouldShowPermissionOnboarding(
        introComplete: Bool,
        permissionOnboardingComplete: Bool,
        permissionState: Permissions.RequiredState
    ) -> Bool {
        !introComplete
            || !permissionState.checked
            || !permissionState.allGranted
            || !permissionOnboardingComplete
    }

    static func canContinueToAuth(permissionState: Permissions.RequiredState) -> Bool {
        permissionState.checked && permissionState.allGranted
    }
}
#endif
