import Foundation

/// Abstraction over a Unix-domain socket that receives one JSON line per
/// event from hook commands installed into a coding agent's configuration.
/// Routers own one listener process-wide; tests substitute a fake.
public protocol HookLineSource: AnyObject, Sendable {
    var onLine: (@Sendable (String) -> Void)? { get set }
    func start() throws
    func stop()
}

#if os(macOS)
import Darwin

/// Listens on a Unix-domain socket for newline-delimited JSON posted by
/// installed hook commands. Each connection is read to EOF, so a payload
/// larger than one read still arrives whole.
public final class HookSocketListener: HookLineSource, @unchecked Sendable {
    public let path: String
    public var onLine: (@Sendable (String) -> Void)?

    private var socketFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let maxBytesPerConnection = 256 * 1024

    public init(path: String) {
        self.path = path
    }

    public func start() throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd == -1 { throw NSError(domain: "HookSocketListener", code: Int(errno)) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count <= maxLen else {
            close(fd)
            throw NSError(
                domain: "HookSocketListener",
                code: Int(ENAMETOOLONG),
                userInfo: [NSLocalizedDescriptionKey: "socket path is too long"]
            )
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for i in 0..<pathBytes.count {
                buf[i] = pathBytes[i]
            }
            buf[pathBytes.count] = 0
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, len)
            }
        }
        if bindResult != 0 {
            close(fd)
            throw NSError(domain: "HookSocketListener", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "bind failed"])
        }
        if listen(fd, 8) != 0 {
            close(fd)
            throw NSError(domain: "HookSocketListener", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "listen failed"])
        }

        socketFD = fd
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
        _ = unlink(path)
    }

    private func acceptConnection() {
        var clientAddr = sockaddr()
        var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
        let client = accept(socketFD, &clientAddr, &clientLen)
        if client == -1 { return }
        defer { close(client) }

        var received = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while received.count < maxBytesPerConnection {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break }
            received.append(buf, count: n)
        }
        guard !received.isEmpty, let text = String(data: received, encoding: .utf8) else { return }
        for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
            onLine?(String(line))
        }
    }
}
#else
public final class HookSocketListener: HookLineSource, @unchecked Sendable {
    public let path: String
    public var onLine: (@Sendable (String) -> Void)?
    public init(path: String) { self.path = path }
    public func start() throws {}
    public func stop() {}
}
#endif
