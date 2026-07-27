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

    func testRemoveDeletesDevice() throws {
        let url = registryURL()
        let registry = DeviceRegistry(fileURL: url)
        let device = makeDevice(id: "gt-phone-3")

        try registry.add(device)
        try registry.remove(device.deviceId)

        XCTAssertNil(registry.get(device.deviceId))
        XCTAssertFalse(registry.isKnown(device.deviceId))
        XCTAssertFalse(registry.isRevoked(device.deviceId))

        let reloaded = DeviceRegistry(fileURL: url)
        XCTAssertNil(reloaded.get(device.deviceId))
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
        FileManager.default.temporaryDirectory
            .appendingPathComponent("glasstunnel-device-registry-\(UUID().uuidString)")
            .appendingPathComponent("devices.json")
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
