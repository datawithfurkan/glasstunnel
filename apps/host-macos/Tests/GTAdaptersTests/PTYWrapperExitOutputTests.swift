import Foundation
import XCTest
@testable import GTAdapters

final class PTYWrapperExitOutputTests: XCTestCase {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        private(set) var outputAtExit = ""
        private(set) var exitStatus: Int32?

        func append(_ chunk: String) {
            lock.lock(); text += chunk; lock.unlock()
        }

        func recordExit(status: Int32) {
            lock.lock()
            exitStatus = status
            outputAtExit = text
            lock.unlock()
        }
    }

    /// A process that prints and exits at once must not lose its last words:
    /// adapters read exit messages (Claude Code's "session held elsewhere",
    /// a shell's error) from the output that arrived before the exit state.
    func testOutputWrittenRightBeforeExitArrivesBeforeTheExitState() throws {
        let pty = PTYWrapper(executable: "/bin/sh", arguments: ["-c", "printf 'GT_LAST_WORDS'; exit 3"])
        let collector = Collector()
        let exited = expectation(description: "pty exit")
        pty.onData = { data in collector.append(String(decoding: data, as: UTF8.self)) }
        pty.onStateChange = { state in
            if case .exited(let status) = state {
                collector.recordExit(status: status)
                exited.fulfill()
            }
        }

        try pty.start()
        wait(for: [exited], timeout: 5)

        XCTAssertEqual(collector.exitStatus, 3)
        XCTAssertTrue(collector.outputAtExit.contains("GT_LAST_WORDS"), "Output seen at exit: \(collector.outputAtExit)")
    }
}
