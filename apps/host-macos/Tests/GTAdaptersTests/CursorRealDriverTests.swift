import AppKit
import XCTest
@testable import GTAdapters

/// Opt-in check against the running Cursor app: shows the chat named by
/// `GT_CURSOR_REAL_CHAT` (default "GT cursor submit response"), writes a probe
/// line into the composer without submitting, and clears it again. Run with
/// `GT_CURSOR_REAL_DRIVER=1` on a Mac where Cursor is open; skipped otherwise.
final class CursorRealDriverTests: XCTestCase {
    func testRealDriverShowsAChatAndWritesIntoTheComposerWithoutSubmitting() throws {
        guard ProcessInfo.processInfo.environment["GT_CURSOR_REAL_DRIVER"] == "1" else {
            throw XCTSkip("set GT_CURSOR_REAL_DRIVER=1 with Cursor open to run this check")
        }
        let chat = ProcessInfo.processInfo.environment["GT_CURSOR_REAL_CHAT"] ?? "GT cursor submit response"
        let driver = CursorAccessibilityDriver()
        var clock = Date()
        func lap(_ label: String) { print("[real driver] \(label) after \(String(format: "%.2f", Date().timeIntervalSince(clock)))s"); clock = Date() }

        // With GT_CURSOR_REAL_OTHER_CHAT set, another chat is shown first so the
        // write happens right after a switch, as it does on the phone.
        if let other = ProcessInfo.processInfo.environment["GT_CURSOR_REAL_OTHER_CHAT"] {
            do { try driver.showChat(titled: other) } catch { XCTFail("showChat(other) failed: \(error)") }
            Thread.sleep(forTimeInterval: 1.5)
            print("[real driver] other chat shown: \(driver.frontChatTitle(candidates: [other, chat]) ?? "nil")")
            lap("show other chat")
        }
        print("[real driver] front chat before: \(driver.frontChatTitle(candidates: [chat]) ?? "nil")")
        lap("read front title")
        do { try driver.showChat(titled: chat) } catch { XCTFail("showChat failed: \(error)") }
        lap("showChat")
        Thread.sleep(forTimeInterval: 0.5)
        let front = driver.frontChatTitle(candidates: [chat])
        print("[real driver] front chat after showChat: \(front ?? "nil")")
        XCTAssertEqual(front, chat)
        lap("read front title again")

        do {
            try driver.deliver(text: "GT driver probe, not submitted", submit: false)
            lap("deliver (ok)")
        } catch {
            lap("deliver (failed)")
            XCTFail("deliver failed: \(error)")
        }

        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: CursorAccessibilityDriver.bundleID).first {
            driver.keyboard.pressCommandA(targetPID: app.processIdentifier)
            driver.keyboard.pressDelete(targetPID: app.processIdentifier)
        }
    }
}
