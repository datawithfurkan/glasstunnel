import XCTest
@testable import GTProtocol

final class CodecTests: XCTestCase {
    func testDataChannelMessageRoundTrip() throws {
        let app = RemoteApp(
            remoteAppId: "codex",
            displayName: "Codex",
            adapterKind: .mirror,
            agentId: "codex",
            enabled: true,
            available: true,
            status: .working,
            statusDetail: "Syncing context",
            windowTitle: "Glasstunnel",
            applicationBundleId: "com.openai.codex",
            hasVideo: true
        )
        let msg = DataChannelMessage(
            body: .hello(Hello(
                hostVersion: "0.1.0",
                hostOsVersion: "macOS 14",
                hostDeviceLabel: "Test Mac",
                supportedAdapters: ["mirror", "cursor"],
                currentLayout: GridLayout(shape: .twoByTwo, cells: []),
                remoteApps: [app]
            ))
        )
        let data = try ProtocolCodec.encode(msg)
        let decoded = try ProtocolCodec.decode(DataChannelMessage.self, from: data)
        XCTAssertEqual(msg, decoded)
    }

    func testRemoteAppsUpdateRoundTrip() throws {
        let update = RemoteAppsUpdate(remoteApps: [
            RemoteApp(
                remoteAppId: "cursor",
                displayName: "Cursor",
                adapterKind: .cursor,
                agentId: "cursor",
                enabled: true,
                available: false,
                status: .disconnected,
                statusDetail: "Open Cursor on this Mac",
                applicationBundleId: "com.todesktop.230313mzl4w4u92",
                hasVideo: true
            )
        ])
        let msg = DataChannelMessage(body: .remoteAppsUpdate(update))
        let data = try ProtocolCodec.encode(msg)
        let decoded = try ProtocolCodec.decode(DataChannelMessage.self, from: data)
        XCTAssertEqual(msg, decoded)
    }

    func testUserInputRoundTrip() throws {
        let msg = DataChannelMessage(
            body: .userInput(UserInput(agentId: "agent-1", text: "hello"))
        )
        let json = try ProtocolCodec.encodeString(msg)
        XCTAssertTrue(json.contains("userInput"))
        let decoded = try ProtocolCodec.decodeString(DataChannelMessage.self, from: json)
        XCTAssertEqual(msg, decoded)
    }

    func testInputRequestResponseRoundTrip() throws {
        let msg = DataChannelMessage(
            body: .inputRequestResponse(AgentInputRequestResponse(
                agentId: "agent-1",
                requestId: "call-plan-1",
                answers: [
                    AgentInputRequestAnswer(questionId: "alignment_delivery", choiceIds: ["1"])
                ]
            ))
        )
        let json = try ProtocolCodec.encodeString(msg)
        XCTAssertTrue(json.contains("inputRequestResponse"))
        let decoded = try ProtocolCodec.decodeString(DataChannelMessage.self, from: json)
        XCTAssertEqual(msg, decoded)
    }

    func testImageAttachmentInputRoundTrip() throws {
        let msg = DataChannelMessage(
            body: .imageAttachmentInput(ImageAttachmentInput(
                agentId: "agent-1",
                text: "inspect this",
                filename: "screenshot.png",
                mimeType: "image/png",
                bytes: Data([0x89, 0x50, 0x4E, 0x47])
            ))
        )
        let json = try ProtocolCodec.encodeString(msg)
        XCTAssertTrue(json.contains("imageAttachmentInput"))
        let decoded = try ProtocolCodec.decodeString(DataChannelMessage.self, from: json)
        XCTAssertEqual(msg, decoded)
    }

    func testImageAttachmentChunkRoundTrip() throws {
        let msg = DataChannelMessage(
            body: .imageAttachmentChunk(ImageAttachmentChunk(
                transferId: "transfer-1",
                agentId: "agent-1",
                text: "inspect this",
                filename: "screenshot.png",
                mimeType: "image/png",
                totalBytes: 8,
                chunkIndex: 1,
                chunkCount: 2,
                bytes: Data([0x50, 0x4E, 0x47, 0x21])
            ))
        )
        let json = try ProtocolCodec.encodeString(msg)
        XCTAssertTrue(json.contains("imageAttachmentChunk"))
        let decoded = try ProtocolCodec.decodeString(DataChannelMessage.self, from: json)
        XCTAssertEqual(msg, decoded)
    }

    func testFileAttachmentChunkRoundTrip() throws {
        let msg = DataChannelMessage(
            body: .fileAttachmentChunk(FileAttachmentChunk(
                batchId: "batch-1",
                transferId: "transfer-1",
                agentId: "agent-1",
                text: "inspect these",
                filename: "notes.txt",
                mimeType: "text/plain",
                totalBytes: 8,
                fileIndex: 0,
                fileCount: 2,
                chunkIndex: 1,
                chunkCount: 2,
                bytes: Data([0x74, 0x65, 0x78, 0x74])
            ))
        )
        let json = try ProtocolCodec.encodeString(msg)
        XCTAssertTrue(json.contains("fileAttachmentChunk"))
        let decoded = try ProtocolCodec.decodeString(DataChannelMessage.self, from: json)
        XCTAssertEqual(msg, decoded)
    }

    func testAgentStateSnapshotRoundTrip() throws {
        let snap = AgentStateSnapshot(
            agentId: "agent-1",
            agentLabel: "Cursor",
            adapterKind: .cursor,
            status: .working,
            statusDetail: "editing file.swift",
            recentMessages: [
                AgentChatMessage(messageId: "1", role: .user, text: "fix the bug"),
                AgentChatMessage(messageId: "2", role: .assistant, text: "on it"),
            ],
            availableTargets: [
                AgentTargetOption(
                    targetId: "/Users/developer/Documents/GitHub/glasstunnel",
                    label: "glasstunnel",
                    subtitle: "Review entire project",
                    selected: true
                )
            ],
            remoteAppId: "cursor",
            pendingInputRequest: AgentInputRequest(
                requestId: "call-plan-1",
                questions: [
                    AgentInputRequestQuestion(
                        questionId: "alignment_delivery",
                        header: "Delivery",
                        question: "Should Codex create aligned copies?",
                        choices: [
                            AgentInputRequestChoice(
                                choiceId: "1",
                                label: "Create aligned copies (Recommended)",
                                description: "Best path for customer review.",
                                recommended: true
                            ),
                            AgentInputRequestChoice(
                                choiceId: "2",
                                label: "Score originals only",
                                description: "Lower risk.",
                                recommended: false
                            ),
                        ]
                    )
                ]
            ),
            runtimeControls: AgentRuntimeControls(
                modelId: "gpt-5.5",
                modelLabel: "GPT-5.5",
                modelOptions: [
                    AgentRuntimeOption(id: "gpt-5.5", label: "GPT-5.5")
                ],
                reasoningEffort: "xhigh",
                reasoningEffortLabel: "Extra high",
                reasoningEffortOptions: [
                    AgentRuntimeOption(id: "xhigh", label: "Extra high")
                ],
                fastMode: true,
                supportsModelSelection: true,
                supportsReasoningEffort: true,
                supportsFastMode: true,
                editable: true,
                appliesOn: .immediate,
                note: "Restarts Codex CLI"
            )
        )
        let data = try ProtocolCodec.encode(snap)
        let decoded = try ProtocolCodec.decode(AgentStateSnapshot.self, from: data)
        XCTAssertEqual(snap, decoded)
    }

    func testTargetSelectionRequestRoundTrip() throws {
        let msg = DataChannelMessage(
            body: .targetSelectionRequest(TargetSelectionRequest(
                agentId: "agent-1",
                targetId: "/Users/developer/Documents/GitHub/docs-site"
            ))
        )
        let json = try ProtocolCodec.encodeString(msg)
        XCTAssertTrue(json.contains("targetSelectionRequest"))
        let decoded = try ProtocolCodec.decodeString(DataChannelMessage.self, from: json)
        XCTAssertEqual(msg, decoded)
    }

    func testTargetRenameRequestRoundTrip() throws {
        let msg = DataChannelMessage(
            body: .targetRenameRequest(TargetRenameRequest(
                agentId: "terminal",
                targetId: "terminal-session:glasstunnel-terminal",
                label: "Release console"
            ))
        )
        let json = try ProtocolCodec.encodeString(msg)
        XCTAssertTrue(json.contains("targetRenameRequest"))
        XCTAssertTrue(json.contains("Release console"))
        let decoded = try ProtocolCodec.decodeString(DataChannelMessage.self, from: json)
        XCTAssertEqual(msg, decoded)
    }

    func testAgentRuntimeSettingsUpdateRoundTrip() throws {
        let msg = DataChannelMessage(
            body: .agentRuntimeSettingsUpdate(AgentRuntimeSettingsUpdate(
                agentId: "codex-cli",
                modelId: "gpt-5.5",
                reasoningEffort: "xhigh",
                fastMode: true
            ))
        )
        let json = try ProtocolCodec.encodeString(msg)
        XCTAssertTrue(json.contains("agentRuntimeSettingsUpdate"))
        XCTAssertTrue(json.contains("gpt-5.5"))
        let decoded = try ProtocolCodec.decodeString(DataChannelMessage.self, from: json)
        XCTAssertEqual(msg, decoded)
    }

    func testRemoteAppActionRequestRoundTrip() throws {
        let msg = DataChannelMessage(
            body: .remoteAppActionRequest(RemoteAppActionRequest(
                remoteAppId: "screen",
                action: .start,
                screenQuality: .readable
            ))
        )
        let json = try ProtocolCodec.encodeString(msg)
        XCTAssertTrue(json.contains("remoteAppActionRequest"))
        XCTAssertTrue(json.contains("screenQuality"))
        XCTAssertTrue(json.contains("readable"))
        let decoded = try ProtocolCodec.decodeString(DataChannelMessage.self, from: json)
        XCTAssertEqual(msg, decoded)
    }

    func testRemoteAppNewSessionActionRoundTrip() throws {
        let msg = DataChannelMessage(
            body: .remoteAppActionRequest(RemoteAppActionRequest(
                remoteAppId: "terminal",
                action: .newSession
            ))
        )
        let json = try ProtocolCodec.encodeString(msg)
        XCTAssertTrue(json.contains("remoteAppActionRequest"))
        XCTAssertTrue(json.contains("newSession"))
        let decoded = try ProtocolCodec.decodeString(DataChannelMessage.self, from: json)
        XCTAssertEqual(msg, decoded)
    }

    func testRemoteAppCloseSessionActionRoundTrip() throws {
        let msg = DataChannelMessage(
            body: .remoteAppActionRequest(RemoteAppActionRequest(
                remoteAppId: "terminal",
                action: .closeSession
            ))
        )
        let json = try ProtocolCodec.encodeString(msg)
        XCTAssertTrue(json.contains("remoteAppActionRequest"))
        XCTAssertTrue(json.contains("closeSession"))
        let decoded = try ProtocolCodec.decodeString(DataChannelMessage.self, from: json)
        XCTAssertEqual(msg, decoded)
    }

    func testScreenPointerInputRoundTrip() throws {
        let msg = DataChannelMessage(
            body: .screenPointerInput(ScreenPointerInput(
                agentId: "screen",
                x: 0.42,
                y: 0.64,
                action: .doubleClick
            ))
        )
        let json = try ProtocolCodec.encodeString(msg)
        XCTAssertTrue(json.contains("screenPointerInput"))
        let decoded = try ProtocolCodec.decodeString(DataChannelMessage.self, from: json)
        XCTAssertEqual(msg, decoded)
    }

    func testGridLayoutShapes() {
        XCTAssertEqual(GridShape.twoByTwo.cellCount, 4)
        XCTAssertEqual(GridShape.twoByOne.cellCount, 2)
        XCTAssertEqual(GridShape.oneByTwo.cellCount, 2)
        XCTAssertEqual(GridShape.oneByOne.cellCount, 1)
        XCTAssertEqual(GridLayout.empty(shape: .twoByTwo).cells.count, 4)
    }

    func testEnvelopePayloadEncoding() throws {
        let env = Envelope(
            fromDeviceId: "gt-mac",
            toDeviceId: "gt-phone",
            payload: .ping(Ping(atUnixMs: 1776589761565))
        )
        let data = try ProtocolCodec.encode(env)
        let str = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("\"kind\":\"ping\""))
        let decoded = try ProtocolCodec.decode(Envelope.self, from: data)
        XCTAssertEqual(decoded.fromDeviceId, "gt-mac")
    }

    func testEnvelopeDecodesFromTypeScriptWireFormat() throws {
        let json = """
        {
          "envelopeId":"e8acec0c-f205-4d36-b01b-8fbbb49aba4b",
          "fromDeviceId":"gt-1ccd36da5afd6cd2",
          "toDeviceId":"gt-e2026aace28c680c",
          "sentAtUnixMs":1776589761565,
          "signature":"myOlZKbxcHMh0Hhp0QeUoIjMdgBrO+bvRW/nRD8LcntNv3ljLaMw/XOL5/9IbhrrWbLGuo6y/OFh5R2+9GpBDA==",
          "payload":{
            "kind":"sdpAnswer",
            "sdpAnswer":{
              "sdp":"v=0",
              "sessionId":"session-1"
            }
          }
        }
        """
        let decoded = try ProtocolCodec.decodeString(Envelope.self, from: json)
        XCTAssertEqual(decoded.fromDeviceId, "gt-1ccd36da5afd6cd2")
        guard case .sdpAnswer(let answer) = decoded.payload else {
            return XCTFail("expected sdpAnswer payload")
        }
        XCTAssertEqual(answer.sdp, "v=0")
        XCTAssertEqual(answer.sessionId, "session-1")
    }
}
