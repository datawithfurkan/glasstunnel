import XCTest
@testable import GlassTunnelApp

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testEnableAndDisableReflectServiceState() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertNil(controller.feedback)

        controller.setEnabled(false)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertNil(controller.feedback)
    }

    func testRefreshUsesExternalSystemStateAsSourceOfTruth() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(service: service)

        service.status = .enabled
        controller.refresh()

        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.status, .enabled)
    }

    func testRegistrationFailureRestoresTruthfulDisabledState() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        service.registerError = TestLaunchAtLoginError.denied
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertEqual(controller.feedback?.tone, .error)
        XCTAssertTrue(controller.feedback?.message.contains("Could not update Launch at Login") == true)
    }

    func testRequiresApprovalDoesNotAppearEnabled() {
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.feedback?.tone, .information)
        XCTAssertTrue(controller.feedback?.message.contains("System Settings") == true)
    }

    func testUnregisterFailureKeepsTruthfulEnabledState() {
        let service = FakeLaunchAtLoginService(status: .enabled)
        service.unregisterError = TestLaunchAtLoginError.denied
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(false)

        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertEqual(controller.feedback?.tone, .error)
    }
}

private enum TestLaunchAtLoginError: LocalizedError {
    case denied

    var errorDescription: String? { "Denied for test" }
}

private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginRegistrationStatus
    var registerError: Error?
    var unregisterError: Error?
    var registerCount = 0
    var unregisterCount = 0

    init(status: LaunchAtLoginRegistrationStatus) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}
