import XCTest
import GTProtocol
import GTSecurity
import WebRTC
@testable import GTTransport

@MainActor
final class HostPermissionTests: XCTestCase {
    func testRelayBrowserCannotRelaxHostRestriction() async throws {
        let h = try PermissionHarness()
        h.lock.setReadOnly(true)
        h.manager.handleRelayCommand(.init(body: .readOnlyModeUpdate(.init(readOnly: false))), from: "first")
        h.manager.handleRelayCommand(h.pointer, from: "first")
        await h.settle()
        XCTAssertTrue(h.lock.isReadOnly)
        XCTAssertEqual(h.clicks, 0)
    }

    func testBrowserRestrictionDoesNotAffectAnotherBrowser() async throws {
        let h = try PermissionHarness()
        h.manager.handleRelayCommand(.init(body: .readOnlyModeUpdate(.init(readOnly: true))), from: "first")
        h.manager.handleRelayCommand(.init(body: .readOnlyModeUpdate(.init(readOnly: false))), from: "second")
        h.manager.handleRelayCommand(h.pointer, from: "first")
        h.manager.handleRelayCommand(h.pointer, from: "second")
        await h.settle()
        XCTAssertFalse(h.lock.isReadOnly)
        XCTAssertEqual(h.clicks, 1)
    }

    func testQueuedRelayControlRechecksHostRestriction() async throws {
        let h = try PermissionHarness()
        h.manager.handleRelayCommand(h.pointer, from: "first")
        h.lock.setReadOnly(true)
        await h.settle()
        XCTAssertEqual(h.clicks, 0)
    }

    func testDataChannelBrowserCannotRelaxHostRestriction() async throws {
        let h = try PermissionHarness()
        h.lock.setReadOnly(true)
        h.peer.onDataChannelMessage?(.init(body: .readOnlyModeUpdate(.init(readOnly: false))))
        h.peer.onDataChannelMessage?(h.pointer)
        await h.settle()
        XCTAssertTrue(h.lock.isReadOnly)
        XCTAssertEqual(h.clicks, 0)
    }

    func testQueuedDataChannelControlRechecksHostRestriction() async throws {
        let h = try PermissionHarness()
        h.session.handleDataChannelMessage(h.pointer)
        h.lock.setReadOnly(true)
        await h.settle()
        XCTAssertEqual(h.clicks, 0)
    }

    func testBrowserRestrictionIsSharedAcrossTransportsButNotDevices() async throws {
        let h = try PermissionHarness()
        h.manager.handleRelayCommand(.init(body: .readOnlyModeUpdate(.init(readOnly: true))), from: "first")
        h.session.handleDataChannelMessage(h.pointer)
        await h.settle()
        XCTAssertEqual(h.clicks, 0)
        h.session.handleDataChannelMessage(.init(body: .readOnlyModeUpdate(.init(readOnly: false))))
        h.session.handleDataChannelMessage(h.pointer)
        await h.settle()
        XCTAssertEqual(h.clicks, 1)
    }

    func testEveryControlFamilyIsClassified() throws {
        var bodies: [DataChannelMessage.Body] = [
            .userInput(.init(agentId: "test", text: "test")),
            .quickReply(.init(agentId: "test", kind: .approve)),
            .interruptRequest(.init(agentId: "test")),
            .imageAttachmentInput(.init(agentId: "test", text: "", filename: "a.png", mimeType: "image/png", bytes: Data([0]))),
            .imageAttachmentChunk(.init(transferId: "t", agentId: "test", text: "", filename: "a.png", mimeType: "image/png", totalBytes: 1, chunkIndex: 0, chunkCount: 1, bytes: Data([0]))),
            .fileAttachmentChunk(.init(batchId: "b", transferId: "t", agentId: "test", text: "", filename: "a.txt", mimeType: "text/plain", totalBytes: 1, fileIndex: 0, fileCount: 1, chunkIndex: 0, chunkCount: 1, bytes: Data([0]))),
            .targetSelectionRequest(.init(agentId: "test", targetId: "t")),
            .targetRenameRequest(.init(agentId: "test", targetId: "t", label: "Test")),
            .agentRuntimeSettingsUpdate(.init(agentId: "test", modelId: "test")),
            .inputRequestResponse(.init(agentId: "test", requestId: "r", answers: [])),
            .screenPointerInput(.init(agentId: "test", x: 0, y: 0)),
        ]
        let actions: [RemoteAppActionRequest.Action] = [.enable, .disable, .start, .stop, .launch, .newSession, .closeSession]
        bodies += actions.map { .remoteAppActionRequest(.init(remoteAppId: "test", action: $0)) }
        for body in bodies { XCTAssertEqual(body.controlAgentID, "test") }
        XCTAssertNil(DataChannelMessage.Body.messageDetailRequest(.init(agentId: "test", messageId: "m")).controlAgentID)
        XCTAssertNil(DataChannelMessage.Body.heartbeatPing(.init()).controlAgentID)
    }
}

@MainActor
private final class PermissionHarness {
    let lock = AutoLock()
    let peer: WebRTCPeer
    var session: Session!
    var manager: SessionManager!
    var clicks = 0
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaultsName = "HostPermissionTests.\(UUID().uuidString)"
    let pointer = DataChannelMessage(body: .screenPointerInput(.init(agentId: "screen", x: 0.5, y: 0.5)))

    init() throws {
        let defaults = UserDefaults(suiteName: defaultsName)!
        let controller = RemoteAppController(defaults: defaults, executableExists: { _ in false })
        let key = DeviceKey()
        let url = URL(string: "ws://127.0.0.1:1/signal")!
        peer = try WebRTCPeer(remoteDeviceID: "first", iceServers: [])
        session = Session(peer: peer, phoneDeviceID: "first", hostDeviceKey: key,
            signaling: SignalingClient(url: url, deviceKey: key), autoLock: lock, remoteAppController: controller,
            screenPointerInputHandler: { [weak self] _ in self?.clicks += 1 })
        manager = SessionManager(deviceKey: key, signalingURL: url, turnURL: "", hostDeviceLabel: "Test",
            autoLock: lock, registry: DeviceRegistry(fileURL: directory.appendingPathComponent("devices.json")),
            remoteAppController: controller, screenPointerInputHandler: { [weak self] _ in self?.clicks += 1 })
    }

    func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    deinit {
        UserDefaults(suiteName: defaultsName)?.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: directory)
    }
}
