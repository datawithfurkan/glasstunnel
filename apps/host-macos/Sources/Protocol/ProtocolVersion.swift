import Foundation

public enum GlasstunnelProtocol {
    public static let version = "0.2.2"
    public static let signalingPath = "/signal"
    /// Wire protocol version. Even = stable, odd = development.
    /// Bumped on breaking schema changes.
    public static let currentProtocolVersion: UInt32 = 4

    /// Production signaling default. Local development can override this with
    /// `GLASSTUNNEL_SIGNALING_URL`, but the account-first sign-in path should
    /// not silently point at localhost just because the bundle is a dev build.
    public static var defaultSignalingURL: URL {
        if let explicitSignalingURL { return explicitSignalingURL }
        return URL(string: "wss://signaling.glasstunnel.io/signal")!
    }

    /// Hosted phone app URL. This intentionally does not follow dev mode:
    /// account sign-in is a user-facing path and must not open localhost unless
    /// a developer explicitly opts into it.
    public static var defaultWebAppURL: URL {
        if let explicitWebAppURL { return explicitWebAppURL }
        return URL(string: "https://app.glasstunnel.io")!
    }

    public static var explicitWebAppURL: URL? {
        urlFromEnvironment("GLASSTUNNEL_WEB_APP_URL")
    }

    public static var explicitSignalingURL: URL? {
        urlFromEnvironment("GLASSTUNNEL_SIGNALING_URL")
    }

    public static var hasExplicitSignalingURLOverride: Bool {
        explicitSignalingURL != nil
    }

    public static var hasExplicitWebAppURLOverride: Bool {
        explicitWebAppURL != nil
    }

    public static var defaultTurnURL: String {
        // TURN requires credentials. Until the app can provision those
        // automatically, default to STUN-only and let Settings provide an
        // explicit TURN relay when configured.
        ""
    }

    public static let defaultStunURLs = [
        "stun:stun.l.google.com:19302",
        "stun:stun.cloudflare.com:3478",
    ]

    /// True when the Mac host was launched in the local development loop.
    /// Triggered by any of:
    ///   - `GLASSTUNNEL_DEV=1` env var
    ///   - bundle identifier ends with `.dev` (scripts/dev-app.sh bundles)
    ///   - `~/.glasstunnel-dev` marker file exists
    /// Never true in shipping release builds, which use the `io.glasstunnel.host`
    /// bundle identifier and run without the marker file.
    public static var isDevMode: Bool {
        if ProcessInfo.processInfo.environment["GLASSTUNNEL_DEV"] == "1" { return true }
        if Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true { return true }
        let marker = (ProcessInfo.processInfo.environment["HOME"] ?? "") + "/.glasstunnel-dev"
        return FileManager.default.fileExists(atPath: marker)
    }

    private static func urlFromEnvironment(_ key: String) -> URL? {
        guard
            let raw = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            let url = URL(string: raw),
            url.scheme != nil,
            url.host != nil
        else {
            return nil
        }
        return url
    }
}
