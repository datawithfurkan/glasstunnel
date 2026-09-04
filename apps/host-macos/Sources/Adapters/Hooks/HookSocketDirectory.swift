import Foundation
#if os(macOS)
import Darwin
#endif

/// Where Glasstunnel hosts listen for hook events.
///
/// Every host process binds its own socket in this directory, and the hook
/// commands Glasstunnel installs send each event to every socket found there
/// (and to the single legacy path older hosts bind). Two hosts on one Mac,
/// the installed app and a lab or development build, therefore both hear
/// every event; before this they shared one path and the last host to start
/// silently took the hooks away from the other.
public enum HookSocketDirectory {
    private static let lock = NSLock()
    private static var override: URL?

    /// Tests point this at a temporary directory; nil means the real one.
    public static var directoryOverride: URL? {
        get { lock.lock(); defer { lock.unlock() }; return override }
        set { lock.lock(); override = newValue; lock.unlock() }
    }

    public static var directoryURL: URL {
        if let directoryOverride { return directoryOverride }
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("Glasstunnel", isDirectory: true)
            .appendingPathComponent("hooks", isDirectory: true)
    }

    /// Unique per process, so two hosts never bind the same file.
    public static let processSuffix: String = {
        let random = UUID().uuidString.lowercased().prefix(8)
        return "\(ProcessInfo.processInfo.processIdentifier)-\(random)"
    }()

    /// The socket this process binds for a hook family ("cc" for Claude Code,
    /// "cursor" for Cursor).
    public static func socketPath(family: String) -> String {
        directoryURL.appendingPathComponent("\(family)-\(processSuffix).sock").path
    }

    /// The shell-glob pattern the hook commands expand to find every host.
    public static func globPattern(family: String) -> String {
        directoryURL.appendingPathComponent("\(family)-*.sock").path
    }

    /// Python source, for the installed hook commands, that delivers the
    /// string `out` to every live socket of `family` and to `legacyPath`.
    /// Uses double quotes only: the program is wrapped in bash single quotes.
    public static func pythonDelivery(family: String, legacyPath: String) -> String {
        let pattern = globPattern(family: family).replacingOccurrences(of: "'", with: "'\\''")
        let legacy = legacyPath.replacingOccurrences(of: "'", with: "'\\''")
        return """
        import glob, os
        targets = sorted(glob.glob("\(pattern)")) + ["\(legacy)"]
        for path in targets:
            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.settimeout(1)
                sock.connect(path)
                sock.sendall(out.encode("utf-8"))
                sock.close()
            except Exception:
                pass
        """
    }

    #if os(macOS)
    /// Removes sockets in the directory whose host is gone (nothing accepts a
    /// connection), keeping `except` (the socket this process is about to bind).
    public static func removeStaleSockets(except keep: String? = nil) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directoryURL.path) else { return }
        for name in names where name.hasSuffix(".sock") {
            let path = directoryURL.appendingPathComponent(name).path
            if path == keep { continue }
            if !isLive(path) { _ = unlink(path) }
        }
    }

    static func isLive(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd != -1 else { return true }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard bytes.count <= maxLen else { return true }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for i in 0..<bytes.count { buf[i] = bytes[i] }
            buf[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, len)
            }
        }
        return result == 0
    }
    #else
    public static func removeStaleSockets(except keep: String? = nil) {}
    #endif
}
