import Foundation

public enum TerminalSessionConfiguration {
    public struct Launch: Equatable, Sendable {
        public let executable: String
        public let arguments: [String]
    }

    public static let sharedSessionName = "glasstunnel-terminal"
    public static let screenExecutable = "/usr/bin/screen"

    public static func defaultLaunch(
        shell: String?,
        sessionName: String = sharedSessionName,
        executableExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Launch {
        if executableExists(screenExecutable) {
            return Launch(
                executable: screenExecutable,
                arguments: ["-xRR", "-S", sessionName]
            )
        }

        let trimmedShell = shell?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Launch(
            executable: trimmedShell.isEmpty ? "/bin/zsh" : trimmedShell,
            arguments: ["-l"]
        )
    }

    public static func visibleTerminalCommand() -> String {
        visibleTerminalCommand(sessionName: sharedSessionName)
    }

    public static func visibleTerminalCommand(sessionName: String) -> String {
        "exec \(screenExecutable) -xRR -S \(sessionName)"
    }
}
