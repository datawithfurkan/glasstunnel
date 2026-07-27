import Foundation
import GTProtocol
import GTSecurity
import WebRTC

/// High-level WebRTC peer for the Mac host. Hides RTCPeerConnection machinery
/// behind a narrow API that the app and adapters can use without touching
/// the WebRTC framework directly.
///
/// One `WebRTCPeer` per connected device. The peer owns:
///   - a DataChannel named "control" for DataChannelMessage traffic
///   - zero or more video tracks (one per grid cell with video enabled)
///
/// ICE candidates and SDP flow over the SignalingClient as `Envelope` messages.
public final class WebRTCPeer: NSObject, @unchecked Sendable {
    public enum State: Sendable {
        case new
        case connecting
        case connected
        case disconnected
        case failed(String)
        case closed
    }

    public var onState: (@Sendable (State) -> Void)?
    public var onDataChannelMessage: (@Sendable (DataChannelMessage) -> Void)?
    public var onLocalDescription: (@Sendable (RTCSessionDescription) -> Void)?
    public var onLocalICECandidate: (@Sendable (RTCIceCandidate) -> Void)?

    public let remoteDeviceID: DeviceID
    public let sessionID: SessionID

    private let factory: RTCPeerConnectionFactory
    private let connection: RTCPeerConnection
    private var dataChannel: RTCDataChannel?
    private let senderLock = NSLock()
    private var _videoSenders: [String: RTCRtpSender] = [:]

    /// RTCInitializeSSL is process-global. Ensure it runs exactly once.
    private static let _initializeSSL: Bool = {
        RTCInitializeSSL()
        return true
    }()

    public init(
        remoteDeviceID: DeviceID,
        iceServers: [RTCIceServer],
        sessionID: SessionID = UUID().uuidString
    ) throws {
        _ = Self._initializeSSL
        let factory = RTCPeerConnectionFactory()
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.tcpCandidatePolicy = .disabled
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            throw PeerError.peerConnectionCreationFailed
        }
        self.factory = factory
        self.connection = connection
        self.remoteDeviceID = remoteDeviceID
        self.sessionID = sessionID
        super.init()
        connection.delegate = self
    }

    // MARK: - SDP

    public func createOffer() async throws -> RTCSessionDescription {
        ensureDataChannel()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let sdp = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RTCSessionDescription, Error>) in
            connection.offer(for: constraints) { sdp, err in
                if let err = err { cont.resume(throwing: err); return }
                if let sdp = sdp { cont.resume(returning: sdp); return }
                cont.resume(throwing: PeerError.noSDP)
            }
        }
        try await setLocalDescription(sdp)
        return sdp
    }

    public func createAnswer() async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let sdp = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RTCSessionDescription, Error>) in
            connection.answer(for: constraints) { sdp, err in
                if let err = err { cont.resume(throwing: err); return }
                if let sdp = sdp { cont.resume(returning: sdp); return }
                cont.resume(throwing: PeerError.noSDP)
            }
        }
        try await setLocalDescription(sdp)
        return sdp
    }

    public func setLocalDescription(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(sdp) { err in
                if let err = err { cont.resume(throwing: err) } else { cont.resume(returning: ()) }
            }
        }
        onLocalDescription?(sdp)
    }

    public func setRemoteDescription(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(sdp) { err in
                if let err = err { cont.resume(throwing: err) } else { cont.resume(returning: ()) }
            }
        }
    }

    public func add(remoteCandidate: RTCIceCandidate) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.add(remoteCandidate) { err in
                if let err = err { cont.resume(throwing: err) } else { cont.resume(returning: ()) }
            }
        }
    }

    // MARK: - DataChannel

    public func send(_ message: DataChannelMessage) throws {
        guard let dc = dataChannel else { throw PeerError.noDataChannel }
        let data = try ProtocolCodec.encode(message)
        let buffer = RTCDataBuffer(data: data, isBinary: false)
        dc.sendData(buffer)
    }

    public func ensureDataChannel() {
        if dataChannel != nil { return }
        let config = RTCDataChannelConfiguration()
        config.isOrdered = true
        config.isNegotiated = false
        let dc = connection.dataChannel(forLabel: "control", configuration: config)
        dc?.delegate = self
        dataChannel = dc
    }

    // MARK: - Video track helpers

    /// Attach a VideoSource to the peer for a given grid cell. Returns a stable
    /// trackID the phone can use to map video to the agent.
    public func addVideoTrack(agentID: AgentID, source: RTCVideoSource) -> String {
        let trackID = "gt-\(agentID)"
        let track = factory.videoTrack(with: source, trackId: trackID)
        let sender = connection.add(track, streamIds: ["gt-main"])
        senderLock.lock()
        if let sender { _videoSenders[agentID] = sender }
        senderLock.unlock()
        return trackID
    }

    public func removeVideoTrack(agentID: AgentID) {
        senderLock.lock()
        let sender = _videoSenders.removeValue(forKey: agentID)
        senderLock.unlock()
        guard let sender else { return }
        connection.removeTrack(sender)
    }

    public func videoSource() -> RTCVideoSource {
        factory.videoSource()
    }

    // MARK: - Close

    public func close() {
        dataChannel?.close()
        dataChannel = nil
        connection.close()
        onState?(.closed)
    }
}

extension WebRTCPeer: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        switch newState {
        case .new, .checking: onState?(.connecting)
        case .connected, .completed: onState?(.connected)
        case .disconnected: onState?(.disconnected)
        case .failed: onState?(.failed("ICE failed"))
        case .closed: onState?(.closed)
        default: break
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onLocalICECandidate?(candidate)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.delegate = self
        self.dataChannel = dataChannel
    }
}

extension WebRTCPeer: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let msg = try? ProtocolCodec.decode(DataChannelMessage.self, from: buffer.data) else { return }
        onDataChannelMessage?(msg)
    }
}

public enum PeerError: Error, Sendable {
    case noSDP
    case noDataChannel
    case peerConnectionCreationFailed
}

extension PeerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noSDP:
            return "WebRTC did not produce an SDP description."
        case .noDataChannel:
            return "WebRTC data channel is not available yet."
        case .peerConnectionCreationFailed:
            return "WebRTC peer connection could not be created. Check TURN URL and credentials."
        }
    }
}
