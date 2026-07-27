import XCTest
@testable import GTTransport

final class SessionManagerTests: XCTestCase {
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
