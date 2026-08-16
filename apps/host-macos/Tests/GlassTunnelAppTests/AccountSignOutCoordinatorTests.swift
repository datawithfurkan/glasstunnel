import XCTest
@testable import GlassTunnelApp

final class AccountSignOutCoordinatorTests: XCTestCase {
    func testOfflineSignOutClearsTrustedDevicesAndRotatesIdentity() async throws {
        var events: [String] = []
        let coordinator = AccountSignOutCoordinator<String>(
            clearTrustedDevices: {
                events.append("clear-devices")
            },
            rotateDeviceIdentity: {
                events.append("rotate-identity")
                return "new-identity"
            }
        )

        let outcome = try await coordinator.perform(remoteUnlink: nil)

        XCTAssertEqual(events, ["clear-devices", "rotate-identity"])
        XCTAssertEqual(outcome.replacementIdentity, "new-identity")
        XCTAssertFalse(outcome.remoteUnlinkConfirmed)
        XCTAssertNil(outcome.remoteUnlinkFailureDescription)
    }

    func testSuccessfulRemoteUnlinkStillRotatesLocalIdentityAfterClearingTrustedDevices() async throws {
        var events: [String] = []
        let coordinator = AccountSignOutCoordinator<String>(
            clearTrustedDevices: {
                events.append("clear-devices")
            },
            rotateDeviceIdentity: {
                events.append("rotate-identity")
                return "new-identity"
            }
        )

        let outcome = try await coordinator.perform(remoteUnlink: {
            events.append("remote-unlink")
        })

        XCTAssertEqual(events, ["remote-unlink", "clear-devices", "rotate-identity"])
        XCTAssertEqual(outcome.replacementIdentity, "new-identity")
        XCTAssertTrue(outcome.remoteUnlinkConfirmed)
        XCTAssertNil(outcome.remoteUnlinkFailureDescription)
    }

    func testFailedRemoteUnlinkStillCompletesLocalSignOutWithFreshIdentity() async throws {
        struct RemoteFailure: LocalizedError {
            var errorDescription: String? { "signaling unavailable" }
        }

        var events: [String] = []
        let coordinator = AccountSignOutCoordinator<String>(
            clearTrustedDevices: {
                events.append("clear-devices")
            },
            rotateDeviceIdentity: {
                events.append("rotate-identity")
                return "new-identity"
            }
        )

        let outcome = try await coordinator.perform(remoteUnlink: {
            events.append("remote-unlink")
            throw RemoteFailure()
        })

        XCTAssertEqual(events, ["remote-unlink", "clear-devices", "rotate-identity"])
        XCTAssertEqual(outcome.replacementIdentity, "new-identity")
        XCTAssertFalse(outcome.remoteUnlinkConfirmed)
        XCTAssertEqual(outcome.remoteUnlinkFailureDescription, "signaling unavailable")
    }
}
