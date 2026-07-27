import XCTest
@testable import GTSecurity

#if os(macOS)
final class PermissionsTests: XCTestCase {
    func testUncheckedRequiredStateIsNotGranted() {
        let state = Permissions.RequiredState.unchecked

        XCTAssertFalse(state.checked)
        XCTAssertFalse(state.screenRecordingGranted)
        XCTAssertFalse(state.accessibilityGranted)
        XCTAssertFalse(state.allGranted)
        XCTAssertFalse(state.isGranted(.screenRecording))
        XCTAssertFalse(state.isGranted(.accessibility))
    }

    func testRequiredStateRequiresBothPermissions() {
        let allGranted = Permissions.RequiredState(
            screenRecording: .authorized,
            accessibility: .authorized,
            checked: true
        )
        let screenMissing = Permissions.RequiredState(
            screenRecording: .denied,
            accessibility: .authorized,
            checked: true
        )
        let accessibilityMissing = Permissions.RequiredState(
            screenRecording: .authorized,
            accessibility: .denied,
            checked: true
        )
        let bothMissing = Permissions.RequiredState(
            screenRecording: .denied,
            accessibility: .denied,
            checked: true
        )

        XCTAssertTrue(allGranted.allGranted)
        XCTAssertFalse(screenMissing.allGranted)
        XCTAssertFalse(accessibilityMissing.allGranted)
        XCTAssertFalse(bothMissing.allGranted)
    }

    func testRequiredStateReportsEachPermissionIndependently() {
        let state = Permissions.RequiredState(
            screenRecording: .authorized,
            accessibility: .denied,
            checked: true
        )

        XCTAssertEqual(state.status(for: .screenRecording), .authorized)
        XCTAssertEqual(state.status(for: .accessibility), .denied)
        XCTAssertTrue(state.isGranted(.screenRecording))
        XCTAssertFalse(state.isGranted(.accessibility))
        XCTAssertTrue(state.screenRecordingGranted)
        XCTAssertFalse(state.accessibilityGranted)
    }

    func testScreenRecordingStatusTrustsPreflightGrant() {
        let status = Permissions.screenRecordingStatus(preflight: { true })

        XCTAssertEqual(status, .authorized)
    }

    func testScreenRecordingStatusDeniesWhenPreflightFails() {
        let status = Permissions.screenRecordingStatus(preflight: { false })

        XCTAssertEqual(status, .denied)
    }
}
#endif
