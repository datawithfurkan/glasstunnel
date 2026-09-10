import XCTest
import GTProtocol
import GTSecurity
@testable import GTTransport

final class SessionManagerTests: XCTestCase {
    @MainActor
    func testOfflineRevocationDeniesLocallyWithoutClaimingServerConfirmation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = DeviceRegistry(fileURL: directory.appendingPathComponent("devices.json"))
        let phone = DeviceKey()
        try registry.add(.init(deviceId: phone.deviceId, publicKey: phone.publicKeyRaw, label: "Local test"))
        let defaultsName = "OfflineRevocationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let manager = SessionManager(deviceKey: DeviceKey(),
            signalingURL: URL(string: "ws://127.0.0.1:1/signal")!, turnURL: "",
            hostDeviceLabel: "Local test", autoLock: AutoLock(), registry: registry,
            remoteAppController: RemoteAppController(defaults: defaults, executableExists: { _ in false }))
        do {
            try await manager.revokeDevice(phone.deviceId)
            XCTFail("Offline revocation must not claim confirmation")
        } catch is SessionManager.RevocationError { }
        XCTAssertTrue(registry.isRevoked(phone.deviceId))
        XCTAssertNil(registry.get(phone.deviceId)?.revocationConfirmedAt)
        let restored = DeviceRegistry(fileURL: directory.appendingPathComponent("devices.json"))
        XCTAssertTrue(restored.isRevoked(phone.deviceId))
    }

    @MainActor
    func testLinkCodeReauthorizationRestoresARemovedDevice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = DeviceRegistry(fileURL: directory.appendingPathComponent("devices.json"))
        let phone = DeviceKey()
        let device = DeviceRegistry.PairedDevice(deviceId: phone.deviceId, publicKey: phone.publicKeyRaw, label: "Local test")
        try registry.add(device)
        try registry.remove(phone.deviceId)
        let defaultsName = "ReauthorizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let manager = SessionManager(deviceKey: DeviceKey(),
            signalingURL: URL(string: "ws://127.0.0.1:1/signal")!, turnURL: "",
            hostDeviceLabel: "Local test", autoLock: AutoLock(), registry: registry,
            remoteAppController: RemoteAppController(defaults: defaults, executableExists: { _ in false }))
        let paired = expectation(description: "the restored device is reported as paired")
        manager.onPaired = { _ in paired.fulfill() }

        // A plain account notice and a re-authorization older than the removal keep the denial.
        manager.acceptAuthorizedDevice(device, reauthorizedAt: nil)
        XCTAssertTrue(registry.isRevoked(phone.deviceId))
        manager.acceptAuthorizedDevice(device, reauthorizedAt: Date(timeIntervalSinceNow: -3600))
        XCTAssertTrue(registry.isRevoked(phone.deviceId))

        manager.acceptAuthorizedDevice(device, reauthorizedAt: Date(timeIntervalSinceNow: 60))

        XCTAssertTrue(registry.isKnown(phone.deviceId))
        XCTAssertFalse(registry.isRevoked(phone.deviceId))
        wait(for: [paired], timeout: 1)
    }

    @MainActor
    func testRelayUploadChunksAreIsolatedByDeviceAndDiscardedOnRevocation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = DeviceRegistry(fileURL: directory.appendingPathComponent("devices.json"))
        let phone = DeviceKey()
        try registry.add(.init(deviceId: phone.deviceId, publicKey: phone.publicKeyRaw, label: "Local test"))
        let defaultsName = "UploadRevocationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let manager = SessionManager(deviceKey: DeviceKey(),
            signalingURL: URL(string: "ws://127.0.0.1:1/signal")!, turnURL: "",
            hostDeviceLabel: "Local test", autoLock: AutoLock(), registry: registry,
            remoteAppController: RemoteAppController(defaults: defaults, executableExists: { _ in false }))
        func chunk(_ index: Int) -> ImageAttachmentChunk {
            .init(transferId: "shared-id", agentId: "terminal", text: "", filename: "test.png",
                mimeType: "image/png", totalBytes: 2, chunkIndex: index, chunkCount: 2,
                bytes: Data([UInt8(index)]), submitOnSend: false)
        }
        XCTAssertNil(try manager.receiveRelayImageAttachmentChunk(chunk(0), from: phone.deviceId))
        XCTAssertNil(try manager.receiveRelayImageAttachmentChunk(chunk(1), from: "other-phone"))
        let other = try manager.receiveRelayImageAttachmentChunk(chunk(0), from: "other-phone")
        XCTAssertEqual(other?.bytes, Data([0, 1]))
        do { try await manager.revokeDevice(phone.deviceId) } catch is SessionManager.RevocationError { }
        XCTAssertNil(try manager.receiveRelayImageAttachmentChunk(chunk(1), from: phone.deviceId))
    }

    @MainActor
    func testRevokedRelayDeviceCannotChangeHostState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = DeviceRegistry(fileURL: directory.appendingPathComponent("devices.json"))
        let phone = DeviceKey()
        try registry.add(.init(deviceId: phone.deviceId, publicKey: phone.publicKeyRaw, label: "Local test"))
        try registry.revoke(phone.deviceId)
        let defaultsName = "RevocationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let autoLock = AutoLock()
        let manager = SessionManager(
            deviceKey: DeviceKey(), signalingURL: URL(string: "ws://127.0.0.1:1/signal")!, turnURL: "",
            hostDeviceLabel: "Local test", autoLock: autoLock, registry: registry,
            remoteAppController: RemoteAppController(defaults: defaults, executableExists: { _ in false })
        )
        manager.handleRelayCommand(DataChannelMessage(body: .readOnlyModeUpdate(.init(readOnly: true))), from: phone.deviceId)
        XCTAssertFalse(autoLock.isReadOnly)
        manager.handleRelayCommand(DataChannelMessage(body: .readOnlyModeUpdate(.init(readOnly: true))), from: nil)
        XCTAssertFalse(autoLock.isReadOnly)
    }

    func testLockedRelayPolicyStillAllowsStopActions() {
        XCTAssertTrue(SessionManager.allowsRelayRemoteAppAction(.stop, locked: true))
        XCTAssertTrue(SessionManager.allowsRelayRemoteAppAction(.disable, locked: true))
        XCTAssertTrue(SessionManager.allowsRelayRemoteAppAction(.closeSession, locked: true))
        XCTAssertFalse(SessionManager.allowsRelayRemoteAppAction(.start, locked: true))
        XCTAssertFalse(SessionManager.allowsRelayRemoteAppAction(.launch, locked: true))
        XCTAssertFalse(SessionManager.allowsRelayRemoteAppAction(.newSession, locked: true))
        XCTAssertTrue(SessionManager.allowsRelayRemoteAppAction(.start, locked: false))
        XCTAssertTrue(SessionManager.allowsRelayRemoteAppAction(.newSession, locked: false))
        XCTAssertTrue(SessionManager.allowsRelayRemoteAppAction(.closeSession, locked: false))
    }

    func testMakeIceServersOmitsTurnWhenCredentialsMissing() {
        let servers = SessionManager.makeIceServers(
            stunURLs: ["stun:stun.l.google.com:19302"],
            turnURL: "turn:localhost:3478",
            turnUsername: "glasstunnel",
            turnPassword: nil
        )

        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers.first?.urlStrings, ["stun:stun.l.google.com:19302"])
    }

    func testMakeIceServersIncludesTurnWhenFullyConfigured() {
        let servers = SessionManager.makeIceServers(
            stunURLs: [],
            turnURL: "turn:localhost:3478",
            turnUsername: "glasstunnel",
            turnPassword: "secret"
        )

        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers.first?.urlStrings, ["turn:localhost:3478"])
        XCTAssertEqual(servers.first?.username, "glasstunnel")
        XCTAssertEqual(servers.first?.credential, "secret")
    }

    func testHostIdentityParsesLinkedAccountControlMessage() {
        let identity = SessionManager.hostIdentity(fromControlMessage: [
            "type": "host_identity",
            "linked": true,
            "user_id": "user-123",
            "email": "dev@example.com",
            "display_name": "Dev User",
            "avatar_url": "https://example.com/avatar.png",
        ])

        XCTAssertEqual(identity?.linked, true)
        XCTAssertEqual(identity?.userID, "user-123")
        XCTAssertEqual(identity?.email, "dev@example.com")
        XCTAssertEqual(identity?.displayName, "Dev User")
        XCTAssertEqual(identity?.avatarURL, "https://example.com/avatar.png")
    }

    func testHostIdentityTreatsBlankOptionalFieldsAsMissing() {
        let identity = SessionManager.hostIdentity(fromControlMessage: [
            "type": "host_identity",
            "linked": true,
            "user_id": "user-123",
            "email": "   ",
            "display_name": "",
            "avatar_url": "\n",
        ])

        XCTAssertEqual(identity?.linked, true)
        XCTAssertEqual(identity?.userID, "user-123")
        XCTAssertNil(identity?.email)
        XCTAssertNil(identity?.displayName)
        XCTAssertNil(identity?.avatarURL)
    }

    func testHostIdentityParsesUnlinkedControlMessage() {
        let identity = SessionManager.hostIdentity(fromControlMessage: [
            "type": "host_identity",
            "linked": false,
        ])

        XCTAssertEqual(identity?.linked, false)
        XCTAssertNil(identity?.userID)
        XCTAssertNil(identity?.email)
        XCTAssertNil(identity?.displayName)
        XCTAssertNil(identity?.avatarURL)
    }

    func testHostIdentityIgnoresOtherControlMessages() {
        let identity = SessionManager.hostIdentity(fromControlMessage: [
            "type": "pong",
            "linked": true,
        ])

        XCTAssertNil(identity)
    }
}
