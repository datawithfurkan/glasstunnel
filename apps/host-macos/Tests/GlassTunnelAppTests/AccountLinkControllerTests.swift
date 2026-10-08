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

    func testSummaryCarriesTheAccountNameForThisMac() {
        let summary = AccountLinkController.summary(from: linkedIdentity(hostLabel: "Studio Mac"))

        XCTAssertEqual(summary?.hostLabel, "Studio Mac")
        XCTAssertEqual(AccountLinkController.accountNameLine(for: summary), "Shown in your account as Studio Mac")
    }

    func testAccountNameLineIsHiddenWithoutANameOrAccount() {
        XCTAssertNil(AccountLinkController.accountNameLine(for: nil))
        XCTAssertNil(AccountLinkController.accountNameLine(for: linkedSummary()))
        XCTAssertNil(AccountLinkController.accountNameLine(for: AccountLinkController.summary(
            from: linkedIdentity(hostLabel: nil)
        )))
    }

    func testRenameUpdatesTheNameShownForThisMac() {
        let linked = AccountLinkController.identityState(
            after: linkedIdentity(hostLabel: "Studio Mac mini"),
            from: .init(linkedAccount: nil, showsRemovedFromAccountNotice: false)
        )
        XCTAssertEqual(linked.linkedAccount?.hostLabel, "Studio Mac mini")

        let renamed = AccountLinkController.identityState(after: linkedIdentity(hostLabel: "Office Mac"), from: linked)

        XCTAssertEqual(renamed.linkedAccount?.userID, "user-123")
        XCTAssertEqual(renamed.linkedAccount?.hostLabel, "Office Mac")
        XCTAssertFalse(renamed.showsRemovedFromAccountNotice)
        XCTAssertEqual(
            AccountLinkController.accountNameLine(for: renamed.linkedAccount),
            "Shown in your account as Office Mac"
        )
    }

    func testRemovalFromAnotherDeviceClearsTheAccountAndShowsTheNotice() {
        let linked = AccountLinkController.IdentityState(
            linkedAccount: linkedSummary(hostLabel: "Studio Mac"),
            showsRemovedFromAccountNotice: false
        )

        let removed = AccountLinkController.identityState(after: unlinkedIdentity(reason: "removed_from_account"), from: linked)

        XCTAssertNil(removed.linkedAccount)
        XCTAssertTrue(removed.showsRemovedFromAccountNotice)
        XCTAssertEqual(
            AccountLinkController.removedFromAccountNotice,
            "This Mac was removed from your account on another device. Link it again to use it remotely."
        )
        // The Mac lands on the sign-in screen, which is where the notice shows.
        XCTAssertEqual(
            AccountRoutePolicy.route(linkedAccount: removed.linkedAccount, identityChecked: true, sessionManagerState: "connected"),
            .signIn
        )
    }

    func testNormalUnlinkClearsTheAccountWithoutTheNotice() {
        let linked = AccountLinkController.IdentityState(
            linkedAccount: linkedSummary(hostLabel: "Studio Mac"),
            showsRemovedFromAccountNotice: false
        )

        let unlinked = AccountLinkController.identityState(after: unlinkedIdentity(reason: nil), from: linked)
        XCTAssertNil(unlinked.linkedAccount)
        XCTAssertFalse(unlinked.showsRemovedFromAccountNotice)

        let unknownReason = AccountLinkController.identityState(after: unlinkedIdentity(reason: "maintenance"), from: linked)
        XCTAssertNil(unknownReason.linkedAccount)
        XCTAssertFalse(unknownReason.showsRemovedFromAccountNotice)
    }

    func testRemovalNoticeStaysUntilTheMacIsLinkedAgain() {
        let removed = AccountLinkController.IdentityState(linkedAccount: nil, showsRemovedFromAccountNotice: true)

        // Reconnecting while still unlinked keeps the notice.
        let reconnected = AccountLinkController.identityState(after: unlinkedIdentity(reason: nil), from: removed)
        XCTAssertNil(reconnected.linkedAccount)
        XCTAssertTrue(reconnected.showsRemovedFromAccountNotice)

        let relinked = AccountLinkController.identityState(after: linkedIdentity(hostLabel: "Studio Mac"), from: reconnected)
        XCTAssertEqual(relinked.linkedAccount?.hostLabel, "Studio Mac")
        XCTAssertFalse(relinked.showsRemovedFromAccountNotice)
    }

    func testRemovalReportedOnReconnectAfterARelaunchShowsTheNotice() {
        // The Mac was offline or quit when the owner removed it. It relaunches
        // with the cached account and learns of the removal on reconnect.
        let (suiteName, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        AccountLinkController.cacheLinkedAccountSummary(linkedSummary(hostLabel: "Studio Mac mini"), defaults: defaults)
        let relaunched = AccountLinkController.IdentityState(
            linkedAccount: AccountLinkController.loadCachedLinkedAccountSummary(defaults: defaults),
            showsRemovedFromAccountNotice: AccountLinkController.loadRemovedFromAccountNotice(defaults: defaults),
            removedFromAccountNoticeDismissed: AccountLinkController.loadRemovedFromAccountNoticeDismissed(defaults: defaults)
        )
        XCTAssertNotNil(relaunched.linkedAccount)
        XCTAssertFalse(relaunched.showsRemovedFromAccountNotice)

        let removed = AccountLinkController.identityState(after: unlinkedIdentity(reason: "removed_from_account"), from: relaunched)

        XCTAssertNil(removed.linkedAccount)
        XCTAssertTrue(removed.showsRemovedFromAccountNotice)
        XCTAssertEqual(
            AccountRoutePolicy.route(linkedAccount: removed.linkedAccount, identityChecked: true, sessionManagerState: "connected"),
            .signIn
        )
        AccountLinkController.cacheLinkedAccountSummary(removed.linkedAccount, defaults: defaults)
        AccountLinkController.cacheRemovedFromAccountNotice(removed.showsRemovedFromAccountNotice, defaults: defaults)
        XCTAssertNil(AccountLinkController.loadCachedLinkedAccountSummary(defaults: defaults))
        XCTAssertTrue(AccountLinkController.loadRemovedFromAccountNotice(defaults: defaults))
    }

    func testDismissedNoticeStaysHiddenWhenAReconnectReportsTheRemovalAgain() {
        let removed = AccountLinkController.identityState(
            after: unlinkedIdentity(reason: "removed_from_account"),
            from: .init(linkedAccount: linkedSummary(hostLabel: "Studio Mac"), showsRemovedFromAccountNotice: false)
        )
        XCTAssertTrue(removed.showsRemovedFromAccountNotice)

        // Reported again before the owner dismissed it: still one notice.
        let repeated = AccountLinkController.identityState(after: unlinkedIdentity(reason: "removed_from_account"), from: removed)
        XCTAssertEqual(repeated, removed)

        let dismissed = AccountLinkController.dismissingRemovedFromAccountNotice(repeated)
        XCTAssertFalse(dismissed.showsRemovedFromAccountNotice)
        XCTAssertTrue(dismissed.removedFromAccountNoticeDismissed)

        let reconnected = AccountLinkController.identityState(after: unlinkedIdentity(reason: "removed_from_account"), from: dismissed)
        XCTAssertNil(reconnected.linkedAccount)
        XCTAssertFalse(reconnected.showsRemovedFromAccountNotice)
        XCTAssertTrue(reconnected.removedFromAccountNoticeDismissed)

        // Linking again starts over: a later removal shows the notice again.
        let relinked = AccountLinkController.identityState(after: linkedIdentity(hostLabel: "Studio Mac"), from: reconnected)
        XCTAssertFalse(relinked.showsRemovedFromAccountNotice)
        XCTAssertFalse(relinked.removedFromAccountNoticeDismissed)
        let removedAgain = AccountLinkController.identityState(after: unlinkedIdentity(reason: "removed_from_account"), from: relinked)
        XCTAssertTrue(removedAgain.showsRemovedFromAccountNotice)
    }

    func testDismissingWithoutANoticeChangesNothing() {
        let linked = AccountLinkController.IdentityState(
            linkedAccount: linkedSummary(hostLabel: "Studio Mac"),
            showsRemovedFromAccountNotice: false
        )

        XCTAssertEqual(AccountLinkController.dismissingRemovedFromAccountNotice(linked), linked)
    }

    func testRemovalNoticeDismissalCacheRoundTripsAndClears() {
        let (suiteName, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(AccountLinkController.loadRemovedFromAccountNoticeDismissed(defaults: defaults))
        AccountLinkController.cacheRemovedFromAccountNoticeDismissed(true, defaults: defaults)
        XCTAssertTrue(AccountLinkController.loadRemovedFromAccountNoticeDismissed(defaults: defaults))
        // The notice flag is stored separately.
        XCTAssertFalse(AccountLinkController.loadRemovedFromAccountNotice(defaults: defaults))
        AccountLinkController.cacheRemovedFromAccountNoticeDismissed(false, defaults: defaults)
        XCTAssertFalse(AccountLinkController.loadRemovedFromAccountNoticeDismissed(defaults: defaults))
    }

    func testRemovalNoticeCacheRoundTripsAndClears() {
        let (suiteName, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(AccountLinkController.loadRemovedFromAccountNotice(defaults: defaults))
        AccountLinkController.cacheRemovedFromAccountNotice(true, defaults: defaults)
        XCTAssertTrue(AccountLinkController.loadRemovedFromAccountNotice(defaults: defaults))
        AccountLinkController.cacheRemovedFromAccountNotice(false, defaults: defaults)
        XCTAssertFalse(AccountLinkController.loadRemovedFromAccountNotice(defaults: defaults))
    }

    func testCachedSummaryKeepsTheAccountNameForThisMac() {
        let (suiteName, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let summary = linkedSummary(hostLabel: "Studio Mac")

        AccountLinkController.cacheLinkedAccountSummary(summary, defaults: defaults)

        XCTAssertEqual(AccountLinkController.loadCachedLinkedAccountSummary(defaults: defaults)?.hostLabel, "Studio Mac")
    }

    func testSummaryCachedBeforeMacNamesStillLoads() {
        let (suiteName, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = #"{"userID":"user-123","email":"dev@example.com","displayName":"Dev User"}"#
        defaults.set(Data(legacy.utf8), forKey: "app.cachedLinkedAccountSummary")

        let loaded = AccountLinkController.loadCachedLinkedAccountSummary(defaults: defaults)

        XCTAssertEqual(loaded, linkedSummary())
        XCTAssertNil(loaded?.hostLabel)
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

    private func linkedSummary(hostLabel: String? = nil) -> AccountLinkController.LinkedAccountSummary {
        AccountLinkController.LinkedAccountSummary(
            userID: "user-123",
            email: "dev@example.com",
            displayName: "Dev User",
            avatarURL: nil,
            hostLabel: hostLabel
        )
    }

    private func linkedIdentity(hostLabel: String?) -> SessionManager.HostIdentity {
        SessionManager.HostIdentity(
            linked: true,
            userID: "user-123",
            email: "dev@example.com",
            displayName: "Dev User",
            avatarURL: nil,
            hostLabel: hostLabel
        )
    }

    private func unlinkedIdentity(reason: String?) -> SessionManager.HostIdentity {
        SessionManager.HostIdentity(
            linked: false,
            userID: nil,
            email: nil,
            displayName: nil,
            avatarURL: nil,
            reason: reason
        )
    }

    private func isolatedDefaults() -> (String, UserDefaults) {
        let suiteName = "AccountLinkControllerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }
}
