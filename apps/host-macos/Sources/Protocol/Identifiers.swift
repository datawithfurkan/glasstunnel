import Foundation

public typealias DeviceID = String
public typealias AgentID = String
public typealias MessageID = String
public typealias SessionID = String

public enum AgentStatus: Int, Codable, Sendable, Hashable {
    case unspecified = 0
    case idle = 1
    case working = 2
    case waitingInput = 3
    case awaitingApproval = 4
    case done = 5
    case error = 6
    case disconnected = 7

    public var isTerminal: Bool {
        switch self {
        case .done, .error, .disconnected, .waitingInput, .awaitingApproval:
            return true
        default:
            return false
        }
    }

    public var userVisibleLabel: String {
        switch self {
        case .idle: return "Idle"
        case .working: return "Working"
        case .waitingInput: return "Waiting for input"
        case .awaitingApproval: return "Awaiting approval"
        case .done: return "Done"
        case .error: return "Error"
        case .disconnected: return "Disconnected"
        case .unspecified: return ""
        }
    }
}

public enum AdapterKind: Int, Codable, Sendable, Hashable, CaseIterable {
    case unspecified = 0
    case mirror = 1
    case cursor = 2
    case claudeCode = 3
    case codexCli = 4
    case openCode = 5
    case terminal = 6
    case geminiCli = 7
    case cursorAgent = 8
    case claudeDesktop = 9

    public var displayName: String {
        switch self {
        case .mirror: return "Mirror"
        case .cursor: return "Cursor"
        case .claudeCode: return "Claude Code"
        case .codexCli: return "Codex CLI"
        case .openCode: return "OpenCode"
        case .terminal: return "Terminal"
        case .geminiCli: return "Gemini CLI"
        case .cursorAgent: return "Cursor Agent"
        case .claudeDesktop: return "Claude"
        case .unspecified: return ""
        }
    }

    /// Display names advertised in the handshake.
    public static var advertisedDisplayNames: [String] {
        allCases
            .filter { $0 != .unspecified }
            .map(\.displayName)
    }

    public var icon: String {
        switch self {
        case .mirror: return "rectangle.inset.filled.and.person.filled"
        case .cursor: return "cursorarrow.rays"
        case .claudeCode: return "terminal"
        case .codexCli: return "terminal.fill"
        case .openCode: return "terminal"
        case .terminal: return "terminal.fill"
        case .geminiCli: return "terminal"
        case .cursorAgent: return "terminal"
        case .claudeDesktop: return "macwindow"
        case .unspecified: return "questionmark"
        }
    }
}

public enum ChatRole: Int, Codable, Sendable, Hashable {
    case unspecified = 0
    case user = 1
    case assistant = 2
    case system = 3
    case tool = 4
}

public enum QuickReplyKind: Int, Codable, Sendable, Hashable {
    case unspecified = 0
    case continueReply = 1
    case tryAgain = 2
    case explain = 3
    case commit = 4
    case stop = 5
    case approve = 6
    case reject = 7

    public var literalText: String {
        switch self {
        case .continueReply: return "continue"
        case .tryAgain: return "try again"
        case .explain: return "explain"
        case .commit: return "commit this change"
        case .stop: return "stop"
        case .approve: return "approve"
        case .reject: return "reject"
        case .unspecified: return ""
        }
    }
}

public enum GridShape: Int, Codable, Sendable, Hashable, CaseIterable {
    case unspecified = 0
    case oneByOne = 1
    case twoByOne = 2
    case oneByTwo = 3
    case twoByTwo = 4

    public var rows: Int {
        switch self {
        case .oneByOne, .twoByOne: return 1
        case .oneByTwo, .twoByTwo: return 2
        case .unspecified: return 0
        }
    }

    public var cols: Int {
        switch self {
        case .oneByOne, .oneByTwo: return 1
        case .twoByOne, .twoByTwo: return 2
        case .unspecified: return 0
        }
    }

    public var cellCount: Int { rows * cols }

    public var displayName: String {
        switch self {
        case .oneByOne: return "Single"
        case .twoByOne: return "Two across"
        case .oneByTwo: return "Two stacked"
        case .twoByTwo: return "Four (2x2)"
        case .unspecified: return ""
        }
    }
}
