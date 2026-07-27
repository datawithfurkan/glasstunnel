import XCTest
@testable import GlassTunnelApp

final class KeepAwakeControllerTests: XCTestCase {
    func testEnableCreatesOneAssertionAndDisableReleasesIt() throws {
        let manager = FakeKeepAwakeAssertionManager(assertionID: 42)
        let controller = KeepAwakeController(manager: manager)

        try controller.setEnabled(true)
        try controller.setEnabled(true)

        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.assertionID, 42)
        XCTAssertEqual(manager.createdReasons.count, 1)
        XCTAssertEqual(manager.releasedIDs, [])

        try controller.setEnabled(false)

        XCTAssertFalse(controller.isActive)
        XCTAssertNil(controller.assertionID)
        XCTAssertEqual(manager.releasedIDs, [42])
    }

    func testEnableFailureDoesNotBecomeActive() {
        let manager = FakeKeepAwakeAssertionManager(error: KeepAwakeControllerError.assertionFailed(-1))
        let controller = KeepAwakeController(manager: manager)

        XCTAssertThrowsError(try controller.setEnabled(true)) { error in
            XCTAssertEqual(error as? KeepAwakeControllerError, .assertionFailed(-1))
        }
        XCTAssertFalse(controller.isActive)
        XCTAssertNil(controller.assertionID)
        XCTAssertEqual(manager.releasedIDs, [])
    }
}

private final class FakeKeepAwakeAssertionManager: KeepAwakeAssertionManaging {
    var assertionID: UInt32
    var error: Error?
    var createdReasons: [String] = []
    var releasedIDs: [UInt32] = []

    init(assertionID: UInt32 = 1, error: Error? = nil) {
        self.assertionID = assertionID
        self.error = error
    }

    func createAssertion(reason: String) throws -> UInt32 {
        createdReasons.append(reason)
        if let error {
            throw error
        }
        return assertionID
    }

    func releaseAssertion(_ assertionID: UInt32) {
        releasedIDs.append(assertionID)
    }
}
