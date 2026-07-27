#if os(macOS)
import Foundation

struct OnboardingContentPolicy {
    struct IntroPage: Equatable {
        let title: String
        let subtitle: String?
        let primarySymbol: String
    }

    static let introPages: [IntroPage] = [
        IntroPage(
            title: "Run coding agents from your phone",
            subtitle: "Check progress, send prompts, and keep your coding agents moving from anywhere.",
            primarySymbol: "sparkles"
        ),
        IntroPage(
            title: "Stay close to the work",
            subtitle: "Open your Mac screen, continue a session, and send the next instruction without returning to your desk.",
            primarySymbol: "keyboard"
        )
    ]

    static let permissionTitle = "Allow Mac control"
    static let permissionSubtitle = "These permissions let your phone see this Mac and send prompts or clicks to coding agents."

    static let blockedPrimaryPathTerms = [
        "adapter",
        "approval polling",
        "DataChannel",
        "Durable Object",
        "fallback",
        "host ID",
        "pairing",
        "snapshot"
    ]
}
#endif
