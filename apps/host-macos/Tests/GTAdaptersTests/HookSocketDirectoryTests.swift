#if os(macOS)
import XCTest
@testable import GTAdapters

/// Two hosts on one Mac each bind their own socket and the installed hook
/// command reaches both; sockets left by dead hosts are cleaned up.
final class HookSocketDirectoryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("gt-hooks-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        HookSocketDirectory.directoryOverride = directory
    }

    override func tearDownWithError() throws {
        HookSocketDirectory.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testEveryHostReceivesAHookLineDeliveredByTheInstalledCommand() throws {
        let first = HookSocketListener(path: directory.appendingPathComponent("cursor-1111-aaaa.sock").path)
        let second = HookSocketListener(path: directory.appendingPathComponent("cursor-2222-bbbb.sock").path)
        let firstLine = expectation(description: "first host")
        let secondLine = expectation(description: "second host")
        first.onLine = { line in if line.contains("\"kind\":\"stop\"") { firstLine.fulfill() } }
        second.onLine = { line in if line.contains("\"kind\":\"stop\"") { secondLine.fulfill() } }
        try first.start()
        try second.start()
        defer { first.stop(); second.stop() }

        // The exact delivery code the hook commands carry, run by python3.
        let program = """
        import json, socket, sys
        out = json.dumps({"kind": "stop"}, separators=(",", ":")) + "\\n"
        \(HookSocketDirectory.pythonDelivery(family: "cursor", legacyPath: directory.appendingPathComponent("legacy.sock").path))
        """
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        python.arguments = ["python3", "-c", program]
        try python.run()
        python.waitUntilExit()
        XCTAssertEqual(python.terminationStatus, 0, "a missing legacy socket must not fail the hook")

        wait(for: [firstLine, secondLine], timeout: 5)
    }

    func testSocketsOfDeadHostsAreRemovedAndLiveOnesKept() throws {
        let live = HookSocketListener(path: HookSocketDirectory.socketPath(family: "cc"))
        try live.start()
        defer { live.stop() }
        let dead = directory.appendingPathComponent("cc-1-dead.sock").path
        FileManager.default.createFile(atPath: dead, contents: Data())
        let other = directory.appendingPathComponent("notes.txt").path
        FileManager.default.createFile(atPath: other, contents: Data())

        HookSocketDirectory.removeStaleSockets(except: live.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dead), "a socket nobody accepts on is gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path), "the live host keeps its socket")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other), "only .sock files are touched")
        XCTAssertTrue(live.path.hasSuffix("-\(HookSocketDirectory.processSuffix).sock"))
    }

    func testStoppingAListenerUnlinksItsSocket() throws {
        let listener = ClaudeCodeHookListener()
        try listener.start()
        XCTAssertTrue(listener.path.hasPrefix(directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: listener.path))
        listener.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: listener.path))
    }

    func testInstalledCommandsNameEveryHostAndTheLegacyPath() {
        // The override points the glob at this test's directory; the real
        // command names the hooks directory under Application Support.
        let claude = ClaudeCodeHookInstaller().commandFor(event: "Stop")
        XCTAssertTrue(claude.contains("glob.glob(\"\(directory.path)/cc-*.sock\")"), "fans out to every running host")
        XCTAssertTrue(claude.contains("Glasstunnel/cc.sock"), "still reaches a host from before 0.1.10")
        let cursor = CursorHookInstaller.hookCommand()
        XCTAssertTrue(cursor.contains("glob.glob(\"\(directory.path)/cursor-*.sock\")"))
        XCTAssertTrue(cursor.contains("Glasstunnel/cursor.sock"))

        HookSocketDirectory.directoryOverride = nil
        XCTAssertTrue(HookSocketDirectory.globPattern(family: "cc").hasSuffix("/Glasstunnel/hooks/cc-*.sock"))
        XCTAssertTrue(ClaudeCodeHookInstaller().commandFor(event: "Stop").contains("Glasstunnel/hooks/cc-*.sock"))
    }
}
#endif
