import XCTest
import WebRTC
@testable import GTTransport

final class WebRTCPeerTests: XCTestCase {
    func testRestartedCaptureReusesTheNegotiatedSender() throws {
        let peer = try WebRTCPeer(remoteDeviceID: "phone-test", iceServers: [])
        defer { peer.close() }

        let firstTrack = peer.addVideoTrack(agentID: "screen", source: peer.videoSource())
        XCTAssertEqual(firstTrack, "gt-screen")
        XCTAssertEqual(peer.videoSenderCount, 1)
        XCTAssertEqual(peer.senderCount, 1)

        peer.removeVideoTrack(agentID: "screen")
        XCTAssertTrue(peer.hasVideoSender(agentID: "screen"), "stopping keeps the sender the phone negotiated")
        XCTAssertEqual(peer.senderCount, 1)

        let secondTrack = peer.addVideoTrack(agentID: "screen", source: peer.videoSource())
        XCTAssertEqual(secondTrack, firstTrack, "the phone maps video by track id")
        XCTAssertEqual(peer.videoSenderCount, 1)
        XCTAssertEqual(peer.senderCount, 1, "a restart must not add a second m-section")
    }

    func testVideoSenderCarriesTheProfileLimits() throws {
        let peer = try WebRTCPeer(remoteDeviceID: "phone-test", iceServers: [])
        defer { peer.close() }

        _ = peer.addVideoTrack(agentID: "screen", source: peer.videoSource(), limits: ScreenStreamProfile.readable.encodingLimits)
        XCTAssertEqual(peer.videoEncodingLimits(agentID: "screen"), VideoEncodingLimits(maxBitrateBps: 6_000_000, maxFramerate: 12))
        XCTAssertEqual(peer.videoDegradationPreference(agentID: "screen"), .maintainResolution)

        // A restarted capture with another profile updates the same sender.
        _ = peer.addVideoTrack(agentID: "screen", source: peer.videoSource(), limits: ScreenStreamProfile.fast.encodingLimits)
        XCTAssertEqual(peer.videoEncodingLimits(agentID: "screen")?.maxBitrateBps, 2_500_000)
        XCTAssertEqual(peer.senderCount, 1)

        XCTAssertEqual(ScreenStreamProfile.profile(for: .fast).maxDimension, 1280)
        XCTAssertEqual(ScreenStreamProfile.profile(for: .readable).maxDimension, 1920)
        XCTAssertEqual(ScreenStreamProfile.readable.activeFps, ScreenStreamProfile.fast.activeFps, "only size and bitrate differ between the presets")
    }

    func testEachAgentGetsItsOwnSender() throws {
        let peer = try WebRTCPeer(remoteDeviceID: "phone-test", iceServers: [])
        defer { peer.close() }

        _ = peer.addVideoTrack(agentID: "screen", source: peer.videoSource())
        _ = peer.addVideoTrack(agentID: "cursor", source: peer.videoSource())

        XCTAssertEqual(peer.videoSenderCount, 2)
        XCTAssertEqual(peer.senderCount, 2)
    }
}
