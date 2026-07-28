#if os(macOS)
import Combine
import Foundation
import AppKit
import SwiftUI
import GTProtocol
import GTSecurity
import GTCapture
import GTTransport
import GTAdapters

/// Top-level observable state for the Mac app.
///
/// Owns: the device key, grid layout, paired devices, auto-lock, session
/// manager, and capture pipeline.
@MainActor
final class AppState: ObservableObject {
    typealias LinkedAccountSummary = AccountLinkController.LinkedAccountSummary

    private enum DefaultsKey {
        static let signalingURL = "app.signalingURL"
        static let webAppURL = "app.webAppURL"
        static let turnURL = "app.turnURL"
        static let turnUsername = "app.turnUsername"
        static let introOnboardingDismissed = "app.introOnboardingDismissed"
        static let permissionOnboardingDismissed = "app.permissionOnboardingDismissed"
        static let keepAwakeEnabled = "app.keepAwakeEnabled"
    }

    @Published var layout: GTProtocol.GridLayout = GTProtocol.GridLayout.empty(shape: .twoByTwo)
    @Published var selectedTab: AppNavigationTab = .workspace
    @Published var availableWindows: [CapturableWindow] = []
    @Published var pairedDevices: [DeviceRegistry.PairedDevice] = []
    @Published var signalingURL: URL = AppState.loadSignalingURL() {
        didSet {
            UserDefaults.standard.set(signalingURL.absoluteString, forKey: DefaultsKey.signalingURL)
        }
    }
    @Published var webAppURL: URL = AppState.loadWebAppURL() {
        didSet {
            UserDefaults.standard.set(webAppURL.absoluteString, forKey: DefaultsKey.webAppURL)
        }
    }
    @Published var turnURL: String = AppState.loadTurnURL() {
        didSet {
            UserDefaults.standard.set(turnURL, forKey: DefaultsKey.turnURL)
        }
    }
    @Published var turnUsername: String = AppState.loadTurnUsername() {
        didSet {
            UserDefaults.standard.set(turnUsername, forKey: DefaultsKey.turnUsername)
        }
    }
    @Published var turnPassword: String = ""
    @Published var isReadOnly: Bool = false {
        didSet { autoLock.setReadOnly(isReadOnly) }
    }
    @Published var keepAwakeEnabled: Bool = AppState.loadKeepAwakeEnabled() {
        didSet {
            UserDefaults.standard.set(keepAwakeEnabled, forKey: DefaultsKey.keepAwakeEnabled)
            guard !isApplyingKeepAwakePreference else { return }
            applyKeepAwakePreference()
        }
    }
    @Published private(set) var keepAwakeActive: Bool = false
    @Published var lastError: String? = nil
    @Published var isAnyDeviceConnected: Bool = false
    @Published var connectedPhoneIDs: Set<DeviceID> = []
    @Published var introOnboardingComplete: Bool = AppState.loadIntroOnboardingDismissed() {
        didSet {
            UserDefaults.standard.set(introOnboardingComplete, forKey: DefaultsKey.introOnboardingDismissed)
        }
    }
    @Published var onboardingComplete: Bool = AppState.loadPermissionOnboardingDismissed() {
        didSet {
            UserDefaults.standard.set(onboardingComplete, forKey: DefaultsKey.permissionOnboardingDismissed)
        }
    }
    @Published private(set) var permissionState: Permissions.RequiredState = .unchecked
    @Published var requestedPermissions: Set<Permissions.Permission> = []
    @Published var sessionManagerState: String = "idle"
    @Published var accountIdentityChecked: Bool = false
    let approvalController = ApprovalController()
    let accountLinkController = AccountLinkController()
    let launchAtLogin = LaunchAtLoginController()

    @Published var linkedAccount: AccountLinkController.LinkedAccountSummary? = AccountLinkController.loadCachedLinkedAccountSummary()
    @Published var accountLinkCode: String? = nil
    @Published var accountLinkCodeExpiresAt: Date? = nil
    @Published var activeApproval: ApprovalController.PendingDeviceApproval? = nil
    @Published var agentSnapshots: [AgentID: AgentStateSnapshot] = [:]
    @Published var remoteApps: [RemoteApp] = []

    let autoLock = AutoLock()
    let keepAwakeController = KeepAwakeController()
    let registry = DeviceRegistry.shared
    let redactor = SecretRedactor()
    let remoteAppController = RemoteAppController()

    private var deviceKey: DeviceKey?
    private var sessionManager: SessionManager?
    private var refreshTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var isApplyingKeepAwakePreference = false

    init() {
        remoteAppController.onRemoteAppsChanged = { [weak self] apps in
            guard let appState = self else { return }
            Task { @MainActor [appState] in
                appState.remoteApps = apps
                appState.layout = appState.remoteAppController.deprecatedLayout()
                appState.sessionManager?.applyRemoteApps(apps)
            }
        }
        remoteAppController.onAgentState = { [weak self] snapshot in
            guard let appState = self else { return }
            Task { @MainActor [appState] in
                appState.agentSnapshots[snapshot.agentId] = snapshot
                appState.sessionManager?.broadcastAgentState(snapshot)
            }
        }
        remoteApps = remoteAppController.remoteAppsSnapshot()

        approvalController.setActiveChangedHandler { [weak self] approval in
            guard let appState = self else { return }
            Task { @MainActor [appState] in
                appState.activeApproval = approval
            }
        }

        Task { await self.bootstrap() }
    }

    private func bootstrap() async {
        do {
            deviceKey = try DeviceKeyStore.shared.getOrCreate()
        } catch {
            lastError = "Could not load device key: \(error.localizedDescription)"
        }
        refreshPairedDevices()
        refreshPermissions(startSessionOnCompletion: false)
        await refreshWindows()
        autoLock.onLock = { [weak self] in
            guard let appState = self else { return }
            Task { @MainActor [appState] in
                appState.isAnyDeviceConnected = false
                appState.connectedPhoneIDs.removeAll()
            }
        }
        autoLock.start()
        applyKeepAwakePreference()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let appState = self else { return }
            Task { @MainActor [appState] in
                appState.refreshPermissions()
                await appState.refreshWindows()
            }
        }
        if onboardingComplete && requiredPermissionsGranted {
            await startSessionManagerIfNeeded()
        }
    }

    func hostDeviceID() -> DeviceID? { deviceKey?.deviceId }
    var hostDisplayName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
    func hostPublicKeyBase64() -> String? { deviceKey?.publicKeyRaw.base64EncodedString() }
    var isLinkedToAccount: Bool { linkedAccount != nil }
    var trustedDeviceCount: Int { pairedDevices.filter { !$0.revoked }.count }
    var screenRecordingGranted: Bool { permissionState.screenRecordingGranted }
    var accessibilityGranted: Bool { permissionState.accessibilityGranted }
    var permissionsChecked: Bool { permissionState.checked }
    var requiredPermissionsGranted: Bool { permissionState.allGranted }
    var shouldShowPermissionOnboarding: Bool {
        PermissionOnboardingGate.shouldShowPermissionOnboarding(
            introComplete: introOnboardingComplete,
            permissionOnboardingComplete: onboardingComplete,
            permissionState: permissionState
        )
    }
    var pendingApprovalCount: Int { approvalController.pendingApprovalCount }
    var visiblePendingApprovals: [ApprovalController.PendingDeviceApproval] {
        approvalController.visiblePendingApprovals
    }
    var connectedDevices: [DeviceRegistry.PairedDevice] {
        pairedDevices.filter { connectedPhoneIDs.contains($0.deviceId) && !$0.revoked }
    }
    var activeConnectionSummary: String {
        let connected = connectedDevices
        if connected.isEmpty {
            switch sessionManagerState {
            case "connected":
                return "Ready for remote access"
            case "connecting":
                return "Reconnecting to signaling"
            case "error":
                return "Retrying in the background"
            default:
                return "Waiting for signaling"
            }
        }
        if connected.count == 1 {
            return "\(connected[0].label) connected"
        }
        return "\(connected.count) devices connected"
    }
    var accountStatusSummary: String {
        AccountLinkController.accountStatusSummary(for: linkedAccount)
    }
    var keepAwakeStatusSummary: String {
        if keepAwakeActive { return "Keeping Mac awake" }
        return "Off"
    }
    var shouldWaitForAccountIdentity: Bool {
        accountRoute == .checkingAccount
    }
    var accountRoute: AccountRoutePolicy.Route {
        AccountRoutePolicy.route(
            linkedAccount: linkedAccount,
            identityChecked: accountIdentityChecked,
            sessionManagerState: sessionManagerState
        )
    }
    var hostStatusLabel: String {
        switch sessionManagerState {
        case "connected":
            return "Online"
        case "connecting":
            return "Reconnecting"
        case "error":
            return "Reconnecting"
        default:
            return "Offline"
        }
    }

    func refreshWindows() async {
        guard screenRecordingGranted else {
            availableWindows = []
            remoteAppController.updateWindows([])
            return
        }

        do {
            self.availableWindows = try await WindowCatalog.refresh()
            self.remoteAppController.updateWindows(self.availableWindows)
        } catch {
            self.lastError = "Window enumeration failed: \(error.localizedDescription)"
        }
    }

    func refreshPairedDevices() {
        pairedDevices = registry.all()
    }

    func selectTab(_ tab: AppNavigationTab) {
        selectedTab = tab
    }

    func completeIntroOnboarding() {
        introOnboardingComplete = true
    }

    func continueFromPermissionOnboarding() {
        refreshPermissions(startSessionOnCompletion: false)
        guard PermissionOnboardingGate.canContinueToAuth(permissionState: permissionState) else { return }
        introOnboardingComplete = true
        onboardingComplete = true
        selectedTab = .access
        Task { await startSessionManagerIfNeeded() }
    }

    func requestPermission(_ permission: Permissions.Permission) {
        requestedPermissions.insert(permission)
        Permissions.request(permission)
        refreshPermissions()
        schedulePermissionFollowUps(for: permission)
    }

    func permissionWasRequested(_ permission: Permissions.Permission) -> Bool {
        requestedPermissions.contains(permission)
    }

    func restartApp() {
        let bundleURL = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    func refreshPermissions(startSessionOnCompletion: Bool = true) {
        let previouslyComplete = onboardingComplete
        let currentPermissions = Permissions.requiredState()
        permissionState = currentPermissions
        remoteAppController.setScreenRecordingAvailable(currentPermissions.screenRecordingGranted)
        clearResolvedPermissionPrompts(using: currentPermissions)
        if !requiredPermissionsGranted {
            onboardingComplete = false
        }
        if startSessionOnCompletion && deviceKey != nil && !previouslyComplete && onboardingComplete && requiredPermissionsGranted {
            Task { await startSessionManagerIfNeeded() }
        }
    }

    private func schedulePermissionFollowUps(for permission: Permissions.Permission) {
        for delay in [0.4, 1.2, 2.5] {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await MainActor.run {
                    guard let appState = self else { return }
                    appState.refreshPermissions()
                }
            }
        }
    }

    private func clearResolvedPermissionPrompts(using currentPermissions: Permissions.RequiredState) {
        for permission in Permissions.Permission.allCases where currentPermissions.isGranted(permission) {
            requestedPermissions.remove(permission)
        }
    }

    func assign(window: CapturableWindow, toPosition position: GridCellPosition) {
        let kind = AdapterFactory.resolveKind(forBundleID: window.applicationBundleID)
        let cell = GridCell(
            position: position,
            agentId: "\(kind.displayName.lowercased().replacingOccurrences(of: " ", with: ""))-\(window.windowID)",
            windowTitle: window.title,
            applicationBundleId: window.applicationBundleID,
            adapterKind: kind,
            videoEnabled: true
        )
        layout.replace(cell: cell)
        agentSnapshots[cell.agentId] = AgentStateSnapshot(
            agentId: cell.agentId,
            agentLabel: cell.windowTitle.isEmpty ? kind.displayName : cell.windowTitle,
            adapterKind: kind,
            status: isAnyDeviceConnected ? .working : .idle,
            statusDetail: isAnyDeviceConnected ? "preparing for web" : "ready to open on web",
            position: position,
            hasVideoTrack: cell.videoEnabled
        )
        sessionManager?.applyRemoteApps(remoteApps)
    }

    func clearCell(position: GridCellPosition) {
        if let current = layout.cell(at: position), !current.agentId.isEmpty {
            agentSnapshots.removeValue(forKey: current.agentId)
        }
        let cell = GridCell(
            position: position,
            agentId: "",
            adapterKind: .unspecified,
            videoEnabled: false
        )
        layout.replace(cell: cell)
        sessionManager?.applyRemoteApps(remoteApps)
    }

    func changeShape(_ shape: GridShape) {
        var newLayout = GTProtocol.GridLayout.empty(shape: shape)
        for cell in layout.cells {
            if cell.position.row < shape.rows && cell.position.col < shape.cols {
                newLayout.replace(cell: cell)
            }
        }
        layout = newLayout
        sessionManager?.applyRemoteApps(remoteApps)
    }

    func setRemoteAppEnabled(_ remoteAppId: String, enabled: Bool) {
        remoteAppController.setEnabled(remoteAppId: remoteAppId, enabled: enabled)
    }

    func selectRemoteAppWindow(remoteAppId: String, windowKey: String) {
        remoteAppController.selectWindow(remoteAppId: remoteAppId, windowKey: windowKey)
    }

    func windowOptions(for remoteAppId: String) -> [RemoteAppWindowOption] {
        remoteAppController.windowOptions(for: remoteAppId)
    }

    func selectedWindow(for remoteAppId: String) -> RemoteAppWindowOption? {
        remoteAppController.selectedWindow(for: remoteAppId)
    }

    func revokeDevice(_ id: DeviceID) {
        try? registry.revoke(id)
        refreshPairedDevices()
    }

    func removeDevice(_ id: DeviceID) {
        try? registry.remove(id)
        refreshPairedDevices()
    }

    // MARK: - Session

    enum AppStateError: LocalizedError {
        case noDeviceKey
        case signalingUnreachable(URL, Error)
        case sessionManagerNotReady

        var errorDescription: String? {
            switch self {
            case .noDeviceKey:
                return "No host device key available. Restart the app to regenerate."
            case .signalingUnreachable(let url, let underlying):
                let host = url.host(percentEncoded: false) ?? ""
                let nsError = underlying as NSError
                let isProductionSignaling = host == "signaling.glasstunnel.io"
                let isLocalSignaling = host == "localhost" || host == "127.0.0.1" || host == "::1"
                let hint: String
                if isProductionSignaling && nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorBadServerResponse {
                    hint = "The hosted signaling service is returning an error, usually because the Cloudflare Worker request limit is exhausted or the worker is failing."
                } else if GlasstunnelProtocol.isDevMode && isLocalSignaling {
                    hint = "Is `pnpm dev:stack` or your local signaling server running?"
                } else {
                    hint = "Check the configured signaling URL and your network connectivity."
                }
                return "Could not reach signaling server at \(url.absoluteString). "
                     + hint + " "
                     + "Underlying error: \(underlying.localizedDescription)"
            case .sessionManagerNotReady:
                return "Session manager not ready."
            }
        }
    }

    func ensureSessionManager() async throws {
        guard sessionManager == nil else { return }
        guard let deviceKey else { throw AppStateError.noDeviceKey }

        let manager = SessionManager(
            deviceKey: deviceKey,
            signalingURL: signalingURL,
            turnURL: turnURL,
            turnUsername: turnUsername.isEmpty ? nil : turnUsername,
            turnPassword: turnPassword.isEmpty ? nil : turnPassword,
            hostDeviceLabel: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            autoLock: autoLock,
            redactor: redactor,
            registry: registry,
            remoteAppController: remoteAppController
        )
        manager.onState = { [weak self] state in
            guard let appState = self else { return }
            Task { @MainActor [appState, manager] in
                guard appState.sessionManager === manager else { return }
                switch state {
                case .idle: appState.sessionManagerState = "idle"
                case .connecting: appState.sessionManagerState = "connecting"
                case .connected:
                    appState.sessionManagerState = "connected"
                    appState.lastError = nil
                case .error(let s):
                    appState.sessionManagerState = "error"
                    appState.lastError = s
                }
            }
        }
        manager.onPaired = { [weak self] _ in
            guard let appState = self else { return }
            Task { @MainActor [appState] in
                appState.refreshPairedDevices()
            }
        }
        manager.onPeerConnected = { [weak self] id in
            guard let appState = self else { return }
            Task { @MainActor [appState] in
                appState.connectedPhoneIDs.insert(id)
                appState.isAnyDeviceConnected = true
            }
        }
        manager.onPeerDisconnected = { [weak self] id in
            guard let appState = self else { return }
            Task { @MainActor [appState] in
                appState.connectedPhoneIDs.remove(id)
                appState.isAnyDeviceConnected = !appState.connectedPhoneIDs.isEmpty
            }
        }
        manager.onHostIdentity = { [weak self] identity in
            guard let appState = self else { return }
            Task { @MainActor [appState, manager] in
                guard appState.sessionManager === manager else { return }
                let summary = AccountLinkController.summary(from: identity)
                appState.linkedAccount = summary
                AccountLinkController.cacheLinkedAccountSummary(summary)
                appState.accountIdentityChecked = true
            }
        }
        manager.onLinkCode = { [weak self] linkCode in
            guard let appState = self else { return }
            Task { @MainActor [appState] in
                appState.accountLinkCode = linkCode.code
                appState.accountLinkCodeExpiresAt = linkCode.expiresAt
            }
        }
        manager.onApprovalRequested = { [weak self] request in
            guard let appState = self else { return }
            Task { @MainActor [appState] in
                appState.approvalController.enqueue(
                    id: request.id,
                    requesterDeviceID: request.requesterDeviceID,
                    requesterPublicKeyB64: request.requesterPublicKeyB64,
                    requesterLabel: request.requesterLabel,
                    requestedAt: request.requestedAt
                )
            }
        }
        manager.onAgentState = { [weak self] snapshot in
            guard let appState = self else { return }
            Task { @MainActor [appState] in
                appState.agentSnapshots[snapshot.agentId] = snapshot
            }
        }

        approvalController.setDecisionHandler { [weak self] requestID, approved in
            guard let self else { return }
            try? await self.sessionManager?.recordApprovalDecision(requestID: requestID, approved: approved)
        }
        approvalController.setRegistryAddHandler { [weak self] device in
            try self?.registry.add(device)
            self?.refreshPairedDevices()
        }

        self.sessionManager = manager
        do {
            try await manager.start()
        } catch {
            throw AppStateError.signalingUnreachable(signalingURL, error)
        }
    }

    private func reconnectSessionManager() async throws {
        sessionManager?.stop()
        sessionManager = nil
        try await ensureSessionManager()
    }

    /// Bootstrap-style starter: best-effort, surfaces failures as `lastError`
    /// without propagating them (so onboarding / permission refresh doesn't
    /// blow up if signaling is down).
    func startSessionManagerIfNeeded() async {
        do {
            try await ensureSessionManager()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func createAccountLinkCode() async throws {
        let linkCode = try await withFreshSessionManager { manager in
            try await manager.createAccountLinkCode()
        }
        accountLinkCode = linkCode.code
        accountLinkCodeExpiresAt = linkCode.expiresAt
    }

    enum HostedAuthMethod: String {
        case google
        case github
        case email
    }

    func beginHostedAccountSignIn(method: HostedAuthMethod? = nil) async throws {
        selectedTab = .access
        try await createAccountLinkCode()
        guard let code = accountLinkCode else {
            throw NSError(
                domain: "AppState",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "Could not create an account link code."]
            )
        }

        guard var components = URLComponents(url: webAppURL, resolvingAgainstBaseURL: false) else {
            throw NSError(
                domain: "AppState",
                code: -7,
                userInfo: [NSLocalizedDescriptionKey: "Phone web app URL is not valid."]
            )
        }

        var items = components.queryItems ?? []
        items.removeAll { $0.name == "linkCode" || $0.name == "authProvider" }
        items.append(URLQueryItem(name: "linkCode", value: code))
        if let method {
            items.append(URLQueryItem(name: "authProvider", value: method.rawValue))
        }
        components.queryItems = items

        guard let signInURL = components.url else {
            throw NSError(
                domain: "AppState",
                code: -8,
                userInfo: [NSLocalizedDescriptionKey: "Could not open the account sign-in URL."]
            )
        }

        NSWorkspace.shared.open(signInURL)
    }

    func signOutLinkedAccount() async throws {
        guard isLinkedToAccount else { return }

        let manager = sessionManager
        let remoteUnlink: (() async throws -> Void)?
        if sessionManagerState == "connected", let manager {
            remoteUnlink = { [weak self, manager] in
                guard let self else { return }
                try await self.unlinkHostBeforeSignOut(manager)
            }
        } else {
            remoteUnlink = nil
        }

        let coordinator = AccountSignOutCoordinator<DeviceKey>(
            clearTrustedDevices: { [registry] in
                try registry.removeAll()
            },
            rotateDeviceIdentity: {
                try DeviceKeyStore.shared.reset()
                return try DeviceKeyStore.shared.getOrCreate()
            }
        )
        let outcome = try await coordinator.perform(remoteUnlink: remoteUnlink)

        manager?.stop()
        sessionManager = nil
        sessionManagerState = "idle"
        if let replacementIdentity = outcome.replacementIdentity {
            deviceKey = replacementIdentity
        }
        pairedDevices = []
        linkedAccount = nil
        AccountLinkController.cacheLinkedAccountSummary(nil)
        accountIdentityChecked = true
        accountLinkCode = nil
        accountLinkCodeExpiresAt = nil
        approvalController.clearActive()
        activeApproval = nil
        connectedPhoneIDs.removeAll()
        isAnyDeviceConnected = false
        lastError = nil

        do {
            try await reconnectSessionManager()
        } catch {
            lastError = "Signed out, but the host could not reconnect: \(error.localizedDescription)"
        }
    }

    private func unlinkHostBeforeSignOut(_ manager: SessionManager) async throws {
        let timeout = Task { @MainActor [manager] in
            try await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            manager.stop()
        }
        defer { timeout.cancel() }
        try await manager.unlinkHost()
    }

    private func withFreshSessionManager<T>(
        _ operation: (SessionManager) async throws -> T
    ) async throws -> T {
        if sessionManager == nil || sessionManagerState != "connected" || sessionManagerNeedsReconfigure() {
            try await reconnectSessionManager()
        }
        guard let manager = sessionManager else {
            throw AppStateError.sessionManagerNotReady
        }

        do {
            return try await operation(manager)
        } catch {
            try await reconnectSessionManager()
            guard let manager = sessionManager else {
                throw AppStateError.sessionManagerNotReady
            }
            return try await operation(manager)
        }
    }

    func approveActiveDevice() {
        approvalController.approveActive()
    }

    func rejectActiveDevice() {
        approvalController.rejectActive()
    }

    private func applyKeepAwakePreference() {
        isApplyingKeepAwakePreference = true
        defer { isApplyingKeepAwakePreference = false }

        do {
            try keepAwakeController.setEnabled(keepAwakeEnabled)
            keepAwakeActive = keepAwakeController.isActive
        } catch {
            keepAwakeEnabled = false
            UserDefaults.standard.set(false, forKey: DefaultsKey.keepAwakeEnabled)
            keepAwakeActive = false
            lastError = error.localizedDescription
        }
    }

    private func sessionManagerNeedsReconfigure() -> Bool {
        guard let sessionManager else { return false }
        return sessionManager.signalingURL != signalingURL
            || sessionManager.turnURL != turnURL
            || sessionManager.turnUsername != nonEmpty(turnUsername)
            || sessionManager.turnPassword != nonEmpty(turnPassword)
    }

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }



    private static func loadSignalingURL() -> URL {
        let defaults = UserDefaults.standard
        if let explicit = GlasstunnelProtocol.explicitSignalingURL {
            defaults.set(explicit.absoluteString, forKey: DefaultsKey.signalingURL)
            return explicit
        }
        if
            let raw = defaults.string(forKey: DefaultsKey.signalingURL),
            let url = URL(string: raw)
        {
            if shouldMigrateSavedURL(url, kind: .signaling) {
                let migrated = GlasstunnelProtocol.defaultSignalingURL
                defaults.set(migrated.absoluteString, forKey: DefaultsKey.signalingURL)
                return migrated
            }
            return url
        }
        return GlasstunnelProtocol.defaultSignalingURL
    }

    private static func loadWebAppURL() -> URL {
        let defaults = UserDefaults.standard
        if let explicit = GlasstunnelProtocol.explicitWebAppURL {
            defaults.set(explicit.absoluteString, forKey: DefaultsKey.webAppURL)
            return explicit
        }
        if
            let raw = defaults.string(forKey: DefaultsKey.webAppURL),
            let url = URL(string: raw)
        {
            if shouldMigrateSavedURL(url, kind: .webApp) {
                let migrated = GlasstunnelProtocol.defaultWebAppURL
                defaults.set(migrated.absoluteString, forKey: DefaultsKey.webAppURL)
                return migrated
            }
            return url
        }
        return GlasstunnelProtocol.defaultWebAppURL
    }

    private static func loadTurnURL() -> String {
        let defaults = UserDefaults.standard
        return defaults.string(forKey: DefaultsKey.turnURL) ?? GlasstunnelProtocol.defaultTurnURL
    }

    private static func loadTurnUsername() -> String {
        let defaults = UserDefaults.standard
        return defaults.string(forKey: DefaultsKey.turnUsername) ?? ""
    }

    private static func loadPermissionOnboardingDismissed() -> Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.permissionOnboardingDismissed)
    }

    private static func loadIntroOnboardingDismissed() -> Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.introOnboardingDismissed)
    }

    private static func loadKeepAwakeEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.keepAwakeEnabled)
    }

    private enum EndpointKind {
        case signaling
        case webApp
    }

    private static func shouldMigrateSavedURL(_ url: URL, kind: EndpointKind) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if kind == .signaling && GlasstunnelProtocol.hasExplicitSignalingURLOverride { return false }
        if kind == .webApp && GlasstunnelProtocol.hasExplicitWebAppURLOverride { return false }

        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "0.0.0.0" {
            return true
        }
        if isPrivateIPv4Host(host) { return true }

        switch kind {
        case .signaling:
            return false
        case .webApp:
            return host == "glasstunnel.pages.dev"
        }
    }

    private static func isPrivateIPv4Host(_ host: String) -> Bool {
        let octets = host.split(separator: ".")
        guard octets.count == 4 else { return false }
        let parts = octets.compactMap { Int($0) }
        guard parts.count == 4 else { return false }

        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (169, 254), (192, 168):
            return true
        case (172, 16...31):
            return true
        default:
            return false
        }
    }
}
#else
import Foundation
import SwiftUI
@MainActor final class AppState: ObservableObject {}
#endif
