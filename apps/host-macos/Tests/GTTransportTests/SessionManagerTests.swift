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
        // Older servers send no Mac name or reason.
        XCTAssertNil(identity?.hostLabel)
        XCTAssertNil(identity?.reason)
        XCTAssertEqual(identity?.wasRemovedFromAccount, false)
    }

    func testHostIdentityParsesTheAccountNameForThisMac() {
        let identity = SessionManager.hostIdentity(fromControlMessage: [
            "type": "host_identity",
            "linked": true,
            "user_id": "user-123",
            "email": "dev@example.com",
            "display_name": "Dev User",
            "avatar_url": "",
            "host_label": "  Studio Mac  ",
        ])

        XCTAssertEqual(identity?.linked, true)
        XCTAssertEqual(identity?.hostLabel, "Studio Mac")
        XCTAssertNil(identity?.reason)
        XCTAssertEqual(identity?.wasRemovedFromAccount, false)
    }

    func testHostIdentityDropsControlCharactersAndBlankHostLabels() {
        let cleaned = SessionManager.hostIdentity(fromControlMessage: [
            "type": "host_identity",
            "linked": true,
            "user_id": "user-123",
            "host_label": "Studio\u{0007} Mac\n",
        ])
        XCTAssertEqual(cleaned?.hostLabel, "Studio Mac")

        let blank = SessionManager.hostIdentity(fromControlMessage: [
            "type": "host_identity",
            "linked": true,
            "user_id": "user-123",
            "host_label": " \n\t ",
        ])
        XCTAssertNil(blank?.hostLabel)

        let wrongType = SessionManager.hostIdentity(fromControlMessage: [
            "type": "host_identity",
            "linked": true,
            "user_id": "user-123",
            "host_label": 42,
        ])
        XCTAssertNil(wrongType?.hostLabel)
    }

    func testHostLabelKeepsEmojiZeroWidthJoinerSequencesIntact() throws {
        // Technologist and family emoji are ZWJ sequences; the England flag
        // is a tag sequence (format characters the name rule allows).
        let label = "Dev \u{1F469}\u{200D}\u{1F4BB} Mac \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} "
            + "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
        XCTAssertEqual(label.unicodeScalars.count, 25)

        let shown = try XCTUnwrap(SessionManager.hostIdentity(fromControlMessage: [
            "type": "host_identity",
            "linked": true,
            "user_id": "user-123",
            "host_label": label,
        ])?.hostLabel)

        XCTAssertEqual(shown, label)
        XCTAssertEqual(shown.unicodeScalars.count, 25)
        XCTAssertEqual(shown.unicodeScalars.filter { $0 == "\u{200D}" }.count, 3)
        XCTAssertEqual(shown.count, 13)
    }

    func testHostLabelKeepsPersianZeroWidthNonJoiner() {
        // "مک‌بوک من": the non-joiner keeps the two halves of the word apart.
        let label = "\u{0645}\u{06A9}\u{200C}\u{0628}\u{0648}\u{06A9} \u{0645}\u{0646}"

        let shown = SessionManager.displayLabel(label)

        XCTAssertEqual(shown, label)
        XCTAssertEqual(shown?.unicodeScalars.count, label.unicodeScalars.count)
        XCTAssertEqual(shown?.unicodeScalars.contains("\u{200C}"), true)
    }

    func testHostLabelDropsBidiControlsAndInvisibleCharacters() {
        // A right-to-left override would show "Studio cam Mac" as "Studio mac Mac".
        XCTAssertEqual(SessionManager.displayLabel("Studio \u{202E}cam\u{202C} Mac"), "Studio cam Mac")
        XCTAssertEqual(SessionManager.displayLabel("\u{202A}Studio\u{202B} \u{202D}Mac\u{202C}"), "Studio Mac")
        XCTAssertEqual(SessionManager.displayLabel("\u{2066}Studio\u{2069} \u{2067}Mac\u{2069}\u{2068}"), "Studio Mac")
        XCTAssertEqual(SessionManager.displayLabel("\u{200F}Studio Mac\u{200E}"), "Studio Mac")
        XCTAssertEqual(SessionManager.displayLabel("Stu\u{200B}dio\u{2060} Mac\u{FEFF}"), "Studio Mac")
        XCTAssertEqual(SessionManager.displayLabel("Studio\u{2028} Mac\u{2029}"), "Studio Mac")
        // C0 and C1 controls, including NEL.
        XCTAssertEqual(SessionManager.displayLabel("\u{0000}Studio\u{0085} Mac\u{009B}\u{007F}"), "Studio Mac")
        // Whitespace exposed by a dropped character is trimmed; nothing left is nil.
        XCTAssertEqual(SessionManager.displayLabel("\u{FEFF} Studio Mac \u{202C}"), "Studio Mac")
        XCTAssertNil(SessionManager.displayLabel("\u{202E}\u{200B} \u{FEFF}\u{2066}\u{2069}\u{200F}"))
        XCTAssertNil(SessionManager.displayLabel(nil))
    }

    func testHostLabelHidesOnlyTheCharactersTheNameRuleNames() {
        let hidden: [Unicode.Scalar] = [
            "\u{0000}", "\u{0009}", "\u{000A}", "\u{001F}", "\u{007F}", "\u{0085}", "\u{009F}",
            "\u{2028}", "\u{2029}",
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
            "\u{200E}", "\u{200F}", "\u{200B}", "\u{2060}", "\u{FEFF}",
        ]
        for scalar in hidden {
            XCTAssertTrue(SessionManager.isHiddenInDisplayLabel(scalar), "U+\(String(scalar.value, radix: 16, uppercase: true))")
        }

        // Joiners, the soft hyphen, variation selectors, emoji tags and plain
        // spaces are allowed in a name and stay visible.
        let kept: [Unicode.Scalar] = [
            "\u{200C}", "\u{200D}", "\u{00AD}", "\u{FE0F}", "\u{E0067}", "\u{E007F}",
            " ", "\u{00A0}", "A", "\u{0645}", "\u{1F4BB}",
        ]
        for scalar in kept {
            XCTAssertFalse(SessionManager.isHiddenInDisplayLabel(scalar), "U+\(String(scalar.value, radix: 16, uppercase: true))")
        }
    }

    func testHostIdentityParsesRemovalFromAnotherDevice() {
        let identity = SessionManager.hostIdentity(fromControlMessage: [
            "type": "host_identity",
            "linked": false,
            "reason": "removed_from_account",
        ])

        XCTAssertEqual(identity?.linked, false)
        XCTAssertEqual(identity?.reason, SessionManager.HostIdentity.removedFromAccountReason)
        XCTAssertEqual(identity?.wasRemovedFromAccount, true)
        XCTAssertNil(identity?.userID)
        XCTAssertNil(identity?.hostLabel)
    }

    func testHostIdentityTreatsUnknownReasonsAsAPlainUnlink() {
        let unknown = SessionManager.hostIdentity(fromControlMessage: [
            "type": "host_identity",
            "linked": false,
            "reason": "maintenance",
        ])
        XCTAssertEqual(unknown?.reason, "maintenance")
        XCTAssertEqual(unknown?.wasRemovedFromAccount, false)

        // A removal reason on a linked identity is contradictory; it is not a removal.
        let linked = SessionManager.hostIdentity(fromControlMessage: [
            "type": "host_identity",
            "linked": true,
            "user_id": "user-123",
            "reason": "removed_from_account",
        ])
        XCTAssertEqual(linked?.wasRemovedFromAccount, false)
    }

    @MainActor
    func testRemovalFromAccountEndsLivePhoneSessionsAndReportsIdentity() throws {
        let harness = try IdentityHarness()
        harness.installSession(phone: "phone-a")
        harness.installSession(phone: "phone-b")
        XCTAssertEqual(harness.manager.sessionCount(), 2)

        harness.manager.handleControlMessage([
            "type": "host_identity",
            "linked": false,
            "reason": "removed_from_account",
        ])

        XCTAssertEqual(harness.manager.sessionCount(), 0)
        XCTAssertEqual(Set(harness.events.disconnected), ["phone-a", "phone-b"])
        XCTAssertEqual(harness.events.identities.map(\.wasRemovedFromAccount), [true])
    }

    @MainActor
    func testPlainUnlinkKeepsLivePhoneSessionsAsBefore() throws {
        let harness = try IdentityHarness()
        harness.installSession(phone: "phone-a")

        harness.manager.handleControlMessage(["type": "host_identity", "linked": false])
        harness.manager.handleControlMessage(["type": "host_identity", "linked": false, "reason": "maintenance"])

        XCTAssertEqual(harness.manager.sessionCount(), 1)
        XCTAssertTrue(harness.events.disconnected.isEmpty)
        XCTAssertEqual(harness.events.identities.count, 2)
        XCTAssertFalse(harness.events.identities.contains(where: \.wasRemovedFromAccount))
    }

    @MainActor
    func testRenamePushReportsTheNewNameWithoutTouchingSessions() throws {
        let harness = try IdentityHarness()
        harness.installSession(phone: "phone-a")

        harness.manager.handleControlMessage([
            "type": "host_identity",
            "linked": true,
            "user_id": "user-123",
            "email": "dev@example.com",
            "host_label": "Office Mac",
        ])

        XCTAssertEqual(harness.manager.sessionCount(), 1)
        XCTAssertEqual(harness.events.identities.last?.hostLabel, "Office Mac")
    }

    @MainActor
    func testRemovalReportedWhenSignalingReconnectsEndsSessionsLikeTheLiveNotice() async throws {
        let server = try LocalSignalingServer()
        let signalingURL = try await server.start()
        server.setMessagesAfterAuth([[
            "type": "host_identity",
            "linked": true,
            "user_id": "user-123",
            "email": "dev@example.com",
            "host_label": "Studio Mac mini",
        ]])
        let harness = try IdentityHarness(signalingURL: signalingURL)
        defer {
            harness.manager.stop()
            server.stop()
        }

        try await harness.manager.start()
        try await waitUntil("the Mac learns its account") {
            harness.events.identities.contains(where: \.linked)
        }
        harness.installSession(phone: "phone-a")
        harness.installSession(phone: "phone-b")
        let socketsBeforeDrop = server.authenticatedSocketCount

        // The owner removes the Mac while its signaling socket is down. The
        // phones' WebRTC sessions outlive that socket; the Worker reports the
        // removal on the socket the Mac reconnects with.
        server.setMessagesAfterAuth([[
            "type": "host_identity",
            "linked": false,
            "reason": "removed_from_account",
        ]])
        server.dropAllConnections()

        try await waitUntil("the reconnected socket reports the removal", timeout: 20) {
            harness.events.identities.contains(where: \.wasRemovedFromAccount)
        }
        XCTAssertGreaterThan(server.authenticatedSocketCount, socketsBeforeDrop)
        XCTAssertEqual(harness.events.identities.first?.hostLabel, "Studio Mac mini")
        XCTAssertEqual(harness.events.identities.filter(\.wasRemovedFromAccount).count, 1)
        // The same outcome as the live notice.
        XCTAssertEqual(harness.manager.sessionCount(), 0)
        XCTAssertEqual(Set(harness.events.disconnected), ["phone-a", "phone-b"])
        XCTAssertEqual(harness.events.disconnected.count, 2)
    }

    @MainActor
    func testRemovalReportedAgainOnReconnectEndsSessionsOnce() throws {
        let harness = try IdentityHarness()
        harness.installSession(phone: "phone-a")
        let removal: [String: Any] = ["type": "host_identity", "linked": false, "reason": "removed_from_account"]

        harness.manager.handleControlMessage(removal)
        harness.manager.handleControlMessage(removal)

        XCTAssertEqual(harness.manager.sessionCount(), 0)
        XCTAssertEqual(harness.events.disconnected, ["phone-a"])
        XCTAssertEqual(harness.events.identities.map(\.wasRemovedFromAccount), [true, true])
    }

    /// Polls on the main actor, where the manager reports identities.
    @MainActor
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 10,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting until \(description)")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
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

private final class IdentityEvents: @unchecked Sendable {
    var identities: [SessionManager.HostIdentity] = []
    var disconnected: [DeviceID] = []
}

@MainActor
private final class IdentityHarness {
    let events = IdentityEvents()
    let manager: SessionManager
    private let key = DeviceKey()
    private let lock = AutoLock()
    private let controller: RemoteAppController
    private let signalingURL: URL
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let defaultsName = "SessionManagerIdentityTests.\(UUID().uuidString)"

    init(signalingURL: URL = URL(string: "ws://127.0.0.1:1/signal")!) throws {
        self.signalingURL = signalingURL
        let defaults = UserDefaults(suiteName: defaultsName)!
        controller = RemoteAppController(defaults: defaults, executableExists: { _ in false })
        manager = SessionManager(deviceKey: key, signalingURL: signalingURL, turnURL: "", hostDeviceLabel: "Local test",
            autoLock: lock, registry: DeviceRegistry(fileURL: directory.appendingPathComponent("devices.json")),
            remoteAppController: controller)
        let events = events
        manager.onHostIdentity = { identity in events.identities.append(identity) }
        manager.onPeerDisconnected = { id in events.disconnected.append(id) }
    }

    func installSession(phone: DeviceID) {
        let peer = try! WebRTCPeer(remoteDeviceID: phone, iceServers: [])
        manager.sessions[phone] = Session(peer: peer, phoneDeviceID: phone, hostDeviceKey: key,
            signaling: SignalingClient(url: signalingURL, deviceKey: key), autoLock: lock, remoteAppController: controller)
    }

    deinit {
        UserDefaults(suiteName: defaultsName)?.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: directory)
    }
}
