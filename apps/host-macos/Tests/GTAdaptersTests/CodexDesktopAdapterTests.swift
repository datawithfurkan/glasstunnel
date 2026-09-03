import XCTest
@testable import GTAdapters
import GTProtocol

final class CodexDesktopSessionParserTests: XCTestCase {
    func testParsesRecentMessagesAndThreadName() {
        let jsonl = """
        {"timestamp":"2026-04-19T08:00:38.343Z","type":"session_meta","payload":{"cwd":"/Users/developer/Documents/GitHub/glasstunnel"}}
        {"timestamp":"2026-04-19T08:00:52.916Z","type":"event_msg","payload":{"type":"thread_name_updated","thread_id":"thread-1","thread_name":"Glasstunnel 1"}}
        {"timestamp":"2026-04-19T08:01:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello from phone"}]}}
        {"timestamp":"2026-04-19T08:01:05.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"working on it"}]}}
        {"timestamp":"2026-04-19T08:01:06.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command"}}
        """

        let parsed = CodexDesktopSessionParser.parse(jsonl: jsonl, agentID: "codex-window", maxMessages: 24)

        XCTAssertEqual(parsed.workspaceRoot, "/Users/developer/Documents/GitHub/glasstunnel")
        XCTAssertEqual(parsed.threadName, "Glasstunnel 1")
        XCTAssertEqual(parsed.messages.count, 2)
        XCTAssertEqual(parsed.messages[0].role, .user)
        XCTAssertEqual(parsed.messages[0].text, "hello from phone")
        XCTAssertEqual(parsed.messages[1].role, .assistant)
        XCTAssertEqual(parsed.messages[1].text, "working on it")
        XCTAssertNil(parsed.pendingInputRequest)
    }

    func testParsesPlanningInputRequestAndClearsAfterResponse() {
        let arguments = """
        {"questions":[{"header":"Delivery","id":"alignment_delivery","question":"Should the pipeline create aligned copies or only score originals?","options":[{"label":"Create aligned copies (Recommended)","description":"Best path for customer review."},{"label":"Score originals only","description":"Lower risk but less useful."}]}]}
        """
        let escapedArguments = arguments
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
        let jsonl = """
        {"timestamp":"2026-05-11T11:47:00.000Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"\(escapedArguments)","call_id":"call-plan-1"}}
        """

        let parsed = CodexDesktopSessionParser.parse(jsonl: jsonl, agentID: "codex-window", maxMessages: 24)

        XCTAssertEqual(parsed.pendingInputRequest?.requestId, "call-plan-1")
        XCTAssertEqual(parsed.pendingInputRequest?.questions.count, 1)
        XCTAssertEqual(parsed.pendingInputRequest?.questions.first?.questionId, "alignment_delivery")
        XCTAssertEqual(parsed.pendingInputRequest?.questions.first?.choices.map(\.choiceId), ["1", "2"])
        XCTAssertEqual(parsed.pendingInputRequest?.questions.first?.choices.first?.label, "Create aligned copies (Recommended)")
        XCTAssertEqual(parsed.pendingInputRequest?.questions.first?.choices.first?.recommended, true)
        XCTAssertEqual(parsed.status, .waitingInput)
        XCTAssertEqual(parsed.statusDetail, "Waiting for your answer")

        let completedJsonl = jsonl + "\n" + """
        {"timestamp":"2026-05-11T11:48:00.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-plan-1","output":"{}"}}
        """
        let completed = CodexDesktopSessionParser.parse(jsonl: completedJsonl, agentID: "codex-window", maxMessages: 24)
        XCTAssertNil(completed.pendingInputRequest)
    }

    func testParsesRealTaskLifecycleStatus() {
        let started = """
        {"timestamp":"2026-07-23T12:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}
        """
        let completed = started + "\n" + """
        {"timestamp":"2026-07-23T12:00:05.000Z","type":"event_msg","payload":{"type":"task_complete"}}
        """
        let aborted = started + "\n" + """
        {"timestamp":"2026-07-23T12:00:03.000Z","type":"event_msg","payload":{"type":"turn_aborted"}}
        """

        let working = CodexDesktopSessionParser.parse(jsonl: started, agentID: "codex-window", maxMessages: 24)
        let done = CodexDesktopSessionParser.parse(jsonl: completed, agentID: "codex-window", maxMessages: 24)
        let stopped = CodexDesktopSessionParser.parse(jsonl: aborted, agentID: "codex-window", maxMessages: 24)

        XCTAssertEqual(working.status, .working)
        XCTAssertEqual(working.statusDetail, "Codex is working")
        XCTAssertEqual(done.status, .done)
        XCTAssertEqual(done.statusDetail, "Response ready")
        XCTAssertEqual(stopped.status, .idle)
        XCTAssertEqual(stopped.statusDetail, "Stopped")
    }

    func testKeepsOnlyNewestMessages() {
        let jsonl = """
        {"timestamp":"2026-04-19T08:00:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"one"}]}}
        {"timestamp":"2026-04-19T08:00:01.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"two"}]}}
        {"timestamp":"2026-04-19T08:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"three"}]}}
        """

        let parsed = CodexDesktopSessionParser.parse(jsonl: jsonl, agentID: "codex-window", maxMessages: 2)

        XCTAssertEqual(parsed.messages.map(\.text), ["two", "three"])
    }

    func testParsesSessionSummary() {
        let jsonl = """
        {"timestamp":"2026-04-19T08:00:38.343Z","type":"session_meta","payload":{"cwd":"/Users/developer/Documents/GitHub/docs-site","originator":"Codex Desktop","source":"vscode","thread_source":"user"}}
        {"timestamp":"2026-04-19T08:00:52.916Z","type":"event_msg","payload":{"type":"thread_name_updated","thread_id":"thread-1","thread_name":"Landing page polish"}}
        """

        let modifiedAt = Date(timeIntervalSince1970: 1_776_590_000)
        let parsed = CodexDesktopSessionParser.parseSummary(
            jsonl: jsonl,
            path: "/tmp/example-project.jsonl",
            modifiedAt: modifiedAt
        )

        XCTAssertEqual(parsed?.workspaceRoot, "/Users/developer/Documents/GitHub/docs-site")
        XCTAssertEqual(parsed?.threadName, "Landing page polish")
        XCTAssertEqual(parsed?.modifiedAt, modifiedAt)
    }

    func testParsesStandaloneChatSummaryWithoutWorkspace() {
        let jsonl = """
        {"timestamp":"2026-04-19T08:00:38.343Z","type":"session_meta","payload":{"originator":"Codex Desktop","source":"vscode","thread_source":"user"}}
        {"timestamp":"2026-04-19T08:00:52.916Z","type":"event_msg","payload":{"type":"thread_name_updated","thread_id":"thread-1","thread_name":"General Codex chat"}}
        """

        let parsed = CodexDesktopSessionParser.parseSummary(
            jsonl: jsonl,
            path: "/tmp/chat.jsonl",
            modifiedAt: Date(timeIntervalSince1970: 1_776_590_000)
        )

        XCTAssertNil(parsed?.workspaceRoot)
        XCTAssertEqual(parsed?.threadName, "General Codex chat")
    }

    func testSkipsSubagentSessionSummary() {
        let subagentPayloads = [
            #""originator":"Codex Desktop","source":"vscode","thread_source":"subagent""#,
            #""originator":"Codex Desktop","source":"vscode","parent_thread_id":"parent-thread""#,
            #""originator":"Codex Desktop","source":{"subagent":{"name":"reviewer"}}"#,
        ]

        for payload in subagentPayloads {
            let jsonl = """
            {"timestamp":"2026-06-25T16:09:00.742Z","type":"session_meta","payload":{"session_id":"parent-thread","id":"subagent-thread","cwd":"/Users/developer/Documents/GitHub2/example-project",\(payload)}}
            {"timestamp":"2026-06-25T16:09:22.956Z","type":"event_msg","payload":{"type":"thread_name_updated","thread_id":"thread-1","thread_name":"Review Supabase backend fix"}}
            """

            let parsed = CodexDesktopSessionParser.parseSummary(
                jsonl: jsonl,
                path: "/tmp/review-subagent.jsonl",
                modifiedAt: Date(timeIntervalSince1970: 1_782_403_000)
            )

            XCTAssertNil(parsed, "Expected Codex subagent metadata to be hidden from selectable targets: \(payload)")
        }
    }

    func testSkipsInternalExecSessionSummary() {
        let jsonl = """
        {"timestamp":"2026-07-23T11:00:00.000Z","type":"session_meta","payload":{"id":"internal-exec","cwd":"/Users/developer/Documents/GitHub2/example-project","originator":"codex_exec","source":"exec","thread_source":"user"}}
        {"timestamp":"2026-07-23T11:00:02.000Z","type":"event_msg","payload":{"type":"thread_name_updated","thread_id":"internal-exec","thread_name":"Review backend fix"}}
        """

        let parsed = CodexDesktopSessionParser.parseSummary(
            jsonl: jsonl,
            path: "/tmp/internal-exec.jsonl",
            modifiedAt: Date(timeIntervalSince1970: 1_784_804_400)
        )

        XCTAssertNil(parsed, "Internal Codex executions must not appear as desktop chats")
    }

    func testParsesLargeSessionFromHeadAndTailOnly() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let sessionURL = tempDir.appendingPathComponent("large.jsonl")

        let head = """
        {"timestamp":"2026-04-19T08:00:38.343Z","type":"session_meta","payload":{"cwd":"/Users/developer/Documents/GitHub/glasstunnel","originator":"Codex Desktop","source":"vscode","thread_source":"user"}}
        {"timestamp":"2026-04-19T08:00:52.916Z","type":"event_msg","payload":{"type":"thread_name_updated","thread_id":"thread-1","thread_name":"Glasstunnel 1"}}

        """
        let filler = String(repeating: "x", count: 9 * 1024 * 1024)
        let tail = """

        {"timestamp":"2026-04-19T08:00:59.000Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-04-19T08:01:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"latest prompt"}]}}
        {"timestamp":"2026-04-19T08:01:05.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"latest answer"}]}}
        """
        try (head + filler + tail).write(to: sessionURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let parsed = CodexDesktopSessionParser.parseRecentFile(
            at: sessionURL,
            agentID: "codex-window",
            maxMessages: 24
        )

        XCTAssertEqual(parsed?.workspaceRoot, "/Users/developer/Documents/GitHub/glasstunnel")
        XCTAssertEqual(parsed?.threadName, "Glasstunnel 1")
        XCTAssertEqual(parsed?.messages.map(\.text), ["latest prompt", "latest answer"])
        XCTAssertEqual(parsed?.status, .working)
        XCTAssertEqual(parsed?.statusDetail, "Codex is working")
    }

    func testSummaryPreviewUsesTailForLatestThreadName() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let sessionURL = tempDir.appendingPathComponent("renamed.jsonl")

        let head = """
        {"timestamp":"2026-04-19T08:00:38.343Z","type":"session_meta","payload":{"cwd":"/Users/developer/Documents/GitHub/glasstunnel","originator":"Codex Desktop","source":"vscode","thread_source":"user"}}
        {"timestamp":"2026-04-19T08:00:52.916Z","type":"event_msg","payload":{"type":"thread_name_updated","thread_id":"thread-1","thread_name":"Glasstunnel"}}

        """
        let filler = String(repeating: "x", count: 9 * 1024 * 1024)
        let tail = """

        {"timestamp":"2026-04-19T08:08:52.916Z","type":"event_msg","payload":{"type":"thread_name_updated","thread_id":"thread-1","thread_name":"Glasstunnel 1"}}
        """
        try (head + filler + tail).write(to: sessionURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let parsed = CodexDesktopSessionParser.parseSummaryPreview(
            at: sessionURL,
            path: sessionURL.path,
            modifiedAt: Date(timeIntervalSince1970: 1_776_590_000)
        )

        XCTAssertEqual(parsed?.workspaceRoot, "/Users/developer/Documents/GitHub/glasstunnel")
        XCTAssertEqual(parsed?.threadName, "Glasstunnel 1")
    }

    func testSessionIndexOverridesMissingJsonlThreadName() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let sessionPath = tempDir
            .appendingPathComponent("rollout-2026-06-10T20-47-49-019eb2dc-b538-7110-92d0-9a27783672e0.jsonl")
            .path
        let summary = CodexSessionSummary(
            path: sessionPath,
            modifiedAt: Date(timeIntervalSince1970: 1_781_312_921),
            workspaceRoot: "/Users/developer/Documents/GitHub2/automation-sample",
            threadName: nil
        )
        let indexURL = tempDir.appendingPathComponent("session_index.jsonl")
        try """
        {"id":"019eb2dc-b538-7110-92d0-9a27783672e0","thread_name":"Audit project codebase","updated_at":"2026-06-10T18:49:23.022213Z"}
        {"id":"019eb2dc-b538-7110-92d0-9a27783672e0","thread_name":"trading bot 2","updated_at":"2026-06-10T20:29:16.620208Z"}
        """.write(to: indexURL, atomically: true, encoding: .utf8)

        let indexedNames = CodexSessionIndex.loadThreadNames(from: indexURL)
        let resolved = CodexSessionIndex.applyingIndexedThreadName(
            to: summary,
            indexedThreadNames: indexedNames
        )

        XCTAssertEqual(indexedNames["019eb2dc-b538-7110-92d0-9a27783672e0"], "trading bot 2")
        XCTAssertEqual(resolved.threadName, "trading bot 2")

        let catalog = CodexProjectCatalog.build(
            globalStateURL: tempDir.appendingPathComponent(".codex-global-state.json"),
            sessionSummaries: [resolved]
        )

        XCTAssertEqual(catalog.descriptors.first?.label, "automation-sample")
        XCTAssertEqual(catalog.descriptors.first?.recentThreadName, "trading bot 2")
        XCTAssertEqual(catalog.descriptors.first?.protocolTarget(selected: true).label, "trading bot 2")
    }

    func testSessionIndexKeepsJsonlThreadNameWhenNoMatchingSessionId() {
        let summary = CodexSessionSummary(
            path: "/tmp/no-codex-session-id.jsonl",
            modifiedAt: Date(timeIntervalSince1970: 1_781_312_921),
            workspaceRoot: "/Users/developer/Documents/GitHub2/glasstunnel",
            threadName: "Glasstunnel 1"
        )

        let resolved = CodexSessionIndex.applyingIndexedThreadName(
            to: summary,
            indexedThreadNames: ["019eb2dc-b538-7110-92d0-9a27783672e0": "wrong session"]
        )

        XCTAssertEqual(resolved.threadName, "Glasstunnel 1")
    }
}

final class CodexProjectCatalogTests: XCTestCase {
    func testProjectlessThreadIDsStayOutOfProjects() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projectRoot = "/Users/developer/Documents/GitHub2/glasstunnel"
        let projectlessID = "019eb2dc-b538-7110-92d0-9a27783672e0"
        let globalStateURL = tempDir.appendingPathComponent(".codex-global-state.json")
        try """
        {
          "project-order": ["\(projectRoot)"],
          "electron-saved-workspace-roots": ["\(projectRoot)"],
          "active-workspace-roots": ["\(projectRoot)"],
          "projectless-thread-ids": ["\(projectlessID)"]
        }
        """.write(to: globalStateURL, atomically: true, encoding: .utf8)

        let catalog = CodexProjectCatalog.build(
            globalStateURL: globalStateURL,
            sessionSummaries: [
                CodexSessionSummary(
                    path: "/tmp/rollout-project-thread-019eb2dc-b538-7110-92d0-9a27783672e1.jsonl",
                    modifiedAt: Date(timeIntervalSince1970: 20),
                    workspaceRoot: projectRoot,
                    threadName: "Project thread"
                ),
                CodexSessionSummary(
                    path: "/tmp/rollout-standalone-\(projectlessID).jsonl",
                    modifiedAt: Date(timeIntervalSince1970: 30),
                    workspaceRoot: projectRoot,
                    threadName: "Standalone chat"
                ),
            ]
        )

        XCTAssertEqual(catalog.descriptors.map(\.recentThreadName), ["Project thread", "Standalone chat"])
        XCTAssertEqual(catalog.descriptors[0].protocolTarget(selected: false).projectLabel, "glasstunnel")
        XCTAssertNil(catalog.descriptors[1].protocolTarget(selected: false).projectLabel)
        XCTAssertEqual(catalog.descriptors[1].subtitle, "Standalone chat")
    }

    func testBuildsTargetsFromGlobalStateOrderAndRecentSessions() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let globalStateURL = tempDir.appendingPathComponent(".codex-global-state.json")
        let globalState = """
        {
          "project-order": [
            "/Users/developer/Documents/GitHub/glasstunnel",
            "/Users/developer/Documents/GitHub/docs-site"
          ],
          "electron-saved-workspace-roots": [
            "/Users/developer/Documents/GitHub/sample-app"
          ],
          "active-workspace-roots": [
            "/Users/developer/Documents/GitHub/docs-site"
          ]
        }
        """
        try globalState.write(to: globalStateURL, atomically: true, encoding: .utf8)

        let summaries = [
            CodexSessionSummary(
                path: "/tmp/1.jsonl",
                modifiedAt: Date(timeIntervalSince1970: 20),
                workspaceRoot: "/Users/developer/Documents/GitHub/glasstunnel",
                threadName: "Review entire project"
            ),
            CodexSessionSummary(
                path: "/tmp/1b.jsonl",
                modifiedAt: Date(timeIntervalSince1970: 25),
                workspaceRoot: "/Users/developer/Documents/GitHub/glasstunnel",
                threadName: "Glasstunnel 1"
            ),
            CodexSessionSummary(
                path: "/tmp/2.jsonl",
                modifiedAt: Date(timeIntervalSince1970: 30),
                workspaceRoot: "/Users/developer/Documents/GitHub/docs-site",
                threadName: "Landing page polish"
            ),
            CodexSessionSummary(
                path: "/tmp/3.jsonl",
                modifiedAt: Date(timeIntervalSince1970: 10),
                workspaceRoot: "/Users/developer/Documents/GitHub/model-demo",
                threadName: "Benchmark sweep"
            ),
            CodexSessionSummary(
                path: "/tmp/4.jsonl",
                modifiedAt: Date(timeIntervalSince1970: 40),
                workspaceRoot: nil,
                threadName: "Standalone chat"
            ),
        ]

        let catalog = CodexProjectCatalog.build(globalStateURL: globalStateURL, sessionSummaries: summaries)

        XCTAssertEqual(catalog.activeWorkspaceRoot, "/Users/developer/Documents/GitHub/docs-site")
        XCTAssertEqual(
            catalog.descriptors.map(\.workspaceRoot),
            [
                "/Users/developer/Documents/GitHub/glasstunnel",
                "/Users/developer/Documents/GitHub/glasstunnel",
                "/Users/developer/Documents/GitHub/docs-site",
                "/Users/developer/Documents/GitHub/sample-app",
                "/Users/developer/Documents/GitHub/model-demo",
                nil,
            ]
        )
        XCTAssertEqual(catalog.descriptors[0].recentThreadName, "Glasstunnel 1")
        XCTAssertEqual(catalog.descriptors[0].targetId, "/tmp/1b.jsonl")
        XCTAssertEqual(catalog.descriptors[1].recentThreadName, "Review entire project")
        XCTAssertEqual(catalog.descriptors[2].label, "docs-site")
        XCTAssertEqual(catalog.descriptors[3].targetKind, "project")
        XCTAssertEqual(catalog.descriptors[4].recentThreadName, "Benchmark sweep")
        XCTAssertEqual(catalog.descriptors[5].label, "Standalone chat")
        XCTAssertNil(catalog.descriptors[5].workspaceRoot)
    }

    func testResolvesCurrentLocalProjectIDsToWorkspaceRoots() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let aksanRoot = "/Users/developer/Documents/GitHub2/AKSAN-automation"
        let glasstunnelRoot = "/Users/developer/Documents/GitHub2/glasstunnel"
        let globalStateURL = tempDir.appendingPathComponent(".codex-global-state.json")
        try """
        {
          "project-order": ["local-aksan", "local-glasstunnel"],
          "local-projects": {
            "local-aksan": {
              "id": "local-aksan",
              "name": "AKSAN-automation",
              "rootPaths": ["\(aksanRoot)"]
            },
            "local-glasstunnel": {
              "id": "local-glasstunnel",
              "name": "glasstunnel",
              "rootPaths": ["\(glasstunnelRoot)"]
            }
          },
          "selected-project": {
            "type": "local",
            "projectId": "local-glasstunnel"
          },
          "electron-saved-workspace-roots": ["local-aksan"],
          "active-workspace-roots": []
        }
        """.write(to: globalStateURL, atomically: true, encoding: .utf8)

        let catalog = CodexProjectCatalog.build(
            globalStateURL: globalStateURL,
            sessionSummaries: [
                CodexSessionSummary(
                    path: "/tmp/rollout-2026-07-31-019eb2dc-b538-7110-92d0-9a27783672e0.jsonl",
                    modifiedAt: Date(timeIntervalSince1970: 30),
                    workspaceRoot: aksanRoot,
                    threadName: "AKSAN full batch"
                ),
                CodexSessionSummary(
                    path: "/tmp/rollout-2026-07-31-019eb2dc-b538-7110-92d0-9a27783672e1.jsonl",
                    modifiedAt: Date(timeIntervalSince1970: 20),
                    workspaceRoot: glasstunnelRoot,
                    threadName: "Fix Codex sync"
                ),
            ]
        )

        XCTAssertEqual(catalog.activeWorkspaceRoot, glasstunnelRoot)
        XCTAssertEqual(catalog.descriptors.map(\.workspaceRoot), [aksanRoot, glasstunnelRoot])
        XCTAssertEqual(catalog.descriptors.map(\.recentThreadName), ["AKSAN full batch", "Fix Codex sync"])
        XCTAssertFalse(catalog.descriptors.contains { $0.workspaceRoot?.hasPrefix("local-") == true })
    }

    func testThreadTargetKeepsThreadNameSeparateFromProjectLabel() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let globalStateURL = tempDir.appendingPathComponent(".codex-global-state.json")
        try """
        {
          "project-order": ["/Users/developer/Documents/GitHub2/glasstunnel"],
          "electron-saved-workspace-roots": [],
          "active-workspace-roots": ["/Users/developer/Documents/GitHub2/glasstunnel"]
        }
        """.write(to: globalStateURL, atomically: true, encoding: .utf8)

        let catalog = CodexProjectCatalog.build(
            globalStateURL: globalStateURL,
            sessionSummaries: [
                CodexSessionSummary(
                    path: "/tmp/glass-1.jsonl",
                    modifiedAt: Date(timeIntervalSince1970: 30),
                    workspaceRoot: "/Users/developer/Documents/GitHub2/glasstunnel",
                    threadName: "Glasstunnel 1"
                ),
            ]
        )

        let descriptor = try XCTUnwrap(catalog.descriptors.first)

        XCTAssertEqual(descriptor.label, "glasstunnel")
        XCTAssertEqual(descriptor.recentThreadName, "Glasstunnel 1")
        XCTAssertEqual(descriptor.targetKind, "thread")
    }

    func testProtocolTargetUsesThreadNameAsPrimaryLabel() {
        let descriptor = CodexTargetDescriptor(
            targetId: "/tmp/glass-1.jsonl",
            workspaceRoot: "/Users/developer/Documents/GitHub2/glasstunnel",
            sessionPath: "/tmp/glass-1.jsonl",
            label: "glasstunnel",
            subtitle: "~/Documents/GitHub2/glasstunnel",
            recentThreadName: "Glasstunnel 1",
            recentActivityUnixMs: 1_776_590_000_000,
            targetKind: "thread"
        )

        let target = descriptor.protocolTarget(selected: true)

        XCTAssertEqual(target.label, "Glasstunnel 1")
        XCTAssertEqual(target.threadLabel, "Glasstunnel 1")
        XCTAssertEqual(target.projectLabel, "glasstunnel")
        XCTAssertEqual(target.projectPath, "/Users/developer/Documents/GitHub2/glasstunnel")
        XCTAssertEqual(target.targetKind, "thread")
    }

    func testProtocolTargetRequiresMatchingDesktopThreadBeforeBecomingActive() {
        let descriptor = CodexTargetDescriptor(
            targetId: "/tmp/glass-1.jsonl",
            workspaceRoot: "/Users/developer/Documents/GitHub2/glasstunnel",
            sessionPath: "/tmp/glass-1.jsonl",
            label: "glasstunnel",
            subtitle: "~/Documents/GitHub2/glasstunnel",
            recentThreadName: "Glasstunnel 1",
            recentActivityUnixMs: 1_776_590_000_000,
            targetKind: "thread"
        )

        let unverified = descriptor.protocolTarget(
            selected: true,
            activeDesktopThreadName: "Another chat"
        )
        let verified = descriptor.protocolTarget(
            selected: true,
            activeDesktopThreadName: "Glasstunnel 1"
        )

        XCTAssertTrue(unverified.selected)
        XCTAssertEqual(unverified.label, "Glasstunnel 1")
        XCTAssertEqual(unverified.threadLabel, "Glasstunnel 1")
        XCTAssertEqual(unverified.isActive, false)
        XCTAssertEqual(verified.isActive, true)
    }

    func testProtocolTargetCanActivateUUIDBackedThreadWhenDesktopTitleIsGeneric() {
        let descriptor = CodexTargetDescriptor(
            targetId: "/tmp/rollout-2026-07-31-019eb2dc-b538-7110-92d0-9a27783672e0.jsonl",
            workspaceRoot: "/Users/developer/Documents/GitHub2/glasstunnel",
            sessionPath: "/tmp/rollout-2026-07-31-019eb2dc-b538-7110-92d0-9a27783672e0.jsonl",
            label: "glasstunnel",
            subtitle: "~/Documents/GitHub2/glasstunnel",
            recentThreadName: "Fix Codex sync",
            recentActivityUnixMs: 1_776_590_000_000,
            targetKind: "thread"
        )

        XCTAssertEqual(
            descriptor.desktopThreadURL?.absoluteString,
            "codex://threads/019eb2dc-b538-7110-92d0-9a27783672e0"
        )
        XCTAssertEqual(
            descriptor.protocolTarget(selected: true, activeDesktopThreadName: "ChatGPT").isActive,
            true
        )
    }
}

final class CodexDesktopRealStateTests: XCTestCase {
    func testRealCatalogMatchesDesktopSessionAndProjectlessState() throws {
        let enabled = ProcessInfo.processInfo.environment["GT_CODEX_DESKTOP_REAL_STATE", default: ""]
            .lowercased()
        guard ["1", "true", "yes"].contains(enabled) else {
            throw XCTSkip("Set GT_CODEX_DESKTOP_REAL_STATE=1 to inspect privacy-safe local Codex counts")
        }

        let sessionsRoot = CodexDesktopAdapter.defaultSessionsRoot()
        let globalStateURL = CodexDesktopAdapter.defaultGlobalStateURL()
        let indexedNames = CodexSessionIndex.loadThreadNames(from: CodexDesktopAdapter.defaultSessionIndexURL())
        let projectlessIDs = try loadProjectlessThreadIDs(from: globalStateURL)
        let fileManager = FileManager.default
        let enumerator = try XCTUnwrap(
            fileManager.enumerator(
                at: sessionsRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        )

        var sessionFileCount = 0
        var summaries: [CodexSessionSummary] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values.isRegularFile == true, let modifiedAt = values.contentModificationDate else { continue }
            sessionFileCount += 1
            guard let summary = CodexDesktopSessionParser.parseSummaryPreview(
                at: url,
                path: url.path,
                modifiedAt: modifiedAt
            ) else {
                continue
            }
            summaries.append(
                CodexSessionIndex.applyingIndexedThreadName(
                    to: summary,
                    indexedThreadNames: indexedNames
                )
            )
        }

        let catalog = CodexProjectCatalog.build(
            globalStateURL: globalStateURL,
            sessionSummaries: summaries
        )
        let threadTargets = catalog.descriptors.filter { $0.targetKind == "thread" }
        let standaloneTargets = threadTargets.filter {
            $0.protocolTarget(selected: false).projectLabel == nil
        }
        let expectedStandaloneCount = summaries.filter {
            guard let sessionID = CodexSessionIndex.sessionID(fromPath: $0.path) else { return false }
            return projectlessIDs.contains(sessionID)
        }.count
        let parsedSessions = summaries.compactMap { summary in
            CodexDesktopSessionParser.parseRecentFile(
                at: URL(fileURLWithPath: summary.path),
                agentID: "codex-real-state",
                maxMessages: AgentHistoryLimits.snapshotMessageCount
            )
        }
        let statusCounts = Dictionary(grouping: parsedSessions, by: \.status).mapValues(\.count)

        XCTAssertFalse(summaries.isEmpty, "Installed Codex should expose at least one desktop session")
        XCTAssertEqual(parsedSessions.count, summaries.count)
        XCTAssertEqual(threadTargets.count, summaries.count)
        XCTAssertEqual(standaloneTargets.count, expectedStandaloneCount)
        XCTAssertEqual(Set(threadTargets.map(\.targetId)).count, threadTargets.count)
        XCTAssertTrue(threadTargets.allSatisfy { !$0.protocolTarget(selected: false).label.isEmpty })

        print(
            "CODEX_REAL_STATE "
                + "session_files=\(sessionFileCount) "
                + "desktop_threads=\(summaries.count) "
                + "project_threads=\(threadTargets.count - standaloneTargets.count) "
                + "standalone_chats=\(standaloneTargets.count) "
                + "working=\(statusCounts[.working, default: 0]) "
                + "waiting_input=\(statusCounts[.waitingInput, default: 0]) "
                + "done=\(statusCounts[.done, default: 0]) "
                + "idle=\(statusCounts[.idle, default: 0])"
        )
    }

    private func loadProjectlessThreadIDs(from url: URL) throws -> Set<String> {
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set((json["projectless-thread-ids"] as? [String] ?? []).map { $0.lowercased() })
    }

    func testCatalogScanOpensOnlyTheNewestRollouts() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let day = root.appendingPathComponent("2026/09/03", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        for index in 0..<8 {
            let file = day.appendingPathComponent("rollout-2026-09-03T10-00-0\(index)-0000000\(index)-0000-4000-8000-000000000000.jsonl")
            try "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/repo\"}}\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000 + Double(index) * 60)],
                ofItemAtPath: file.path
            )
        }
        try "not a rollout".write(to: day.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let newest = CodexDesktopAdapter.recentSessionFiles(in: root, limit: 3)
        XCTAssertEqual(newest.map { $0.url.lastPathComponent.prefix(29) }, [
            "rollout-2026-09-03T10-00-07-0",
            "rollout-2026-09-03T10-00-06-0",
            "rollout-2026-09-03T10-00-05-0",
        ])
        XCTAssertEqual(CodexDesktopAdapter.recentSessionFiles(in: root, limit: 100).count, 8)
        XCTAssertTrue(CodexDesktopAdapter.recentSessionFiles(in: root.appendingPathComponent("missing"), limit: 3).isEmpty)
        XCTAssertGreaterThanOrEqual(CodexDesktopAdapter.maxScannedSessions, 100, "recent threads across a few projects must fit")
    }
}
