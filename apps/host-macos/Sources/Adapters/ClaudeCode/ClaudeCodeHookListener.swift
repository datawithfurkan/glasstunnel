#if os(macOS)
import Darwin
import Foundation

/// Listens on a Unix-domain socket for JSON events posted by our installed
/// Claude Code hooks. Each line of JSON is one event.
public final class ClaudeCodeHookListener: @unchecked Sendable {
    public enum HookKind: String, Sendable {
        case stop = "Stop"
        case subagentStop = "SubagentStop"
        case notification = "Notification"
    }

    public struct Event: Sendable {
        public let kind: HookKind
        public let session: String
        public let summary: String
    }

    public var onHook: (@Sendable (Event) -> Void)?

    private var socketFD: Int32 = -1
    private var source: DispatchSourceRead?

    public init() {}

    public func start() throws {
        let path = ClaudeCodeHookInstaller.socketPath
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd == -1 { throw NSError(domain: "HookListener", code: Int(errno)) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        let copyLen = min(pathBytes.count, maxLen)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for i in 0..<copyLen {
                buf[i] = pathBytes[i]
            }
            buf[copyLen] = 0
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, len)
            }
        }
        if bindResult != 0 {
            close(fd)
            throw NSError(domain: "HookListener", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "bind failed"])
        }
        if listen(fd, 8) != 0 {
            close(fd)
            throw NSError(domain: "HookListener", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "listen failed"])
        }

        self.socketFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        if socketFD != -1 {
            close(socketFD)
            socketFD = -1
        }
    }

    private func acceptConnection() {
        var clientAddr = sockaddr()
        var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
        let client = accept(socketFD, &clientAddr, &clientLen)
        if client == -1 { return }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(client, &buf, buf.count)
        close(client)
        guard n > 0 else { return }
        let data = Data(bytes: buf, count: n)
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard let kindString = obj["kind"] as? String, let kind = HookKind(rawValue: kindString) else { return }
        let session = (obj["session"] as? String) ?? ""
        let summary = (obj["summary"] as? String) ?? kindString
        onHook?(Event(kind: kind, session: session, summary: summary))
    }
}
#else
public final class ClaudeCodeHookListener: @unchecked Sendable {
    public init() {}
    public enum HookKind: String, Sendable { case stop = "Stop", subagentStop = "SubagentStop", notification = "Notification" }
    public struct Event: Sendable { public let kind: HookKind; public let session: String; public let summary: String }
    public var onHook: (@Sendable (Event) -> Void)?
    public func start() throws {}
    public func stop() {}
}
#endif
