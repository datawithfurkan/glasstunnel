import AppKit
import XCTest
@testable import GlassTunnelApp

final class AppWindowPresentationPolicyTests: XCTestCase {
    func testMainWindowMovesToActiveSpaceForReliableReopenAndInspection() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )

        AppWindowPresentationPolicy.configureMainWindow(window)

        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
    }
}
