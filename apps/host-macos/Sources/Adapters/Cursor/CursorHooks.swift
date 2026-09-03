import Foundation

/// Installs Glasstunnel's hook commands into `~/.cursor/hooks.json`.
///
/// Cursor (the desktop app and the `cursor-agent` CLI alike) reads this
/// user-global file: `{"version": 1, "hooks": {"<event>": [{"command": "…"}]}}`.
/// The installer only adds or replaces entries whose command names the
/// Glasstunnel socket; every user entry, every other event, and every other
/// top-level key are preserved verbatim. A file that is not valid JSON is left
/// alone and reported, never overwritten.
public final class CursorHookInstaller: @unchecked Sendable {
    public static let socketPath: String = {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Glasstunnel", isDirectory: true).appendingPathComponent("cursor.sock").path
    }()

    /// Events Glasstunnel subscribes to. The prompt itself is never forwarded
    /// (the chat stores carry it); `beforeSubmitPrompt` is used as the start of
    /// a turn, the tool hooks as live rows, and `stop` as the end of a turn.
    public static let events = ["beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure", "stop"]

    public enum InstallError: Error, CustomStringConvertible {
        case unreadable(String)

        public var description: String {
            switch self {
            case .unreadable(let reason):
                return "~/.cursor/hooks.json could not be parsed (\(reason)); fix it before Glasstunnel can add its hooks"
            }
        }
    }

    private let configuredFileURL: URL?

    public init(hooksFileURL: URL? = nil) {
        self.configuredFileURL = hooksFileURL
    }

    public static func defaultHooksFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    public var hooksFileURL: URL {
        configuredFileURL ?? Self.defaultHooksFileURL()
    }

    public func installIfNeeded() throws {
        let url = hooksFileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var config: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw InstallError.unreadable("not a JSON object")
                }
                config = object
            }
        }

        if config["version"] == nil {
            config["version"] = 1
        }
        var hooks = (config["hooks"] as? [String: Any]) ?? [:]
        let command = Self.hookCommand()
        for event in Self.events {
            let existing = (hooks[event] as? [Any]) ?? []
            let preserved = existing.filter { !Self.namesGlasstunnelSocket($0) }
            hooks[event] = preserved + [["command": command]]
        }
        config["hooks"] = hooks

        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    /// True when the file already carries a Glasstunnel entry for every event.
    public func isInstalled() -> Bool {
        guard
            let data = try? Data(contentsOf: hooksFileURL),
            let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hooks = config["hooks"] as? [String: Any]
        else {
            return false
        }
        return Self.events.allSatisfy { event in
            ((hooks[event] as? [Any]) ?? []).contains(where: Self.namesGlasstunnelSocket)
        }
    }

    static func namesGlasstunnelSocket(_ value: Any) -> Bool {
        if let dict = value as? [String: Any] {
            return dict.values.contains { namesGlasstunnelSocket($0) }
        }
        if let array = value as? [Any] {
            return array.contains { namesGlasstunnelSocket($0) }
        }
        if let string = value as? String {
            return string.contains(socketPath) || string.contains("Glasstunnel/cursor.sock")
        }
        return false
    }

    /// The hook command. Cursor passes the event as JSON on stdin and waits for
    /// stdout; printing nothing lets the action proceed. Only routing and
    /// status metadata are forwarded; prompt text, tool input, and tool output
    /// stay in Cursor's own stores, which the adapters read locally.
    static func hookCommand() -> String {
        let escapedSocket = socketPath.replacingOccurrences(of: "'", with: "'\\''")
        return """
        /bin/bash -c 'python3 -c '"'"'import json, socket, sys
        try:
            p = json.load(sys.stdin)
        except Exception:
            p = {}
        def s(k):
            v = p.get(k)
            return v if isinstance(v, str) else ""
        tool_input = p.get("tool_input") if isinstance(p.get("tool_input"), dict) else {}
        title = ""
        for key in ("command", "cmd", "path", "file_path", "target_file", "pattern", "query", "url", "description"):
            v = tool_input.get(key)
            if isinstance(v, str) and v.strip():
                title = " ".join(v.split())[:120]
                break
        roots = p.get("workspace_roots")
        out = json.dumps({"kind": s("hook_event_name"), "conversation": s("conversation_id"), "generation": s("generation_id"), "status": s("status"), "tool": s("tool_name"), "title": title, "transcript": s("transcript_path"), "roots": roots if isinstance(roots, list) else [], "model": s("model"), "mode": s("composer_mode"), "callId": s("tool_call_id") or s("tool_use_id")}, separators=(",", ":")) + "\\n"
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(1)
        sock.connect("\(escapedSocket)")
        sock.sendall(out.encode("utf-8"))
        sock.close()
        '"'"' >/dev/null 2>&1 || true'
        """
    }
}

/// One event forwarded by an installed Cursor hook.
public struct CursorHookEvent: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case beforeSubmitPrompt
        case preToolUse
        case postToolUse
        case postToolUseFailure
        case stop
        case other
    }

    public let kind: Kind
    /// The raw `hook_event_name`, kept for kinds this build does not model.
    public let rawKind: String
    /// Cursor's `conversation_id`: the desktop composer id or the CLI chat id.
    public let conversation: String
    public let generation: String
    /// `stop.status`: `completed`, `aborted`, or `error`.
    public let status: String
    public let toolName: String
    /// One line derived from the tool input by the hook command (a command, a
    /// path, a pattern); never the full input.
    public let toolTitle: String
    public let toolCallId: String
    public let transcriptPath: String
    public let workspaceRoots: [String]
    public let model: String
    public let mode: String
    public let receivedAtUnixMs: Int64

    public init(
        kind: Kind,
        rawKind: String = "",
        conversation: String,
        generation: String = "",
        status: String = "",
        toolName: String = "",
        toolTitle: String = "",
        toolCallId: String = "",
        transcriptPath: String = "",
        workspaceRoots: [String] = [],
        model: String = "",
        mode: String = "",
        receivedAtUnixMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.kind = kind
        self.rawKind = rawKind.isEmpty ? kind.rawValue : rawKind
        self.conversation = conversation
        self.generation = generation
        self.status = status
        self.toolName = toolName
        self.toolTitle = toolTitle
        self.toolCallId = toolCallId
        self.transcriptPath = transcriptPath
        self.workspaceRoots = workspaceRoots
        self.model = model
        self.mode = mode
        self.receivedAtUnixMs = receivedAtUnixMs
    }

    /// Decodes one line written by the hook command. Lines that are not JSON
    /// objects, or that name no event, are ignored.
    public static func decode(line: String) -> CursorHookEvent? {
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        func string(_ key: String) -> String {
            (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let rawKind = string("kind")
        guard !rawKind.isEmpty else { return nil }
        return CursorHookEvent(
            kind: Kind(rawValue: rawKind) ?? .other,
            rawKind: rawKind,
            conversation: string("conversation"),
            generation: string("generation"),
            status: string("status"),
            toolName: string("tool"),
            toolTitle: string("title"),
            toolCallId: string("callId"),
            transcriptPath: string("transcript"),
            workspaceRoots: (object["roots"] as? [Any])?.compactMap { $0 as? String } ?? [],
            model: string("model"),
            mode: string("mode")
        )
    }
}

/// Routes Cursor hook events from the single shared socket to the adapter
/// that owns the conversation they belong to.
///
/// The hooks are user-global and fire for every Cursor chat by either client,
/// so the socket is owned process-wide; adapters subscribe with an ownership
/// predicate over the conversation id (the CLI card knows the chat ids it
/// created or resumed, the desktop card the composer ids in the app's store).
/// Events no subscriber owns are dropped rather than guessed at.
public final class CursorHookRouter: @unchecked Sendable {
    public static let shared = CursorHookRouter()

    private struct Subscriber {
        let ownsConversation: @Sendable (String) -> Bool
        let handler: @Sendable (CursorHookEvent) -> Void
    }

    private let lock = NSLock()
    private let makeListener: @Sendable () -> any HookLineSource
    private var listener: (any HookLineSource)?
    private var subscribers: [UUID: Subscriber] = [:]

    public init(makeListener: @escaping @Sendable () -> any HookLineSource = { HookSocketListener(path: CursorHookInstaller.socketPath) }) {
        self.makeListener = makeListener
    }

    /// The socket is bound inside the critical section and the subscriber is
    /// registered only once that succeeded.
    public func subscribe(
        ownsConversation: @escaping @Sendable (String) -> Bool,
        handler: @escaping @Sendable (CursorHookEvent) -> Void
    ) throws -> UUID {
        lock.lock()
        defer { lock.unlock() }

        if listener == nil {
            let fresh = makeListener()
            fresh.onLine = { [weak self] line in
                guard let event = CursorHookEvent.decode(line: line) else { return }
                self?.route(event)
            }
            try fresh.start()
            listener = fresh
        }
        let id = UUID()
        subscribers[id] = Subscriber(ownsConversation: ownsConversation, handler: handler)
        return id
    }

    public func unsubscribe(_ id: UUID) {
        lock.lock()
        subscribers.removeValue(forKey: id)
        let idle = subscribers.isEmpty
        let current = listener
        if idle { listener = nil }
        lock.unlock()
        if idle { current?.stop() }
    }

    func route(_ event: CursorHookEvent) {
        lock.lock()
        let all = Array(subscribers.values)
        lock.unlock()

        for subscriber in all where subscriber.ownsConversation(event.conversation) {
            subscriber.handler(event)
        }
    }
}
