#if os(macOS)
enum AccountRoutePolicy {
    enum Route: Equatable {
        case checkingAccount
        case signIn
        case workspace
    }

    static func route(
        linkedAccount: AccountLinkController.LinkedAccountSummary?,
        identityChecked: Bool,
        sessionManagerState: String
    ) -> Route {
        if linkedAccount != nil {
            return .workspace
        }
        if identityChecked || sessionManagerState == "error" {
            return .signIn
        }
        return .checkingAccount
    }
}
#endif
