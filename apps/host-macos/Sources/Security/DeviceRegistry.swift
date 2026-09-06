import Foundation
import GTProtocol

/// Persistent registry of account-linked devices. Stored under
/// `~/Library/Application Support/Glasstunnel/devices.json`.
///
/// The registry is the source of truth for which device ids can receive
/// envelopes from this Mac. Removed devices retain a denial tombstone so
/// account auto-authorization cannot silently trust the same identity again.
public final class DeviceRegistry: @unchecked Sendable {
    static let fileEnvironmentKey = "GLASSTUNNEL_DEVICE_REGISTRY_FILE"

    public struct PairedDevice: Codable, Sendable, Hashable, Identifiable {
        public var id: DeviceID { deviceId }
        public var deviceId: DeviceID
        public var publicKey: Data
        public var label: String
        public var pairedAt: Date
        public var lastSeenAt: Date?
        public var revoked: Bool
        public var removedAt: Date?
        public var revocationConfirmedAt: Date?

        public init(deviceId: DeviceID, publicKey: Data, label: String, pairedAt: Date = Date(), lastSeenAt: Date? = nil, revoked: Bool = false) {
            self.deviceId = deviceId
            self.publicKey = publicKey
            self.label = label
            self.pairedAt = pairedAt
            self.lastSeenAt = lastSeenAt
            self.revoked = revoked
            self.removedAt = nil
            self.revocationConfirmedAt = nil
        }
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var devices: [DeviceID: PairedDevice]

    public static let shared = DeviceRegistry()

    public init(
        fileURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let url = fileURL ?? DeviceRegistry.defaultFileURL(environment: environment)
        self.fileURL = url
        self.devices = DeviceRegistry.load(from: url)
    }

    public func all() -> [PairedDevice] {
        lock.lock(); defer { lock.unlock() }
        return devices.values.filter { $0.removedAt == nil }.sorted(by: { $0.pairedAt > $1.pairedAt })
    }

    public func get(_ id: DeviceID) -> PairedDevice? {
        lock.lock(); defer { lock.unlock() }
        guard let device = devices[id], device.removedAt == nil else { return nil }
        return device
    }

    public func add(_ device: PairedDevice) throws {
        lock.lock()
        defer { lock.unlock() }
        if devices[device.deviceId]?.revoked == true { throw RegistryError.revoked }
        devices[device.deviceId] = device
        try persistLocked()
    }

    public func revoke(_ id: DeviceID) throws {
        lock.lock()
        defer { lock.unlock() }
        if var d = devices[id] {
            d.revoked = true
            devices[id] = d
        }
        try persistLocked()
    }

    public func remove(_ id: DeviceID) throws {
        lock.lock()
        defer { lock.unlock() }
        if var device = devices[id] {
            device.revoked = true
            device.removedAt = Date()
            devices[id] = device
        }
        try persistLocked()
    }

    public func confirmRevocation(_ id: DeviceID) throws {
        lock.lock(); defer { lock.unlock() }
        guard var device = devices[id], device.revoked else { throw RegistryError.notRevoked }
        let previous = device
        device.revocationConfirmedAt = Date()
        devices[id] = device
        do { try persistLocked() }
        catch { devices[id] = previous; throw error }
    }

    public enum RegistryError: LocalizedError {
        case revoked, notRevoked
        public var errorDescription: String? {
            switch self {
            case .revoked: return "Access for this device was revoked."
            case .notRevoked: return "Device revocation has not been recorded."
            }
        }
    }

    public func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        devices.removeAll()
        try persistLocked()
    }

    public func updateLastSeen(_ id: DeviceID, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        if var d = devices[id] {
            d.lastSeenAt = date
            devices[id] = d
        }
        try? persistLocked()
    }

    public func isRevoked(_ id: DeviceID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return devices[id]?.revoked ?? false
    }

    public func isKnown(_ id: DeviceID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let d = devices[id] else { return false }
        return !d.revoked
    }

    private func persistLocked() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Array(devices.values))
        try data.write(to: fileURL, options: Data.WritingOptions.atomic)
    }

    private static func load(from url: URL) -> [DeviceID: PairedDevice] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let list = try? JSONDecoder().decode([PairedDevice].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.deviceId, $0) })
    }

    private static func defaultFileURL(environment: [String: String]) -> URL {
        if let path = environment[fileEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return URL(fileURLWithPath: path)
        }

        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fm.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Glasstunnel", isDirectory: true).appendingPathComponent("devices.json")
    }
}
