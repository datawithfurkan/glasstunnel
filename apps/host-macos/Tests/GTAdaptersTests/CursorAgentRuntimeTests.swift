import XCTest
@testable import GTAdapters

final class CursorAgentRuntimeTests: XCTestCase {
    func testCursorAgentModelSelectionIsLimitedToVerifiedDefault() throws {
        XCTAssertEqual(
            try CursorAgentAdapter.normalizedModel("  gpt-5.4-nano-none  "),
            CursorAgentAdapter.defaultModel
        )
        XCTAssertThrowsError(try CursorAgentAdapter.normalizedModel(""))
        XCTAssertThrowsError(try CursorAgentAdapter.normalizedModel("gpt-5.4 nano none"))
        XCTAssertThrowsError(try CursorAgentAdapter.normalizedModel("gpt-5.4-nano-none\""))
        XCTAssertThrowsError(try CursorAgentAdapter.normalizedModel("composer-2.5-fast"))
    }

    func testCursorAgentRuntimeControlsExposeVerifiedDefaultModel() {
        let adapter = CursorAgentAdapter(executable: "/usr/bin/true")
        let controls = adapter.runtimeControls()

        XCTAssertEqual(controls?.modelId, CursorAgentAdapter.defaultModel)
        XCTAssertEqual(controls?.modelLabel, "GPT 5.4 Nano")
        XCTAssertEqual(controls?.modelOptions.map(\.id), [CursorAgentAdapter.defaultModel])
        XCTAssertEqual(controls?.supportsModelSelection, true)
        XCTAssertEqual(controls?.editable, false)
        XCTAssertEqual(controls?.appliesOn, .managedLocally)
        XCTAssertEqual(controls?.note, CursorAgentAdapter.askModeNote)
    }

    func testCursorAgentRejectsRemoteRuntimeUpdates() async throws {
        let adapter = CursorAgentAdapter(executable: "/usr/bin/true")

        do {
            try await adapter.updateRuntimeSettings(.init(agentId: "cursor-agent", modelId: CursorAgentAdapter.defaultModel))
            XCTFail("Cursor Agent runtime updates should remain disabled until a broader model-control path is verified.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("verified \(CursorAgentAdapter.defaultModel)"))
        }
    }
}
