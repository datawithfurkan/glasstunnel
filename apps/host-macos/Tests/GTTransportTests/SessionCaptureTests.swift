#if os(macOS)
import XCTest
import GTCapture
import GTProtocol
import GTSecurity
import WebRTC
@testable import GTTransport

@MainActor
final class SessionCaptureTests: XCTestCase {
    func testScreenCaptureRestartsAfterAStreamError() async throws {
        let harness = try SessionHarness()
        harness.session.applyRemoteApps([screenApp()])
        try await harness.waitUntil { harness.bindings.count == 1 }
        let first = harness.bindings[0]
        try await harness.waitUntil { first.started }
        XCTAssertTrue(harness.peer.hasVideoSender(agentID: "screen"))

        first.onState(.error("stream stopped"))

        try await harness.waitUntil(timeout: 4) { harness.bindings.count == 2 }
        try await harness.waitUntil { first.stopped }
        XCTAssertEqual(harness.peer.videoSenderCount, 1, "a restart reuses the negotiated sender")
        XCTAssertEqual(harness.peer.senderCount, 1)
    }

    func testDisplayChangeRestartsARunningCapture() async throws {
        let harness = try SessionHarness()
        harness.session.applyRemoteApps([screenApp()])
        try await harness.waitUntil { harness.bindings.count == 1 && harness.bindings[0].started }

        harness.session.restartVideoCaptures(reason: "test")

        try await harness.waitUntil { harness.bindings.count == 2 }
        try await harness.waitUntil { harness.bindings[0].stopped && harness.bindings[1].started }
        XCTAssertEqual(harness.peer.senderCount, 1)
    }

    func testTurningSharingOffCancelsAPendingRestart() async throws {
        let harness = try SessionHarness()
        harness.session.applyRemoteApps([screenApp()])
        try await harness.waitUntil { harness.bindings.count == 1 && harness.bindings[0].started }

        harness.bindings[0].onState(.error("stream stopped"))
        harness.session.applyRemoteApps([screenApp(enabled: false)])
        try await harness.waitUntil { harness.bindings[0].stopped }
        try await Task.sleep(nanoseconds: 1_600_000_000)

        XCTAssertEqual(harness.bindings.count, 1, "no restart once sharing is off")
    }

    private func screenApp(enabled: Bool = true) -> RemoteApp {
        RemoteApp(
            remoteAppId: "screen",
            displayName: "Mac Screen",
            adapterKind: .mirror,
            agentId: "screen",
            enabled: enabled,
            available: true,
            status: .idle,
            statusDetail: "Screen ready",
            windowTitle: "",
            applicationBundleId: "",
            hasVideo: true
        )
    }
}

@MainActor
private final class SessionHarness {
    let peer: WebRTCPeer
    let session: Session
    private(set) var bindings: [FakeCaptureBinding] = []

    init() throws {
        let defaults = UserDefaults(suiteName: "SessionCaptureTests.\(UUID().uuidString)")!
        let controller = RemoteAppController(defaults: defaults, executableExists: { _ in false })
        let hostKey = DeviceKey()
        peer = try WebRTCPeer(remoteDeviceID: "phone-test", iceServers: [])
        session = Session(
            peer: peer,
            phoneDeviceID: "phone-test",
            hostDeviceKey: hostKey,
            signaling: SignalingClient(url: URL(string: "wss://localhost.invalid/signal")!, deviceKey: hostKey),
            autoLock: AutoLock(),
            remoteAppController: controller
        )
        session.displayCaptureBindingFactory = { [weak self] agentID, _, trackID, onState in
            let binding = FakeCaptureBinding(agentID: agentID, trackID: trackID, onState: onState)
            self?.bindings.append(binding)
            return binding
        }
    }

    func waitUntil(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met within \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

@MainActor
private final class FakeCaptureBinding: VideoCaptureBinding {
    let agentID: AgentID
    let trackID: String
    let onState: (WindowCapture.State) -> Void
    private(set) var started = false
    private(set) var stopped = false

    init(agentID: AgentID, trackID: String, onState: @escaping (WindowCapture.State) -> Void) {
        self.agentID = agentID
        self.trackID = trackID
        self.onState = onState
    }

    func start() async throws {
        started = true
        onState(.running)
    }

    func stop() async {
        stopped = true
    }
}
#endif
