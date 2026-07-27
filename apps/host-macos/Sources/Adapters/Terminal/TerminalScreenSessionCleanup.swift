import Foundation

public enum TerminalScreenSessionCleanup {
    public struct ScreenSession: Equatable, Sendable {
        public enum State: String, Sendable {
            case attached = "Attached"
            case detached = "Detached"
            case unknown = "Unknown"
        }

        public let identifier: String
        public let name: String
        public let state: State

        public init(identifier: String, name: String, state: State) {
            self.identifier = identifier
            self.name = name
            self.state = state
        }
    }

    public static func parseScreenList(_ output: String) -> [ScreenSession] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            parseScreenListLine(String(rawLine))
        }
    }

    public static func cleanupCandidates(from sessions: [ScreenSession]) -> [ScreenSession] {
        sessions.filter { session in
            session.state == .detached && isGeneratedGlasstunnelSessionName(session.name)
        }
    }

    public static func isGeneratedGlasstunnelSessionName(_ name: String) -> Bool {
        let prefix = "\(TerminalSessionConfiguration.sharedSessionName)-"
        guard name.hasPrefix(prefix) else { return false }

        let suffix = String(name.dropFirst(prefix.count))
        let pieces = suffix.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 1 || pieces.count == 2 else { return false }
        guard isDigits(String(pieces[0])), pieces[0].count >= 10 else { return false }
        if pieces.count == 2 {
            guard pieces[1].count >= 4, pieces[1].count <= 12 else { return false }
            return pieces[1].allSatisfy(\.isHexDigit)
        }
        return true
    }

    private static func parseScreenListLine(_ line: String) -> ScreenSession? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dotIndex = trimmed.firstIndex(of: ".") else { return nil }

        let identifier = String(trimmed[..<dotIndex])
        guard !identifier.isEmpty, identifier.allSatisfy(\.isNumber) else { return nil }

        let afterDot = trimmed[trimmed.index(after: dotIndex)...]
        let nameEnd = afterDot.firstIndex { $0.isWhitespace || $0 == "(" } ?? afterDot.endIndex
        let name = String(afterDot[..<nameEnd])
        guard !name.isEmpty else { return nil }

        let state: ScreenSession.State
        if trimmed.contains("(Attached)") {
            state = .attached
        } else if trimmed.contains("(Detached)") {
            state = .detached
        } else {
            state = .unknown
        }

        return ScreenSession(identifier: identifier, name: name, state: state)
    }

    private static func isDigits(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy(\.isNumber)
    }
}
