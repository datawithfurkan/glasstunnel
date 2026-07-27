import Foundation

public struct PendingToolCall: Codable, Sendable, Hashable, Identifiable {
    public var id: String { toolCallId }
    public var toolName: String
    public var toolCallId: String
    public var summary: String

    public init(toolName: String, toolCallId: String, summary: String) {
        self.toolName = toolName
        self.toolCallId = toolCallId
        self.summary = summary
    }
}

public struct AgentChatMessage: Codable, Sendable, Hashable, Identifiable {
    public var id: String { messageId }
    public var messageId: MessageID
    public var role: ChatRole
    public var text: String
    public var atUnixMs: Int64
    public var redacted: Bool
    public var pendingToolCalls: [PendingToolCall]
    /// Pattern names that fired for this message (never the matched text).
    public var redactionReasons: [String]

    public init(
        messageId: MessageID,
        role: ChatRole,
        text: String,
        atUnixMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        redacted: Bool = false,
        pendingToolCalls: [PendingToolCall] = [],
        redactionReasons: [String] = []
    ) {
        self.messageId = messageId
        self.role = role
        self.text = text
        self.atUnixMs = atUnixMs
        self.redacted = redacted
        self.pendingToolCalls = pendingToolCalls
        self.redactionReasons = redactionReasons
    }
}

public struct AgentTargetOption: Codable, Sendable, Hashable, Identifiable {
    public var id: String { targetId }
    public var targetId: String
    public var label: String
    public var subtitle: String
    public var selected: Bool
    public var projectId: String?
    public var projectLabel: String?
    public var projectPath: String?
    public var threadId: String?
    public var threadLabel: String?
    public var targetKind: String?
    public var lastActivityUnixMs: Int64?
    public var isActive: Bool?
    public var supportsNewThread: Bool?

    public init(
        targetId: String,
        label: String,
        subtitle: String,
        selected: Bool,
        projectId: String? = nil,
        projectLabel: String? = nil,
        projectPath: String? = nil,
        threadId: String? = nil,
        threadLabel: String? = nil,
        targetKind: String? = nil,
        lastActivityUnixMs: Int64? = nil,
        isActive: Bool? = nil,
        supportsNewThread: Bool? = nil
    ) {
        self.targetId = targetId
        self.label = label
        self.subtitle = subtitle
        self.selected = selected
        self.projectId = projectId
        self.projectLabel = projectLabel
        self.projectPath = projectPath
        self.threadId = threadId
        self.threadLabel = threadLabel
        self.targetKind = targetKind
        self.lastActivityUnixMs = lastActivityUnixMs
        self.isActive = isActive
        self.supportsNewThread = supportsNewThread
    }
}

public struct AgentRuntimeOption: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var description: String?

    public init(id: String, label: String, description: String? = nil) {
        self.id = id
        self.label = label
        self.description = description
    }
}

public struct AgentRuntimeControls: Codable, Sendable, Hashable {
    public enum ApplyTiming: String, Codable, Sendable, Hashable {
        case immediate
        case nextStart = "next_start"
        case managedLocally = "managed_locally"
    }

    public var modelId: String?
    public var modelLabel: String?
    public var modelOptions: [AgentRuntimeOption]
    public var reasoningEffort: String?
    public var reasoningEffortLabel: String?
    public var reasoningEffortOptions: [AgentRuntimeOption]
    public var fastMode: Bool?
    public var supportsModelSelection: Bool
    public var supportsReasoningEffort: Bool
    public var supportsFastMode: Bool
    public var editable: Bool
    public var appliesOn: ApplyTiming
    public var note: String?

    public init(
        modelId: String? = nil,
        modelLabel: String? = nil,
        modelOptions: [AgentRuntimeOption] = [],
        reasoningEffort: String? = nil,
        reasoningEffortLabel: String? = nil,
        reasoningEffortOptions: [AgentRuntimeOption] = [],
        fastMode: Bool? = nil,
        supportsModelSelection: Bool = false,
        supportsReasoningEffort: Bool = false,
        supportsFastMode: Bool = false,
        editable: Bool = false,
        appliesOn: ApplyTiming = .managedLocally,
        note: String? = nil
    ) {
        self.modelId = modelId
        self.modelLabel = modelLabel
        self.modelOptions = modelOptions
        self.reasoningEffort = reasoningEffort
        self.reasoningEffortLabel = reasoningEffortLabel
        self.reasoningEffortOptions = reasoningEffortOptions
        self.fastMode = fastMode
        self.supportsModelSelection = supportsModelSelection
        self.supportsReasoningEffort = supportsReasoningEffort
        self.supportsFastMode = supportsFastMode
        self.editable = editable
        self.appliesOn = appliesOn
        self.note = note
    }
}

public struct AgentInputRequestChoice: Codable, Sendable, Hashable, Identifiable {
    public var id: String { choiceId }
    public var choiceId: String
    public var label: String
    public var description: String
    public var recommended: Bool

    public init(choiceId: String, label: String, description: String = "", recommended: Bool = false) {
        self.choiceId = choiceId
        self.label = label
        self.description = description
        self.recommended = recommended
    }
}

public struct AgentInputRequestQuestion: Codable, Sendable, Hashable, Identifiable {
    public var id: String { questionId }
    public var questionId: String
    public var header: String
    public var question: String
    public var choices: [AgentInputRequestChoice]

    public init(
        questionId: String,
        header: String,
        question: String,
        choices: [AgentInputRequestChoice]
    ) {
        self.questionId = questionId
        self.header = header
        self.question = question
        self.choices = choices
    }
}

public struct AgentInputRequest: Codable, Sendable, Hashable, Identifiable {
    public var id: String { requestId }
    public var requestId: String
    public var questions: [AgentInputRequestQuestion]

    public init(requestId: String, questions: [AgentInputRequestQuestion]) {
        self.requestId = requestId
        self.questions = questions
    }
}

public struct AgentInputRequestAnswer: Codable, Sendable, Hashable {
    public var questionId: String
    public var choiceIds: [String]

    public init(questionId: String, choiceIds: [String]) {
        self.questionId = questionId
        self.choiceIds = choiceIds
    }
}

public struct AgentInputRequestResponse: Codable, Sendable, Hashable {
    public var agentId: AgentID
    public var requestId: String
    public var answers: [AgentInputRequestAnswer]

    public init(agentId: AgentID, requestId: String, answers: [AgentInputRequestAnswer]) {
        self.agentId = agentId
        self.requestId = requestId
        self.answers = answers
    }
}

public struct AgentStateSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var id: String { agentId }
    public var agentId: AgentID
    public var agentLabel: String
    public var adapterKind: AdapterKind
    public var status: AgentStatus
    public var statusDetail: String
    public var recentMessages: [AgentChatMessage]
    public var lastActivityUnixMs: Int64
    public var position: GridCellPosition
    public var hasVideoTrack: Bool
    public var availableTargets: [AgentTargetOption]?
    public var remoteAppId: String?
    public var pendingInputRequest: AgentInputRequest?
    public var runtimeControls: AgentRuntimeControls?

    public init(
        agentId: AgentID,
        agentLabel: String,
        adapterKind: AdapterKind,
        status: AgentStatus = .idle,
        statusDetail: String = "",
        recentMessages: [AgentChatMessage] = [],
        lastActivityUnixMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        position: GridCellPosition = GridCellPosition(row: 0, col: 0),
        hasVideoTrack: Bool = false,
        availableTargets: [AgentTargetOption]? = nil,
        remoteAppId: String? = nil,
        pendingInputRequest: AgentInputRequest? = nil,
        runtimeControls: AgentRuntimeControls? = nil
    ) {
        self.agentId = agentId
        self.agentLabel = agentLabel
        self.adapterKind = adapterKind
        self.status = status
        self.statusDetail = statusDetail
        self.recentMessages = recentMessages
        self.lastActivityUnixMs = lastActivityUnixMs
        self.position = position
        self.hasVideoTrack = hasVideoTrack
        self.availableTargets = availableTargets
        self.remoteAppId = remoteAppId
        self.pendingInputRequest = pendingInputRequest
        self.runtimeControls = runtimeControls
    }
}
