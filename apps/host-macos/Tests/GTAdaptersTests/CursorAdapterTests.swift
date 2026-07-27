#if os(macOS)
import XCTest
@testable import GTAdapters
import GTInput
import GTProtocol

final class CursorAdapterTests: XCTestCase {
    func testFallbackCursorTargetDoesNotInventProjectMetadata() {
        let target = CursorStateWatcher.TargetEntry(
            targetId: "cursor-chat-1",
            label: "Cursor chat 1",
            subtitle: "Cursor",
            selected: true,
            lastUpdatedAtUnixMs: 1_770_000_003_000
        )

        let option = CursorAdapter.protocolTarget(from: target)

        XCTAssertEqual(option.label, "Cursor chat 1")
        XCTAssertEqual(option.subtitle, "Cursor")
        XCTAssertEqual(option.threadLabel, "Cursor chat 1")
        XCTAssertEqual(option.targetKind, "thread")
        XCTAssertNil(option.projectId)
        XCTAssertNil(option.projectLabel)
        XCTAssertNil(option.projectPath)
        XCTAssertTrue(option.selected)
        XCTAssertTrue(option.isActive ?? false)
        XCTAssertEqual(option.supportsNewThread, false)
    }

    func testPathBackedCursorTargetPublishesProjectMetadata() {
        let target = CursorStateWatcher.TargetEntry(
            targetId: "cursor-chat-2",
            label: "Release chat",
            subtitle: "~/Documents/GitHub2/glasstunnel",
            selected: false,
            lastUpdatedAtUnixMs: 1_770_000_003_000
        )

        let option = CursorAdapter.protocolTarget(from: target)

        XCTAssertEqual(option.label, "glasstunnel")
        XCTAssertEqual(option.subtitle, "~/Documents/GitHub2/glasstunnel")
        XCTAssertEqual(option.threadLabel, "Release chat")
        XCTAssertEqual(option.projectId, "~/Documents/GitHub2/glasstunnel")
        XCTAssertEqual(option.projectLabel, "glasstunnel")
        XCTAssertEqual(option.projectPath, "~/Documents/GitHub2/glasstunnel")
        XCTAssertFalse(option.selected)
        XCTAssertFalse(option.isActive ?? true)
        XCTAssertEqual(option.supportsNewThread, false)
    }

    func testWorkspacePathBackedCursorTargetPublishesProjectMetadataWithoutPathSubtitle() {
        let target = CursorStateWatcher.TargetEntry(
            targetId: "cursor-chat-3",
            label: "Cursor chat 1",
            labelSource: .generatedFallback,
            subtitle: "Workspace composer",
            projectPath: "/Users/tester/Documents/GitHub2/glasstunnel",
            selected: false,
            lastUpdatedAtUnixMs: 1_770_000_003_000
        )

        let option = CursorAdapter.protocolTarget(from: target)

        XCTAssertEqual(option.label, "glasstunnel")
        XCTAssertEqual(option.subtitle, "Workspace composer")
        XCTAssertEqual(option.threadLabel, "Cursor chat 1")
        XCTAssertEqual(option.projectId, "/Users/tester/Documents/GitHub2/glasstunnel")
        XCTAssertEqual(option.projectLabel, "glasstunnel")
        XCTAssertEqual(option.projectPath, "/Users/tester/Documents/GitHub2/glasstunnel")
        XCTAssertFalse(option.selected)
        XCTAssertFalse(option.isActive ?? true)
        XCTAssertEqual(option.supportsNewThread, false)
    }

    func testLocalOnlyCursorTargetCanBeSelectedWithoutBeingActiveInCursor() {
        let target = CursorStateWatcher.TargetEntry(
            targetId: "cursor-chat-2",
            label: "Release chat",
            subtitle: "~/Documents/GitHub2/glasstunnel",
            selected: true,
            lastUpdatedAtUnixMs: 1_770_000_003_000
        )

        let option = CursorAdapter.protocolTarget(from: target, isActive: false)

        XCTAssertTrue(option.selected)
        XCTAssertEqual(option.isActive, false)
        XCTAssertEqual(option.threadLabel, "Release chat")
        XCTAssertEqual(option.projectLabel, "glasstunnel")
        XCTAssertEqual(option.supportsNewThread, false)
    }

    func testRuntimeControlsAreReadOnlyAndManagedInCursor() async throws {
        let adapter = CursorAdapter()

        let controls = try XCTUnwrap(adapter.runtimeControls())

        XCTAssertFalse(controls.editable)
        XCTAssertFalse(controls.supportsModelSelection)
        XCTAssertFalse(controls.supportsReasoningEffort)
        XCTAssertFalse(controls.supportsFastMode)
        XCTAssertTrue(controls.modelOptions.isEmpty)
        XCTAssertTrue(controls.reasoningEffortOptions.isEmpty)
        XCTAssertEqual(controls.appliesOn, .managedLocally)
        XCTAssertEqual(controls.note, "Managed in Cursor")

        do {
            try await adapter.updateRuntimeSettings(.init(agentId: "cursor", modelId: "composer-2.5-fast"))
            XCTFail("Cursor should reject remote runtime settings updates")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("does not support remote model settings"))
        }
    }

    func testSendInputTargetsCursorChatAndPublishesWorkingState() async throws {
        let injector = RecordingCursorInjector()
        let adapter = CursorAdapter(injector: injector)
        var stream = adapter.observeState().makeAsyncIterator()

        try await adapter.sendInput("Review this diff", submit: true)

        XCTAssertEqual(injector.deliveries, [
            .init(
                bundleID: "com.todesktop.230313mzl4w4u92",
                text: "Review this diff",
                submit: true,
                targetHint: "chat"
            ),
        ])
        let snapshot = await stream.next()
        XCTAssertEqual(snapshot?.status, .working)
        XCTAssertEqual(snapshot?.statusDetail, "input delivered")
        XCTAssertEqual(snapshot?.runtimeControls?.note, "Managed in Cursor")
    }

    func testSendInputFallsBackToUnhintedCursorInputWhenChatHintIsMissing() async throws {
        let injector = ChatHintMissingCursorInjector()
        let adapter = CursorAdapter(injector: injector)
        var stream = adapter.observeState().makeAsyncIterator()

        try await adapter.sendInput("Review this diff", submit: true)

        XCTAssertEqual(injector.deliveries, [
            .init(
                bundleID: "com.todesktop.230313mzl4w4u92",
                text: "Review this diff",
                submit: true,
                targetHint: "chat"
            ),
            .init(
                bundleID: "com.todesktop.230313mzl4w4u92",
                text: "Review this diff",
                submit: true,
                targetHint: nil
            ),
        ])
        let snapshot = await stream.next()
        XCTAssertEqual(snapshot?.status, .working)
        XCTAssertEqual(snapshot?.statusDetail, "input delivered")
    }

    func testSendInputRejectsUnverifiedFallbackDelivery() async throws {
        let injector = UnverifiedFallbackCursorInjector()
        let adapter = CursorAdapter(injector: injector)

        do {
            try await adapter.sendInput("Review this diff", submit: true)
            XCTFail("Expected Cursor input delivery to reject unverified writes")
        } catch {
            XCTAssertTrue(String(describing: error).contains("not verified"))
        }

        XCTAssertEqual(injector.deliveries, [
            .init(
                bundleID: "com.todesktop.230313mzl4w4u92",
                text: "Review this diff",
                submit: true,
                targetHint: "chat"
            ),
            .init(
                bundleID: "com.todesktop.230313mzl4w4u92",
                text: "Review this diff",
                submit: true,
                targetHint: nil
            ),
        ])
    }

    func testLocalOnlyTargetSelectionBlocksPromptDelivery() async throws {
        let injector = RecordingCursorInjector()
        let adapter = CursorAdapter(injector: injector)
        var stream = adapter.observeState().makeAsyncIterator()

        try await adapter.selectTarget("cursor-chat-2")

        let selectedSnapshot = await stream.next()
        XCTAssertEqual(selectedSnapshot?.status, .waitingInput)
        XCTAssertEqual(selectedSnapshot?.statusDetail, CursorAdapter.localOnlyTargetSelectionDetail)

        do {
            try await adapter.sendInput("Send to selected parsed chat", submit: true)
            XCTFail("Expected Cursor input delivery to reject local-only target selection")
        } catch {
            XCTAssertTrue(String(describing: error).contains("local-only"))
        }

        XCTAssertTrue(injector.deliveries.isEmpty)
        let blockedSnapshot = await stream.next()
        XCTAssertEqual(blockedSnapshot?.status, .waitingInput)
        XCTAssertEqual(blockedSnapshot?.statusDetail, CursorAdapter.localOnlyTargetSelectionDetail)
    }
}

private final class RecordingCursorInjector: CursorInputDelivering, @unchecked Sendable {
    struct Delivery: Equatable {
        var bundleID: String
        var text: String
        var submit: Bool
        var targetHint: String?
    }

    private(set) var deliveries: [Delivery] = []

    func deliver(
        bundleID: String,
        text: String,
        submit: Bool,
        targetHint: String?
    ) throws -> AccessibilityDeliveryResult {
        deliveries.append(.init(bundleID: bundleID, text: text, submit: submit, targetHint: targetHint))
        return AccessibilityDeliveryResult(verified: true, targetHint: targetHint)
    }
}

private final class ChatHintMissingCursorInjector: CursorInputDelivering, @unchecked Sendable {
    private(set) var deliveries: [RecordingCursorInjector.Delivery] = []

    func deliver(
        bundleID: String,
        text: String,
        submit: Bool,
        targetHint: String?
    ) throws -> AccessibilityDeliveryResult {
        deliveries.append(.init(bundleID: bundleID, text: text, submit: submit, targetHint: targetHint))
        if targetHint == "chat" {
            throw AccessibilityInjector.InjectionError.noInputField(bundleID)
        }
        return AccessibilityDeliveryResult(verified: true, targetHint: targetHint)
    }
}

private final class UnverifiedFallbackCursorInjector: CursorInputDelivering, @unchecked Sendable {
    private(set) var deliveries: [RecordingCursorInjector.Delivery] = []

    func deliver(
        bundleID: String,
        text: String,
        submit: Bool,
        targetHint: String?
    ) throws -> AccessibilityDeliveryResult {
        deliveries.append(.init(bundleID: bundleID, text: text, submit: submit, targetHint: targetHint))
        if targetHint == "chat" {
            throw AccessibilityInjector.InjectionError.noInputField(bundleID)
        }
        return AccessibilityDeliveryResult(verified: false, targetHint: targetHint)
    }
}
#endif
