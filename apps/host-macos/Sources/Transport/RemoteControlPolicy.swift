import GTProtocol

extension DataChannelMessage.Body {
    /// Exhaustive classification: new protocol actions must choose a boundary.
    var controlAgentID: AgentID? {
        switch self {
        case .userInput(let v): return v.agentId
        case .quickReply(let v): return v.agentId
        case .interruptRequest(let v): return v.agentId
        case .imageAttachmentInput(let v): return v.agentId
        case .imageAttachmentChunk(let v): return v.agentId
        case .fileAttachmentChunk(let v): return v.agentId
        case .targetSelectionRequest(let v): return v.agentId
        case .targetRenameRequest(let v): return v.agentId
        case .agentRuntimeSettingsUpdate(let v): return v.agentId
        case .inputRequestResponse(let v): return v.agentId
        case .screenPointerInput(let v): return v.agentId
        case .remoteAppActionRequest(let v):
            return RemoteAppDefinition.definition(for: v.remoteAppId)?.agentId ?? v.remoteAppId
        case .hello, .agentState, .agentChatMessage, .remoteAppsUpdate,
             .messageDetailRequest, .messageDetail, .readOnlyModeUpdate,
             .heartbeatPing, .heartbeatPong, .videoTrackHint,
             .gridLayoutUpdate, .redactionPolicyUpdate:
            return nil
        }
    }
}
