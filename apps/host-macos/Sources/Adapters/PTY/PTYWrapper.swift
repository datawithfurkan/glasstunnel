#if os(macOS)
import Darwin
import Foundation

/// A minimal PTY (pseudo-terminal) wrapper for running an interactive CLI
/// tool under glasstunnel's control. Spawns the child process connected to
/// a PTY so the tool believes it's running in a real terminal.
///
/// Used by the Claude Code, Codex CLI, and OpenCode adapters. The Mirror
/// adapter does NOT use PTY - it just shows the user's existing terminal
/// window and injects synthetic keystrokes into it.
public final class PTYWrapper: @unchecked Sendable {
    public enum State: Sendable {
        case idle
        case running(pid: pid_t)
        case exited(status: Int32)
        case error(String)
    }

    public var onData: (@Sendable (Data) -> Void)?
    public var onStateChange: (@Sendable (State) -> Void)?

    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]
    private let cwd: String?
    private let ioQueue = DispatchQueue(label: "io.glasstunnel.pty.io")

    private var masterFD: Int32 = -1
    private var pid: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var state: State = .idle
    private var processRecordURL: URL?

    public init(executable: String, arguments: [String] = [], environment: [String: String] = [:], cwd: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
    }

    public func start() throws {
        var master: Int32 = 0
        var slave: Int32 = 0
        var ws = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        let openResult = withUnsafeMutablePointer(to: &ws) { wsPtr in
            openpty(&master, &slave, nil, nil, wsPtr)
        }
        guard openResult == 0 else {
            throw PTYError.openFailed(errno)
        }

        let cmd = [executable] + arguments
        var argv: [UnsafeMutablePointer<CChar>?] = cmd.map { strdup($0) }
        argv.append(nil)

        let envpStrings = Self.terminalEnvironment(overrides: environment)
            .map { "\($0.key)=\($0.value)" }
        var envp: [UnsafeMutablePointer<CChar>?] = envpStrings.map { strdup($0) }
        envp.append(nil)

        var fileActions = posix_spawn_file_actions_t(bitPattern: 0)
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, master)
        posix_spawn_file_actions_addclose(&fileActions, slave)

        if let cwd {
            if #available(macOS 10.15, *) {
                cwd.withCString { cstr in
                    _ = posix_spawn_file_actions_addchdir_np(&fileActions, cstr)
                }
            }
        }

        var attr = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var flags: Int16 = 0
        flags |= Int16(POSIX_SPAWN_SETSIGDEF)
        flags |= Int16(POSIX_SPAWN_SETPGROUP)
        posix_spawnattr_setpgroup(&attr, 0)
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGPIPE)
        posix_spawnattr_setsigdefault(&attr, &defaultSignals)
        posix_spawnattr_setflags(&attr, flags)

        var childPid: pid_t = 0
        let result = posix_spawnp(&childPid, executable, &fileActions, &attr, argv, envp)
        argv.forEach { free($0) }
        envp.forEach { free($0) }
        close(slave)

        guard result == 0 else {
            close(master)
            throw PTYError.spawnFailed(Int32(result))
        }

        let spawnedPid = childPid
        self.masterFD = master
        self.pid = spawnedPid
        self.processRecordURL = Self.recordProcess(childPid: spawnedPid, executable: executable, arguments: arguments)
        startReader()
        state = .running(pid: spawnedPid)
        onStateChange?(state)

        let processRecordURL = self.processRecordURL
        Task.detached { [weak self, spawnedPid, processRecordURL] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(spawnedPid, &status, 0)
            self.pid = -1
            if self.masterFD != -1 {
                close(self.masterFD)
                self.masterFD = -1
            }
            self.readSource?.cancel()
            self.readSource = nil
            if let processRecordURL {
                try? FileManager.default.removeItem(at: processRecordURL)
            }
            let exit = (status >> 8) & 0xff
            self.state = .exited(status: exit)
            self.onStateChange?(.exited(status: exit))
        }
    }

    public func write(_ data: Data) {
        guard masterFD != -1 else { return }
        data.withUnsafeBytes { ptr in
            _ = Darwin.write(masterFD, ptr.baseAddress, data.count)
        }
    }

    public func writeString(_ text: String) {
        guard let d = text.data(using: .utf8) else { return }
        write(d)
    }

    public func interrupt() {
        writeString("\u{0003}") // Ctrl+C
        signalProcessGroup(SIGINT)
    }

    public func stop() {
        let childPid = pid
        guard childPid > 0 else { return }

        // Immediately tear down I/O to prevent further reads/writes.
        readSource?.cancel()
        readSource = nil
        if masterFD != -1 {
            close(masterFD)
            masterFD = -1
        }

        signalProcessGroup(SIGTERM, fallbackPid: childPid)

        // Escalate to SIGKILL if the child ignores SIGTERM.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            if self.pid == childPid {
                self.signalProcessGroup(SIGKILL, fallbackPid: childPid)
            }
        }
    }

    @discardableResult
    public static func reapStaleRecordedProcesses() -> Int {
        reapStaleRecordedProcesses(
            currentOwnerPid: getpid(),
            processIsRunning: { pid in
                kill(pid, 0) == 0 || errno == EPERM
            },
            signalProcessGroup: { childPid, signal in
                if kill(-childPid, signal) != 0 {
                    kill(childPid, signal)
                }
            }
        )
    }

    @discardableResult
    static func reapStaleRecordedProcesses(
        currentOwnerPid: pid_t,
        processIsRunning: (pid_t) -> Bool,
        signalProcessGroup: (pid_t, Int32) -> Void,
        registryDirectory: URL = processRegistryDirectory()
    ) -> Int {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: registryDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var reaped = 0
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(ProcessRecord.self, from: data) else {
                try? manager.removeItem(at: file)
                continue
            }
            guard record.ownerPid != currentOwnerPid else { continue }
            guard !processIsRunning(record.ownerPid) else { continue }
            guard record.childPid > 0 else {
                try? manager.removeItem(at: file)
                continue
            }
            signalProcessGroup(record.childPid, SIGTERM)
            reaped += 1
            try? manager.removeItem(at: file)
        }
        return reaped
    }

    private func signalProcessGroup(_ signal: Int32, fallbackPid: pid_t? = nil) {
        let childPid = fallbackPid ?? pid
        guard childPid > 0 else { return }
        if kill(-childPid, signal) != 0 {
            kill(childPid, signal)
        }
    }

    private func startReader() {
        readSource?.cancel()
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: ioQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(self.masterFD, &buf, buf.count)
            if n > 0 {
                let data = Data(bytes: buf, count: n)
                self.respondToTerminalQueries(in: data)
                self.onData?(data)
            }
        }
        source.setCancelHandler { }
        source.resume()
        readSource = source
    }

    private func respondToTerminalQueries(in data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        var response = ""

        if text.contains("\u{001B}[6n") {
            response += "\u{001B}[1;1R"
        }
        if text.contains("\u{001B}]10;?\u{001B}\\") || text.contains("\u{001B}]10;?\u{0007}") {
            response += "\u{001B}]10;rgb:ffff/ffff/ffff\u{001B}\\"
        }
        if text.contains("\u{001B}]11;?\u{001B}\\") || text.contains("\u{001B}]11;?\u{0007}") {
            response += "\u{001B}]11;rgb:0000/0000/0000\u{001B}\\"
        }
        if text.contains("\u{001B}[c") {
            response += "\u{001B}[?1;2c"
        }

        if !response.isEmpty {
            writeString(response)
        }
    }

    private static func recordProcess(childPid: pid_t, executable: String, arguments: [String]) -> URL? {
        let directory = processRegistryDirectory()
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let record = ProcessRecord(
                ownerPid: getpid(),
                childPid: childPid,
                executable: executable,
                arguments: arguments,
                preserveOnOwnerExit: false,
                createdAt: Date()
            )
            let data = try JSONEncoder().encode(record)
            let url = directory.appendingPathComponent("\(childPid).json")
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    private static func processRegistryDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("Glasstunnel", isDirectory: true)
            .appendingPathComponent("pty-processes", isDirectory: true)
    }

    struct ProcessRecord: Codable, Equatable {
        let ownerPid: pid_t
        let childPid: pid_t
        let executable: String
        let arguments: [String]
        // Retained so records written by older builds still decode. Attachments are
        // always reaped when their owner is gone; the screen server keeps the session.
        let preserveOnOwnerExit: Bool
        let createdAt: Date
    }

    static func terminalEnvironment(overrides: [String: String]) -> [String: String] {
        var merged = ProcessInfo.processInfo.environment.merging(overrides) { _, new in new }
        let term = merged["TERM"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if term == nil || term == "" || term == "dumb" {
            merged["TERM"] = "xterm-256color"
        }
        return merged
    }
}

public enum PTYError: Error, Sendable {
    case openFailed(Int32)
    case spawnFailed(Int32)
}

/// Strips ANSI CSI escape sequences (colors, cursor moves, clear-line, etc.)
/// from captured PTY output so we can render it cleanly on the phone.
public enum ANSIStripper {
    private static let clearLineToken: Character = "\u{000B}"
    private static let clearLinePattern: NSRegularExpression = {
        let esc = "\u{001B}"
        return try! NSRegularExpression(pattern: "\(esc)\\[[0-?]*[ -/]*K", options: [])
    }()

    private static let pattern: NSRegularExpression = {
        let esc = "\u{001B}"
        let bel = "\u{0007}"
        // CSI sequences + OSC (terminated by BEL) + single-char ESC sequences.
        let raw = "\(esc)(?:\\[[0-?]*[ -/]*[@-~]|\\].*?\(bel)|[@-Z\\\\_])"
        return try! NSRegularExpression(pattern: raw, options: [])
    }()

    public static func strip(_ input: String) -> String {
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return pattern.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: "")
    }

    public static func normalizeForLog(_ input: String) -> String {
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        let withClearLineTokens = clearLinePattern.stringByReplacingMatches(
            in: input,
            options: [],
            range: range,
            withTemplate: String(clearLineToken)
        )
        return collapseLineRewrites(strip(withClearLineTokens))
    }

    static func collapseLineRewrites(_ input: String) -> String {
        var lines: [[Character]] = [[]]
        var cursor = 0

        func updateCurrentLine(_ body: (inout [Character]) -> Void) {
            var line = lines.removeLast()
            body(&line)
            lines.append(line)
        }

        for character in input {
            switch character {
            case "\r":
                cursor = 0
            case "\n":
                lines.append([])
                cursor = 0
            case clearLineToken:
                updateCurrentLine { line in
                    line.removeAll()
                }
                cursor = 0
            case "\u{0008}", "\u{007F}":
                guard cursor > 0 else { continue }
                cursor -= 1
                updateCurrentLine { line in
                    if cursor < line.count {
                        line.remove(at: cursor)
                    }
                }
            default:
                updateCurrentLine { line in
                    while cursor > line.count {
                        line.append(" ")
                    }
                    if cursor < line.count {
                        line[cursor] = character
                    } else {
                        line.append(character)
                    }
                }
                cursor += 1
            }
        }

        return lines.map { String($0) }.joined(separator: "\n")
    }
}
#else
public final class PTYWrapper: @unchecked Sendable {
    public init(executable: String, arguments: [String] = [], environment: [String: String] = [:], cwd: String? = nil) {}
    public func start() throws {}
    public func write(_ data: Data) {}
    public func writeString(_ text: String) {}
    public func interrupt() {}
    public func stop() {}
}
public enum ANSIStripper {
    public static func strip(_ input: String) -> String { input }
}
#endif
