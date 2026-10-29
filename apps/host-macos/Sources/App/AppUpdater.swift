#if os(macOS)
import AppKit
import Combine
import Foundation
import Sparkle

/// Decides from the running bundle whether Glasstunnel can update itself.
///
/// Only a packaged release carries both the update feed and the public key
/// that update archives and the feed must be signed with. Development
/// wrappers, `swift run`, and local test builds fall back to the Releases page
/// so they never replace themselves with a public release.
enum AppUpdatePolicy {
    enum Mode: Equatable {
        case inApp
        case releasesPage(reason: String)
    }

    static let developmentBuildReason = "This development build does not update itself. Download releases from GitHub."
    static let unsignedBuildReason = "This build was made without update signing. Download releases from GitHub."

    static func mode(bundleURL: URL, info: [String: Any]) -> Mode {
        guard bundleURL.pathExtension == "app" else {
            return .releasesPage(reason: developmentBuildReason)
        }
        guard let feed = info["SUFeedURL"] as? String,
              let feedURL = URL(string: feed),
              feedURL.scheme == "https" || isLocalTestFeed(feedURL),
              let publicKey = info["SUPublicEDKey"] as? String,
              !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .releasesPage(reason: unsignedBuildReason)
        }
        return .inApp
    }

    /// The update smoke serves its feed from this Mac over plain HTTP.
    private static func isLocalTestFeed(_ url: URL) -> Bool {
        url.scheme == "http" && (url.host == "127.0.0.1" || url.host == "localhost")
    }
}

/// Owns Sparkle's updater and mirrors its state for the menus and Settings.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()
    nonisolated static let menuTitle = "Check for Updates…"

    let mode: AppUpdatePolicy.Mode
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?

    private let controller: SPUStandardUpdaterController?

    private init(bundle: Bundle = .main) {
        mode = AppUpdatePolicy.mode(bundleURL: bundle.bundleURL, info: bundle.infoDictionary ?? [:])
        guard mode == .inApp else {
            controller = nil
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$automaticallyChecksForUpdates)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$automaticallyDownloadsUpdates)
        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: RunLoop.main)
            .assign(to: &$lastUpdateCheckDate)
    }

    var updatesInApp: Bool { mode == .inApp }

    /// The menu item and Settings button stay enabled on development builds,
    /// where they open the Releases page instead.
    var checkIsAvailable: Bool { updatesInApp ? canCheckForUpdates : true }

    /// The Settings and menu bar button title for this build.
    var checkTitle: String { updatesInApp ? Self.menuTitle : "View Releases" }

    func checkForUpdates() {
        if let controller {
            controller.checkForUpdates(nil)
        } else {
            NSWorkspace.shared.open(AppVersionInfo.releasesURL)
        }
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }
}

enum AppUpdateCopy {
    static func lastChecked(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Not checked yet" }
        if now.timeIntervalSince(date) < 60 { return "Checked just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Checked \(formatter.localizedString(for: date, relativeTo: now))"
    }
}
#endif
