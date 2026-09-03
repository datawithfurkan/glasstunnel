import Foundation

/// Messages sent over the WebRTC DataChannel between the Mac host and the phone.
/// These NEVER touch the signaling server.
public struct DataChannelMessage: Codable, Sendable, Hashable {
    public var messageId: MessageID
    public var atUnixMs: Int64
    public var body: Body

    public init(
        messageId: MessageID = UUID().uuidString,
        atUnixMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        body: Body
    ) {
        self.messageId = messageId
        self.atUnixMs = atUnixMs
        self.body = body
    }

    public enum Body: Codable, Sendable, Hashable {
        case hello(Hello)
        case agentState(AgentStateSnapshot)
        case agentChatMessage(AgentChatMessage)
        case userInput(UserInput)
        case screenPointerInput(ScreenPointerInput)
        case imageAttachmentInput(ImageAttachmentInput)
        case imageAttachmentChunk(ImageAttachmentChunk)
        case fileAttachmentChunk(FileAttachmentChunk)
        case quickReply(QuickReply)
        case interruptRequest(InterruptRequest)
        case targetSelectionRequest(TargetSelectionRequest)
        case targetRenameRequest(TargetRenameRequest)
        case agentRuntimeSettingsUpdate(AgentRuntimeSettingsUpdate)
        case remoteAppActionRequest(RemoteAppActionRequest)
        case inputRequestResponse(AgentInputRequestResponse)
        case gridLayoutUpdate(GridLayoutUpdate)
        case remoteAppsUpdate(RemoteAppsUpdate)
        case readOnlyModeUpdate(ReadOnlyModeUpdate)
        case heartbeatPing(HeartbeatPing)
        case heartbeatPong(HeartbeatPong)
        case videoTrackHint(VideoTrackHint)
        case redactionPolicyUpdate(RedactionPolicyUpdate)
        case messageDetailRequest(MessageDetailRequest)
        case messageDetail(MessageDetail)

        private enum CodingKeys: String, CodingKey {
            case kind
            case hello
            case agentState
            case agentChatMessage
            case userInput
            case screenPointerInput
            case imageAttachmentInput
            case imageAttachmentChunk
            case fileAttachmentChunk
            case quickReply
            case interruptRequest
            case targetSelectionRequest
            case targetRenameRequest
            case agentRuntimeSettingsUpdate
            case remoteAppActionRequest
            case inputRequestResponse
            case gridLayoutUpdate
            case remoteAppsUpdate
            case readOnlyModeUpdate
            case heartbeatPing
            case heartbeatPong
            case videoTrackHint
            case redactionPolicyUpdate
            case messageDetailRequest
            case messageDetail
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(String.self, forKey: .kind)
            switch kind {
            case "hello":
                self = .hello(try container.decode(Hello.self, forKey: .hello))
            case "agentState":
                self = .agentState(try container.decode(AgentStateSnapshot.self, forKey: .agentState))
            case "agentChatMessage":
                self = .agentChatMessage(try container.decode(AgentChatMessage.self, forKey: .agentChatMessage))
            case "userInput":
                self = .userInput(try container.decode(UserInput.self, forKey: .userInput))
            case "screenPointerInput":
                self = .screenPointerInput(try container.decode(ScreenPointerInput.self, forKey: .screenPointerInput))
            case "imageAttachmentInput":
                self = .imageAttachmentInput(try container.decode(ImageAttachmentInput.self, forKey: .imageAttachmentInput))
            case "imageAttachmentChunk":
                self = .imageAttachmentChunk(try container.decode(ImageAttachmentChunk.self, forKey: .imageAttachmentChunk))
            case "fileAttachmentChunk":
                self = .fileAttachmentChunk(try container.decode(FileAttachmentChunk.self, forKey: .fileAttachmentChunk))
            case "quickReply":
                self = .quickReply(try container.decode(QuickReply.self, forKey: .quickReply))
            case "interruptRequest":
                self = .interruptRequest(try container.decode(InterruptRequest.self, forKey: .interruptRequest))
            case "targetSelectionRequest":
                self = .targetSelectionRequest(try container.decode(TargetSelectionRequest.self, forKey: .targetSelectionRequest))
            case "targetRenameRequest":
                self = .targetRenameRequest(try container.decode(TargetRenameRequest.self, forKey: .targetRenameRequest))
            case "agentRuntimeSettingsUpdate":
                self = .agentRuntimeSettingsUpdate(try container.decode(AgentRuntimeSettingsUpdate.self, forKey: .agentRuntimeSettingsUpdate))
            case "remoteAppActionRequest":
                self = .remoteAppActionRequest(try container.decode(RemoteAppActionRequest.self, forKey: .remoteAppActionRequest))
            case "inputRequestResponse":
                self = .inputRequestResponse(try container.decode(AgentInputRequestResponse.self, forKey: .inputRequestResponse))
            case "gridLayoutUpdate":
                self = .gridLayoutUpdate(try container.decode(GridLayoutUpdate.self, forKey: .gridLayoutUpdate))
            case "remoteAppsUpdate":
                self = .remoteAppsUpdate(try container.decode(RemoteAppsUpdate.self, forKey: .remoteAppsUpdate))
            case "readOnlyModeUpdate":
                self = .readOnlyModeUpdate(try container.decode(ReadOnlyModeUpdate.self, forKey: .readOnlyModeUpdate))
            case "heartbeatPing":
                self = .heartbeatPing(try container.decode(HeartbeatPing.self, forKey: .heartbeatPing))
            case "heartbeatPong":
                self = .heartbeatPong(try container.decode(HeartbeatPong.self, forKey: .heartbeatPong))
            case "videoTrackHint":
                self = .videoTrackHint(try container.decode(VideoTrackHint.self, forKey: .videoTrackHint))
            case "redactionPolicyUpdate":
                self = .redactionPolicyUpdate(try container.decode(RedactionPolicyUpdate.self, forKey: .redactionPolicyUpdate))
            case "messageDetailRequest":
                self = .messageDetailRequest(try container.decode(MessageDetailRequest.self, forKey: .messageDetailRequest))
            case "messageDetail":
                self = .messageDetail(try container.decode(MessageDetail.self, forKey: .messageDetail))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "unknown DataChannelMessage.Body kind '\(kind)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .hello(let v):
                try container.encode("hello", forKey: .kind)
                try container.encode(v, forKey: .hello)
            case .agentState(let v):
                try container.encode("agentState", forKey: .kind)
                try container.encode(v, forKey: .agentState)
            case .agentChatMessage(let v):
                try container.encode("agentChatMessage", forKey: .kind)
                try container.encode(v, forKey: .agentChatMessage)
            case .userInput(let v):
                try container.encode("userInput", forKey: .kind)
                try container.encode(v, forKey: .userInput)
            case .screenPointerInput(let v):
                try container.encode("screenPointerInput", forKey: .kind)
                try container.encode(v, forKey: .screenPointerInput)
            case .imageAttachmentInput(let v):
                try container.encode("imageAttachmentInput", forKey: .kind)
                try container.encode(v, forKey: .imageAttachmentInput)
            case .imageAttachmentChunk(let v):
                try container.encode("imageAttachmentChunk", forKey: .kind)
                try container.encode(v, forKey: .imageAttachmentChunk)
            case .fileAttachmentChunk(let v):
                try container.encode("fileAttachmentChunk", forKey: .kind)
                try container.encode(v, forKey: .fileAttachmentChunk)
            case .quickReply(let v):
                try container.encode("quickReply", forKey: .kind)
                try container.encode(v, forKey: .quickReply)
            case .interruptRequest(let v):
                try container.encode("interruptRequest", forKey: .kind)
                try container.encode(v, forKey: .interruptRequest)
            case .targetSelectionRequest(let v):
                try container.encode("targetSelectionRequest", forKey: .kind)
                try container.encode(v, forKey: .targetSelectionRequest)
            case .targetRenameRequest(let v):
                try container.encode("targetRenameRequest", forKey: .kind)
                try container.encode(v, forKey: .targetRenameRequest)
            case .agentRuntimeSettingsUpdate(let v):
                try container.encode("agentRuntimeSettingsUpdate", forKey: .kind)
                try container.encode(v, forKey: .agentRuntimeSettingsUpdate)
            case .remoteAppActionRequest(let v):
                try container.encode("remoteAppActionRequest", forKey: .kind)
                try container.encode(v, forKey: .remoteAppActionRequest)
            case .inputRequestResponse(let v):
                try container.encode("inputRequestResponse", forKey: .kind)
                try container.encode(v, forKey: .inputRequestResponse)
            case .gridLayoutUpdate(let v):
                try container.encode("gridLayoutUpdate", forKey: .kind)
                try container.encode(v, forKey: .gridLayoutUpdate)
            case .remoteAppsUpdate(let v):
                try container.encode("remoteAppsUpdate", forKey: .kind)
                try container.encode(v, forKey: .remoteAppsUpdate)
            case .readOnlyModeUpdate(let v):
                try container.encode("readOnlyModeUpdate", forKey: .kind)
                try container.encode(v, forKey: .readOnlyModeUpdate)
            case .heartbeatPing(let v):
                try container.encode("heartbeatPing", forKey: .kind)
                try container.encode(v, forKey: .heartbeatPing)
            case .heartbeatPong(let v):
                try container.encode("heartbeatPong", forKey: .kind)
                try container.encode(v, forKey: .heartbeatPong)
            case .videoTrackHint(let v):
                try container.encode("videoTrackHint", forKey: .kind)
                try container.encode(v, forKey: .videoTrackHint)
            case .redactionPolicyUpdate(let v):
                try container.encode("redactionPolicyUpdate", forKey: .kind)
                try container.encode(v, forKey: .redactionPolicyUpdate)
            case .messageDetailRequest(let v):
                try container.encode("messageDetailRequest", forKey: .kind)
                try container.encode(v, forKey: .messageDetailRequest)
            case .messageDetail(let v):
                try container.encode("messageDetail", forKey: .kind)
                try container.encode(v, forKey: .messageDetail)
            }
        }
    }
}

public struct Hello: Codable, Sendable, Hashable {
    public var hostVersion: String
    public var hostOsVersion: String
    public var hostDeviceLabel: String
    public var supportedAdapters: [String]
    public var currentLayout: GridLayout
    public var remoteApps: [RemoteApp]
    public var protocolVersion: UInt32

    public init(
        hostVersion: String,
        hostOsVersion: String,
        hostDeviceLabel: String,
        supportedAdapters: [String],
        currentLayout: GridLayout,
        remoteApps: [RemoteApp] = [],
        protocolVersion: UInt32 = GlasstunnelProtocol.currentProtocolVersion
    ) {
        self.hostVersion = hostVersion
        self.hostOsVersion = hostOsVersion
        self.hostDeviceLabel = hostDeviceLabel
        self.supportedAdapters = supportedAdapters
        self.currentLayout = currentLayout
        self.remoteApps = remoteApps
        self.protocolVersion = protocolVersion
    }
}

public struct UserInput: Codable, Sendable, Hashable {
    public var agentId: AgentID
    public var text: String
    public var submitOnSend: Bool

    public init(agentId: AgentID, text: String, submitOnSend: Bool = true) {
        self.agentId = agentId
        self.text = text
        self.submitOnSend = submitOnSend
    }
}

public enum ScreenPointerAction: String, Codable, Sendable, Hashable {
    case click
    case doubleClick
}

public struct ScreenPointerInput: Codable, Sendable, Hashable {
    public var agentId: AgentID
    public var x: Double
    public var y: Double
    public var action: ScreenPointerAction

    public init(agentId: AgentID, x: Double, y: Double, action: ScreenPointerAction = .click) {
        self.agentId = agentId
        self.x = x
        self.y = y
        self.action = action
    }
}

public struct ImageAttachmentInput: Codable, Sendable, Hashable {
    public var agentId: AgentID
    public var text: String
    public var filename: String
    public var mimeType: String
    public var bytes: Data
    public var submitOnSend: Bool

    public init(
        agentId: AgentID,
        text: String,
        filename: String,
        mimeType: String,
        bytes: Data,
        submitOnSend: Bool = true
    ) {
        self.agentId = agentId
        self.text = text
        self.filename = filename
        self.mimeType = mimeType
        self.bytes = bytes
        self.submitOnSend = submitOnSend
    }
}

public struct ImageAttachmentChunk: Codable, Sendable, Hashable {
    public var transferId: String
    public var agentId: AgentID
    public var text: String
    public var filename: String
    public var mimeType: String
    public var totalBytes: Int
    public var chunkIndex: Int
    public var chunkCount: Int
    public var bytes: Data
    public var submitOnSend: Bool

    public init(
        transferId: String,
        agentId: AgentID,
        text: String,
        filename: String,
        mimeType: String,
        totalBytes: Int,
        chunkIndex: Int,
        chunkCount: Int,
        bytes: Data,
        submitOnSend: Bool = true
    ) {
        self.transferId = transferId
        self.agentId = agentId
        self.text = text
        self.filename = filename
        self.mimeType = mimeType
        self.totalBytes = totalBytes
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
        self.bytes = bytes
        self.submitOnSend = submitOnSend
    }
}

public struct FileAttachmentChunk: Codable, Sendable, Hashable {
    public var batchId: String
    public var transferId: String
    public var agentId: AgentID
    public var text: String
    public var filename: String
    public var mimeType: String
    public var totalBytes: Int
    public var fileIndex: Int
    public var fileCount: Int
    public var chunkIndex: Int
    public var chunkCount: Int
    public var bytes: Data
    public var submitOnSend: Bool

    public init(
        batchId: String,
        transferId: String,
        agentId: AgentID,
        text: String,
        filename: String,
        mimeType: String,
        totalBytes: Int,
        fileIndex: Int,
        fileCount: Int,
        chunkIndex: Int,
        chunkCount: Int,
        bytes: Data,
        submitOnSend: Bool = true
    ) {
        self.batchId = batchId
        self.transferId = transferId
        self.agentId = agentId
        self.text = text
        self.filename = filename
        self.mimeType = mimeType
        self.totalBytes = totalBytes
        self.fileIndex = fileIndex
        self.fileCount = fileCount
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
        self.bytes = bytes
        self.submitOnSend = submitOnSend
    }
}

public struct QuickReply: Codable, Sendable, Hashable {
    public var agentId: AgentID
    public var kind: QuickReplyKind

    public init(agentId: AgentID, kind: QuickReplyKind) {
        self.agentId = agentId
        self.kind = kind
    }
}

public struct InterruptRequest: Codable, Sendable, Hashable {
    public var agentId: AgentID

    public init(agentId: AgentID) {
        self.agentId = agentId
    }
}

/// Phone → Mac: the full text of a message whose snapshot copy was a preview.
public struct MessageDetailRequest: Codable, Sendable, Hashable {
    public var agentId: AgentID
    public var messageId: MessageID

    public init(agentId: AgentID, messageId: MessageID) {
        self.agentId = agentId
        self.messageId = messageId
    }
}

/// Mac → phone: the full text of one message, redacted like a snapshot.
public struct MessageDetail: Codable, Sendable, Hashable {
    public var agentId: AgentID
    public var messageId: MessageID
    public var text: String
    public var redacted: Bool
    public var redactionReasons: [String]
    public var truncated: Bool

    public init(
        agentId: AgentID,
        messageId: MessageID,
        text: String,
        redacted: Bool = false,
        redactionReasons: [String] = [],
        truncated: Bool = false
    ) {
        self.agentId = agentId
        self.messageId = messageId
        self.text = text
        self.redacted = redacted
        self.redactionReasons = redactionReasons
        self.truncated = truncated
    }
}

public struct TargetSelectionRequest: Codable, Sendable, Hashable {
    public var agentId: AgentID
    public var targetId: String

    public init(agentId: AgentID, targetId: String) {
        self.agentId = agentId
        self.targetId = targetId
    }
}

public struct TargetRenameRequest: Codable, Sendable, Hashable {
    public var agentId: AgentID
    public var targetId: String
    public var label: String

    public init(agentId: AgentID, targetId: String, label: String) {
        self.agentId = agentId
        self.targetId = targetId
        self.label = label
    }
}

public struct AgentRuntimeSettingsUpdate: Codable, Sendable, Hashable {
    public var agentId: AgentID
    public var modelId: String?
    public var reasoningEffort: String?
    public var fastMode: Bool?

    public init(
        agentId: AgentID,
        modelId: String? = nil,
        reasoningEffort: String? = nil,
        fastMode: Bool? = nil
    ) {
        self.agentId = agentId
        self.modelId = modelId
        self.reasoningEffort = reasoningEffort
        self.fastMode = fastMode
    }
}

public struct RemoteAppActionRequest: Codable, Sendable, Hashable {
    public enum Action: String, Codable, Sendable, Hashable {
        case enable
        case disable
        case launch
        case start
        case stop
        case newSession
        case closeSession
    }

    public enum ScreenQuality: String, Codable, Sendable, Hashable {
        case fast
        case readable
    }

    public var remoteAppId: String
    public var action: Action
    public var screenQuality: ScreenQuality?

    public init(
        remoteAppId: String,
        action: Action,
        screenQuality: ScreenQuality? = nil
    ) {
        self.remoteAppId = remoteAppId
        self.action = action
        self.screenQuality = screenQuality
    }
}

public struct GridLayoutUpdate: Codable, Sendable, Hashable {
    public var layout: GridLayout

    public init(layout: GridLayout) {
        self.layout = layout
    }
}

public struct RemoteAppsUpdate: Codable, Sendable, Hashable {
    public var remoteApps: [RemoteApp]

    public init(remoteApps: [RemoteApp]) {
        self.remoteApps = remoteApps
    }
}

public struct ReadOnlyModeUpdate: Codable, Sendable, Hashable {
    public var readOnly: Bool

    public init(readOnly: Bool) {
        self.readOnly = readOnly
    }
}

public struct HeartbeatPing: Codable, Sendable, Hashable {
    public var atUnixMs: Int64

    public init(atUnixMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.atUnixMs = atUnixMs
    }
}

public struct HeartbeatPong: Codable, Sendable, Hashable {
    public var atUnixMs: Int64

    public init(atUnixMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.atUnixMs = atUnixMs
    }
}

public struct VideoTrackHint: Codable, Sendable, Hashable {
    public var agentId: AgentID
    public var trackId: String
    public var active: Bool

    public init(agentId: AgentID, trackId: String, active: Bool) {
        self.agentId = agentId
        self.trackId = trackId
        self.active = active
    }
}

public struct RedactionPolicyUpdate: Codable, Sendable, Hashable {
    public var patterns: [String]

    public init(patterns: [String]) {
        self.patterns = patterns
    }
}
