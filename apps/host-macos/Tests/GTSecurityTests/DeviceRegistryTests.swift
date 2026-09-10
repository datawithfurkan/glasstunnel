import XCTest
@testable import GTSecurity

final class DeviceRegistryTests: XCTestCase {
    func testEnvironmentOverrideUsesIsolatedRegistryFile() throws {
        let url = registryURL()
        let registry = DeviceRegistry(environment: [
            DeviceRegistry.fileEnvironmentKey: url.path
        ])
        let device = makeDevice(id: "gt-lab-phone")

        try registry.add(device)

        XCTAssertTrue(DeviceRegistry(fileURL: url).isKnown(device.deviceId))
    }

    func testAddPersistsKnownDevice() throws {
        let url = registryURL()
        let registry = DeviceRegistry(fileURL: url)
        let device = makeDevice(id: "gt-phone-1")

        try registry.add(device)

        XCTAssertTrue(registry.isKnown(device.deviceId))
        XCTAssertFalse(registry.isRevoked(device.deviceId))
        XCTAssertEqual(registry.get(device.deviceId)?.label, "Phone gt-phone-1")

        let reloaded = DeviceRegistry(fileURL: url)
        XCTAssertTrue(reloaded.isKnown(device.deviceId))
        XCTAssertEqual(reloaded.get(device.deviceId)?.publicKey, device.publicKey)
    }

    func testRevokePersistsAndBlocksKnownDevice() throws {
        let url = registryURL()
        let registry = DeviceRegistry(fileURL: url)
        let device = makeDevice(id: "gt-phone-2")

        try registry.add(device)
        try registry.revoke(device.deviceId)

        XCTAssertFalse(registry.isKnown(device.deviceId))
        XCTAssertTrue(registry.isRevoked(device.deviceId))
        XCTAssertTrue(try XCTUnwrap(registry.get(device.deviceId)).revoked)

        let reloaded = DeviceRegistry(fileURL: url)
        XCTAssertFalse(reloaded.isKnown(device.deviceId))
        XCTAssertTrue(reloaded.isRevoked(device.deviceId))
    }

    func testRemoveHidesDeviceButRetainsRevocationAcrossReload() throws {
        let url = registryURL()
        let registry = DeviceRegistry(fileURL: url)
        let device = makeDevice(id: "gt-phone-3")

        try registry.add(device)
        try registry.remove(device.deviceId)

        XCTAssertNil(registry.get(device.deviceId))
        XCTAssertFalse(registry.isKnown(device.deviceId))
        XCTAssertTrue(registry.isRevoked(device.deviceId))
        XCTAssertTrue(registry.all().isEmpty)

        let reloaded = DeviceRegistry(fileURL: url)
        XCTAssertNil(reloaded.get(device.deviceId))
        XCTAssertTrue(reloaded.isRevoked(device.deviceId))
        XCTAssertThrowsError(try reloaded.add(device))
    }

    func testAutomaticTrustCannotReAddRevokedIdentity() throws {
        let url = registryURL()
        let registry = DeviceRegistry(fileURL: url)
        let device = makeDevice(id: "gt-revoked")
        try registry.add(device)
        try registry.revoke(device.deviceId)
        XCTAssertThrowsError(try registry.add(device))
        XCTAssertTrue(DeviceRegistry(fileURL: url).isRevoked(device.deviceId))
    }

    func testRevocationConfirmationPersistsSeparatelyFromLocalDenial() throws {
        let url = registryURL()
        let registry = DeviceRegistry(fileURL: url)
        let device = makeDevice(id: "gt-confirmed")
        try registry.add(device)
        XCTAssertThrowsError(try registry.confirmRevocation(device.deviceId))
        try registry.revoke(device.deviceId)
        XCTAssertNil(registry.get(device.deviceId)?.revocationConfirmedAt)
        try registry.confirmRevocation(device.deviceId)
        XCTAssertNotNil(DeviceRegistry(fileURL: url).get(device.deviceId)?.revocationConfirmedAt)
    }

    func testUpdateLastSeenPersists() throws {
        let url = registryURL()
        let registry = DeviceRegistry(fileURL: url)
        let device = makeDevice(id: "gt-phone-4")
        let seenAt = Date(timeIntervalSince1970: 1_720_000_000)

        try registry.add(device)
        registry.updateLastSeen(device.deviceId, at: seenAt)

        XCTAssertEqual(registry.get(device.deviceId)?.lastSeenAt, seenAt)

        let reloaded = DeviceRegistry(fileURL: url)
        XCTAssertEqual(reloaded.get(device.deviceId)?.lastSeenAt, seenAt)
    }

    private func registryURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glasstunnel-device-registry-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("devices.json")
    }

    func testRemovedDeviceIsRestoredOnlyByALaterReauthorization() throws {
        let url = registryURL()
        let registry = DeviceRegistry(fileURL: url)
        let device = makeDevice(id: "gt-phone-relink")
        try registry.add(device)

        try registry.remove(device.deviceId)

        XCTAssertTrue(registry.isRevoked(device.deviceId))
        XCTAssertNil(registry.get(device.deviceId))
        XCTAssertThrowsError(try registry.add(device))
        XCTAssertFalse(registry.isReauthorized(device.deviceId, at: Date(timeIntervalSinceNow: -60)))
        XCTAssertTrue(registry.isReauthorized(device.deviceId, at: Date(timeIntervalSinceNow: 60)))

        try registry.restore(device.deviceId)

        XCTAssertFalse(registry.isRevoked(device.deviceId))
        XCTAssertTrue(registry.isKnown(device.deviceId))
        XCTAssertNil(registry.get(device.deviceId)?.removedAt)
        XCTAssertTrue(DeviceRegistry(fileURL: url).isKnown(device.deviceId))
        XCTAssertThrowsError(try registry.restore("gt-never-paired"))
    }

    func testAddKeepsPairingDateAndLastSeenAndSkipsUnchangedWrites() throws {
        let url = registryURL()
        let registry = DeviceRegistry(fileURL: url)
        let device = makeDevice(id: "gt-phone-refresh")
        XCTAssertTrue(try registry.add(device))
        let seen = Date(timeIntervalSince1970: 1_720_000_000)
        registry.updateLastSeen(device.deviceId, at: seen)

        var relayCopy = device
        relayCopy.pairedAt = Date()
        XCTAssertFalse(try registry.add(relayCopy))
        XCTAssertEqual(registry.get(device.deviceId)?.pairedAt, device.pairedAt)
        XCTAssertEqual(registry.get(device.deviceId)?.lastSeenAt, seen)

        relayCopy.label = "Renamed phone"
        XCTAssertTrue(try registry.add(relayCopy))
        XCTAssertEqual(registry.get(device.deviceId)?.label, "Renamed phone")
        XCTAssertEqual(registry.get(device.deviceId)?.lastSeenAt, seen)
        XCTAssertEqual(DeviceRegistry(fileURL: url).get(device.deviceId)?.label, "Renamed phone")
    }

    private func makeDevice(id: String) -> DeviceRegistry.PairedDevice {
        DeviceRegistry.PairedDevice(
            deviceId: id,
            publicKey: Data("public-key-\(id)".utf8),
            label: "Phone \(id)",
            pairedAt: Date(timeIntervalSince1970: 1_710_000_000)
        )
    }
}
