import Foundation

/// Installs Claude Code hooks under `~/.claude/settings.json`. We only
/// write/rewrite the `glasstunnel` section under `hooks`; user-defined
/// entries are preserved verbatim.
public final class ClaudeCodeHookInstaller: @unchecked Sendable {
    public static let socketPath: String = {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Glasstunnel", isDirectory: true).appendingPathComponent("cc.sock").path
    }()

    private let configuredSettingsFileURL: URL?

    public init(settingsFileURL: URL? = nil) {
        self.configuredSettingsFileURL = settingsFileURL
    }

    public func installIfNeeded() throws {
        let settingsURL = try settingsFileURL()
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let data = try Data(contentsOf: settingsURL)
            if !data.isEmpty, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                settings = obj
            }
        }

        let hooks = hookConfig()
        var current = (settings["hooks"] as? [String: Any]) ?? [:]
        current["Stop"] = mergedHooks(existing: current["Stop"], glasstunnelHook: hooks.stop)
        current["SubagentStop"] = mergedHooks(existing: current["SubagentStop"], glasstunnelHook: hooks.subagentStop)
        current["Notification"] = mergedHooks(existing: current["Notification"], glasstunnelHook: hooks.notification)
        settings["hooks"] = current

        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }

    private func mergedHooks(existing: Any?, glasstunnelHook: [String: Any]) -> [Any] {
        let existingHooks = (existing as? [Any]) ?? []
        let preserved = existingHooks.filter { hook in
            !containsGlasstunnelCommand(hook)
        }
        return preserved + [glasstunnelHook]
    }

    private func containsGlasstunnelCommand(_ value: Any) -> Bool {
        if let dict = value as? [String: Any] {
            return dict.values.contains { containsGlasstunnelCommand($0) }
        }
        if let array = value as? [Any] {
            return array.contains { containsGlasstunnelCommand($0) }
        }
        if let string = value as? String {
            return string.contains(ClaudeCodeHookInstaller.socketPath)
                || string.contains("Glasstunnel/cc.sock")
        }
        return false
    }

    private func hookConfig() -> (stop: [String: Any], subagentStop: [String: Any], notification: [String: Any]) {
        let notify: [String: Any] = [
            "matcher": ".*",
            "hooks": [[
                "type": "command",
                "command": commandFor(event: "$CC_EVENT_KIND")
            ]]
        ]
        return (
            stop: notify.merging(["matcher": ".*"]) { _, new in new },
            subagentStop: notify.merging(["matcher": ".*"]) { _, new in new },
            notification: notify.merging(["matcher": ".*"]) { _, new in new }
        )
    }

    private func commandFor(event: String) -> String {
        _ = event
        // Claude Code hooks receive JSON on stdin. Forward only routing/status
        // metadata to Glasstunnel; transcript content is read from Claude's
        // local JSONL store by `ClaudeCodeSessionParser`.
        let socket = ClaudeCodeHookInstaller.socketPath
        let escapedSocket = socket.replacingOccurrences(of: "'", with: "'\\''")
        return """
        /bin/bash -c 'python3 -c '"'"'import json, socket, sys
        try:
            payload = json.load(sys.stdin)
        except Exception:
            payload = {}
        event = payload.get("hook_event_name") or payload.get("event") or payload.get("kind") or ""
        session = payload.get("session_id") or payload.get("sessionId") or payload.get("session") or ""
        summary = payload.get("message") or payload.get("notification") or event
        out = json.dumps({"kind": event, "session": session, "summary": summary}, separators=(",", ":")) + "\\n"
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(1)
        sock.connect("\(escapedSocket)")
        sock.sendall(out.encode("utf-8"))
        sock.close()
        '"'"' >/dev/null 2>&1 || true'
        """
    }

    private func settingsFileURL() throws -> URL {
        if let configuredSettingsFileURL {
            return configuredSettingsFileURL
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude").appendingPathComponent("settings.json")
    }
}
