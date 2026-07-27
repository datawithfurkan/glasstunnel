import XCTest
import GTProtocol
@testable import GlassTunnelApp

final class WorkspaceRemoteAppPresentationTests: XCTestCase {
    func testTerminalRowHasDirectAccessSwitchWhenStopped() {
        let presentation = RemoteAppRowPresentation(
            app: terminalApp(enabled: false, status: .idle, statusDetail: "Stopped"),
            openHint: "Open Terminal on this Mac"
        )

        XCTAssertTrue(presentation.hasToggle)
        XCTAssertEqual(presentation.controlLabelText, "Open Terminal")
        XCTAssertEqual(presentation.controlStatusText, "Closed")
        XCTAssertEqual(presentation.controlTone, .muted)
        XCTAssertEqual(presentation.primaryDetail, "Open Terminal to start remote access")
    }

    func testTerminalRowShowsOpeningStateWhileStartIsPending() {
        let presentation = RemoteAppRowPresentation(
            app: terminalApp(enabled: true, status: .working, statusDetail: "Opening on Mac"),
            openHint: "Open Terminal on this Mac"
        )

        XCTAssertTrue(presentation.hasToggle)
        XCTAssertEqual(presentation.controlStatusText, "Opening")
        XCTAssertEqual(presentation.controlTone, .accent)
        XCTAssertEqual(presentation.primaryDetail, "Opening on Mac")
    }

    func testTerminalRowShowsReadyStateWhenEnabledAndAvailable() {
        let presentation = RemoteAppRowPresentation(
            app: terminalApp(enabled: true, status: .done, statusDetail: "Ready from web"),
            openHint: "Open Terminal on this Mac"
        )

        XCTAssertTrue(presentation.hasToggle)
        XCTAssertEqual(presentation.controlStatusText, "Terminal ready")
        XCTAssertEqual(presentation.controlTone, .success)
        XCTAssertEqual(presentation.primaryDetail, "Ready for terminal access")
    }

    private func terminalApp(
        enabled: Bool,
        status: AgentStatus,
        statusDetail: String
    ) -> RemoteApp {
        RemoteApp(
            remoteAppId: "terminal",
            displayName: "Terminal",
            adapterKind: .terminal,
            agentId: "terminal",
            enabled: enabled,
            available: true,
            status: status,
            statusDetail: statusDetail,
            windowTitle: "",
            applicationBundleId: "com.apple.Terminal",
            hasVideo: false
        )
    }
}
