import Foundation

/// Persistent store for the host's DeviceKey. Lazily generates on first use.
public final class DeviceKeyStore: @unchecked Sendable {
    public static let shared = DeviceKeyStore()

    static let hostKeyAccountBase = "host.private_key"
    static let hostKeySuffixEnvironmentKey = "GLASSTUNNEL_KEYCHAIN_SUFFIX"
    static let devModeEnvironmentKey = "GLASSTUNNEL_DEV"
    static let devKeyFileEnvironmentKey = "GLASSTUNNEL_DEV_DEVICE_KEY_FILE"

    private let hostKeyAccount: String
    private let devKeyFileURL: URL?
    private let queue = DispatchQueue(label: "io.glasstunnel.devicekeystore")
    private var cached: DeviceKey?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.hostKeyAccount = Self.resolveHostKeyAccount(environment: environment)
        self.devKeyFileURL = Self.resolveDevKeyFileURL(environment: environment)
    }

    static func resolveHostKeyAccount(environment: [String: String]) -> String {
        guard
            let rawSuffix = environment[hostKeySuffixEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawSuffix.isEmpty
        else {
            return hostKeyAccountBase
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let sanitized = String(
            rawSuffix.unicodeScalars
                .map { allowed.contains($0) ? Character($0) : "_" }
        ).prefix(64)

        guard !sanitized.isEmpty else {
            return hostKeyAccountBase
        }

        return "\(hostKeyAccountBase).\(sanitized)"
    }

    static func resolveDevKeyFileURL(environment: [String: String]) -> URL? {
        if let rawPath = environment[devKeyFileEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawPath.isEmpty {
            return URL(fileURLWithPath: rawPath)
        }

        guard environment[devModeEnvironmentKey] == "1" else { return nil }

        let account = resolveHostKeyAccount(environment: environment)
        let fileName = account.replacingOccurrences(of: "/", with: "_") + ".key"
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return appSupport
            .appendingPathComponent("Glasstunnel", isDirectory: true)
            .appendingPathComponent("DevKeys", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public func getOrCreate() throws -> DeviceKey {
        try queue.sync {
            if let cached { return cached }
            if let devKeyFileURL {
                let key = try loadOrCreateDevKey(at: devKeyFileURL)
                cached = key
                return key
            }
            do {
                let raw = try Keychain.load(account: hostKeyAccount)
                let key = try DeviceKey(rawRepresentation: raw)
                cached = key
                return key
            } catch Keychain.KeychainError.notFound {
                let fresh = DeviceKey()
                try Keychain.store(fresh.privateKeyRaw, forAccount: hostKeyAccount)
                cached = fresh
                return fresh
            }
        }
    }

    /// Delete the stored private key. Next launch will generate a fresh one.
    /// Paired devices will also need to re-pair because the host's public key changes.
    public func reset() throws {
        try queue.sync {
            if let devKeyFileURL {
                try? FileManager.default.removeItem(at: devKeyFileURL)
                cached = nil
                return
            }
            try Keychain.delete(account: hostKeyAccount)
            cached = nil
        }
    }

    /// An in-memory DeviceKey used by tests.
    public static func ephemeral() -> DeviceKey {
        DeviceKey()
    }

    private func loadOrCreateDevKey(at url: URL) throws -> DeviceKey {
        if FileManager.default.fileExists(atPath: url.path) {
            let raw = try Data(contentsOf: url)
            return try DeviceKey(rawRepresentation: raw)
        }

        let fresh = DeviceKey()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fresh.privateKeyRaw.write(to: url, options: [.atomic])
        return fresh
    }
}
