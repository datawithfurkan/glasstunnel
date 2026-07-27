import XCTest
@testable import GlassTunnelApp

final class AccountRoutePolicyTests: XCTestCase {
    func testWaitsForAccountIdentityBeforeShowingSignIn() {
        XCTAssertEqual(AccountRoutePolicy.route(
            linkedAccount: nil,
            identityChecked: false,
            sessionManagerState: "connecting"
        ), .checkingAccount)
    }

    func testShowsSignInAfterUnlinkedIdentityIsKnown() {
        XCTAssertEqual(AccountRoutePolicy.route(
            linkedAccount: nil,
            identityChecked: true,
            sessionManagerState: "connected"
        ), .signIn)
    }

    func testShowsSignInWhenAccountCheckCannotComplete() {
        XCTAssertEqual(AccountRoutePolicy.route(
            linkedAccount: nil,
            identityChecked: false,
            sessionManagerState: "error"
        ), .signIn)
    }

    func testLinkedAccountSkipsSignInEvenBeforeIdentityCheckCompletes() {
        XCTAssertEqual(AccountRoutePolicy.route(
            linkedAccount: linkedSummary(),
            identityChecked: false,
            sessionManagerState: "connecting"
        ), .workspace)
    }

    func testCachedLinkedAccountDoesNotFallBackToSignInOnBootstrapError() {
        XCTAssertEqual(AccountRoutePolicy.route(
            linkedAccount: linkedSummary(),
            identityChecked: false,
            sessionManagerState: "error"
        ), .workspace)
    }

    func testWaitsDuringIdleBootstrapBeforeShowingSignIn() {
        XCTAssertEqual(AccountRoutePolicy.route(
            linkedAccount: nil,
            identityChecked: false,
            sessionManagerState: "idle"
        ), .checkingAccount)
    }

    private func linkedSummary() -> AccountLinkController.LinkedAccountSummary {
        AccountLinkController.LinkedAccountSummary(
            userID: "user-123",
            email: "dev@example.com",
            displayName: "Dev User",
            avatarURL: nil
        )
    }
}
