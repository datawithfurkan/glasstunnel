import Foundation
import SwiftUI
import GTProtocol
import GTTransport
import GTSecurity

/// Manages account-linking business logic. State is owned by AppState so
/// SwiftUI can track @Published properties directly.
@MainActor
final class AccountLinkController {
    struct LinkedAccountSummary: Codable, Equatable {
        let userID: String
        let email: String
        let displayName: String
        let avatarURL: String?
        /// The account's name for this Mac. Optional so summaries cached
        /// before the server sent it still decode.
        var hostLabel: String? = nil
    }

    /// What the account UI shows after a `host_identity` message.
    struct IdentityState: Equatable {
        var linkedAccount: LinkedAccountSummary?
        var showsRemovedFromAccountNotice: Bool
        /// The owner dismissed the notice for this removal. The server can
        /// report the removal again when the Mac reconnects; that does not
        /// bring a dismissed notice back. The next link starts over.
        var removedFromAccountNoticeDismissed: Bool = false
    }

    static let removedFromAccountNotice =
        "This Mac was removed from your account on another device. Link it again to use it remotely."

    private static let cachedLinkedAccountKey = "app.cachedLinkedAccountSummary"
    private static let removedFromAccountNoticeKey = "app.removedFromAccountNotice"
    private static let removedFromAccountNoticeDismissedKey = "app.removedFromAccountNoticeDismissed"

    static func summary(from identity: SessionManager.HostIdentity) -> LinkedAccountSummary? {
        guard identity.linked, let userID = identity.userID else { return nil }
        return LinkedAccountSummary(
            userID: userID,
            email: identity.email ?? "",
            displayName: identity.displayName ?? identity.email ?? "Glasstunnel user",
            avatarURL: identity.avatarURL,
            hostLabel: identity.hostLabel
        )
    }

    /// Applies a server identity. A linked identity replaces the account
    /// (including a renamed Mac) and clears the removal notice. Any unlinked
    /// identity clears the account as before; only a removal from another
    /// device raises the notice, whether it arrives live or when the Mac
    /// reconnects, unless the owner already dismissed it for this removal.
    /// Other reasons leave the notice as it was.
    static func identityState(
        after identity: SessionManager.HostIdentity,
        from current: IdentityState
    ) -> IdentityState {
        if let summary = summary(from: identity) {
            return IdentityState(linkedAccount: summary, showsRemovedFromAccountNotice: false)
        }
        let raisesNotice = identity.wasRemovedFromAccount && !current.removedFromAccountNoticeDismissed
        return IdentityState(
            linkedAccount: nil,
            showsRemovedFromAccountNotice: raisesNotice || current.showsRemovedFromAccountNotice,
            removedFromAccountNoticeDismissed: current.removedFromAccountNoticeDismissed
        )
    }

    /// Hides the removal notice until the Mac is linked again.
    static func dismissingRemovedFromAccountNotice(_ current: IdentityState) -> IdentityState {
        IdentityState(
            linkedAccount: current.linkedAccount,
            showsRemovedFromAccountNotice: false,
            removedFromAccountNoticeDismissed: current.showsRemovedFromAccountNotice
                || current.removedFromAccountNoticeDismissed
        )
    }

    static func accountStatusSummary(for linkedAccount: LinkedAccountSummary?) -> String {
        guard let linkedAccount else { return "This Mac is not linked to an account yet." }
        return linkedAccount.email.isEmpty ? linkedAccount.displayName : linkedAccount.email
    }

    /// The line that tells the owner what phones call this Mac, or nil when
    /// the server has not sent a name.
    static func accountNameLine(for linkedAccount: LinkedAccountSummary?) -> String? {
        guard let hostLabel = linkedAccount?.hostLabel, !hostLabel.isEmpty else { return nil }
        return "Shown in your account as \(hostLabel)"
    }

    static func cacheLinkedAccountSummary(
        _ summary: LinkedAccountSummary?,
        defaults: UserDefaults = .standard
    ) {
        guard let summary else {
            defaults.removeObject(forKey: cachedLinkedAccountKey)
            return
        }
        guard let encoded = try? JSONEncoder().encode(summary) else { return }
        defaults.set(encoded, forKey: cachedLinkedAccountKey)
    }

    static func loadCachedLinkedAccountSummary(
        defaults: UserDefaults = .standard
    ) -> LinkedAccountSummary? {
        guard let data = defaults.data(forKey: cachedLinkedAccountKey) else { return nil }
        return try? JSONDecoder().decode(LinkedAccountSummary.self, from: data)
    }

    /// The removal notice survives a relaunch so an owner who was away still
    /// learns why the Mac is signed out.
    static func cacheRemovedFromAccountNotice(
        _ shows: Bool,
        defaults: UserDefaults = .standard
    ) {
        if shows {
            defaults.set(true, forKey: removedFromAccountNoticeKey)
        } else {
            defaults.removeObject(forKey: removedFromAccountNoticeKey)
        }
    }

    static func loadRemovedFromAccountNotice(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: removedFromAccountNoticeKey)
    }

    /// A dismissal survives a relaunch too, so a removal the server reports
    /// again on the next connection stays dismissed.
    static func cacheRemovedFromAccountNoticeDismissed(
        _ dismissed: Bool,
        defaults: UserDefaults = .standard
    ) {
        if dismissed {
            defaults.set(true, forKey: removedFromAccountNoticeDismissedKey)
        } else {
            defaults.removeObject(forKey: removedFromAccountNoticeDismissedKey)
        }
    }

    static func loadRemovedFromAccountNoticeDismissed(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: removedFromAccountNoticeDismissedKey)
    }

    static func shouldWaitForAccountIdentity(
        linkedAccount: LinkedAccountSummary?,
        identityChecked: Bool,
        sessionManagerState: String
    ) -> Bool {
        AccountRoutePolicy.route(
            linkedAccount: linkedAccount,
            identityChecked: identityChecked,
            sessionManagerState: sessionManagerState
        ) == .checkingAccount
    }
}
