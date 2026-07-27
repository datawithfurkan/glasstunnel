import Foundation

/// The signaling server routes by `toDeviceId`; content lives on the WebRTC
/// channel. Server-side push paths may inspect small status metadata.
public struct Envelope: Codable, Sendable {
    public var envelopeId: String
    public var fromDeviceId: DeviceID
    public var toDeviceId: DeviceID
    public var sentAtUnixMs: Int64
    public var signature: Data
    public var payload: Payload

    public init(
        envelopeId: String = UUID().uuidString,
        fromDeviceId: DeviceID,
        toDeviceId: DeviceID,
        sentAtUnixMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        signature: Data = Data(),
        payload: Payload
    ) {
        self.envelopeId = envelopeId
        self.fromDeviceId = fromDeviceId
        self.toDeviceId = toDeviceId
        self.sentAtUnixMs = sentAtUnixMs
        self.signature = signature
        self.payload = payload
    }

    public enum Payload: Codable, Sendable {
        case sdpOffer(SdpOffer)
        case sdpAnswer(SdpAnswer)
        case iceCandidate(IceCandidate)
        case pushRegister(PushRegister)
        case agentStateEvent(AgentStateEvent)
        case ping(Ping)
        case pong(Pong)
        case protoError(ProtoError)

        private enum CodingKeys: String, CodingKey {
            case kind
            case sdpOffer
            case sdpAnswer
            case iceCandidate
            case pushRegister
            case agentStateEvent
            case ping
            case pong
            case protoError = "error"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(String.self, forKey: .kind)
            switch kind {
            case "sdpOffer":
                self = .sdpOffer(try container.decode(SdpOffer.self, forKey: .sdpOffer))
            case "sdpAnswer":
                self = .sdpAnswer(try container.decode(SdpAnswer.self, forKey: .sdpAnswer))
            case "iceCandidate":
                self = .iceCandidate(try container.decode(IceCandidate.self, forKey: .iceCandidate))
            case "pushRegister":
                self = .pushRegister(try container.decode(PushRegister.self, forKey: .pushRegister))
            case "agentStateEvent":
                self = .agentStateEvent(try container.decode(AgentStateEvent.self, forKey: .agentStateEvent))
            case "ping":
                self = .ping(try container.decode(Ping.self, forKey: .ping))
            case "pong":
                self = .pong(try container.decode(Pong.self, forKey: .pong))
            case "error":
                self = .protoError(try container.decode(ProtoError.self, forKey: .protoError))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "unknown Envelope.Payload kind '\(kind)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .sdpOffer(let v):
                try container.encode("sdpOffer", forKey: .kind)
                try container.encode(v, forKey: .sdpOffer)
            case .sdpAnswer(let v):
                try container.encode("sdpAnswer", forKey: .kind)
                try container.encode(v, forKey: .sdpAnswer)
            case .iceCandidate(let v):
                try container.encode("iceCandidate", forKey: .kind)
                try container.encode(v, forKey: .iceCandidate)
            case .pushRegister(let v):
                try container.encode("pushRegister", forKey: .kind)
                try container.encode(v, forKey: .pushRegister)
            case .agentStateEvent(let v):
                try container.encode("agentStateEvent", forKey: .kind)
                try container.encode(v, forKey: .agentStateEvent)
            case .ping(let v):
                try container.encode("ping", forKey: .kind)
                try container.encode(v, forKey: .ping)
            case .pong(let v):
                try container.encode("pong", forKey: .kind)
                try container.encode(v, forKey: .pong)
            case .protoError(let v):
                try container.encode("error", forKey: .kind)
                try container.encode(v, forKey: .protoError)
            }
        }
    }
}

public struct SdpOffer: Codable, Sendable {
    public var sdp: String
    public var sessionId: SessionID

    public init(sdp: String, sessionId: SessionID) {
        self.sdp = sdp
        self.sessionId = sessionId
    }
}

public struct SdpAnswer: Codable, Sendable {
    public var sdp: String
    public var sessionId: SessionID

    public init(sdp: String, sessionId: SessionID) {
        self.sdp = sdp
        self.sessionId = sessionId
    }
}

public struct IceCandidate: Codable, Sendable {
    public var candidate: String
    public var sdpMid: String
    public var sdpMlineIndex: Int32
    public var sessionId: SessionID

    public init(candidate: String, sdpMid: String, sdpMlineIndex: Int32, sessionId: SessionID) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMlineIndex = sdpMlineIndex
        self.sessionId = sessionId
    }
}

public struct PushRegister: Codable, Sendable {
    public var endpoint: String
    public var p256dh: String
    public var auth: String
    public var phonePublicKey: Data

    public init(endpoint: String, p256dh: String, auth: String, phonePublicKey: Data) {
        self.endpoint = endpoint
        self.p256dh = p256dh
        self.auth = auth
        self.phonePublicKey = phonePublicKey
    }
}

public struct AgentStateEvent: Codable, Sendable {
    public var agentId: AgentID
    public var status: AgentStatus
    public var summary: String
    public var atUnixMs: Int64

    public init(agentId: AgentID, status: AgentStatus, summary: String = "", atUnixMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.agentId = agentId
        self.status = status
        self.summary = summary
        self.atUnixMs = atUnixMs
    }
}

public struct Ping: Codable, Sendable {
    public var atUnixMs: Int64
    public init(atUnixMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.atUnixMs = atUnixMs
    }
}

public struct Pong: Codable, Sendable {
    public var atUnixMs: Int64
    public init(atUnixMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.atUnixMs = atUnixMs
    }
}

public struct ProtoError: Codable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
