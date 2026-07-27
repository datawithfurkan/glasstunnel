import Foundation

public struct RemoteApp: Codable, Sendable, Hashable, Identifiable {
    public var id: String { remoteAppId }
    public var remoteAppId: String
    public var displayName: String
    public var adapterKind: AdapterKind
    public var agentId: AgentID
    public var enabled: Bool
    public var available: Bool
    public var status: AgentStatus
    public var statusDetail: String
    public var windowTitle: String
    public var applicationBundleId: String
    public var hasVideo: Bool

    public init(
        remoteAppId: String,
        displayName: String,
        adapterKind: AdapterKind,
        agentId: AgentID,
        enabled: Bool,
        available: Bool,
        status: AgentStatus = .idle,
        statusDetail: String = "",
        windowTitle: String = "",
        applicationBundleId: String = "",
        hasVideo: Bool = true
    ) {
        self.remoteAppId = remoteAppId
        self.displayName = displayName
        self.adapterKind = adapterKind
        self.agentId = agentId
        self.enabled = enabled
        self.available = available
        self.status = status
        self.statusDetail = statusDetail
        self.windowTitle = windowTitle
        self.applicationBundleId = applicationBundleId
        self.hasVideo = hasVideo
    }
}
