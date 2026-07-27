import XCTest
@testable import GlassTunnelApp
@testable import GTTransport

@MainActor
final class AccountLinkControllerTests: XCTestCase {
    func testSummaryMapsLinkedHostIdentityForAccountUI() {
        let summary = AccountLinkController.summary(from: SessionManager.HostIdentity(
            linked: true,
            userID: "user-123",
            email: "dev@example.com",
            displayName: "Dev User",
            avatarURL: "https://example.com/avatar.png"
        ))

        XCTAssertEqual(summary?.userID, "user-123")
        XCTAssertEqual(summary?.email, "dev@example.com")
        XCTAssertEqual(summary?.displayName, "Dev User")
        XCTAssertEqual(summary?.avatarURL, "https://example.com/avatar.png")
        XCTAssertEqual(AccountLinkController.accountStatusSummary(for: summary), "dev@example.com")
    }

    func testSummaryFallsBackToEmailOrDefaultName() {
        let emailSummary = AccountLinkController.summary(from: SessionManager.HostIdentity(
            linked: true,
            userID: "user-email",
            email: "dev@example.com",
            displayName: nil,
            avatarURL: nil
        ))
        XCTAssertEqual(emailSummary?.displayName, "dev@example.com")

        let defaultSummary = AccountLinkController.summary(from: SessionManager.HostIdentity(
            linked: true,
            userID: "user-default",
            email: nil,
            displayName: nil,
            avatarURL: nil
        ))
        XCTAssertEqual(defaultSummary?.displayName, "Glasstunnel user")
        XCTAssertEqual(AccountLinkController.accountStatusSummary(for: defaultSummary), "Glasstunnel user")
    }

    func testSummaryRejectsUnlinkedOrIncompleteIdentity() {
        XCTAssertNil(AccountLinkController.summary(from: SessionManager.HostIdentity(
            linked: false,
            userID: "user-123",
            email: "dev@example.com",
            displayName: "Dev User",
            avatarURL: nil
        )))

        XCTAssertNil(AccountLinkController.summary(from: SessionManager.HostIdentity(
            linked: true,
            userID: nil,
            email: "dev@example.com",
            displayName: "Dev User",
            avatarURL: nil
        )))
    }

    func testLinkedAccountSummaryCacheRoundTripsForRelaunchBootstrap() {
        let (suiteName, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let summary = linkedSummary()

        AccountLinkController.cacheLinkedAccountSummary(summary, defaults: defaults)

        XCTAssertEqual(AccountLinkController.loadCachedLinkedAccountSummary(defaults: defaults), summary)
    }

    func testLinkedAccountSummaryCacheClearsWhenAccountIsUnlinked() {
        let (suiteName, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AccountLinkController.cacheLinkedAccountSummary(linkedSummary(), defaults: defaults)
        AccountLinkController.cacheLinkedAccountSummary(nil, defaults: defaults)

        XCTAssertNil(AccountLinkController.loadCachedLinkedAccountSummary(defaults: defaults))
    }

    func testLinkedAccountSummaryCacheIgnoresInvalidData() {
        let (suiteName, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: "app.cachedLinkedAccountSummary")

        XCTAssertNil(AccountLinkController.loadCachedLinkedAccountSummary(defaults: defaults))
    }

    func testWaitsForAccountIdentityBeforeShowingSignInGate() {
        XCTAssertTrue(AccountLinkController.shouldWaitForAccountIdentity(
            linkedAccount: nil,
            identityChecked: false,
            sessionManagerState: "connecting"
        ))

        XCTAssertFalse(AccountLinkController.shouldWaitForAccountIdentity(
            linkedAccount: nil,
            identityChecked: true,
            sessionManagerState: "connected"
        ))

        XCTAssertFalse(AccountLinkController.shouldWaitForAccountIdentity(
            linkedAccount: linkedSummary(),
            identityChecked: false,
            sessionManagerState: "connected"
        ))

        XCTAssertFalse(AccountLinkController.shouldWaitForAccountIdentity(
            linkedAccount: nil,
            identityChecked: false,
            sessionManagerState: "error"
        ))
    }

    private func linkedSummary() -> AccountLinkController.LinkedAccountSummary {
        AccountLinkController.LinkedAccountSummary(
            userID: "user-123",
            email: "dev@example.com",
            displayName: "Dev User",
            avatarURL: nil
        )
    }

    private func isolatedDefaults() -> (String, UserDefaults) {
        let suiteName = "AccountLinkControllerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }
}
