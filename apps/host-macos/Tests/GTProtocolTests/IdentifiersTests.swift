import XCTest
@testable import GTProtocol

final class IdentifiersTests: XCTestCase {
    func testAgentStatusLabels() {
        XCTAssertEqual(AgentStatus.working.userVisibleLabel, "Working")
        XCTAssertEqual(AgentStatus.done.userVisibleLabel, "Done")
        XCTAssertTrue(AgentStatus.done.isTerminal)
        XCTAssertFalse(AgentStatus.working.isTerminal)
    }

    func testAdapterKindDisplayNames() {
        XCTAssertEqual(AdapterKind.cursor.displayName, "Cursor")
        XCTAssertEqual(AdapterKind.cursorAgent.displayName, "Cursor Agent")
        XCTAssertEqual(AdapterKind.claudeCode.displayName, "Claude Code")
        XCTAssertEqual(AdapterKind.geminiCli.displayName, "Gemini CLI")
        XCTAssertEqual(AdapterKind.mirror.displayName, "Mirror")
        XCTAssertEqual(AdapterKind.terminal.displayName, "Terminal")
        XCTAssertEqual(AdapterKind.terminal.icon, "terminal.fill")
        XCTAssertEqual(AdapterKind.cursorAgent.icon, "terminal")
    }

    func testQuickReplyLiteralText() {
        XCTAssertEqual(QuickReplyKind.continueReply.literalText, "continue")
        XCTAssertEqual(QuickReplyKind.commit.literalText, "commit this change")
    }

    func testGridShapeDimensions() {
        XCTAssertEqual(GridShape.oneByOne.rows, 1)
        XCTAssertEqual(GridShape.oneByOne.cols, 1)
        XCTAssertEqual(GridShape.twoByTwo.rows, 2)
        XCTAssertEqual(GridShape.twoByTwo.cols, 2)
    }
}
