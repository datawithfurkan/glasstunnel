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
    }

    private static let cachedLinkedAccountKey = "app.cachedLinkedAccountSummary"

    static func summary(from identity: SessionManager.HostIdentity) -> LinkedAccountSummary? {
        guard identity.linked, let userID = identity.userID else { return nil }
        return LinkedAccountSummary(
            userID: userID,
            email: identity.email ?? "",
            displayName: identity.displayName ?? identity.email ?? "Glasstunnel user",
            avatarURL: identity.avatarURL
        )
    }

    static func accountStatusSummary(for linkedAccount: LinkedAccountSummary?) -> String {
        guard let linkedAccount else { return "This Mac is not linked to an account yet." }
        return linkedAccount.email.isEmpty ? linkedAccount.displayName : linkedAccount.email
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
