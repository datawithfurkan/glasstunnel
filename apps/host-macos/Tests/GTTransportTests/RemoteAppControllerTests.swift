import XCTest
import CoreGraphics
import GTAdapters
import GTProtocol
import GTCapture
import GTSecurity
@testable import GTTransport

@MainActor
final class RemoteAppControllerTests: XCTestCase {
    func testInstalledApplicationResolverAcceptsOnlyStableApplicationRoots() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        XCTAssertTrue(InstalledApplicationResolver.isStableInstallURL(
            URL(fileURLWithPath: "/Applications/Cursor.app", isDirectory: true),
            homeDirectory: home
        ))
        XCTAssertTrue(InstalledApplicationResolver.isStableInstallURL(
            URL(fileURLWithPath: "/Users/tester/Applications/Cursor.app", isDirectory: true),
            homeDirectory: home
        ))
        XCTAssertTrue(InstalledApplicationResolver.isStableInstallURL(
            URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app", isDirectory: true),
            homeDirectory: home
        ))
        XCTAssertFalse(InstalledApplicationResolver.isStableInstallURL(
            URL(fileURLWithPath: "/Users/tester/Library/Caches/vendor.ShipIt/update/Cursor.app", isDirectory: true),
            homeDirectory: home
        ))
        XCTAssertFalse(InstalledApplicationResolver.isStableInstallURL(
            URL(fileURLWithPath: "/private/var/folders/AppTranslocation/Cursor.app", isDirectory: true),
            homeDirectory: home
        ))
        XCTAssertFalse(InstalledApplicationResolver.isStableInstallURL(
            URL(fileURLWithPath: "/Volumes/Cursor/Cursor.app", isDirectory: true),
            homeDirectory: home
        ))
    }

    func testSupportedWindowsBecomeRemoteApps() {
        let defaults = isolatedDefaults()
        let controller = RemoteAppController(defaults: defaults, executableExists: { _ in false })
        controller.updateWindows([
            CapturableWindow(
                windowID: 100,
                title: "Glasstunnel 1",
                applicationName: "Codex",
                applicationBundleID: "com.openai.codex",
                pid: 1234,
                frame: .zero,
                isOnScreen: true
            ),
            CapturableWindow(
                windowID: 200,
                title: "Cursor Agents",
                applicationName: "Cursor",
                applicationBundleID: "com.todesktop.230313mzl4w4u92",
                pid: 2345,
                frame: .zero,
                isOnScreen: true
            ),
        ])

        let apps = controller.remoteAppsSnapshot()
        XCTAssertEqual(apps.first(where: { $0.remoteAppId == "codex" })?.available, true)
        XCTAssertEqual(apps.first(where: { $0.remoteAppId == "codex" })?.hasVideo, false)
        XCTAssertEqual(apps.first(where: { $0.remoteAppId == "cursor" })?.available, true)
        XCTAssertEqual(apps.first(where: { $0.remoteAppId == "cursor" })?.hasVideo, false)
        XCTAssertNil(apps.first(where: { $0.remoteAppId == "claude-code" }))
        XCTAssertNil(apps.first(where: { $0.remoteAppId == "gemini-cli" }))
        XCTAssertNil(apps.first(where: { $0.remoteAppId == "opencode" }))
        XCTAssertEqual(apps.first(where: { $0.remoteAppId == "screen" })?.enabled, true)
        XCTAssertEqual(apps.first(where: { $0.remoteAppId == "screen" })?.hasVideo, true)
        let screenDetail = apps.first(where: { $0.remoteAppId == "screen" })?.statusDetail ?? ""
        XCTAssertFalse(screenDetail.localizedCaseInsensitiveContains("enable"))
    }

    func testAbsentCliAppsAreNotPublishedForThisMac() {
        let defaults = isolatedDefaults()
        let controller = RemoteAppController(defaults: defaults, executableExists: { _ in false })

        let apps = controller.remoteAppsSnapshot()

        XCTAssertNil(apps.first { $0.remoteAppId == "claude-code" })
        XCTAssertNil(apps.first { $0.remoteAppId == "cursor-agent" })
        XCTAssertNil(apps.first { $0.remoteAppId == "gemini-cli" })
        XCTAssertNil(apps.first { $0.remoteAppId == "opencode" })
        XCTAssertNil(apps.first { $0.remoteAppId == "codex-cli" })
        XCTAssertNotNil(apps.first { $0.remoteAppId == "screen" })
    }

    func testInstalledClosedGuiAppIsPublishedForLaunch() {
        let defaults = isolatedDefaults()
        let controller = RemoteAppController(
            defaults: defaults,
            executableExists: { _ in false },
            appExists: { bundleID in
                bundleID == "com.todesktop.230313mzl4w4u92"
            }
        )

        let cursor = controller.remoteAppsSnapshot().first { $0.remoteAppId == "cursor" }

        XCTAssertNotNil(cursor)
        XCTAssertEqual(cursor?.available, false)
        XCTAssertEqual(cursor?.statusDetail, "Open Cursor on this Mac")
    }

    func testUnavailableEnabledAppDoesNotEnterDeprecatedLayout() {
        let defaults = isolatedDefaults()
        let controller = RemoteAppController(defaults: defaults, executableExists: { _ in false })
        controller.setEnabled(remoteAppId: "codex", enabled: true)

        XCTAssertNil(controller.remoteAppsSnapshot().first { $0.remoteAppId == "codex" })
        XCTAssertEqual(controller.deprecatedLayout().cells.filter { !$0.agentId.isEmpty }.count, 0)
    }

    func testScreenRecordingPermissionControlsMacScreenAvailability() {
        let defaults = isolatedDefaults()
        let controller = RemoteAppController(defaults: defaults, executableExists: { _ in false })

        controller.setScreenRecordingAvailable(false)

        var screen = controller.remoteAppsSnapshot().first { $0.remoteAppId == "screen" }
        XCTAssertEqual(screen?.enabled, true)
        XCTAssertEqual(screen?.available, false)
        XCTAssertEqual(screen?.status, .disconnected)
        XCTAssertEqual(screen?.statusDetail, "Allow Screen Recording in System Settings")

        controller.setScreenRecordingAvailable(true)

        screen = controller.remoteAppsSnapshot().first { $0.remoteAppId == "screen" }
        XCTAssertEqual(screen?.enabled, true)
        XCTAssertEqual(screen?.available, true)
    }

    func testCliBackedRemoteAppCanBeAvailableWithoutWindow() {
        let defaults = isolatedDefaults()
        let controller = RemoteAppController(defaults: defaults, executableExists: { candidate in
            candidate == "claude"
        })

        let claude = controller.remoteAppsSnapshot().first { $0.remoteAppId == "claude-code" }

        XCTAssertEqual(claude?.available, true)
        XCTAssertEqual(claude?.hasVideo, false)
        XCTAssertEqual(claude?.statusDetail, "Ready from web")
    }

    func testCodexCliPublicationUsesAdapterExecutableCandidates() {
        let definition = RemoteAppDefinition.definition(for: "codex-cli")

        XCTAssertEqual(definition?.executableCandidates, CodexAdapter.executableCandidates())
    }

    func testGeminiCliPublicationUsesAdapterExecutableCandidates() {
        let definition = RemoteAppDefinition.definition(for: "gemini-cli")

        XCTAssertEqual(definition?.executableCandidates, GeminiAdapter.executableCandidates())
    }

    func testCursorAgentPublicationUsesAdapterExecutableCandidates() {
        let definition = RemoteAppDefinition.definition(for: "cursor-agent")

        XCTAssertEqual(definition?.executableCandidates, CursorAgentAdapter.executableCandidates())
    }

    func testOpenCodePublicationUsesAdapterExecutableCandidates() {
        let definition = RemoteAppDefinition.definition(for: "opencode")

        XCTAssertEqual(definition?.executableCandidates, OpenCodeAdapter.executableCandidates())
    }

    func testGeminiCliCanBeAvailableWithoutWindow() {
        let defaults = isolatedDefaults()
        let geminiCandidates = Set(GeminiAdapter.executableCandidates())
        let controller = RemoteAppController(defaults: defaults, executableExists: { candidate in
            geminiCandidates.contains(candidate)
        })

        let gemini = controller.remoteAppsSnapshot().first { $0.remoteAppId == "gemini-cli" }

        XCTAssertEqual(gemini?.available, true)
        XCTAssertEqual(gemini?.hasVideo, false)
        XCTAssertEqual(gemini?.adapterKind, .geminiCli)
        XCTAssertEqual(gemini?.statusDetail, "Ready from web")
    }

    func testCursorAgentCanBeAvailableWithoutWindow() {
        let defaults = isolatedDefaults()
        let cursorAgentCandidates = Set(CursorAgentAdapter.executableCandidates())
        let controller = RemoteAppController(defaults: defaults, executableExists: { candidate in
            cursorAgentCandidates.contains(candidate)
        })

        let cursorAgent = controller.remoteAppsSnapshot().first { $0.remoteAppId == "cursor-agent" }

        XCTAssertEqual(cursorAgent?.available, true)
        XCTAssertEqual(cursorAgent?.hasVideo, false)
        XCTAssertEqual(cursorAgent?.adapterKind, .cursorAgent)
        XCTAssertEqual(cursorAgent?.statusDetail, "Ready from web")
    }

    func testGeminiCliStartActionCreatesAndStartsAdapter() async throws {
        let defaults = isolatedDefaults()
        defaults.set([], forKey: "remoteApps.enabled.v1")
        defaults.set(true, forKey: "remoteApps.terminalDefaultEnabled.v1")
        let geminiCandidates = Set(GeminiAdapter.executableCandidates())
        let adapter = StubAgentAdapter(
            agentID: "gemini-cli",
            kind: .geminiCli,
            label: "Gemini CLI"
        )
        let factory = AdapterFactoryRecorder(remoteAppId: "gemini-cli", adapter: adapter)
        let controller = RemoteAppController(
            defaults: defaults,
            executableExists: { candidate in geminiCandidates.contains(candidate) },
            adapterFactory: { definition, window in
                factory.makeAdapter(definition: definition, window: window)
            }
        )
        let snapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            snapshots.append(snapshot)
        }

        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "gemini-cli",
            action: .start
        ))

        try await waitUntil {
            adapter.startCalls() == 1
        }
        XCTAssertTrue(factory.remoteAppIds().contains("gemini-cli"))
        XCTAssertTrue(snapshots.contains { snapshot in
            snapshot.agentId == "gemini-cli" &&
            snapshot.status == .working &&
            snapshot.statusDetail == "Starting" &&
            snapshot.recentMessages.contains { $0.text.contains("Starting Gemini CLI on this Mac") }
        })
        XCTAssertEqual(controller.remoteAppsSnapshot().first { $0.remoteAppId == "gemini-cli" }?.enabled, true)
    }

    func testCursorAgentStartActionCreatesAndStartsAdapter() async throws {
        let defaults = isolatedDefaults()
        defaults.set([], forKey: "remoteApps.enabled.v1")
        defaults.set(true, forKey: "remoteApps.terminalDefaultEnabled.v1")
        let cursorAgentCandidates = Set(CursorAgentAdapter.executableCandidates())
        let adapter = StubAgentAdapter(
            agentID: "cursor-agent",
            kind: .cursorAgent,
            label: "Cursor Agent"
        )
        let factory = AdapterFactoryRecorder(remoteAppId: "cursor-agent", adapter: adapter)
        let controller = RemoteAppController(
            defaults: defaults,
            executableExists: { candidate in cursorAgentCandidates.contains(candidate) },
            adapterFactory: { definition, window in
                factory.makeAdapter(definition: definition, window: window)
            }
        )
        let snapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            snapshots.append(snapshot)
        }

        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "cursor-agent",
            action: .start
        ))

        try await waitUntil {
            adapter.startCalls() == 1
        }
        XCTAssertTrue(factory.remoteAppIds().contains("cursor-agent"))
        XCTAssertTrue(snapshots.contains { snapshot in
            snapshot.agentId == "cursor-agent" &&
            snapshot.status == .working &&
            snapshot.statusDetail == "Starting" &&
            snapshot.recentMessages.contains { $0.text.contains("Starting Cursor Agent on this Mac") }
        })
        XCTAssertEqual(controller.remoteAppsSnapshot().first { $0.remoteAppId == "cursor-agent" }?.enabled, true)
    }

    func testCodexCliStartActionCreatesAndStartsAdapter() async throws {
        let defaults = isolatedDefaults()
        defaults.set([], forKey: "remoteApps.enabled.v1")
        defaults.set(true, forKey: "remoteApps.terminalDefaultEnabled.v1")
        let codexCandidates = Set(CodexAdapter.executableCandidates())
        let adapter = StubAgentAdapter(
            agentID: "codex-cli",
            kind: .codexCli,
            label: "Codex CLI"
        )
        let factory = AdapterFactoryRecorder(remoteAppId: "codex-cli", adapter: adapter)
        let controller = RemoteAppController(
            defaults: defaults,
            executableExists: { candidate in codexCandidates.contains(candidate) },
            adapterFactory: { definition, window in
                factory.makeAdapter(definition: definition, window: window)
            }
        )
        let snapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            snapshots.append(snapshot)
        }

        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "codex-cli",
            action: .start
        ))

        try await waitUntil {
            adapter.startCalls() == 1
        }
        XCTAssertTrue(factory.remoteAppIds().contains("codex-cli"))
        XCTAssertTrue(snapshots.contains { snapshot in
            snapshot.agentId == "codex-cli" &&
            snapshot.status == .working &&
            snapshot.statusDetail == "Starting" &&
            snapshot.recentMessages.contains { $0.text.contains("Starting Codex CLI on this Mac") }
        })
        XCTAssertEqual(controller.remoteAppsSnapshot().first { $0.remoteAppId == "codex-cli" }?.enabled, true)
    }

    func testOpenCodeStartActionCreatesAndStartsAdapter() async throws {
        let defaults = isolatedDefaults()
        defaults.set([], forKey: "remoteApps.enabled.v1")
        defaults.set(true, forKey: "remoteApps.terminalDefaultEnabled.v1")
        let openCodeCandidates = Set(OpenCodeAdapter.executableCandidates())
        let adapter = StubAgentAdapter(
            agentID: "opencode",
            kind: .openCode,
            label: "OpenCode"
        )
        let factory = AdapterFactoryRecorder(remoteAppId: "opencode", adapter: adapter)
        let controller = RemoteAppController(
            defaults: defaults,
            executableExists: { candidate in openCodeCandidates.contains(candidate) },
            adapterFactory: { definition, window in
                factory.makeAdapter(definition: definition, window: window)
            }
        )
        let snapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            snapshots.append(snapshot)
        }

        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "opencode",
            action: .start
        ))

        try await waitUntil {
            adapter.startCalls() == 1
        }
        XCTAssertTrue(factory.remoteAppIds().contains("opencode"))
        XCTAssertTrue(snapshots.contains { snapshot in
            snapshot.agentId == "opencode" &&
            snapshot.status == .working &&
            snapshot.statusDetail == "Starting" &&
            snapshot.recentMessages.contains { $0.text.contains("Starting OpenCode on this Mac") }
        })
        XCTAssertEqual(controller.remoteAppsSnapshot().first { $0.remoteAppId == "opencode" }?.enabled, true)
    }

    func testRemoteAppPublicationPreservesExistingRedactionMetadata() async throws {
        let defaults = isolatedDefaults()
        defaults.set([], forKey: "remoteApps.enabled.v1")
        defaults.set(true, forKey: "remoteApps.terminalDefaultEnabled.v1")
        let codexCandidates = Set(CodexAdapter.executableCandidates())
        let message = AgentChatMessage(
            messageId: "codex-cli-redacted",
            role: .assistant,
            text: "Provider auth failed with <redacted:test_secret>.",
            redacted: true,
            redactionReasons: ["test_secret"]
        )
        let adapter = StubAgentAdapter(
            agentID: "codex-cli",
            kind: .codexCli,
            label: "Codex CLI",
            emittedMessage: message
        )
        let factory = AdapterFactoryRecorder(remoteAppId: "codex-cli", adapter: adapter)
        let controller = RemoteAppController(
            defaults: defaults,
            redactor: SecretRedactor(patterns: [
                SecretRedactor.Pattern(name: "test_secret", regex: #"GTSECRET_[0-9]+"#),
            ]),
            executableExists: { candidate in codexCandidates.contains(candidate) },
            adapterFactory: { definition, window in
                factory.makeAdapter(definition: definition, window: window)
            }
        )
        let snapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            snapshots.append(snapshot)
        }

        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "codex-cli",
            action: .start
        ))

        let snapshot = try await waitForSnapshot(from: snapshots) { snapshot in
            snapshot.agentId == "codex-cli" &&
                snapshot.recentMessages.contains { $0.messageId == "codex-cli-redacted" }
        }
        let published = try XCTUnwrap(snapshot.recentMessages.first { $0.messageId == "codex-cli-redacted" })
        XCTAssertTrue(published.redacted)
        XCTAssertEqual(published.redactionReasons, ["test_secret"])
    }

    func testCodexCliStartFailurePublishesVisibleErrorSnapshot() async throws {
        let defaults = isolatedDefaults()
        defaults.set([], forKey: "remoteApps.enabled.v1")
        defaults.set(true, forKey: "remoteApps.terminalDefaultEnabled.v1")
        let codexCandidates = Set(CodexAdapter.executableCandidates())
        let adapter = StubAgentAdapter(
            agentID: "codex-cli",
            kind: .codexCli,
            label: "Codex CLI",
            startHandler: {
                throw NSError(
                    domain: "RemoteAppControllerTests",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "spawn failed for codex"]
                )
            }
        )
        let factory = AdapterFactoryRecorder(remoteAppId: "codex-cli", adapter: adapter)
        let controller = RemoteAppController(
            defaults: defaults,
            executableExists: { candidate in codexCandidates.contains(candidate) },
            adapterFactory: { definition, window in
                factory.makeAdapter(definition: definition, window: window)
            }
        )
        let snapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            snapshots.append(snapshot)
        }

        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "codex-cli",
            action: .start
        ))

        _ = try await waitForSnapshot(from: snapshots) { snapshot in
            snapshot.agentId == "codex-cli" &&
            snapshot.status == .error &&
            snapshot.statusDetail == "Start failed" &&
            snapshot.recentMessages.contains {
                $0.text.contains("Could not start Codex CLI") &&
                    $0.text.contains("spawn failed for codex")
            }
        }
        XCTAssertTrue(factory.remoteAppIds().contains("codex-cli"))
        XCTAssertEqual(controller.remoteAppsSnapshot().first { $0.remoteAppId == "codex-cli" }?.status, .error)
        XCTAssertEqual(controller.remoteAppsSnapshot().first { $0.remoteAppId == "codex-cli" }?.statusDetail, "Start failed")
    }

    func testOpenCodeStartFailurePublishesVisibleErrorSnapshot() async throws {
        let defaults = isolatedDefaults()
        defaults.set([], forKey: "remoteApps.enabled.v1")
        defaults.set(true, forKey: "remoteApps.terminalDefaultEnabled.v1")
        let openCodeCandidates = Set(OpenCodeAdapter.executableCandidates())
        let adapter = StubAgentAdapter(
            agentID: "opencode",
            kind: .openCode,
            label: "OpenCode",
            startHandler: {
                throw NSError(
                    domain: "RemoteAppControllerTests",
                    code: 11,
                    userInfo: [NSLocalizedDescriptionKey: "spawn failed for opencode"]
                )
            }
        )
        let factory = AdapterFactoryRecorder(remoteAppId: "opencode", adapter: adapter)
        let controller = RemoteAppController(
            defaults: defaults,
            executableExists: { candidate in openCodeCandidates.contains(candidate) },
            adapterFactory: { definition, window in
                factory.makeAdapter(definition: definition, window: window)
            }
        )
        let snapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            snapshots.append(snapshot)
        }

        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "opencode",
            action: .start
        ))

        _ = try await waitForSnapshot(from: snapshots) { snapshot in
            snapshot.agentId == "opencode" &&
            snapshot.status == .error &&
            snapshot.statusDetail == "Start failed" &&
            snapshot.recentMessages.contains {
                $0.text.contains("Could not start OpenCode") &&
                    $0.text.contains("spawn failed for opencode")
            }
        }
        XCTAssertTrue(factory.remoteAppIds().contains("opencode"))
        XCTAssertEqual(controller.remoteAppsSnapshot().first { $0.remoteAppId == "opencode" }?.status, .error)
        XCTAssertEqual(controller.remoteAppsSnapshot().first { $0.remoteAppId == "opencode" }?.statusDetail, "Start failed")
    }

    func testOpenCodeBundledCLIIsRecognized() {
        let defaults = isolatedDefaults()
        let controller = RemoteAppController(defaults: defaults, executableExists: { candidate in
            candidate == "/Applications/OpenCode.app/Contents/MacOS/opencode-cli"
        })

        let openCode = controller.remoteAppsSnapshot().first { $0.remoteAppId == "opencode" }

        XCTAssertEqual(openCode?.available, true)
        XCTAssertEqual(openCode?.applicationBundleId, "ai.opencode.app")
    }

    func testOpenCodeDesktopAppExecutableDoesNotCountAsCLI() {
        let defaults = isolatedDefaults()
        let controller = RemoteAppController(
            defaults: defaults,
            executableExists: { candidate in
                candidate == "/Applications/OpenCode.app/Contents/MacOS/OpenCode"
            },
            appExists: { bundleID in
                bundleID == "ai.opencode.desktop"
            }
        )

        let openCode = controller.remoteAppsSnapshot().first { $0.remoteAppId == "opencode" }

        XCTAssertEqual(openCode?.available, false)
        XCTAssertEqual(openCode?.statusDetail, "Install OpenCode CLI on this Mac")
        XCTAssertEqual(openCode?.applicationBundleId, "ai.opencode.desktop")
    }

    func testOpenCodePublishesDetectedDesktopBundleIdentity() {
        let defaults = isolatedDefaults()
        let controller = RemoteAppController(
            defaults: defaults,
            executableExists: { candidate in
                candidate == "opencode"
            },
            appExists: { bundleID in
                bundleID == "ai.opencode.desktop"
            }
        )

        let openCode = controller.remoteAppsSnapshot().first { $0.remoteAppId == "opencode" }

        XCTAssertEqual(openCode?.available, true)
        XCTAssertEqual(openCode?.applicationBundleId, "ai.opencode.desktop")
    }

    func testInstalledOpenCodeDesktopWithoutCLIShowsCliHint() {
        let defaults = isolatedDefaults()
        let controller = RemoteAppController(
            defaults: defaults,
            executableExists: { _ in false },
            appExists: { bundleID in
                bundleID == "ai.opencode.desktop"
            }
        )

        let openCode = controller.remoteAppsSnapshot().first { $0.remoteAppId == "opencode" }

        XCTAssertEqual(openCode?.available, false)
        XCTAssertEqual(openCode?.statusDetail, "Install OpenCode CLI on this Mac")
        XCTAssertEqual(openCode?.applicationBundleId, "ai.opencode.desktop")
    }

    func testInstalledOpenCodeDesktopWithoutCliLaunchRequiresCli() async throws {
        let defaults = isolatedDefaults()
        defaults.set([], forKey: "remoteApps.enabled.v1")
        var launchedBundleIDs: [String] = []
        let controller = RemoteAppController(
            defaults: defaults,
            executableExists: { _ in false },
            appExists: { bundleID in
                bundleID == "ai.opencode.desktop"
            },
            appLauncher: { bundleID in
                launchedBundleIDs.append(bundleID)
                return bundleID == "ai.opencode.desktop"
            }
        )
        let snapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            snapshots.append(snapshot)
        }

        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "opencode",
            action: .launch
        ))

        XCTAssertEqual(launchedBundleIDs, [])
        XCTAssertTrue(snapshots.contains { snapshot in
            snapshot.agentId == "opencode" &&
            snapshot.status == .error &&
            snapshot.statusDetail == "Not available" &&
            snapshot.recentMessages.contains {
                $0.text.contains("OpenCode is not available on this Mac") &&
                    $0.text.contains("Install OpenCode CLI on this Mac")
            }
        })

        let openCode = controller.remoteAppsSnapshot().first { $0.remoteAppId == "opencode" }
        XCTAssertEqual(openCode?.enabled, false)
        XCTAssertEqual(openCode?.available, false)
        XCTAssertEqual(openCode?.status, .error)
        XCTAssertEqual(openCode?.statusDetail, "Not available")
    }

    func testTerminalRemoteAppIsAvailableWithoutWindow() {
        let defaults = isolatedDefaults()
        let controller = RemoteAppController(defaults: defaults, executableExists: { candidate in
            candidate == "/bin/zsh"
        })

        let terminal = controller.remoteAppsSnapshot().first { $0.remoteAppId == "terminal" }

        XCTAssertEqual(terminal?.available, true)
        XCTAssertEqual(terminal?.hasVideo, false)
        XCTAssertEqual(terminal?.adapterKind, .terminal)
    }

    func testTerminalRemoteAppIsEnabledByDefault() {
        let defaults = isolatedDefaults()
        let controller = RemoteAppController(defaults: defaults, executableExists: { candidate in
            candidate == "/bin/zsh"
        })

        let terminal = controller.remoteAppsSnapshot().first { $0.remoteAppId == "terminal" }

        XCTAssertEqual(terminal?.enabled, true)
        XCTAssertEqual(terminal?.available, true)
        XCTAssertEqual(terminal?.statusDetail, "Ready from web")
    }

    func testLegacyEnabledPreferencesMigrateTerminalOnOnce() {
        let defaults = isolatedDefaults()
        defaults.set(["codex"], forKey: "remoteApps.enabled.v1")

        let controller = RemoteAppController(defaults: defaults, executableExists: { candidate in
            candidate == "/bin/zsh"
        })

        let terminal = controller.remoteAppsSnapshot().first { $0.remoteAppId == "terminal" }
        let storedEnabled = defaults.stringArray(forKey: "remoteApps.enabled.v1") ?? []

        XCTAssertEqual(terminal?.enabled, true)
        XCTAssertTrue(storedEnabled.contains("terminal"))
        XCTAssertTrue(defaults.bool(forKey: "remoteApps.terminalDefaultEnabled.v1"))
    }

    func testTerminalStaysDisabledAfterDefaultMigrationHasRun() {
        let defaults = isolatedDefaults()
        defaults.set(["codex"], forKey: "remoteApps.enabled.v1")
        defaults.set(true, forKey: "remoteApps.terminalDefaultEnabled.v1")

        let controller = RemoteAppController(defaults: defaults, executableExists: { candidate in
            candidate == "/bin/zsh"
        })

        let terminal = controller.remoteAppsSnapshot().first { $0.remoteAppId == "terminal" }

        XCTAssertEqual(terminal?.enabled, false)
        XCTAssertEqual(terminal?.available, true)
    }

    func testRemoteAppStartActionPublishesStartingSnapshot() async throws {
        let defaults = isolatedDefaults()
        let controller = RemoteAppController(defaults: defaults, executableExists: { candidate in
            candidate == "/bin/zsh"
        })
        let snapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            snapshots.append(snapshot)
        }

        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "terminal",
            action: .start
        ))

        XCTAssertTrue(snapshots.contains { snapshot in
            snapshot.agentId == "terminal" &&
            snapshot.status == .working &&
            snapshot.statusDetail == "Starting" &&
            snapshot.recentMessages.contains { $0.text.contains("Starting Terminal") }
        })
    }

    func testRemoteAppStartActionOpensVisibleSharedTerminalSession() async throws {
        let defaults = isolatedDefaults()
        var launchedCommands: [String] = []
        let controller = RemoteAppController(
            defaults: defaults,
            executableExists: { candidate in
                candidate == "/usr/bin/screen" || candidate == "/bin/zsh"
            },
            terminalCommandLauncher: { command in
                launchedCommands.append(command)
                return true
            }
        )
        let snapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            snapshots.append(snapshot)
        }

        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "terminal",
            action: .start
        ))

        XCTAssertEqual(launchedCommands, [TerminalSessionConfiguration.visibleTerminalCommand()])
        XCTAssertTrue(snapshots.contains { snapshot in
            snapshot.agentId == "terminal" &&
            snapshot.status == .working &&
            snapshot.statusDetail == "Opening on Mac" &&
            snapshot.recentMessages.contains { $0.text.contains("Opening Terminal on this Mac") }
        })
    }

    func testRemoteAppStartActionRestartsExitedPtyAdapter() async throws {
        let defaults = isolatedDefaults()
        let controller = RemoteAppController(
            defaults: defaults,
            executableExists: { candidate in
                candidate == "/bin/zsh"
            },
            terminalCommandLauncher: { _ in false }
        )
        let initialSnapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            initialSnapshots.append(snapshot)
        }

        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "terminal",
            action: .start
        ))
        _ = try await waitForSnapshot(from: initialSnapshots) { snapshot in
            snapshot.agentId == "terminal" &&
            snapshot.status == .idle &&
            snapshot.statusDetail == "started"
        }

        controller.publishRemoteAppStatus(
            remoteAppId: "terminal",
            status: .done,
            detail: "process exited (0)",
            text: "Terminal process exited."
        )

        let restartSnapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            restartSnapshots.append(snapshot)
        }
        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "terminal",
            action: .start
        ))

        XCTAssertTrue(restartSnapshots.contains { snapshot in
            snapshot.agentId == "terminal" &&
            snapshot.status == .working &&
            snapshot.statusDetail == "Starting"
        })
        _ = try await waitForSnapshot(from: restartSnapshots) { snapshot in
            snapshot.agentId == "terminal" &&
            snapshot.status == .idle &&
            snapshot.statusDetail == "started"
        }
    }

    func testTerminalNewSessionCreatesRememberedSessionAndOpensVisibleTerminal() async throws {
        let defaults = isolatedDefaults()
        var resetSessions: [String] = []
        var launchedCommands: [String] = []
        let controller = RemoteAppController(
            defaults: defaults,
            executableExists: { candidate in
                candidate == "/usr/bin/screen" || candidate == "/bin/zsh"
            },
            terminalCommandLauncher: { command in
                launchedCommands.append(command)
                return true
            },
            terminalSessionResetter: { sessionName in
                resetSessions.append(sessionName)
                return true
            },
            terminalSessionNameGenerator: { "glasstunnel-terminal-two" }
        )
        let snapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            snapshots.append(snapshot)
        }

        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "terminal",
            action: .newSession
        ))

        XCTAssertEqual(resetSessions, [])
        XCTAssertEqual(launchedCommands, [TerminalSessionConfiguration.visibleTerminalCommand(sessionName: "glasstunnel-terminal-two")])
        XCTAssertEqual(controller.remoteAppsSnapshot().first { $0.remoteAppId == "terminal" }?.enabled, true)
        XCTAssertTrue(snapshots.contains { snapshot in
            snapshot.agentId == "terminal" &&
            snapshot.status == .working &&
            snapshot.statusDetail == "New session" &&
            snapshot.recentMessages.contains { $0.text.contains("Starting a new Terminal session") }
        })
        let targetSnapshot = try await waitForSnapshot(from: snapshots) { snapshot in
            snapshot.agentId == "terminal" &&
            snapshot.availableTargets?.contains(where: {
                $0.targetId == "terminal-session:glasstunnel-terminal-two" &&
                $0.selected == true &&
                $0.label == "Terminal 2"
            }) == true &&
            snapshot.availableTargets?.contains(where: {
                $0.targetId == TerminalAdapter.sessionTargetId(sessionName: TerminalSessionConfiguration.sharedSessionName) &&
                $0.selected == false
            }) == true
        }
        XCTAssertEqual(targetSnapshot.availableTargets?.count, 2)
    }

    func testTerminalNewSessionAvoidsDuplicateSessionNamesWhenGeneratorCollides() async throws {
        let defaults = isolatedDefaults()
        var launchedCommands: [String] = []
        let controller = RemoteAppController(
            defaults: defaults,
            executableExists: { candidate in
                candidate == "/usr/bin/screen" || candidate == "/bin/zsh"
            },
            terminalCommandLauncher: { command in
                launchedCommands.append(command)
                return true
            },
            terminalSessionNameGenerator: { "glasstunnel-terminal-same" }
        )
        let snapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            snapshots.append(snapshot)
        }

        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "terminal",
            action: .newSession
        ))
        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "terminal",
            action: .newSession
        ))

        XCTAssertEqual(launchedCommands, [
            TerminalSessionConfiguration.visibleTerminalCommand(sessionName: "glasstunnel-terminal-same"),
            TerminalSessionConfiguration.visibleTerminalCommand(sessionName: "glasstunnel-terminal-same-2"),
        ])
        let targetSnapshot = try await waitForSnapshot(from: snapshots) { snapshot in
            snapshot.agentId == "terminal" &&
            snapshot.availableTargets?.contains(where: {
                $0.targetId == "terminal-session:glasstunnel-terminal-same" &&
                $0.selected == false &&
                $0.label == "Terminal 2"
            }) == true &&
            snapshot.availableTargets?.contains(where: {
                $0.targetId == "terminal-session:glasstunnel-terminal-same-2" &&
                $0.selected == true &&
                $0.label == "Terminal 3"
            }) == true
        }
        XCTAssertEqual(targetSnapshot.availableTargets?.map(\.targetId), [
            "terminal-session:glasstunnel-terminal-same-2",
            TerminalAdapter.sessionTargetId(sessionName: TerminalSessionConfiguration.sharedSessionName),
            "terminal-session:glasstunnel-terminal-same",
        ])
    }

    func testTerminalCloseSessionResetsSharedSessionAndDisablesTerminal() async throws {
        let defaults = isolatedDefaults()
        var resetSessions: [String] = []
        let controller = RemoteAppController(
            defaults: defaults,
            executableExists: { candidate in
                candidate == "/usr/bin/screen" || candidate == "/bin/zsh"
            },
            terminalSessionResetter: { sessionName in
                resetSessions.append(sessionName)
                return true
            }
        )
        let snapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            snapshots.append(snapshot)
        }

        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "terminal",
            action: .closeSession
        ))

        XCTAssertEqual(resetSessions, [TerminalSessionConfiguration.sharedSessionName])
        XCTAssertEqual(controller.remoteAppsSnapshot().first { $0.remoteAppId == "terminal" }?.enabled, false)
        XCTAssertTrue(snapshots.contains { snapshot in
            snapshot.agentId == "terminal" &&
            snapshot.status == .idle &&
            snapshot.statusDetail == "Closed" &&
            snapshot.recentMessages.contains { $0.text.contains("Terminal session was closed") }
        })
    }

    func testTerminalCloseNonDefaultSessionOpensNextRememberedSession() async throws {
        let defaults = isolatedDefaults()
        defaults.set([
            TerminalSessionConfiguration.sharedSessionName,
            "glasstunnel-terminal-two",
        ], forKey: "remoteApps.terminalSessionNames.v1")
        defaults.set("glasstunnel-terminal-two", forKey: "remoteApps.terminalActiveSessionName.v1")
        let labels = ["glasstunnel-terminal-two": "Terminal 2"]
        let labelsData = try JSONEncoder().encode(labels)
        defaults.set(labelsData, forKey: "remoteApps.terminalSessionLabels.v1")

        var resetSessions: [String] = []
        var launchedCommands: [String] = []
        let adapter = StubAgentAdapter(
            agentID: "terminal",
            kind: .terminal,
            label: "Terminal"
        )
        let factory = AdapterFactoryRecorder(remoteAppId: "terminal", adapter: adapter)
        let controller = RemoteAppController(
            defaults: defaults,
            executableExists: { candidate in
                candidate == "/usr/bin/screen" || candidate == "/bin/zsh"
            },
            terminalCommandLauncher: { command in
                launchedCommands.append(command)
                return true
            },
            terminalSessionResetter: { sessionName in
                resetSessions.append(sessionName)
                return true
            },
            adapterFactory: { @Sendable definition, window in
                factory.makeAdapter(definition: definition, window: window)
            }
        )
        let snapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            snapshots.append(snapshot)
        }

        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "terminal",
            action: .closeSession
        ))

        XCTAssertEqual(resetSessions, ["glasstunnel-terminal-two"])
        XCTAssertEqual(launchedCommands, [TerminalSessionConfiguration.visibleTerminalCommand()])
        XCTAssertEqual(defaults.string(forKey: "remoteApps.terminalActiveSessionName.v1"), TerminalSessionConfiguration.sharedSessionName)
        XCTAssertEqual(defaults.stringArray(forKey: "remoteApps.terminalSessionNames.v1"), [TerminalSessionConfiguration.sharedSessionName])
        XCTAssertEqual(controller.remoteAppsSnapshot().first { $0.remoteAppId == "terminal" }?.enabled, true)
        XCTAssertTrue(snapshots.contains { snapshot in
            snapshot.agentId == "terminal" &&
            snapshot.status == .working &&
            snapshot.statusDetail == "Opening session" &&
            snapshot.recentMessages.contains { $0.text.contains("Closed Terminal 2 and opening Default Terminal") }
        })
        try await waitUntil {
            adapter.startCalls() == 1
        }
        XCTAssertEqual(factory.remoteAppIds(), ["terminal"])
    }

    func testTerminalRenamePersistsAndPublishesSessionLabel() async throws {
        let defaults = isolatedDefaults()
        let controller = RemoteAppController(
            defaults: defaults,
            executableExists: { candidate in
                candidate == "/bin/zsh"
            },
            terminalCommandLauncher: { _ in false }
        )
        let renamed = expectation(description: "Terminal publishes renamed session")
        renamed.assertForOverFulfill = false
        let targetId = TerminalAdapter.sessionTargetId(sessionName: TerminalSessionConfiguration.sharedSessionName)
        controller.onAgentState = { snapshot in
            if snapshot.agentId == "terminal",
               snapshot.availableTargets?.contains(where: {
                   $0.targetId == targetId &&
                   $0.label == "Release console" &&
                   $0.threadLabel == "Release console"
               }) == true {
                renamed.fulfill()
            }
        }

        try await controller.renameTarget(TargetRenameRequest(
            agentId: "terminal",
            targetId: targetId,
            label: "  Release console  "
        ))
        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "terminal",
            action: .start
        ))

        await fulfillment(of: [renamed], timeout: 4)
    }

    func testTerminalSelectSessionPersistsActiveSessionWithoutOpeningAnotherWindow() async throws {
        let defaults = isolatedDefaults()
        defaults.set([
            TerminalSessionConfiguration.sharedSessionName,
            "glasstunnel-terminal-two",
        ], forKey: "remoteApps.terminalSessionNames.v1")
        var launchedCommands: [String] = []
        let controller = RemoteAppController(
            defaults: defaults,
            executableExists: { candidate in
                candidate == "/usr/bin/screen" || candidate == "/bin/zsh"
            },
            terminalCommandLauncher: { command in
                launchedCommands.append(command)
                return true
            }
        )
        let snapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            snapshots.append(snapshot)
        }

        try await controller.selectTarget(
            agentId: "terminal",
            targetId: TerminalAdapter.sessionTargetId(sessionName: "glasstunnel-terminal-two")
        )

        XCTAssertEqual(launchedCommands, [])
        XCTAssertEqual(controller.remoteAppsSnapshot().first { $0.remoteAppId == "terminal" }?.enabled, true)
        let targetSnapshot = try await waitForSnapshot(from: snapshots) { snapshot in
            snapshot.agentId == "terminal" &&
            snapshot.availableTargets?.contains(where: {
                $0.targetId == "terminal-session:glasstunnel-terminal-two" &&
                $0.selected == true
            }) == true &&
            snapshot.availableTargets?.contains(where: {
                $0.targetId == TerminalAdapter.sessionTargetId(sessionName: TerminalSessionConfiguration.sharedSessionName) &&
                $0.selected == false
            }) == true
        }
        XCTAssertEqual(targetSnapshot.status, .idle)
    }

    func testTerminalSelectCurrentSessionIsNoOp() async throws {
        let defaults = isolatedDefaults()
        defaults.set([
            TerminalSessionConfiguration.sharedSessionName,
            "glasstunnel-terminal-two",
        ], forKey: "remoteApps.terminalSessionNames.v1")
        defaults.set("glasstunnel-terminal-two", forKey: "remoteApps.terminalActiveSessionName.v1")
        var launchedCommands: [String] = []
        let controller = RemoteAppController(
            defaults: defaults,
            executableExists: { candidate in
                candidate == "/usr/bin/screen" || candidate == "/bin/zsh"
            },
            terminalCommandLauncher: { command in
                launchedCommands.append(command)
                return true
            }
        )
        let snapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            snapshots.append(snapshot)
        }

        try await controller.selectTarget(
            agentId: "terminal",
            targetId: TerminalAdapter.sessionTargetId(sessionName: "glasstunnel-terminal-two")
        )

        XCTAssertEqual(launchedCommands, [])
        XCTAssertNil(snapshots.first { _ in true })
        XCTAssertEqual(defaults.string(forKey: "remoteApps.terminalActiveSessionName.v1"), "glasstunnel-terminal-two")
    }

    func testEnablingTerminalUsesStartPathAndOpensVisibleSharedSession() {
        let defaults = isolatedDefaults()
        defaults.set([], forKey: "remoteApps.enabled.v1")
        defaults.set(true, forKey: "remoteApps.terminalDefaultEnabled.v1")
        var launchedCommands: [String] = []
        let controller = RemoteAppController(
            defaults: defaults,
            executableExists: { candidate in
                candidate == "/usr/bin/screen" || candidate == "/bin/zsh"
            },
            terminalCommandLauncher: { command in
                launchedCommands.append(command)
                return true
            }
        )
        let snapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            snapshots.append(snapshot)
        }

        controller.setEnabled(remoteAppId: "terminal", enabled: true)

        XCTAssertEqual(launchedCommands, [TerminalSessionConfiguration.visibleTerminalCommand()])
        XCTAssertEqual(controller.remoteAppsSnapshot().first { $0.remoteAppId == "terminal" }?.enabled, true)
        XCTAssertTrue(snapshots.contains { snapshot in
            snapshot.agentId == "terminal" &&
            snapshot.status == .working &&
            snapshot.statusDetail == "Opening on Mac"
        })
    }

    func testRemoteAppLaunchFallsBackToHeadlessSessionWhenNativeAppMissing() async throws {
        let defaults = isolatedDefaults()
        let controller = RemoteAppController(
            defaults: defaults,
            executableExists: { candidate in
                candidate == "/bin/zsh"
            },
            appLauncher: { _ in false }
        )
        let snapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            snapshots.append(snapshot)
        }

        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "terminal",
            action: .launch
        ))

        XCTAssertTrue(snapshots.contains { snapshot in
            snapshot.agentId == "terminal" &&
            snapshot.status == .working &&
            snapshot.statusDetail == "Starting on Mac" &&
            snapshot.recentMessages.contains { $0.text.contains("Starting Terminal on this Mac") }
        })
    }

    func testInstalledGuiLaunchFailurePublishesVisibleError() async throws {
        let defaults = isolatedDefaults()
        let controller = RemoteAppController(
            defaults: defaults,
            executableExists: { _ in false },
            appExists: { bundleID in
                bundleID == "com.todesktop.230313mzl4w4u92"
            },
            appLauncher: { _ in false }
        )
        let snapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            snapshots.append(snapshot)
        }

        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "cursor",
            action: .launch
        ))

        XCTAssertTrue(snapshots.contains { snapshot in
            snapshot.agentId == "cursor" &&
            snapshot.status == .error &&
            snapshot.statusDetail == "Open failed" &&
            snapshot.recentMessages.contains { $0.text.contains("Could not open Cursor on this Mac") }
        })

        let cursor = controller.remoteAppsSnapshot().first { $0.remoteAppId == "cursor" }
        XCTAssertEqual(cursor?.enabled, false)
        XCTAssertEqual(cursor?.available, false)
        XCTAssertEqual(cursor?.status, .error)
        XCTAssertEqual(cursor?.statusDetail, "Open failed")
    }

    func testScreenRemoteAppStartPublishesStartingSnapshot() async throws {
        let defaults = isolatedDefaults()
        let controller = RemoteAppController(defaults: defaults, executableExists: { _ in false })
        let snapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            snapshots.append(snapshot)
        }

        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "screen",
            action: .start
        ))

        XCTAssertTrue(snapshots.contains { snapshot in
            snapshot.agentId == "screen" &&
            snapshot.status == .working &&
            snapshot.recentMessages.contains { $0.text.contains("Starting Mac Screen") }
        })
    }

    func testScreenRemoteAppCanBeTurnedOffAndBackOnWithoutStaleStopState() async throws {
        let defaults = isolatedDefaults()
        let controller = RemoteAppController(defaults: defaults, executableExists: { _ in false })
        let snapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            snapshots.append(snapshot)
        }

        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "screen",
            action: .stop
        ))

        var screen = controller.remoteAppsSnapshot().first { $0.remoteAppId == "screen" }
        XCTAssertEqual(screen?.enabled, false)
        XCTAssertEqual(screen?.statusDetail, "Screen sharing off")
        XCTAssertTrue(snapshots.contains { snapshot in
            snapshot.agentId == "screen" &&
            snapshot.status == .idle &&
            snapshot.statusDetail == "Screen sharing off"
        })

        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "screen",
            action: .start
        ))

        screen = controller.remoteAppsSnapshot().first { $0.remoteAppId == "screen" }
        XCTAssertEqual(screen?.enabled, true)
        XCTAssertEqual(screen?.available, true)
        XCTAssertNotEqual(screen?.statusDetail, "Stopping stream")
        XCTAssertNotEqual(screen?.statusDetail, "Screen sharing off")
        XCTAssertTrue(["Starting", "Screen ready"].contains(screen?.statusDetail ?? ""))
        XCTAssertTrue(snapshots.contains { snapshot in
            snapshot.agentId == "screen" &&
            snapshot.status == .working &&
            snapshot.statusDetail == "Starting" &&
            snapshot.recentMessages.contains { $0.text.contains("Starting Mac Screen") }
        })
    }

    func testStaleScreenStoppingSnapshotDoesNotLeaveWorkspaceSyncing() {
        let defaults = isolatedDefaults()
        let controller = RemoteAppController(defaults: defaults, executableExists: { _ in false })

        controller.publishRemoteAppStatus(
            remoteAppId: "screen",
            status: .working,
            detail: "Stopping stream",
            text: "Stopping Mac Screen stream."
        )

        let screen = controller.remoteAppsSnapshot().first { $0.remoteAppId == "screen" }
        XCTAssertEqual(screen?.enabled, true)
        XCTAssertEqual(screen?.status, .idle)
        XCTAssertEqual(screen?.statusDetail, "Screen ready")
    }

    func testUnavailableRemoteAppActionPublishesErrorSnapshot() async throws {
        let defaults = isolatedDefaults()
        let controller = RemoteAppController(defaults: defaults, executableExists: { _ in false })
        let snapshots = SnapshotRecorder()
        controller.onAgentState = { snapshot in
            snapshots.append(snapshot)
        }

        try await controller.performRemoteAppAction(RemoteAppActionRequest(
            remoteAppId: "claude-code",
            action: .launch
        ))

        XCTAssertTrue(snapshots.contains { snapshot in
            snapshot.agentId == "claude-code" &&
            snapshot.status == .error &&
            snapshot.statusDetail == "Not available" &&
            snapshot.recentMessages.contains { $0.text.contains("Claude Code is not available") }
        })
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "RemoteAppControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private final class SnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [AgentStateSnapshot] = []

    func append(_ snapshot: AgentStateSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        snapshots.append(snapshot)
    }

    func contains(where predicate: (AgentStateSnapshot) -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.contains(where: predicate)
    }

    func first(where predicate: (AgentStateSnapshot) -> Bool) -> AgentStateSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.first(where: predicate)
    }
}

private final class AdapterFactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let remoteAppId: String
    private let adapter: any AgentAdapter
    private var ids: [String] = []

    init(remoteAppId: String, adapter: any AgentAdapter) {
        self.remoteAppId = remoteAppId
        self.adapter = adapter
    }

    func makeAdapter(definition: RemoteAppDefinition, window: CapturableWindow?) -> (any AgentAdapter)? {
        _ = window
        guard definition.remoteAppId == remoteAppId else { return nil }
        lock.lock()
        ids.append(definition.remoteAppId)
        lock.unlock()
        return adapter
    }

    func remoteAppIds() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }
}

private final class StubAgentAdapter: AgentAdapter, @unchecked Sendable {
    let agentID: AgentID
    let kind: AdapterKind
    let label: String

    private let lock = NSLock()
    private let startHandler: @Sendable () async throws -> Void
    private let emittedMessage: AgentChatMessage?
    private var startCount = 0
    private var continuation: AsyncStream<AgentStateSnapshot>.Continuation?
    private var pendingSnapshots: [AgentStateSnapshot] = []

    init(
        agentID: AgentID,
        kind: AdapterKind,
        label: String,
        emittedMessage: AgentChatMessage? = nil,
        startHandler: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.agentID = agentID
        self.kind = kind
        self.label = label
        self.emittedMessage = emittedMessage
        self.startHandler = startHandler
    }

    func observeState() -> AsyncStream<AgentStateSnapshot> {
        AsyncStream { continuation in
            lock.lock()
            self.continuation = continuation
            let pendingSnapshots = self.pendingSnapshots
            self.pendingSnapshots.removeAll()
            lock.unlock()
            for snapshot in pendingSnapshots {
                continuation.yield(snapshot)
            }
        }
    }

    func sendInput(_ text: String, submit: Bool) async throws {
        _ = text
        _ = submit
    }

    func interrupt() async throws {}

    func start() async throws {
        incrementStartCount()
        try await startHandler()
        if let emittedMessage {
            emit(status: .idle, detail: "started", message: emittedMessage)
        } else {
            emit(
                status: .idle,
                detail: "started",
                text: "\(label) started."
            )
        }
    }

    func stop() async {}

    func startCalls() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return startCount
    }

    private func emit(status: AgentStatus, detail: String, text: String) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        emit(
            status: status,
            detail: detail,
            message: AgentChatMessage(
                messageId: "\(agentID)-stub-\(now)",
                role: .system,
                text: text,
                atUnixMs: now
            )
        )
    }

    private func emit(status: AgentStatus, detail: String, message: AgentChatMessage) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let snapshot = AgentStateSnapshot(
            agentId: agentID,
            agentLabel: label,
            adapterKind: kind,
            status: status,
            statusDetail: detail,
            recentMessages: [message],
            lastActivityUnixMs: now
        )
        lock.lock()
        let continuation = continuation
        if continuation == nil {
            pendingSnapshots.append(snapshot)
        }
        lock.unlock()
        continuation?.yield(snapshot)
    }

    private func incrementStartCount() {
        lock.lock()
        startCount += 1
        lock.unlock()
    }
}

private func waitForSnapshot(
    from recorder: SnapshotRecorder,
    timeoutSeconds: Double = 4,
    where predicate: (AgentStateSnapshot) -> Bool
) async throws -> AgentStateSnapshot {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if let snapshot = recorder.first(where: predicate) {
            return snapshot
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw NSError(
        domain: "RemoteAppControllerTests",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for matching snapshot."]
    )
}

private func waitUntil(
    timeoutSeconds: Double = 4,
    predicate: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if predicate() {
            return
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw NSError(
        domain: "RemoteAppControllerTests",
        code: -2,
        userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for condition."]
    )
}
