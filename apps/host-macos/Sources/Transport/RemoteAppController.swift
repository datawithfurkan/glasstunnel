import Foundation
import GTAdapters
import GTCapture
import GTProtocol
import GTSecurity
#if os(macOS)
import AppKit
import OSLog
#endif

#if os(macOS)
private let remoteAppControllerLogger = Logger(subsystem: "io.glasstunnel.host", category: "RemoteApps")
#endif

public struct RemoteAppWindowOption: Identifiable, Sendable, Hashable {
    public var id: String { windowKey }
    public let windowKey: String
    public let title: String
    public let subtitle: String
    public let windowID: UInt32
    public let applicationBundleID: String
    public let pid: Int32
}

public struct RemoteAppDefinition: Sendable, Hashable, Identifiable {
    public var id: String { remoteAppId }
    public let remoteAppId: String
    public let displayName: String
    public let adapterKind: AdapterKind
    public let bundleIDs: Set<String>
    public let agentId: AgentID
    public let symbolName: String
    public let openHint: String
    public let requiresWindow: Bool
    public let executableCandidates: [String]
    public let hasVideo: Bool

    public init(
        remoteAppId: String,
        displayName: String,
        adapterKind: AdapterKind,
        bundleIDs: Set<String>,
        agentId: AgentID,
        symbolName: String,
        openHint: String,
        requiresWindow: Bool = true,
        executableCandidates: [String] = [],
        hasVideo: Bool = false
    ) {
        self.remoteAppId = remoteAppId
        self.displayName = displayName
        self.adapterKind = adapterKind
        self.bundleIDs = bundleIDs
        self.agentId = agentId
        self.symbolName = symbolName
        self.openHint = openHint
        self.requiresWindow = requiresWindow
        self.executableCandidates = executableCandidates
        self.hasVideo = hasVideo
    }

    public static let supported: [RemoteAppDefinition] = [
        RemoteAppDefinition(
            remoteAppId: "screen",
            displayName: "Mac Screen",
            adapterKind: .mirror,
            bundleIDs: [],
            agentId: "screen",
            symbolName: "display",
            openHint: "View and control this Mac screen",
            requiresWindow: false,
            executableCandidates: [],
            hasVideo: true
        ),
        RemoteAppDefinition(
            remoteAppId: "codex",
            displayName: "Codex",
            adapterKind: .mirror,
            bundleIDs: [CodexDesktopAdapter.bundleID],
            agentId: "codex",
            symbolName: "sparkles.rectangle.stack",
            openHint: "Open Codex on this Mac"
        ),
        RemoteAppDefinition(
            remoteAppId: "claude-desktop",
            displayName: "Claude",
            adapterKind: .claudeDesktop,
            bundleIDs: [ClaudeDesktopAdapter.bundleID],
            agentId: "claude-desktop",
            symbolName: "macwindow",
            openHint: "Open Claude on this Mac"
        ),
        RemoteAppDefinition(
            remoteAppId: "cursor",
            displayName: "Cursor",
            adapterKind: .cursor,
            bundleIDs: ["com.todesktop.230313mzl4w4u92"],
            agentId: "cursor",
            symbolName: "cursorarrow.rays",
            openHint: "Open Cursor on this Mac"
        ),
        RemoteAppDefinition(
            remoteAppId: "cursor-agent",
            displayName: "Cursor Agent",
            adapterKind: .cursorAgent,
            bundleIDs: [],
            agentId: "cursor-agent",
            symbolName: "terminal",
            openHint: "Install Cursor Agent CLI on this Mac",
            requiresWindow: false,
            executableCandidates: CursorAgentAdapter.executableCandidates(),
            hasVideo: false
        ),
        RemoteAppDefinition(
            remoteAppId: "claude-code",
            displayName: "Claude Code",
            adapterKind: .claudeCode,
            bundleIDs: [],
            agentId: "claude-code",
            symbolName: "terminal",
            openHint: "Install Claude Code CLI on this Mac",
            requiresWindow: false,
            executableCandidates: ClaudeCodeAdapter.executableCandidates(),
            hasVideo: false
        ),
        RemoteAppDefinition(
            remoteAppId: "codex-cli",
            displayName: "Codex CLI",
            adapterKind: .codexCli,
            bundleIDs: ["com.openai.codex.cli"],
            agentId: "codex-cli",
            symbolName: "terminal.fill",
            openHint: "Install Codex CLI on this Mac",
            requiresWindow: false,
            executableCandidates: CodexAdapter.executableCandidates(),
            hasVideo: false
        ),
        RemoteAppDefinition(
            remoteAppId: "gemini-cli",
            displayName: "Gemini CLI",
            adapterKind: .geminiCli,
            bundleIDs: ["com.google.gemini.cli", "com.google.gemini"],
            agentId: "gemini-cli",
            symbolName: "terminal",
            openHint: "Install Gemini CLI on this Mac",
            requiresWindow: false,
            executableCandidates: GeminiAdapter.executableCandidates(),
            hasVideo: false
        ),
        RemoteAppDefinition(
            remoteAppId: "terminal",
            displayName: "Terminal",
            adapterKind: .terminal,
            bundleIDs: ["com.apple.Terminal"],
            agentId: "terminal",
            symbolName: "terminal.fill",
            openHint: "Start a shell on this Mac",
            requiresWindow: false,
            executableCandidates: terminalExecutableCandidates(),
            hasVideo: false
        ),
        RemoteAppDefinition(
            remoteAppId: "opencode",
            displayName: "OpenCode",
            adapterKind: .openCode,
            bundleIDs: ["ai.opencode.app", "ai.opencode.desktop", "dev.opencode.cli"],
            agentId: "opencode",
            symbolName: "terminal",
            openHint: "Install OpenCode CLI on this Mac",
            requiresWindow: false,
            executableCandidates: OpenCodeAdapter.executableCandidates(),
            hasVideo: false
        ),
    ]

    public static func definition(for remoteAppId: String) -> RemoteAppDefinition? {
        supported.first { $0.remoteAppId == remoteAppId }
    }

    public static func definition(for window: CapturableWindow) -> RemoteAppDefinition? {
        supported.first { $0.bundleIDs.contains(window.applicationBundleID) }
    }

    private static func terminalExecutableCandidates() -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var seen = Set<String>()
        return [shell, "/bin/zsh", "/bin/bash", "/bin/sh"]
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }
}

private enum RemoteAppExecutableResolver {
    static func exists(_ candidate: String) -> Bool {
        let fileManager = FileManager.default
        if candidate.contains("/") {
            return fileManager.isExecutableFile(atPath: candidate)
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":").map(String.init) {
            let fullPath = (directory as NSString).appendingPathComponent(candidate)
            if fileManager.isExecutableFile(atPath: fullPath) {
                return true
            }
        }
        return false
    }
}

enum InstalledApplicationResolver {
    static func isStableInstallURL(
        _ url: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return false
        }

        let candidatePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
        ]

        return roots.contains { root in
            let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
            return candidatePath.hasPrefix(rootPath + "/")
        }
    }

    #if os(macOS)
    static func applicationURL(bundleIdentifier: String) -> URL? {
        guard
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
            isStableInstallURL(url)
        else {
            return nil
        }
        return url
    }
    #endif
}

#if os(macOS)
private enum TerminalCommandFileLauncher {
    static func launch(command: String) -> Bool {
        do {
            guard let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                return false
            }
            let scriptURL = try scriptURL()
            let script = """
            #!/bin/zsh
            \(command)
            """
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: scriptURL.path
            )

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(
                [scriptURL],
                withApplicationAt: terminalURL,
                configuration: configuration,
                completionHandler: nil
            )
            return true
        } catch {
            return false
        }
    }

    private static func scriptURL() throws -> URL {
        let fileManager = FileManager.default
        let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = supportDirectory
            .appendingPathComponent("Glasstunnel", isDirectory: true)
            .appendingPathComponent("Terminal", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("glasstunnel-terminal-\(UUID().uuidString).command")
    }
}
#endif

private enum TerminalSessionResetter {
    static func reset(sessionName: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: TerminalSessionConfiguration.screenExecutable) else {
            return true
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: TerminalSessionConfiguration.screenExecutable)
        process.arguments = ["-S", sessionName, "-X", "quit"]
        do {
            try process.run()
            process.waitUntilExit()
            return true
        } catch {
            return false
        }
    }
}

@MainActor
public final class RemoteAppController {
    typealias RemoteAppAdapterFactory = @Sendable (RemoteAppDefinition, CapturableWindow?) -> (any AgentAdapter)?

    public var onRemoteAppsChanged: (@Sendable ([RemoteApp]) -> Void)?
    public var onAgentState: (@Sendable (AgentStateSnapshot) -> Void)?

    private enum DefaultsKey {
        static let enabled = "remoteApps.enabled.v1"
        static let terminalDefaultEnabledMigration = "remoteApps.terminalDefaultEnabled.v1"
        static let terminalSessionLabel = "remoteApps.terminalSessionLabel.v1"
        static let terminalActiveSessionName = "remoteApps.terminalActiveSessionName.v1"
        static let terminalSessionLabels = "remoteApps.terminalSessionLabels.v1"
        static let terminalSessionNames = "remoteApps.terminalSessionNames.v1"
        static let preferredWindow = "remoteApps.preferredWindow.v1"
    }

    private let defaults: UserDefaults
    private let redactor: SecretRedactor
    private var windows: [CapturableWindow] = []
    private var enabledIDs: Set<String>
    private var preferredWindowKeys: [String: String]
    private var adapters: [String: any AgentAdapter] = [:]
    private var adapterObservers: [String: Task<Void, Never>] = [:]
    private var latestSnapshots: [AgentID: AgentStateSnapshot] = [:]
    private var lastPublishedRemoteApps: [RemoteApp]?
    private var screenRecordingAvailable = true
    private let executableExists: @Sendable (String) -> Bool
    private let appExists: @Sendable (String) -> Bool
    private let terminalCommandLauncher: (String) -> Bool
    private let terminalSessionResetter: (String) -> Bool
    private let terminalSessionNameGenerator: () -> String
    private let appLauncher: (String) -> Bool
    private let adapterFactory: RemoteAppAdapterFactory?

    public convenience init(defaults: UserDefaults = .standard, redactor: SecretRedactor = SecretRedactor()) {
        let executableExists: @Sendable (String) -> Bool = { candidate in
            RemoteAppExecutableResolver.exists(candidate)
        }
        let appExists: @Sendable (String) -> Bool = { bundleID in
            #if os(macOS)
            InstalledApplicationResolver.applicationURL(bundleIdentifier: bundleID) != nil
            #else
            false
            #endif
        }
        let appLauncher: (String) -> Bool = { bundleID in
            #if os(macOS)
            guard let url = InstalledApplicationResolver.applicationURL(bundleIdentifier: bundleID) else {
                return false
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
            return true
            #else
            return false
            #endif
        }
        let terminalCommandLauncher: (String) -> Bool = { command in
            #if os(macOS)
            TerminalCommandFileLauncher.launch(command: command)
            #else
            false
            #endif
        }
        let terminalSessionResetter: (String) -> Bool = { sessionName in
            TerminalSessionResetter.reset(sessionName: sessionName)
        }
        self.init(
            defaults: defaults,
            redactor: redactor,
            executableExists: executableExists,
            appExists: appExists,
            terminalCommandLauncher: terminalCommandLauncher,
            terminalSessionResetter: terminalSessionResetter,
            terminalSessionNameGenerator: {
                "glasstunnel-terminal-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
            },
            appLauncher: appLauncher
        )
    }

    init(
        defaults: UserDefaults = .standard,
        redactor: SecretRedactor = SecretRedactor(),
        executableExists: @escaping @Sendable (String) -> Bool,
        appExists: @escaping @Sendable (String) -> Bool = { _ in false },
        terminalCommandLauncher: @escaping (String) -> Bool = { _ in false },
        terminalSessionResetter: @escaping (String) -> Bool = { _ in true },
        terminalSessionNameGenerator: @escaping () -> String = {
            "glasstunnel-terminal-\(Int(Date().timeIntervalSince1970))"
        },
        appLauncher: @escaping (String) -> Bool = { _ in false },
        adapterFactory: RemoteAppAdapterFactory? = nil
    ) {
        self.defaults = defaults
        self.redactor = redactor
        self.executableExists = executableExists
        self.appExists = appExists
        self.terminalCommandLauncher = terminalCommandLauncher
        self.terminalSessionResetter = terminalSessionResetter
        self.terminalSessionNameGenerator = terminalSessionNameGenerator
        self.appLauncher = appLauncher
        self.adapterFactory = adapterFactory
        PTYWrapper.reapStaleRecordedProcesses()
        if let storedEnabled = defaults.stringArray(forKey: DefaultsKey.enabled) {
            var enabledIDs = Set(storedEnabled)
            if !defaults.bool(forKey: DefaultsKey.terminalDefaultEnabledMigration) {
                enabledIDs.insert("terminal")
                defaults.set(Array(enabledIDs).sorted(), forKey: DefaultsKey.enabled)
                defaults.set(true, forKey: DefaultsKey.terminalDefaultEnabledMigration)
            }
            self.enabledIDs = enabledIDs
        } else {
            self.enabledIDs = ["screen", "terminal"]
            defaults.set(true, forKey: DefaultsKey.terminalDefaultEnabledMigration)
        }
        if let data = defaults.data(forKey: DefaultsKey.preferredWindow),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.preferredWindowKeys = decoded
        } else {
            self.preferredWindowKeys = [:]
        }
    }

    deinit {
        for task in adapterObservers.values { task.cancel() }
        for adapter in adapters.values {
            if let ptyAdapter = adapter as? PTYAdapterBase {
                ptyAdapter.shutdownImmediately()
            } else {
                Task { await adapter.stop() }
            }
        }
    }

    public func updateWindows(_ windows: [CapturableWindow]) {
        self.windows = windows
        reconcileAdapters()
        publishRemoteApps()
    }

    public func setScreenRecordingAvailable(_ available: Bool) {
        guard screenRecordingAvailable != available else { return }
        screenRecordingAvailable = available
        if !available {
            latestSnapshots.removeValue(forKey: "screen")
        }
        reconcileAdapters()
        publishRemoteApps()
    }

    public func setEnabled(remoteAppId: String, enabled: Bool) {
        if !enabled, let definition = RemoteAppDefinition.definition(for: remoteAppId) {
            stopRemoteApp(definition)
            return
        }
        if enabled,
           remoteAppId == "terminal",
           let definition = RemoteAppDefinition.definition(for: remoteAppId) {
            startRemoteApp(definition, launchPolicy: .bestEffort)
            return
        }
        if enabled {
            enabledIDs.insert(remoteAppId)
        } else {
            enabledIDs.remove(remoteAppId)
        }
        persistEnabled()
        reconcileAdapters()
        publishRemoteApps()
    }

    public func selectWindow(remoteAppId: String, windowKey: String) {
        preferredWindowKeys[remoteAppId] = windowKey
        persistPreferredWindows()
        removeAdapter(remoteAppId: remoteAppId)
        latestSnapshots.removeValue(forKey: RemoteAppDefinition.definition(for: remoteAppId)?.agentId ?? remoteAppId)
        reconcileAdapters()
        publishRemoteApps()
    }

    public func remoteAppsSnapshot() -> [RemoteApp] {
        RemoteAppDefinition.supported.compactMap { definition in
            guard shouldPublish(definition) else { return nil }
            return makeRemoteApp(definition: definition)
        }
    }

    public func cachedSnapshots() -> [AgentStateSnapshot] {
        Array(latestSnapshots.values)
    }

    public func windowOptions(for remoteAppId: String) -> [RemoteAppWindowOption] {
        guard let definition = RemoteAppDefinition.definition(for: remoteAppId) else { return [] }
        return matchingWindows(for: definition).map { option(for: $0) }
    }

    public func selectedWindow(for remoteAppId: String) -> RemoteAppWindowOption? {
        guard let definition = RemoteAppDefinition.definition(for: remoteAppId),
              let window = selectedWindow(for: definition) else { return nil }
        return option(for: window)
    }

    public func deprecatedLayout() -> GridLayout {
        var layout = GridLayout.empty(shape: .twoByTwo)
        let positions = [
            GridCellPosition(row: 0, col: 0),
            GridCellPosition(row: 0, col: 1),
            GridCellPosition(row: 1, col: 0),
            GridCellPosition(row: 1, col: 1),
        ]
        let apps = remoteAppsSnapshot().filter { app in
            app.remoteAppId != "screen" && app.enabled && app.available
        }
        for (index, app) in apps.prefix(positions.count).enumerated() {
            layout.replace(cell: GridCell(
                position: positions[index],
                agentId: app.agentId,
                windowTitle: app.windowTitle,
                applicationBundleId: app.applicationBundleId,
                adapterKind: app.adapterKind,
                videoEnabled: app.hasVideo
            ))
        }
        return layout
    }

    public func sendInput(agentId: AgentID, text: String, submit: Bool) async throws {
        guard let adapter = adapter(for: agentId) else {
            try throwUnavailable(agentId: agentId)
        }
        try await adapter.sendInput(text, submit: submit)
    }

    public func respondToInputRequest(_ response: AgentInputRequestResponse) async throws {
        guard let adapter = adapter(for: response.agentId) else {
            try throwUnavailable(agentId: response.agentId)
        }
        #if os(macOS)
        remoteAppControllerLogger.info("remote app adapter input response handling agentId=\(response.agentId, privacy: .public) kind=\(String(describing: adapter.kind), privacy: .public) requestId=\(response.requestId, privacy: .public)")
        #endif
        try await adapter.respondToInputRequest(response)
        #if os(macOS)
        remoteAppControllerLogger.info("remote app adapter input response handled agentId=\(response.agentId, privacy: .public) kind=\(String(describing: adapter.kind), privacy: .public) requestId=\(response.requestId, privacy: .public)")
        #endif
    }

    public func interrupt(agentId: AgentID) async throws {
        guard let adapter = adapter(for: agentId) else {
            try throwUnavailable(agentId: agentId)
        }
        try await adapter.interrupt()
    }

    /// The full text of a transcript message, redacted like a snapshot.
    public func messageDetail(agentId: AgentID, messageId: MessageID) -> MessageDetail? {
        guard let adapter = adapter(for: agentId), let detail = adapter.messageDetail(messageId) else {
            return nil
        }
        let (redactedText, hits) = redactor.redact(detail.text)
        let reasons = SecretRedactor.mergedReasons([], hits, SecretRedactor.placeholderReasons(in: redactedText))
        return MessageDetail(
            agentId: agentId,
            messageId: messageId,
            text: redactedText,
            redacted: !reasons.isEmpty,
            redactionReasons: reasons,
            truncated: detail.truncated
        )
    }

    public func selectTarget(agentId: AgentID, targetId: String) async throws {
        if agentId == "terminal" {
            try selectTerminalSession(targetId: targetId)
            return
        }
        guard let adapter = adapter(for: agentId) else {
            try throwUnavailable(agentId: agentId)
        }
        try await adapter.selectTarget(targetId)
    }

    public func renameTarget(_ request: TargetRenameRequest) async throws {
        guard request.agentId == "terminal",
              let sessionName = TerminalAdapter.sessionName(fromTargetId: request.targetId),
              terminalSessionNames().contains(sessionName) else {
            throw NSError(
                domain: "RemoteAppController",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Renaming is available for Terminal sessions only."]
            )
        }
        let label = sanitizedTerminalSessionLabel(request.label)
        setTerminalSessionLabel(label, for: sessionName)

        if sessionName == activeTerminalSessionName(),
           let terminalAdapter = adapters["terminal"] as? TerminalAdapter {
            terminalAdapter.setSessionLabel(label)
        }
        updateTerminalSessionSnapshots()
    }

    public func updateRuntimeSettings(_ update: AgentRuntimeSettingsUpdate) async throws {
        guard let adapter = adapter(for: update.agentId) else {
            try throwUnavailable(agentId: update.agentId)
        }
        try await adapter.updateRuntimeSettings(update)
    }

    public func performRemoteAppAction(_ request: RemoteAppActionRequest) async throws {
        guard let definition = RemoteAppDefinition.definition(for: request.remoteAppId) else {
            throw NSError(
                domain: "RemoteAppController",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Unknown remote app \(request.remoteAppId)."]
            )
        }
        #if os(macOS)
        remoteAppControllerLogger.info("remote app action handling remoteAppId=\(request.remoteAppId, privacy: .public) agentId=\(definition.agentId, privacy: .public) action=\(request.action.rawValue, privacy: .public)")
        #endif

        switch request.action {
        case .disable, .stop:
            stopRemoteApp(definition)
        case .enable, .start:
            startRemoteApp(definition, launchPolicy: .bestEffort)
        case .launch:
            startRemoteApp(definition, launchPolicy: .required)
        case .newSession:
            startNewTerminalSession(definition)
        case .closeSession:
            closeTerminalSession(definition)
        }
    }

    public func performScreenPointerInput(_ input: ScreenPointerInput) async throws {
        guard let adapter = adapter(for: input.agentId) else {
            try throwUnavailable(agentId: input.agentId)
        }
        guard let screenAdapter = adapter as? ScreenMirrorAdapter else {
            throw NSError(
                domain: "RemoteAppController",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Remote app \(input.agentId) does not support screen pointer input."]
            )
        }
        try await screenAdapter.pointerInput(input)
    }

    public func publishRemoteAppStatus(
        remoteAppId: String,
        status: AgentStatus,
        detail: String,
        text: String
    ) {
        guard let definition = RemoteAppDefinition.definition(for: remoteAppId) else { return }
        emitStatusSnapshot(
            definition: definition,
            status: status,
            detail: detail,
            text: text
        )
    }

    private func adapter(for agentId: AgentID) -> (any AgentAdapter)? {
        guard let definition = RemoteAppDefinition.supported.first(where: { $0.agentId == agentId }) else { return nil }
        return adapters[definition.remoteAppId]
    }

    private func throwUnavailable(agentId: AgentID) throws -> Never {
        throw NSError(
            domain: "RemoteAppController",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Remote app \(agentId) is not available."]
        )
    }

    private func reconcileAdapters() {
        for definition in RemoteAppDefinition.supported {
            let shouldRun = enabledIDs.contains(definition.remoteAppId) && isAvailable(definition)
            if shouldRun {
                if adapters[definition.remoteAppId] == nil {
                    startAdapter(for: definition)
                }
            } else {
                removeAdapter(remoteAppId: definition.remoteAppId)
            }
        }
    }

    private func startAdapter(for definition: RemoteAppDefinition) {
        let window = selectedWindow(for: definition)
        if definition.requiresWindow && window == nil { return }
        let adapter: any AgentAdapter
        if let factoryAdapter = adapterFactory?(definition, window) {
            adapter = factoryAdapter
        } else {
            switch definition.remoteAppId {
            case "codex":
                guard let window else { return }
                adapter = CodexDesktopAdapter(
                    agentID: definition.agentId,
                    label: definition.displayName,
                    targetPID: window.pid
                )
            case "claude-desktop":
                guard let window else { return }
                adapter = ClaudeDesktopAdapter(
                    agentID: definition.agentId,
                    label: definition.displayName,
                    targetPID: window.pid
                )
            case "cursor":
                adapter = CursorAdapter(agentID: definition.agentId, label: definition.displayName)
            case "cursor-agent":
                adapter = CursorAgentAdapter(agentID: definition.agentId, label: definition.displayName)
            case "claude-code":
                adapter = ClaudeCodeAdapter(agentID: definition.agentId, label: definition.displayName)
            case "codex-cli":
                adapter = CodexAdapter(agentID: definition.agentId, label: definition.displayName)
            case "gemini-cli":
                adapter = GeminiAdapter(agentID: definition.agentId, label: definition.displayName)
            case "terminal":
                let activeSessionName = activeTerminalSessionName()
                adapter = TerminalAdapter(
                    agentID: definition.agentId,
                    label: definition.displayName,
                    screenSessionName: activeSessionName,
                    sessionLabel: terminalSessionLabel(for: activeSessionName),
                    sessionOptions: terminalSessionOptions()
                )
            case "opencode":
                adapter = OpenCodeAdapter(agentID: definition.agentId, label: definition.displayName)
            case "screen":
                adapter = ScreenMirrorAdapter(agentID: definition.agentId, label: definition.displayName)
            default:
                guard let window else { return }
                adapter = MirrorAdapter(
                    agentID: definition.agentId,
                    label: definition.displayName,
                    targetPID: window.pid,
                    targetBundleID: window.applicationBundleID
                )
            }
        }

        #if os(macOS)
        remoteAppControllerLogger.info("remote app adapter creating remoteAppId=\(definition.remoteAppId, privacy: .public) agentId=\(definition.agentId, privacy: .public) kind=\(String(describing: definition.adapterKind), privacy: .public)")
        #endif
        adapters[definition.remoteAppId] = adapter
        adapterObservers[definition.remoteAppId] = Task { [weak self, adapter, definition] in
            for await snapshot in adapter.observeState() {
                await self?.handleSnapshot(snapshot, definition: definition)
            }
        }
        if latestSnapshots[definition.agentId] == nil {
            emitStatusSnapshot(
                definition: definition,
                status: .working,
                detail: "Starting",
                text: "Starting \(definition.displayName) on this Mac."
            )
        }

        Task { [weak self, adapter, definition] in
            do {
                try await adapter.start()
                #if os(macOS)
                remoteAppControllerLogger.info("remote app adapter started remoteAppId=\(definition.remoteAppId, privacy: .public) agentId=\(definition.agentId, privacy: .public)")
                #endif
                self?.publishRemoteApps()
            } catch {
                #if os(macOS)
                remoteAppControllerLogger.error("remote app adapter start failed remoteAppId=\(definition.remoteAppId, privacy: .public) agentId=\(definition.agentId, privacy: .public) error=\(String(describing: error), privacy: .private)")
                #endif
                await self?.emitAdapterError(error, definition: definition)
            }
        }
    }

    private func removeAdapter(remoteAppId: String) {
        adapterObservers[remoteAppId]?.cancel()
        adapterObservers.removeValue(forKey: remoteAppId)
        guard let adapter = adapters.removeValue(forKey: remoteAppId) else { return }
        Task { await adapter.stop() }
    }

    private enum LaunchPolicy {
        var label: String {
            switch self {
            case .never: return "never"
            case .bestEffort: return "bestEffort"
            case .required: return "required"
            }
        }

        case never
        case bestEffort
        case required
    }

    private func startRemoteApp(_ definition: RemoteAppDefinition, launchPolicy: LaunchPolicy) {
        let requiresExecutable = requiresExecutableBeforeBundleLaunch(definition)
        let availableBeforeLaunch = isAvailable(definition)
        let launched = launchPolicy == .never || (launchPolicy == .required && requiresExecutable && !availableBeforeLaunch)
            ? false
            : launchApplication(for: definition)
        let available = availableBeforeLaunch || isAvailable(definition)
        #if os(macOS)
        remoteAppControllerLogger.info("remote app start resolved remoteAppId=\(definition.remoteAppId, privacy: .public) agentId=\(definition.agentId, privacy: .public) policy=\(launchPolicy.label, privacy: .public) launched=\(launched, privacy: .public) available=\(available, privacy: .public)")
        #endif
        if available {
            if shouldRestartExistingAdapter(for: definition) {
                #if os(macOS)
                remoteAppControllerLogger.info("remote app adapter restarting remoteAppId=\(definition.remoteAppId, privacy: .public) agentId=\(definition.agentId, privacy: .public)")
                #endif
                removeAdapter(remoteAppId: definition.remoteAppId)
                latestSnapshots.removeValue(forKey: definition.agentId)
            }
            enabledIDs.insert(definition.remoteAppId)
            persistEnabled()
            let detail: String
            if launched {
                detail = "Opening on Mac"
            } else if launchPolicy == .required, !definition.requiresWindow, hasExecutable(definition) {
                detail = "Starting on Mac"
            } else {
                detail = "Starting"
            }
            emitStatusSnapshot(
                definition: definition,
                status: .working,
                detail: detail,
                text: launchStartMessage(for: definition, launched: launched)
            )
            reconcileAdapters()
            publishRemoteApps()
            return
        }

        if launchPolicy == .required, launched {
            enabledIDs.insert(definition.remoteAppId)
            persistEnabled()
            emitStatusSnapshot(
                definition: definition,
                status: .working,
                detail: "Opening on Mac",
                text: "Opening \(definition.displayName) on this Mac. Keep Glasstunnel open while it warms up."
            )
            reconcileAdapters()
            publishRemoteApps()
            return
        }

        if launchPolicy == .required, hasExecutable(definition) {
            enabledIDs.insert(definition.remoteAppId)
            persistEnabled()
            emitStatusSnapshot(
                definition: definition,
                status: .working,
                detail: "Starting on Mac",
                text: "Starting \(definition.displayName) on this Mac."
            )
            reconcileAdapters()
            publishRemoteApps()
            return
        }

        if launchPolicy == .required, hasInstalledBundle(definition), !requiresExecutable {
            emitStatusSnapshot(
                definition: definition,
                status: .error,
                detail: "Open failed",
                text: "Could not open \(definition.displayName) on this Mac."
            )
            return
        }

        emitStatusSnapshot(
            definition: definition,
            status: .error,
            detail: "Not available",
            text: "\(definition.displayName) is not available on this Mac. \(definition.openHint)."
        )
    }

    private func requiresExecutableBeforeBundleLaunch(_ definition: RemoteAppDefinition) -> Bool {
        !definition.requiresWindow &&
            !definition.executableCandidates.isEmpty &&
            definition.remoteAppId != "terminal"
    }

    private func shouldRestartExistingAdapter(for definition: RemoteAppDefinition) -> Bool {
        guard adapters[definition.remoteAppId] != nil,
              let snapshot = latestSnapshots[definition.agentId] else {
            return false
        }

        switch snapshot.status {
        case .disconnected, .error:
            return true
        case .done:
            return snapshot.statusDetail
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveContains("process exited")
        default:
            return false
        }
    }

    private func stopRemoteApp(_ definition: RemoteAppDefinition) {
        enabledIDs.remove(definition.remoteAppId)
        persistEnabled()
        removeAdapter(remoteAppId: definition.remoteAppId)
        let detail = definition.remoteAppId == "screen" ? "Screen sharing off" : "Stopped"
        let text = definition.remoteAppId == "screen"
            ? "Mac Screen sharing was turned off."
            : "\(definition.displayName) was stopped."
        emitStatusSnapshot(
            definition: definition,
            status: .idle,
            detail: detail,
            text: text
        )
        publishRemoteApps()
    }

    private func startNewTerminalSession(_ definition: RemoteAppDefinition) {
        guard definition.remoteAppId == "terminal" else {
            emitStatusSnapshot(
                definition: definition,
                status: .error,
                detail: "Action unavailable",
                text: "New sessions are available for Terminal only."
            )
            return
        }

        removeAdapter(remoteAppId: definition.remoteAppId)
        latestSnapshots.removeValue(forKey: definition.agentId)
        let sessionName = nextTerminalSessionName()
        rememberTerminalSession(sessionName, label: nextTerminalSessionLabel())
        defaults.set(sessionName, forKey: DefaultsKey.terminalActiveSessionName)
        enabledIDs.insert(definition.remoteAppId)
        persistEnabled()
        emitStatusSnapshot(
            definition: definition,
            status: .working,
            detail: "New session",
            text: "Starting a new Terminal session on this Mac."
        )
        _ = launchApplication(for: definition)
        reconcileAdapters()
        publishRemoteApps()
    }

    private func closeTerminalSession(_ definition: RemoteAppDefinition) {
        guard definition.remoteAppId == "terminal" else {
            emitStatusSnapshot(
                definition: definition,
                status: .error,
                detail: "Action unavailable",
                text: "Closing sessions is available for Terminal only."
            )
            return
        }

        removeAdapter(remoteAppId: definition.remoteAppId)
        latestSnapshots.removeValue(forKey: definition.agentId)
        let sessionName = activeTerminalSessionName()
        let closedLabel = terminalSessionLabel(for: sessionName)
        _ = terminalSessionResetter(sessionName)
        removeTerminalSession(sessionName)
        if sessionName != TerminalSessionConfiguration.sharedSessionName {
            enabledIDs.insert(definition.remoteAppId)
            persistEnabled()
            let nextLabel = terminalSessionLabel(for: activeTerminalSessionName())
            emitStatusSnapshot(
                definition: definition,
                status: .working,
                detail: "Opening session",
                text: "Closed \(closedLabel) and opening \(nextLabel) on this Mac."
            )
            _ = launchApplication(for: definition)
            reconcileAdapters()
        } else {
            enabledIDs.remove(definition.remoteAppId)
            persistEnabled()
            emitStatusSnapshot(
                definition: definition,
                status: .idle,
                detail: "Closed",
                text: "Terminal session was closed on this Mac."
            )
        }
        publishRemoteApps()
    }

    private func selectTerminalSession(targetId: String) throws {
        guard let sessionName = TerminalAdapter.sessionName(fromTargetId: targetId),
              terminalSessionNames().contains(sessionName),
              let definition = RemoteAppDefinition.definition(for: "terminal") else {
            throw NSError(
                domain: "RemoteAppController",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Terminal session is not available."]
            )
        }

        guard sessionName != activeTerminalSessionName() else {
            return
        }

        removeAdapter(remoteAppId: definition.remoteAppId)
        latestSnapshots.removeValue(forKey: definition.agentId)
        defaults.set(sessionName, forKey: DefaultsKey.terminalActiveSessionName)
        enabledIDs.insert(definition.remoteAppId)
        persistEnabled()
        emitStatusSnapshot(
            definition: definition,
            status: .working,
            detail: "Switching session",
            text: "Switching to \(terminalSessionLabel(for: sessionName))."
        )
        reconcileAdapters()
        publishRemoteApps()
    }

    private func activeTerminalSessionName() -> String {
        let stored = defaults.string(forKey: DefaultsKey.terminalActiveSessionName) ?? TerminalSessionConfiguration.sharedSessionName
        let sanitized = sanitizedTerminalSessionName(stored)
        let sessions = terminalSessionNames()
        if sessions.contains(sanitized) {
            return sanitized
        }
        let fallback = TerminalSessionConfiguration.sharedSessionName
        rememberTerminalSession(fallback, label: terminalSessionLabel(for: fallback))
        defaults.set(fallback, forKey: DefaultsKey.terminalActiveSessionName)
        return fallback
    }

    private func terminalSessionNames() -> [String] {
        let stored = defaults.stringArray(forKey: DefaultsKey.terminalSessionNames) ?? []
        let sanitized = stored.map(sanitizedTerminalSessionName).filter { !$0.isEmpty }
        var seen = Set<String>()
        var result: [String] = []
        for name in [TerminalSessionConfiguration.sharedSessionName] + sanitized {
            guard !seen.contains(name) else { continue }
            seen.insert(name)
            result.append(name)
        }
        return result
    }

    private func terminalSessionOptions() -> [TerminalAdapter.TerminalSessionOption] {
        let active = activeTerminalSessionName()
        let names = terminalSessionNames()
        let ordered = names.sorted { lhs, rhs in
            if lhs == active { return true }
            if rhs == active { return false }
            if lhs == TerminalSessionConfiguration.sharedSessionName { return true }
            if rhs == TerminalSessionConfiguration.sharedSessionName { return false }
            return lhs < rhs
        }
        return ordered.map { name in
            TerminalAdapter.TerminalSessionOption(
                sessionName: name,
                label: terminalSessionLabel(for: name)
            )
        }
    }

    private func terminalSessionLabel(for sessionName: String) -> String {
        let labels = terminalSessionLabels()
        let fallback = sessionName == TerminalSessionConfiguration.sharedSessionName
            ? (defaults.string(forKey: DefaultsKey.terminalSessionLabel) ?? "Default Terminal")
            : sessionName.replacingOccurrences(of: "glasstunnel-terminal-", with: "Terminal ")
        return sanitizedTerminalSessionLabel(labels[sessionName] ?? fallback)
    }

    private func sanitizedTerminalSessionLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Default Terminal" }
        return String(trimmed.prefix(48))
    }

    private func sanitizedTerminalSessionName(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let filtered = value.trimmingCharacters(in: .whitespacesAndNewlines).filter { allowed.contains($0) }
        return String(filtered.prefix(64))
    }

    private func terminalSessionLabels() -> [String: String] {
        guard let data = defaults.data(forKey: DefaultsKey.terminalSessionLabels),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded.reduce(into: [String: String]()) { result, entry in
            let key = sanitizedTerminalSessionName(entry.key)
            guard !key.isEmpty else { return }
            result[key] = sanitizedTerminalSessionLabel(entry.value)
        }
    }

    private func setTerminalSessionLabel(_ label: String, for sessionName: String) {
        rememberTerminalSession(sessionName, label: label)
    }

    private func rememberTerminalSession(_ sessionName: String, label: String) {
        let sanitizedName = sanitizedTerminalSessionName(sessionName)
        guard !sanitizedName.isEmpty else { return }
        var names = terminalSessionNames()
        if !names.contains(sanitizedName) {
            names.append(sanitizedName)
        }
        defaults.set(names, forKey: DefaultsKey.terminalSessionNames)
        var labels = terminalSessionLabels()
        labels[sanitizedName] = sanitizedTerminalSessionLabel(label)
        if let data = try? JSONEncoder().encode(labels) {
            defaults.set(data, forKey: DefaultsKey.terminalSessionLabels)
        }
        if sanitizedName == TerminalSessionConfiguration.sharedSessionName {
            defaults.set(labels[sanitizedName], forKey: DefaultsKey.terminalSessionLabel)
        }
    }

    private func removeTerminalSession(_ sessionName: String) {
        let sanitizedName = sanitizedTerminalSessionName(sessionName)
        var names = terminalSessionNames().filter { $0 != sanitizedName }
        if names.isEmpty {
            names = [TerminalSessionConfiguration.sharedSessionName]
        }
        defaults.set(names, forKey: DefaultsKey.terminalSessionNames)
        var labels = terminalSessionLabels()
        labels.removeValue(forKey: sanitizedName)
        if let data = try? JSONEncoder().encode(labels) {
            defaults.set(data, forKey: DefaultsKey.terminalSessionLabels)
        }
        let nextActive = names.first ?? TerminalSessionConfiguration.sharedSessionName
        defaults.set(nextActive, forKey: DefaultsKey.terminalActiveSessionName)
    }

    private func nextTerminalSessionName() -> String {
        let existing = Set(terminalSessionNames())
        var candidate = sanitizedTerminalSessionName(terminalSessionNameGenerator())
        if candidate.isEmpty {
            candidate = "glasstunnel-terminal-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
        }
        if !existing.contains(candidate) {
            return candidate
        }
        for index in 2...99 {
            let indexed = sanitizedTerminalSessionName("\(candidate)-\(index)")
            if !existing.contains(indexed) {
                return indexed
            }
        }
        return sanitizedTerminalSessionName("\(candidate)-\(UUID().uuidString.prefix(8))")
    }

    private func nextTerminalSessionLabel() -> String {
        let count = terminalSessionNames().count + 1
        return "Terminal \(count)"
    }

    private func updateTerminalSessionSnapshots() {
        let active = activeTerminalSessionName()
        guard var snapshot = latestSnapshots["terminal"] else { return }
        snapshot.availableTargets = terminalSessionOptions().map { option in
            let selected = option.sessionName == active
            return AgentTargetOption(
                targetId: TerminalAdapter.sessionTargetId(sessionName: option.sessionName),
                label: option.label,
                subtitle: selected ? "Current session" : "Switch session",
                selected: selected,
                threadId: TerminalAdapter.sessionTargetId(sessionName: option.sessionName),
                threadLabel: option.label,
                targetKind: "session",
                isActive: selected,
                supportsNewThread: true
            )
        }
        latestSnapshots["terminal"] = snapshot
        onAgentState?(snapshot)
        publishRemoteApps()
    }

    private func launchApplication(for definition: RemoteAppDefinition) -> Bool {
        if definition.remoteAppId == "terminal",
           executableExists(TerminalSessionConfiguration.screenExecutable),
           terminalCommandLauncher(TerminalSessionConfiguration.visibleTerminalCommand(sessionName: activeTerminalSessionName())) {
            return true
        }

        for bundleID in definition.bundleIDs {
            if appLauncher(bundleID) { return true }
        }
        return false
    }

    private func hasExecutable(_ definition: RemoteAppDefinition) -> Bool {
        definition.executableCandidates.contains { executableExists($0) }
    }

    private func hasInstalledBundle(_ definition: RemoteAppDefinition) -> Bool {
        installedBundleID(for: definition) != nil
    }

    private func installedBundleID(for definition: RemoteAppDefinition) -> String? {
        definition.bundleIDs.sorted().first { appExists($0) }
    }

    private func shouldPublish(_ definition: RemoteAppDefinition) -> Bool {
        if definition.remoteAppId == "screen" { return true }
        if isAvailable(definition) { return true }
        if definition.requiresWindow {
            return hasInstalledBundle(definition)
        }
        if !definition.bundleIDs.isEmpty, hasInstalledBundle(definition) {
            return true
        }
        if !definition.executableCandidates.isEmpty {
            return hasExecutable(definition)
        }
        return true
    }

    private func launchStartMessage(for definition: RemoteAppDefinition, launched: Bool) -> String {
        if launched {
            return "Opening \(definition.displayName) on this Mac."
        }
        if !definition.requiresWindow && hasExecutable(definition) {
            return "Starting \(definition.displayName) on this Mac."
        }
        return "Starting \(definition.displayName) on this Mac."
    }

    private func handleSnapshot(_ snapshot: AgentStateSnapshot, definition: RemoteAppDefinition) async {
        var redactedSnapshot = snapshot
        redactedSnapshot.remoteAppId = definition.remoteAppId
        redactedSnapshot.hasVideoTrack = makeRemoteApp(definition: definition).hasVideo
        redactedSnapshot.recentMessages = snapshot.recentMessages.map { message in
            let (redactedText, hits) = redactor.redact(message.text)
            let reasons = SecretRedactor.mergedReasons(
                message.redactionReasons,
                hits,
                SecretRedactor.placeholderReasons(in: redactedText)
            )
            let (redactedTitle, titleHits) = redactor.redact(message.title)
            let allReasons = SecretRedactor.mergedReasons(reasons, titleHits, [])
            var copy = message
            copy.text = redactedText
            copy.title = redactedTitle
            copy.redacted = message.redacted || !allReasons.isEmpty
            copy.redactionReasons = allReasons
            return copy
        }
        latestSnapshots[definition.agentId] = redactedSnapshot
        onAgentState?(redactedSnapshot)
        publishRemoteApps()
    }

    private func emitAdapterError(_ error: Error, definition: RemoteAppDefinition) async {
        emitStatusSnapshot(
            definition: definition,
            status: .error,
            detail: "Start failed",
            text: "Could not start \(definition.displayName): \(error.localizedDescription)"
        )
    }

    private func emitStatusSnapshot(
        definition: RemoteAppDefinition,
        status: AgentStatus,
        detail: String,
        text: String
    ) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let message = AgentChatMessage(
            messageId: "\(definition.agentId)-remote-app-\(now)",
            role: .system,
            text: text,
            atUnixMs: now
        )
        let snapshot = AgentStateSnapshot(
            agentId: definition.agentId,
            agentLabel: definition.displayName,
            adapterKind: definition.adapterKind,
            status: status,
            statusDetail: detail,
            recentMessages: [message],
            lastActivityUnixMs: now,
            hasVideoTrack: definition.hasVideo,
            remoteAppId: definition.remoteAppId
        )
        latestSnapshots[definition.agentId] = snapshot
        onAgentState?(snapshot)
        publishRemoteApps()
    }

    private func makeRemoteApp(definition: RemoteAppDefinition) -> RemoteApp {
        let selected = selectedWindow(for: definition)
        let enabled = enabledIDs.contains(definition.remoteAppId)
        let available = isAvailable(definition)
        let snapshot = latestSnapshots[definition.agentId]
        let status: AgentStatus
        let detail: String
        if !enabled, let snapshot, snapshot.status == .error {
            status = .error
            detail = snapshot.statusDetail.isEmpty ? definition.openHint : snapshot.statusDetail
        } else if !enabled {
            status = .idle
            if definition.remoteAppId == "screen" {
                detail = "Screen sharing off"
            } else {
                detail = available ? "Ready from web" : definition.openHint
            }
        } else if !available {
            if let snapshot, snapshot.status == .working || snapshot.status == .error {
                status = snapshot.status
                detail = snapshot.statusDetail.isEmpty ? definition.openHint : snapshot.statusDetail
            } else {
                status = .disconnected
                detail = unavailableDetail(for: definition)
            }
        } else if let snapshot, !isTransportStoppingSnapshot(snapshot) {
            status = snapshot.status
            detail = snapshot.statusDetail.isEmpty ? "Ready" : snapshot.statusDetail
        } else {
            status = .idle
            detail = definition.remoteAppId == "screen" ? "Screen ready" : "Ready from web"
        }
        return RemoteApp(
            remoteAppId: definition.remoteAppId,
            displayName: definition.displayName,
            adapterKind: definition.adapterKind,
            agentId: definition.agentId,
            enabled: enabled,
            available: available,
            status: status,
            statusDetail: detail,
            windowTitle: selected?.title ?? "",
            applicationBundleId: selected?.applicationBundleID ?? installedBundleID(for: definition) ?? definition.bundleIDs.sorted().first ?? "",
            hasVideo: definition.hasVideo
        )
    }

    private func isTransportStoppingSnapshot(_ snapshot: AgentStateSnapshot) -> Bool {
        snapshot.status == .working &&
            snapshot.statusDetail.trimmingCharacters(in: .whitespacesAndNewlines) == "Stopping stream"
    }

    private func isAvailable(_ definition: RemoteAppDefinition) -> Bool {
        if definition.hasVideo && !screenRecordingAvailable {
            return false
        }
        if definition.requiresWindow {
            return selectedWindow(for: definition) != nil
        }
        if definition.executableCandidates.isEmpty {
            return true
        }
        return definition.executableCandidates.contains { executableExists($0) }
    }

    private func unavailableDetail(for definition: RemoteAppDefinition) -> String {
        if definition.hasVideo && !screenRecordingAvailable {
            return "Allow Screen Recording in System Settings"
        }
        return definition.openHint
    }

    private func matchingWindows(for definition: RemoteAppDefinition) -> [CapturableWindow] {
        windows
            .filter { definition.bundleIDs.contains($0.applicationBundleID) }
            .sorted { lhs, rhs in
                if lhs.isOnScreen != rhs.isOnScreen { return lhs.isOnScreen && !rhs.isOnScreen }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    private func selectedWindow(for definition: RemoteAppDefinition) -> CapturableWindow? {
        let matches = matchingWindows(for: definition)
        if let preferred = preferredWindowKeys[definition.remoteAppId],
           let match = matches.first(where: { windowKey(for: $0) == preferred }) {
            return match
        }
        return matches.first
    }

    private func option(for window: CapturableWindow) -> RemoteAppWindowOption {
        RemoteAppWindowOption(
            windowKey: windowKey(for: window),
            title: window.title.isEmpty ? window.applicationName : window.title,
            subtitle: window.applicationName,
            windowID: window.windowID,
            applicationBundleID: window.applicationBundleID,
            pid: window.pid
        )
    }

    private func windowKey(for window: CapturableWindow) -> String {
        "\(window.applicationBundleID)|\(window.pid)|\(window.windowID)|\(window.title)"
    }

    /// Publishes only when the list actually changed. The 5 s window refresh
    /// calls this constantly; republishing an identical list made every
    /// connected phone re-evaluate its screen stream and rewrite its cache,
    /// and made the relay re-send the hello for nothing.
    private func publishRemoteApps() {
        let snapshot = remoteAppsSnapshot()
        guard snapshot != lastPublishedRemoteApps else { return }
        lastPublishedRemoteApps = snapshot
        onRemoteAppsChanged?(snapshot)
    }

    private func persistEnabled() {
        defaults.set(Array(enabledIDs).sorted(), forKey: DefaultsKey.enabled)
    }

    private func persistPreferredWindows() {
        guard let data = try? JSONEncoder().encode(preferredWindowKeys) else { return }
        defaults.set(data, forKey: DefaultsKey.preferredWindow)
    }
}
