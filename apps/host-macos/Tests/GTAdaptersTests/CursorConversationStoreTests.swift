#if os(macOS)
import XCTest
import SQLite3
@testable import GTAdapters
import GTProtocol

/// The Cursor stores both cards read: the protobuf snapshot walk, the AI-SDK
/// message shapes, injected context, tool rows, and the two SQLite layouts
/// (the desktop app's `state.vscdb` and the CLI's per-chat `store.db`).
final class CursorConversationStoreTests: XCTestCase {
    // MARK: - Codec

    func testProtobufListsLengthDelimitedValuesOfOneFieldInOrder() {
        let first = Data(repeating: 0xaa, count: 32)
        let second = Data(repeating: 0xbb, count: 32)
        var data = Data()
        data.append(contentsOf: [0x50, 0x01]) // field 10, varint 1
        data.append(protobufBytes(field: 1, first))
        data.append(contentsOf: [0x2a, 0x03, 0x01, 0x02, 0x03]) // field 5, 3 bytes
        data.append(protobufBytes(field: 1, second))
        data.append(contentsOf: [0xd0, 0x01, 0xbc, 0xd0, 0xb8, 0xfd, 0xd3, 0xdd, 0x33]) // field 26, a large varint
        data.append(protobufBytes(field: 8, Data(repeating: 0xcc, count: 32)))

        let values = CursorProtobuf.lengthDelimitedValues(in: data, field: 1)
        XCTAssertEqual(values, [first, second])
        XCTAssertEqual(CursorProtobuf.lengthDelimitedValues(in: data, field: 8).count, 1)
        XCTAssertEqual(CursorProtobuf.hexString(Data([0x0f, 0xa0])), "0fa0")
        XCTAssertEqual(CursorProtobuf.data(fromHex: "0FA0"), Data([0x0f, 0xa0]))
        XCTAssertNil(CursorProtobuf.data(fromHex: "0fa"))
        XCTAssertNil(CursorProtobuf.data(fromHex: "zz"))

        // Corrupt tails stop the walk without crashing or inventing values.
        var truncated = data
        truncated.append(contentsOf: [0x0a, 0x7f, 0x01])
        XCTAssertEqual(CursorProtobuf.lengthDelimitedValues(in: truncated, field: 1), [first, second])
    }

    func testInjectedContextIsSkippedAndWrappedPromptsAreUnwrapped() {
        let context = "<user_info>\nOS: darwin\n</user_info>\n<rules>\n<user_rule>Be brief.</user_rule>\n</rules>\n<mcp_file_system>\n<server>x</server>\n</mcp_file_system>"
        XCTAssertTrue(CursorMessageCodec.isInjectedContext(context))
        XCTAssertFalse(CursorMessageCodec.isInjectedContext("<div>keep me</div>"))
        XCTAssertFalse(CursorMessageCodec.isInjectedContext("<user_info> then my own words"))
        XCTAssertFalse(CursorMessageCodec.isInjectedContext("fix the crash"))
        XCTAssertEqual(CursorMessageCodec.userQuery(in: "<user_query>\nfix the crash\n</user_query>"), "fix the crash")
        XCTAssertEqual(CursorMessageCodec.userQuery(in: "plain"), "plain")

        let injected = CursorMessageCodec.decode(object: ["role": "user", "content": context])
        XCTAssertEqual(injected?.isInjectedContext, true)
        XCTAssertEqual(injected?.text, "")
        let wrapped = CursorMessageCodec.decode(object: ["role": "user", "content": "<user_query>hello</user_query>"])
        XCTAssertEqual(wrapped?.isInjectedContext, false)
        XCTAssertEqual(wrapped?.text, "hello")
        let listed = CursorMessageCodec.decode(object: ["role": "user", "content": [["type": "text", "text": "Reply with OK"]]])
        XCTAssertEqual(listed?.text, "Reply with OK")
        XCTAssertEqual(listed?.role, .user)
    }

    func testToolPartsDecodeInBothSdkShapes() {
        let v4 = CursorMessageCodec.decode(object: [
            "role": "assistant",
            "content": [
                ["type": "text", "text": "Reading."],
                ["type": "redacted-reasoning", "data": "xxx"],
                ["type": "tool-call", "toolCallId": "call-1", "toolName": "ReadFile", "args": ["path": "/Users/dev/App/Package.swift"]],
            ],
        ])
        XCTAssertEqual(v4?.text, "Reading.")
        XCTAssertEqual(v4?.toolCalls.map(\.id), ["call-1"])
        XCTAssertEqual(v4?.toolCalls.first?.name, "ReadFile")
        XCTAssertEqual(v4?.toolCalls.first?.title, "Package.swift")

        let v4Result = CursorMessageCodec.decode(object: [
            "role": "tool",
            "content": [[
                "type": "tool-result", "toolCallId": "call-1", "toolName": "ReadFile",
                "result": "// swift-tools-version",
                "experimental_content": [["type": "text", "text": "// swift-tools-version:5.9"]],
            ]],
        ])
        XCTAssertEqual(v4Result?.toolResults.first?.text, "// swift-tools-version:5.9", "experimental_content wins over the raw result")
        XCTAssertEqual(v4Result?.toolResults.first?.isError, false)

        let v5 = CursorMessageCodec.decode(object: [
            "role": "assistant",
            "content": [["type": "tool-call", "toolCallId": "call-2", "toolName": "Shell", "input": ["command": "git   status\n--short"]]],
        ])
        XCTAssertEqual(v5?.toolCalls.first?.title, "git status --short")
        let v5Error = CursorMessageCodec.decode(object: [
            "role": "tool",
            "content": [["type": "tool-result", "toolCallId": "call-2", "toolName": "Shell", "output": ["type": "error-text", "value": "boom"]]],
        ])
        XCTAssertEqual(v5Error?.toolResults.first?.text, "boom")
        XCTAssertEqual(v5Error?.toolResults.first?.isError, true)

        let stringArgs = CursorMessageCodec.decode(object: [
            "role": "assistant",
            "content": [["type": "tool-call", "toolCallId": "call-3", "toolName": "Grep", "args": "{\"pattern\":\"TODO\",\"path\":\"/x/Sources\"}"]],
        ])
        XCTAssertEqual(stringArgs?.toolCalls.first?.title, "TODO in Sources", "arguments serialized as a JSON string still title the row")
    }

    func testToolTitlesCoverTheCommonArgumentKeys() {
        XCTAssertEqual(CursorMessageCodec.toolTitle(name: "Shell", arguments: ["command": "pnpm test"]), "pnpm test")
        XCTAssertEqual(CursorMessageCodec.toolTitle(name: "Grep", arguments: ["pattern": "TODO"]), "TODO")
        XCTAssertEqual(CursorMessageCodec.toolTitle(name: "Glob", arguments: ["pattern": "**/*.swift", "target_directory": "/repo/Sources"]), "**/*.swift in Sources")
        XCTAssertEqual(CursorMessageCodec.toolTitle(name: "StrReplace", arguments: ["target_file": "/repo/Sources/App/Root.swift"]), "Root.swift")
        XCTAssertEqual(CursorMessageCodec.toolTitle(name: "WebSearch", arguments: ["query": "swift concurrency"]), "swift concurrency")
        XCTAssertEqual(CursorMessageCodec.toolTitle(name: "WebFetch", arguments: ["url": "https://example.com/docs/api?x=1"]), "example.com/docs/api")
        XCTAssertEqual(CursorMessageCodec.toolTitle(name: "Task", arguments: ["description": "Explore the transport layer"]), "Explore the transport layer")
        XCTAssertEqual(CursorMessageCodec.toolTitle(name: "TodoWrite", arguments: [:]), "Update todos")
        XCTAssertEqual(CursorMessageCodec.toolTitle(name: "Unknown", arguments: ["thing": 1]), "")
        XCTAssertEqual(CursorMessageCodec.toolTitle(name: "Shell", arguments: ["command": String(repeating: "x", count: 300)]).count, 120)
    }

    func testAskQuestionCallsBecomeStructuredQuestions() {
        let request = CursorMessageCodec.askQuestion(id: "q-1", arguments: [
            "question": "Which option?",
            "options": [["label": "Alpha", "description": "first"], "Beta"],
        ])
        XCTAssertEqual(request?.requestId, "q-1")
        XCTAssertEqual(request?.questions.count, 1)
        XCTAssertEqual(request?.questions.first?.question, "Which option?")
        XCTAssertEqual(request?.questions.first?.choices.map(\.label), ["Alpha", "Beta"])
        XCTAssertEqual(request?.questions.first?.choices.map(\.choiceId), ["1", "2"])
        XCTAssertNil(CursorMessageCodec.askQuestion(id: "q-2", arguments: ["question": "Free-form?"]), "no options means nothing to press on the phone")
        let multi = CursorMessageCodec.askQuestion(id: "q-3", arguments: [
            "questions": [["header": "Scope", "question": "Which scope?", "options": ["Files", "Folders"]]],
        ])
        XCTAssertEqual(multi?.questions.first?.questionId, "Scope")
        XCTAssertEqual(multi?.questions.first?.header, "Scope")
    }

    func testBuilderPairsRowsDerivesStatusAndKeepsStableIds() throws {
        let output = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let stored: [CursorStoredMessage] = [
            try XCTUnwrap(CursorMessageCodec.decode(object: ["role": "system", "content": "You are Cursor."])),
            try XCTUnwrap(CursorMessageCodec.decode(object: ["role": "user", "content": "<user_info>\nOS\n</user_info>"])),
            try XCTUnwrap(CursorMessageCodec.decode(object: ["role": "user", "content": [["type": "text", "text": "Check the repo"]]])),
            try XCTUnwrap(CursorMessageCodec.decode(object: [
                "role": "assistant",
                "content": [
                    ["type": "text", "text": "Looking."],
                    ["type": "tool-call", "toolCallId": "c1", "toolName": "Shell", "args": ["command": "git status --short"]],
                ],
            ])),
            try XCTUnwrap(CursorMessageCodec.decode(object: [
                "role": "tool",
                "content": [["type": "tool-result", "toolCallId": "c1", "toolName": "Shell", "result": output, "isError": true]],
            ])),
            try XCTUnwrap(CursorMessageCodec.decode(object: ["role": "assistant", "content": [["type": "text", "text": "Done."]]])),
        ]

        let conversation = CursorConversationBuilder.build(messages: stored, agentID: "cursor", maxMessages: 50, lastActivityUnixMs: 1_700_000_000_000)
        XCTAssertEqual(conversation.messages.map(\.messageId), ["cursor-cursor-2", "cursor-cursor-3", "cursor-cursor-3-c0", "cursor-cursor-4-r0", "cursor-cursor-5"])
        XCTAssertEqual(conversation.messages.map(\.kind), [.text, .text, .toolCall, .toolResult, .text])
        XCTAssertEqual(conversation.messages[0].role, .user)
        XCTAssertEqual(conversation.messages[0].text, "Check the repo")

        let call = conversation.messages[2]
        XCTAssertEqual(call.role, .tool)
        XCTAssertEqual(call.toolName, "Shell")
        XCTAssertEqual(call.toolCallId, "c1")
        XCTAssertEqual(call.title, "git status --short")
        XCTAssertEqual(call.text, "Using Shell", "older phones still get the old wording")
        XCTAssertEqual(call.pendingToolCalls.map(\.toolCallId), ["c1"])

        let result = conversation.messages[3]
        XCTAssertEqual(result.toolCallId, "c1")
        XCTAssertEqual(result.toolName, "Shell")
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.outputLineCount, 30)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.text.split(separator: "\n").count, 12, "the snapshot carries a preview")
        XCTAssertEqual(conversation.messageDetails[result.messageId]?.split(separator: "\n").count, 30, "the full text waits on the Mac")

        XCTAssertEqual(conversation.status, .done)
        XCTAssertEqual(conversation.statusDetail, CursorConversationBuilder.doneDetail)
        XCTAssertEqual(conversation.messages.dropLast().map(\.atUnixMs), [0, 0, 0, 0], "stored messages carry no stamps of their own")
        XCTAssertEqual(conversation.messages.last?.atUnixMs, 1_700_000_000_000, "the newest message carries the store's clock")
        XCTAssertEqual(conversation.lastActivityUnixMs, 1_700_000_000_000)
    }

    func testBuilderReportsWorkingWaitingAndStopsAtTheMessageCap() throws {
        let pending: [CursorStoredMessage] = [
            try XCTUnwrap(CursorMessageCodec.decode(object: ["role": "user", "content": "Read it"])),
            try XCTUnwrap(CursorMessageCodec.decode(object: [
                "role": "assistant",
                "content": [["type": "tool-call", "toolCallId": "c1", "toolName": "Read", "args": ["path": "/a/b.txt"]]],
            ])),
        ]
        let working = CursorConversationBuilder.build(messages: pending, agentID: "cursor", maxMessages: 50, lastActivityUnixMs: nil)
        XCTAssertEqual(working.status, .working)
        XCTAssertEqual(working.statusDetail, CursorConversationBuilder.workingDetail)
        XCTAssertNil(working.pendingInputRequest)

        let asking = pending + [
            try XCTUnwrap(CursorMessageCodec.decode(object: [
                "role": "tool",
                "content": [["type": "tool-result", "toolCallId": "c1", "toolName": "Read", "result": "b"]],
            ])),
            try XCTUnwrap(CursorMessageCodec.decode(object: [
                "role": "assistant",
                "content": [["type": "tool-call", "toolCallId": "q1", "toolName": "AskQuestion", "args": ["question": "Alpha or Beta?", "options": ["Alpha", "Beta"]]]],
            ])),
        ]
        let waiting = CursorConversationBuilder.build(messages: asking, agentID: "cursor", maxMessages: 50, lastActivityUnixMs: nil)
        XCTAssertEqual(waiting.status, .waitingInput)
        XCTAssertEqual(waiting.statusDetail, CursorConversationBuilder.waitingDetail)
        XCTAssertEqual(waiting.pendingInputRequest?.requestId, "q1")
        XCTAssertEqual(waiting.pendingInputRequest?.questions.first?.choices.map(\.label), ["Alpha", "Beta"])

        let answered = asking + [
            try XCTUnwrap(CursorMessageCodec.decode(object: [
                "role": "tool",
                "content": [["type": "tool-result", "toolCallId": "q1", "toolName": "AskQuestion", "result": "Beta"]],
            ])),
        ]
        let resumed = CursorConversationBuilder.build(messages: answered, agentID: "cursor", maxMessages: 50, lastActivityUnixMs: nil)
        XCTAssertEqual(resumed.status, .working)
        XCTAssertNil(resumed.pendingInputRequest)

        let capped = CursorConversationBuilder.build(messages: answered, agentID: "cursor", maxMessages: 2, lastActivityUnixMs: nil)
        XCTAssertEqual(capped.messages.count, 2)
        XCTAssertEqual(capped.messages.map(\.messageId), ["cursor-cursor-3-c0", "cursor-cursor-4-r0"])
        XCTAssertTrue(capped.messageDetails.isEmpty)
    }

    // MARK: - CLI store

    func testCliChatStoreWalksTheRootBlobAndCatalogResolvesWorkspaces() throws {
        let root = try temporaryDirectory("gt-cursor-cli-store")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = "/Users/dev/App"
        let hash = CursorCLIChatCatalog.workspaceHash(workspace)
        XCTAssertEqual(hash.count, 32)
        let chatId = "5e1698ee-3619-4c90-af60-45c507d75115"
        let chatDir = root.appendingPathComponent("chats/\(hash)/\(chatId)", isDirectory: true)
        try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)
        try """
        {"schemaVersion":1,"createdAtMs":1782383500000,"hasConversation":true,"updatedAtMs":1782383596781}
        """.write(to: chatDir.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        let projectDir = root.appendingPathComponent("projects/Users-dev-App", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try """
        {"trustedAt":"2026-06-25T09:38:34.991Z","workspacePath":"\(workspace)","trustMethod":"cli-flag"}
        """.write(to: projectDir.appendingPathComponent(".workspace-trusted"), atomically: true, encoding: .utf8)

        let messages: [[String: Any]] = [
            ["role": "system", "content": "You are Cursor."],
            ["role": "user", "content": "<user_info>\nOS\n</user_info>"],
            ["role": "user", "content": [["type": "text", "text": "Reply with exactly PING"]]],
            ["role": "assistant", "content": [["type": "tool-call", "toolCallId": "c1", "toolName": "ReadFile", "args": ["path": "\(workspace)/README.md"]]]],
            ["role": "tool", "content": [["type": "tool-result", "toolCallId": "c1", "toolName": "ReadFile", "result": "# App"]]],
            ["role": "assistant", "content": [["type": "text", "text": "PING"]]],
        ]
        var blobs: [(String, Data)] = []
        var rootBlob = Data()
        for message in messages {
            let data = try JSONSerialization.data(withJSONObject: message)
            let id = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            blobs.append((CursorProtobuf.hexString(id), data))
            rootBlob.append(protobufBytes(field: 1, id))
        }
        rootBlob.append(contentsOf: [0xd0, 0x01, 0x01]) // field 26 varint
        let rootId = String(repeating: "ab", count: 32)
        blobs.append((rootId, rootBlob))
        let meta = "{\"agentId\":\"\(chatId)\",\"latestRootBlobId\":\"\(rootId)\",\"name\":\"Ping check\",\"mode\":\"ask\",\"isRunEverything\":false,\"createdAt\":1782383500000}"
        let hexMeta = Data(meta.utf8).map { String(format: "%02x", $0) }.joined()
        let storePath = chatDir.appendingPathComponent("store.db").path
        try createStoreDatabase(at: storePath, metaValue: hexMeta, blobs: blobs)

        let reader = CursorChatStoreReader(path: storePath)
        let storeMeta = try XCTUnwrap(reader.meta())
        XCTAssertEqual(storeMeta.latestRootBlobId, rootId)
        XCTAssertEqual(storeMeta.name, "Ping check")
        XCTAssertEqual(storeMeta.mode, "ask")

        let conversation = try XCTUnwrap(reader.conversation(agentID: "cursor-agent", maxMessages: 50))
        XCTAssertEqual(conversation.messages.map(\.kind), [.text, .toolCall, .toolResult, .text])
        XCTAssertEqual(conversation.messages[0].text, "Reply with exactly PING")
        XCTAssertEqual(conversation.messages[1].title, "README.md")
        XCTAssertEqual(conversation.messages[2].text, "# App")
        XCTAssertEqual(conversation.messages[3].text, "PING")
        XCTAssertEqual(conversation.status, .done)

        let chats = CursorCLIChatCatalog.chats(root: root)
        XCTAssertEqual(chats.count, 1)
        XCTAssertEqual(chats.first?.chatId, chatId)
        XCTAssertEqual(chats.first?.workspacePath, workspace, "resolved through the trusted-workspace record")
        XCTAssertEqual(chats.first?.name, "Ping check")
        XCTAssertEqual(chats.first?.mode, "ask")
        XCTAssertEqual(chats.first?.updatedAtUnixMs, 1_782_383_596_781)
        XCTAssertEqual(chats.first?.hasConversation, true)
        XCTAssertEqual(chats.first?.title, "Ping check")

        let other = "/Users/dev/Other"
        let otherDir = root.appendingPathComponent("chats/\(CursorCLIChatCatalog.workspaceHash(other))/11111111-2222-4333-8444-555555555555", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        try createStoreDatabase(at: otherDir.appendingPathComponent("store.db").path, metaValue: hexMeta, blobs: [])
        let withKnown = CursorCLIChatCatalog.chats(root: root, knownWorkspaces: [other])
        XCTAssertEqual(withKnown.count, 2)
        XCTAssertEqual(withKnown.first { $0.workspaceHash == CursorCLIChatCatalog.workspaceHash(other) }?.workspacePath, other, "a caller-known workspace resolves without a trust record")
    }

    // MARK: - Desktop store

    func testDesktopStoreListsComposersAndDecodesTheBlobConversation() throws {
        let root = try temporaryDirectory("gt-cursor-desktop-store")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceDir = root.appendingPathComponent("User/workspaceStorage/ws-1", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        try "{\"folder\":\"file:///Users/dev/App\"}".write(to: workspaceDir.appendingPathComponent("workspace.json"), atomically: true, encoding: .utf8)
        let dbPath = root.appendingPathComponent("User/globalStorage/state.vscdb").path
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: dbPath).deletingLastPathComponent(), withIntermediateDirectories: true)

        let messages: [[String: Any]] = [
            ["role": "system", "content": "You are Cursor."],
            ["role": "user", "content": "<user_info>\nOS\n</user_info>\n<rules>\n</rules>"],
            ["role": "user", "content": [["type": "text", "text": "Reply with exactly PONG"]]],
            ["role": "assistant", "content": [["type": "redacted-reasoning", "data": "x"], ["type": "text", "text": "PONG"]]],
        ]
        var kvRows: [(String, String)] = []
        var state = Data()
        for message in messages {
            let data = try JSONSerialization.data(withJSONObject: message)
            let id = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            kvRows.append(("agentKv:blob:\(CursorProtobuf.hexString(id))", String(decoding: data, as: UTF8.self)))
            state.append(protobufBytes(field: 1, id))
        }
        state.append(protobufBytes(field: 8, Data(repeating: 0x11, count: 32)))
        let composerData: [String: Any] = [
            "composerId": "composer-new",
            "conversationState": state.base64EncodedString(),
            "createdAt": 1_782_385_375_385,
            "lastUpdatedAt": 1_782_387_526_136,
            "modelConfig": ["modelName": "composer-2.5"],
            "fullConversationHeadersOnly": [],
        ]
        kvRows.append(("composerData:composer-new", String(decoding: try JSONSerialization.data(withJSONObject: composerData), as: UTF8.self)))
        // An older chat keeps its messages as bubble rows.
        kvRows.append(("composerData:composer-old", """
        {"composerId":"composer-old","createdAt":1770000000000,"lastUpdatedAt":1770000003000,"fullConversationHeadersOnly":[{"bubbleId":"b1","type":1},{"bubbleId":"b2","type":2}]}
        """))
        kvRows.append(("bubbleId:composer-old:b1", "{\"bubbleId\":\"b1\",\"type\":1,\"text\":\"old prompt\",\"createdAt\":\"2026-02-01T12:00:00.000Z\"}"))
        kvRows.append(("bubbleId:composer-old:b2", "{\"bubbleId\":\"b2\",\"type\":2,\"text\":\"old reply\",\"createdAt\":\"2026-02-01T12:00:01.000Z\"}"))

        let headers: [(String, String, Int64, Int64, Int, Int, String)] = [
            ("composer-new", "ws-1", 1_782_385_375_385, 1_782_387_526_136, 0, 0, "{\"name\":\"Pong check\",\"unifiedMode\":\"agent\",\"isDraft\":false,\"hasBlockingPendingActions\":true}"),
            ("composer-old", "empty-window", 1_770_000_000_000, 1_770_000_003_000, 0, 0, "{\"name\":\"Old chat\",\"unifiedMode\":\"chat\",\"isDraft\":false}"),
            ("composer-draft", "ws-1", 1_782_000_000_000, 1_782_000_000_000, 0, 0, "{\"unifiedMode\":\"agent\",\"isDraft\":true}"),
            ("composer-sub", "ws-1", 1_782_000_000_000, 1_782_000_000_000, 0, 1, "{\"name\":\"Subagent\",\"unifiedMode\":\"agent\"}"),
            ("composer-archived", "ws-1", 1_781_000_000_000, 1_781_000_000_000, 1, 0, "{\"name\":\"Archived\",\"unifiedMode\":\"agent\"}"),
        ]
        try createStateDatabase(at: dbPath, kvRows: kvRows, headers: headers)

        let reader = CursorDesktopStoreReader(stateDBPath: dbPath, stateRoot: root)
        let composers = try reader.composers()
        XCTAssertEqual(composers.map(\.composerId), ["composer-new", "composer-old"], "drafts, subagents, and archived chats stay out; newest first")
        XCTAssertEqual(composers[0].title, "Pong check")
        XCTAssertEqual(composers[0].workspacePath, "/Users/dev/App")
        XCTAssertEqual(composers[0].mode, "agent")
        XCTAssertTrue(composers[0].hasBlockingPendingActions)
        XCTAssertNil(composers[1].workspacePath, "empty-window chats belong to no folder")
        XCTAssertEqual(try reader.composers(includeArchived: true).map(\.composerId), ["composer-new", "composer-archived", "composer-old"], "archived chats come back in date order when asked for")
        XCTAssertEqual(reader.modelName(composerId: "composer-new"), "composer-2.5")

        let conversation = try XCTUnwrap(reader.conversation(composerId: "composer-new", agentID: "cursor", maxMessages: 50))
        XCTAssertEqual(conversation.messages.map(\.text), ["Reply with exactly PONG", "PONG"])
        XCTAssertEqual(conversation.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(conversation.status, .done)
        XCTAssertEqual(conversation.lastActivityUnixMs, 1_782_387_526_136)
        XCTAssertEqual(conversation.messages.last?.atUnixMs, 1_782_387_526_136)

        let old = try XCTUnwrap(reader.conversation(composerId: "composer-old", agentID: "cursor", maxMessages: 50))
        XCTAssertEqual(old.messages.map(\.text), ["old prompt", "old reply"])
        XCTAssertEqual(old.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(old.status, .done)
        XCTAssertNil(reader.conversation(composerId: "composer-draft", agentID: "cursor", maxMessages: 50))
        XCTAssertNil(CursorDesktopStoreReader.messageBlobIds(fromConversationState: "~"))
    }

    // MARK: - Hooks

    func testHookInstallerMergesPreservesAndIsIdempotent() throws {
        let directory = try temporaryDirectory("gt-cursor-hooks")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("hooks.json")
        try """
        {"version": 1, "hooks": {"stop": [{"command": "./hooks/mine.sh"}], "afterFileEdit": [{"command": "./hooks/format.sh"}]}, "loop_limit": 3}
        """.write(to: file, atomically: true, encoding: .utf8)

        let installer = CursorHookInstaller(hooksFileURL: file)
        XCTAssertFalse(installer.isInstalled())
        try installer.installIfNeeded()
        XCTAssertTrue(installer.isInstalled())

        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(config["version"] as? Int, 1)
        XCTAssertEqual(config["loop_limit"] as? Int, 3, "other keys are preserved")
        let hooks = try XCTUnwrap(config["hooks"] as? [String: Any])
        XCTAssertEqual(commands(hooks["stop"]), ["./hooks/mine.sh", CursorHookInstaller.hookCommand()])
        XCTAssertEqual(commands(hooks["afterFileEdit"]), ["./hooks/format.sh"])
        for event in CursorHookInstaller.events {
            XCTAssertEqual(commands(hooks[event]).last, CursorHookInstaller.hookCommand(), event)
        }

        try installer.installIfNeeded()
        let again = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(commands((again["hooks"] as? [String: Any])?["stop"]).count, 2, "a second install replaces, never duplicates")

        let fresh = directory.appendingPathComponent("missing/hooks.json")
        try CursorHookInstaller(hooksFileURL: fresh).installIfNeeded()
        let created = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fresh)) as? [String: Any])
        XCTAssertEqual(created["version"] as? Int, 1)
        XCTAssertEqual(Set(((created["hooks"] as? [String: Any]) ?? [:]).keys), Set(CursorHookInstaller.events))

        let broken = directory.appendingPathComponent("broken.json")
        try "{not json".write(to: broken, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CursorHookInstaller(hooksFileURL: broken).installIfNeeded())
        XCTAssertEqual(try String(contentsOf: broken, encoding: .utf8), "{not json", "an unreadable file is never overwritten")
        XCTAssertTrue(CursorHookInstaller.hookCommand().contains("cursor.sock"))
        XCTAssertFalse(CursorHookInstaller.hookCommand().contains("\"prompt\""), "the prompt text never rides the hook")
    }

    func testHookEventsDecodeAndRouteByConversation() throws {
        let event = try XCTUnwrap(CursorHookEvent.decode(line: """
        {"kind":"stop","conversation":"composer-1","generation":"gen-1","status":"completed","tool":"","title":"","transcript":"/tmp/t.jsonl","roots":["/Users/dev/App"],"model":"composer-2.5","mode":"agent","callId":""}
        """))
        XCTAssertEqual(event.kind, .stop)
        XCTAssertEqual(event.conversation, "composer-1")
        XCTAssertEqual(event.status, "completed")
        XCTAssertEqual(event.workspaceRoots, ["/Users/dev/App"])
        XCTAssertEqual(event.model, "composer-2.5")
        let tool = try XCTUnwrap(CursorHookEvent.decode(line: "{\"kind\":\"preToolUse\",\"conversation\":\"chat-1\",\"tool\":\"Shell\",\"title\":\"git status\",\"callId\":\"c1\"}"))
        XCTAssertEqual(tool.kind, .preToolUse)
        XCTAssertEqual(tool.toolTitle, "git status")
        XCTAssertEqual(tool.toolCallId, "c1")
        XCTAssertEqual(CursorHookEvent.decode(line: "{\"kind\":\"sessionStart\",\"conversation\":\"x\"}")?.kind, .other)
        XCTAssertEqual(CursorHookEvent.decode(line: "{\"kind\":\"sessionStart\",\"conversation\":\"x\"}")?.rawKind, "sessionStart")
        XCTAssertNil(CursorHookEvent.decode(line: "not json"))
        XCTAssertNil(CursorHookEvent.decode(line: "{\"conversation\":\"x\"}"))

        let source = FakeHookLineSource()
        let router = CursorHookRouter(makeListener: { source })
        var cli: [CursorHookEvent] = []
        var desktop: [CursorHookEvent] = []
        let cliId = try router.subscribe(ownsConversation: { $0 == "chat-1" }, handler: { cli.append($0) })
        let desktopId = try router.subscribe(ownsConversation: { $0 == "composer-1" }, handler: { desktop.append($0) })
        XCTAssertEqual(source.startCount, 1, "one socket serves every subscriber")

        source.onLine?("{\"kind\":\"beforeSubmitPrompt\",\"conversation\":\"chat-1\"}")
        source.onLine?("{\"kind\":\"stop\",\"conversation\":\"composer-1\",\"status\":\"aborted\"}")
        source.onLine?("{\"kind\":\"stop\",\"conversation\":\"nobody\"}")
        XCTAssertEqual(cli.map(\.kind), [.beforeSubmitPrompt])
        XCTAssertEqual(desktop.map(\.status), ["aborted"])

        router.unsubscribe(cliId)
        XCTAssertEqual(source.stopCount, 0)
        router.unsubscribe(desktopId)
        XCTAssertEqual(source.stopCount, 1, "the last subscriber releases the socket")
    }

    // MARK: - Helpers

    private func protobufBytes(field: Int, _ value: Data) -> Data {
        var data = Data()
        data.append(UInt8(field << 3 | 2))
        data.append(UInt8(value.count))
        data.append(value)
        return data
    }

    private func commands(_ entries: Any?) -> [String] {
        ((entries as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
    }

    private func temporaryDirectory(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createStoreDatabase(at path: String, metaValue: String, blobs: [(String, Data)]) throws {
        try withDatabase(path) { db in
            try exec(db, "CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB)")
            try exec(db, "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
            try insert(db, "INSERT INTO meta (key, value) VALUES (?, ?)", texts: ["0", metaValue])
            for (id, data) in blobs {
                try insert(db, "INSERT INTO blobs (id, data) VALUES (?, ?)", texts: [id], blob: data)
            }
        }
    }

    private func createStateDatabase(
        at path: String,
        kvRows: [(String, String)],
        headers: [(String, String, Int64, Int64, Int, Int, String)]
    ) throws {
        try withDatabase(path) { db in
            try exec(db, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
            try exec(db, "CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
            try exec(db, "CREATE TABLE composerHeaders (composerId TEXT PRIMARY KEY, workspaceId TEXT, createdAt INTEGER, lastUpdatedAt INTEGER, isArchived INTEGER, isSubagent INTEGER, recency INTEGER, checkpointAt INTEGER, subagentTypeName TEXT, value TEXT)")
            for (key, value) in kvRows {
                try insert(db, "INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)", texts: [key], blob: Data(value.utf8))
            }
            for header in headers {
                try insert(
                    db,
                    "INSERT INTO composerHeaders (composerId, workspaceId, createdAt, lastUpdatedAt, isArchived, isSubagent, recency, checkpointAt, subagentTypeName, value) VALUES (?, ?, \(header.2), \(header.3), \(header.4), \(header.5), 0, 0, '', ?)",
                    texts: [header.0, header.1, header.6]
                )
            }
        }
    }

    private func withDatabase(_ path: String, _ body: (OpaquePointer) throws -> Void) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "CursorConversationStoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "open failed"])
        }
        defer { sqlite3_close(db) }
        try body(db)
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "CursorConversationStoreTests", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    /// Binds `texts` to the leading placeholders and `blob` to the one after them.
    private func insert(_ db: OpaquePointer, _ sql: String, texts: [String], blob: Data? = nil) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NSError(domain: "CursorConversationStoreTests", code: 3, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        for (index, text) in texts.enumerated() {
            _ = text.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, transient) }
        }
        if let blob {
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(texts.count + 1), $0.baseAddress, Int32(blob.count), transient) }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "CursorConversationStoreTests", code: 4, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }
}

private final class FakeHookLineSource: HookLineSource, @unchecked Sendable {
    var onLine: (@Sendable (String) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() throws { startCount += 1 }
    func stop() { stopCount += 1 }
}

/// Opt-in audit against the real Cursor stores on this Mac. Prints counts and
/// flags only, never titles, prompts, or paths.
extension CursorConversationStoreTests {
    func testRealCursorStoresParse() throws {
        guard ProcessInfo.processInfo.environment["GT_CURSOR_REAL_STATE"] == "1" else {
            throw XCTSkip("set GT_CURSOR_REAL_STATE=1 to audit the real Cursor stores")
        }
        let stateRoot = CursorStateWatcher.defaultStateDir()
        let dbPath = stateRoot.appendingPathComponent("User/globalStorage/state.vscdb").path
        let reader = CursorDesktopStoreReader(stateDBPath: dbPath, stateRoot: stateRoot)
        let composers = try reader.composers(limit: 40)
        print("REAL desktop composers=\(composers.count) named=\(composers.filter { $0.title != nil }.count) withWorkspace=\(composers.filter { $0.workspacePath != nil }.count)")
        for composer in composers {
            let conversation = reader.conversation(composerId: composer.composerId, agentID: "cursor", maxMessages: 250)
            let calls = conversation?.messages.filter { $0.kind == .toolCall }.count ?? 0
            let results = conversation?.messages.filter { $0.kind == .toolResult }.count ?? 0
            let users = conversation?.messages.filter { $0.role == .user }.count ?? 0
            let assistants = conversation?.messages.filter { $0.role == .assistant }.count ?? 0
            print("REAL composer mode=\(composer.mode ?? "-") named=\(composer.title != nil) blocking=\(composer.hasBlockingPendingActions) messages=\(conversation?.messages.count ?? -1) user=\(users) assistant=\(assistants) calls=\(calls) results=\(results) details=\(conversation?.messageDetails.count ?? 0) status=\(conversation.map { String(describing: $0.status) } ?? "unreadable") model=\(reader.modelName(composerId: composer.composerId) != nil)")
        }
        let chats = CursorCLIChatCatalog.chats(limit: 40)
        print("REAL cli chats=\(chats.count) named=\(chats.filter { $0.name != nil }.count) withWorkspace=\(chats.filter { $0.workspacePath != nil }.count) withConversation=\(chats.filter(\.hasConversation).count)")
        for chat in chats.prefix(20) {
            let conversation = CursorChatStoreReader(path: chat.storePath).conversation(agentID: "cursor-agent", maxMessages: 250)
            let calls = conversation?.messages.filter { $0.kind == .toolCall }.count ?? 0
            let results = conversation?.messages.filter { $0.kind == .toolResult }.count ?? 0
            print("REAL chat mode=\(chat.mode ?? "-") named=\(chat.name != nil) workspace=\(chat.workspacePath != nil) messages=\(conversation?.messages.count ?? -1) calls=\(calls) results=\(results) status=\(conversation.map { String(describing: $0.status) } ?? "unreadable")")
        }
    }
}

#endif
