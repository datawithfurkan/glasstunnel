import Foundation
import GTProtocol
import GTSecurity
import WebRTC
#if os(macOS)
import OSLog
#endif

#if os(macOS)
private let sessionRemoteAppLogger = Logger(subsystem: "io.glasstunnel.host", category: "RemoteApps")
#endif

public typealias ScreenPointerInputHandler = @MainActor @Sendable (ScreenPointerInput) async throws -> Void

/// Top-level orchestrator for the Mac host's tunneling lifecycle.
///
/// Owns:
/// - a single `SignalingClient` connection to the signaling server
/// - one `Session` per currently-connected phone (one phone in v0.1 but the
///   API is ready for more)
///
/// Lifecycle:
///   `start()` -> connects to signaling, authenticates, and starts listening.
///   `stop()` tears everything down.
@MainActor
public final class SessionManager {
    public enum State: Sendable {
        case idle
        case connecting
        case connected
        case error(String)
    }

    public struct HostIdentity: Sendable {
        public let linked: Bool
        public let userID: String?
        public let email: String?
        public let displayName: String?
        public let avatarURL: String?
    }

    public struct LinkCode: Sendable {
        public let code: String
        public let expiresAt: Date?
    }

    public struct ApprovalRequest: Sendable, Identifiable {
        public let id: String
        public let requesterDeviceID: DeviceID
        public let requesterPublicKeyB64: String
        public let requesterLabel: String
        public let requestedAt: Date?
    }

    public var onState: (@Sendable (State) -> Void)?
    public var onPaired: (@Sendable (DeviceRegistry.PairedDevice) -> Void)?
    public var onPeerConnected: (@Sendable (DeviceID) -> Void)?
    public var onPeerDisconnected: (@Sendable (DeviceID) -> Void)?
    public var onHostIdentity: (@Sendable (HostIdentity) -> Void)?
    public var onLinkCode: (@Sendable (LinkCode) -> Void)?
    public var onApprovalRequested: (@Sendable (ApprovalRequest) -> Void)?
    public var onAgentState: (@Sendable (AgentStateSnapshot) -> Void)?

    public let signalingURL: URL
    public let turnURL: String
    public let turnUsername: String?
    public let turnPassword: String?
    public let hostDeviceLabel: String

    private let deviceKey: DeviceKey
    private let registry: DeviceRegistry
    private let autoLock: AutoLock
    private let redactor: SecretRedactor
    private let remoteAppController: RemoteAppController
    private let screenPointerInputHandler: ScreenPointerInputHandler?
    #if os(macOS)
    private let relayScreenCaptureFactory: RelayScreenCaptureFactory
    #endif

    private var signaling: SignalingClient?
    private var relay: RelayClient?
    private var sessions: [DeviceID: Session] = [:]
    private var currentRemoteApps: [RemoteApp] = []
    private var relayImageTransfers: [String: PendingRelayImageTransfer] = [:]
    private var relayFileAttachmentBatches: [String: PendingRelayFileAttachmentBatch] = [:]
    #if os(macOS)
    private var relayScreenCapture: (any RelayScreenCapturing)?
    private lazy var relayScreenCaptureReconciler = AsyncLatestStateReconciler<RemoteAppActionRequest.ScreenQuality?>(
        initialValue: nil
    ) { [weak self] quality in
        await self?.reconcileRelayScreenCapture(quality: quality)
    }
    #endif
    private var pendingLinkCodeContinuation: CheckedContinuation<LinkCode, Error>?
    private var pendingUnlinkContinuation: CheckedContinuation<Void, Error>?
    private var pendingLinkCodeTimeout: Timer?
    private var pendingUnlinkTimeout: Timer?
    private var shouldReconnect = false
    private var reconnectTask: Task<Void, Never>?
    private var relayReconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var relayReconnectAttempt = 0
    private let reconnectMaxDelaySeconds = 5 * 60.0

    public init(
        deviceKey: DeviceKey,
        signalingURL: URL,
        turnURL: String,
        turnUsername: String? = nil,
        turnPassword: String? = nil,
        hostDeviceLabel: String,
        autoLock: AutoLock = AutoLock(),
        redactor: SecretRedactor = SecretRedactor(),
        registry: DeviceRegistry = .shared,
        remoteAppController: RemoteAppController,
        screenPointerInputHandler: ScreenPointerInputHandler? = nil,
        relayScreenCaptureFactory: RelayScreenCaptureFactory? = nil
    ) {
        self.deviceKey = deviceKey
        self.signalingURL = signalingURL
        self.turnURL = turnURL
        self.turnUsername = turnUsername
        self.turnPassword = turnPassword
        self.hostDeviceLabel = hostDeviceLabel
        self.autoLock = autoLock
        self.redactor = redactor
        self.registry = registry
        self.remoteAppController = remoteAppController
        self.screenPointerInputHandler = screenPointerInputHandler
        #if os(macOS)
        self.relayScreenCaptureFactory = relayScreenCaptureFactory ?? { agentId, relay, quality in
            RelayScreenCapture(agentId: agentId, relay: relay, quality: quality)
        }
        #endif
        self.currentRemoteApps = remoteAppController.remoteAppsSnapshot()
    }

    public func start() async throws {
        shouldReconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        relayReconnectTask?.cancel()
        relayReconnectTask = nil
        reconnectAttempt = 0
        relayReconnectAttempt = 0
        var relayError: Error?
        do {
            try await connectRelay()
        } catch {
            relayError = error
            scheduleRelayReconnect(after: error)
        }
        do {
            try await connectSignaling()
        } catch {
            scheduleReconnect(after: error)
            if relay == nil {
                throw relayError ?? error
            }
        }
    }

    private func connectRelay() async throws {
        relay?.onState = nil
        relay?.onCommand = nil
        relay?.disconnect()

        let relayURL = RelayClient.relayURL(from: signalingURL, hostDeviceId: deviceKey.deviceId)
        let relay = RelayClient(url: relayURL, deviceKey: deviceKey, deviceLabel: hostDeviceLabel)
        self.relay = relay

        relay.onState = { [weak self] state in
            guard let manager = self else { return }
            Task { @MainActor [manager] in
                switch state {
                case .disconnected:
                    manager.handleRelayDropped(reason: "Relay disconnected")
                case .connecting:
                    manager.onState?(.connecting)
                case .authenticated:
                    manager.relayReconnectAttempt = 0
                    manager.onState?(.connected)
                case .error(let message):
                    manager.handleRelayDropped(reason: message)
                }
            }
        }
        relay.onCommand = { [weak self] message, clientDeviceID in
            guard let manager = self else { return }
            Task { @MainActor [manager] in
                manager.handleRelayCommand(message, from: clientDeviceID)
            }
        }

        do {
            try await relay.connect()
            relayReconnectAttempt = 0
            onState?(.connected)
            try await publishInitialRelayState(using: relay)
        } catch {
            self.relay = nil
            throw error
        }
    }

    private func publishInitialRelayState(using relay: RelayClient) async throws {
        currentRemoteApps = remoteAppController.remoteAppsSnapshot()
        try await relay.publishHello(makeHello())
        try await relay.publishRemoteApps(currentRemoteApps)
        for snapshot in remoteAppController.cachedSnapshots() {
            try await relay.publishAgentState(snapshot)
        }
    }

    private func makeHello() -> Hello {
        Hello(
            hostVersion: GlasstunnelProtocol.version,
            hostOsVersion: hostOSVersion(),
            hostDeviceLabel: hostDeviceLabel,
            supportedAdapters: AdapterKind.advertisedDisplayNames,
            currentLayout: remoteAppController.deprecatedLayout(),
            remoteApps: currentRemoteApps
        )
    }

    private func hostOSVersion() -> String {
        #if os(macOS)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #else
        return "unknown"
        #endif
    }

    private func publishRelayHello() {
        guard let relay else { return }
        let hello = makeHello()
        Task { [relay] in
            try? await relay.publishHello(hello)
        }
    }

    private func publishRelayRemoteApps(_ remoteApps: [RemoteApp]) {
        guard let relay else { return }
        Task { [relay, remoteApps] in
            try? await relay.publishRemoteApps(remoteApps)
        }
    }

    private func publishRelayAgentState(_ snapshot: AgentStateSnapshot) {
        guard let relay else { return }
        Task { [relay, snapshot] in
            try? await relay.publishAgentState(snapshot)
        }
    }

    private func connectSignaling() async throws {
        onState?(.connecting)

        signaling?.onState = nil
        signaling?.onEnvelope = nil
        signaling?.onControlMessage = nil
        signaling?.disconnect()

        let signaling = SignalingClient(url: signalingURL, deviceKey: deviceKey, role: "host", deviceLabel: hostDeviceLabel)

        signaling.onState = { [weak self] state in
            guard let manager = self else { return }
            Task { @MainActor [manager] in
                switch state {
                case .disconnected:
                    manager.handleSignalingDropped(reason: "Signaling disconnected")
                case .connecting:
                    manager.onState?(.connecting)
                case .authenticated:
                    manager.reconnectAttempt = 0
                    manager.onState?(.connected)
                case .error(let message):
                    manager.handleSignalingDropped(reason: message)
                }
            }
        }

        signaling.onEnvelope = { [weak self] env in
            guard let manager = self else { return }
            Task { @MainActor [manager] in
                manager.handleEnvelope(env)
            }
        }
        signaling.onControlMessage = { [weak self] msg in
            guard let manager = self else { return }
            guard let messageData = try? JSONSerialization.data(withJSONObject: msg) else { return }
            Task { @MainActor [manager, messageData] in
                guard let controlMessage = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
                    return
                }
                manager.handleControlMessage(controlMessage)
            }
        }

        try await signaling.connect()
        self.signaling = signaling
    }

    public func stop() {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        relayReconnectTask?.cancel()
        relayReconnectTask = nil
        let activeIDs = Array(sessions.keys)
        for (_, s) in sessions { s.stop() }
        sessions.removeAll()
        for id in activeIDs {
            onPeerDisconnected?(id)
        }
        stopRelayScreenCapture()
        if let pendingLinkCodeContinuation {
            self.pendingLinkCodeContinuation = nil
            pendingLinkCodeTimeout?.invalidate()
            pendingLinkCodeTimeout = nil
            pendingLinkCodeContinuation.resume(throwing: NSError(
                domain: "SessionManager",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "Link code generation was cancelled."]
            ))
        }
        if let pendingUnlinkContinuation {
            self.pendingUnlinkContinuation = nil
            pendingUnlinkTimeout?.invalidate()
            pendingUnlinkTimeout = nil
            pendingUnlinkContinuation.resume(throwing: NSError(
                domain: "SessionManager",
                code: -7,
                userInfo: [NSLocalizedDescriptionKey: "Sign out was cancelled."]
            ))
        }
        signaling?.disconnect()
        signaling = nil
        relay?.disconnect()
        relay = nil
        onState?(.idle)
    }

    private func handleSignalingDropped(reason: String) {
        signaling = nil
        guard shouldReconnect else {
            onState?(.idle)
            return
        }
        if relay != nil {
            onState?(.connected)
        } else {
            onState?(.connecting)
        }
        scheduleReconnect(after: NSError(
            domain: "SessionManager",
            code: -10,
            userInfo: [NSLocalizedDescriptionKey: reason]
        ))
    }

    private func handleRelayDropped(reason: String) {
        relay = nil
        guard shouldReconnect else {
            onState?(.idle)
            return
        }
        onState?(.connecting)
        scheduleRelayReconnect(after: NSError(
            domain: "SessionManager",
            code: -11,
            userInfo: [NSLocalizedDescriptionKey: reason]
        ))
    }

    private func scheduleReconnect(after _: Error) {
        guard shouldReconnect, reconnectTask == nil else { return }
        let baseDelaySeconds = min(pow(2.0, Double(reconnectAttempt)), reconnectMaxDelaySeconds)
        let jitterSeconds = Double.random(in: 0...(baseDelaySeconds * 0.2))
        let delaySeconds = baseDelaySeconds + jitterSeconds
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            let nanoseconds = UInt64(delaySeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.reconnectSignaling()
        }
    }

    private func reconnectSignaling() async {
        guard shouldReconnect else { return }
        reconnectTask = nil
        do {
            try await connectSignaling()
        } catch {
            onState?(.connecting)
            scheduleReconnect(after: error)
        }
    }

    private func scheduleRelayReconnect(after _: Error) {
        guard shouldReconnect, relayReconnectTask == nil else { return }
        let baseDelaySeconds = min(pow(2.0, Double(relayReconnectAttempt)), reconnectMaxDelaySeconds)
        let jitterSeconds = Double.random(in: 0...(baseDelaySeconds * 0.2))
        let delaySeconds = baseDelaySeconds + jitterSeconds
        relayReconnectAttempt += 1
        relayReconnectTask = Task { [weak self] in
            let nanoseconds = UInt64(delaySeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.reconnectRelay()
        }
    }

    private func reconnectRelay() async {
        guard shouldReconnect else { return }
        relayReconnectTask = nil
        do {
            try await connectRelay()
        } catch {
            onState?(.connecting)
            scheduleRelayReconnect(after: error)
        }
    }

    public func createAccountLinkCode() async throws -> LinkCode {
        guard let signaling else { throw NSError(domain: "SessionManager", code: -1) }
        if pendingLinkCodeContinuation != nil {
            throw NSError(domain: "SessionManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Link code generation already in progress."])
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingLinkCodeContinuation = continuation
            pendingLinkCodeTimeout?.invalidate()
            pendingLinkCodeTimeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                guard let manager = self else { return }
                Task { @MainActor [manager] in
                    guard let pending = manager.pendingLinkCodeContinuation else { return }
                    manager.pendingLinkCodeContinuation = nil
                    manager.pendingLinkCodeTimeout?.invalidate()
                    manager.pendingLinkCodeTimeout = nil
                    pending.resume(throwing: NSError(
                        domain: "SessionManager",
                        code: -8,
                        userInfo: [NSLocalizedDescriptionKey: "Link code generation timed out."]
                    ))
                }
            }
            let manager = self
            Task { @MainActor [manager] in
                do {
                    try await signaling.sendControlMessage([
                        "type": "create_link_code",
                        "host_label": manager.hostDeviceLabel,
                        "signaling_url": manager.signalingURL.absoluteString,
                        "turn_url": manager.turnURL,
                        "turn_username": manager.turnUsername ?? "",
                        "turn_password": manager.turnPassword ?? "",
                    ])
                } catch {
                    let pending = manager.pendingLinkCodeContinuation
                    manager.pendingLinkCodeContinuation = nil
                    manager.pendingLinkCodeTimeout?.invalidate()
                    manager.pendingLinkCodeTimeout = nil
                    pending?.resume(throwing: error)
                }
            }
        }
    }

    public func recordApprovalDecision(requestID: String, approved: Bool) async throws {
        guard let signaling else { throw NSError(domain: "SessionManager", code: -1) }
        try await signaling.sendControlMessage([
            "type": "approval_decision",
            "request_id": requestID,
            "approved": approved,
        ])
    }

    public func unlinkHost() async throws {
        guard let signaling else { throw NSError(domain: "SessionManager", code: -1) }
        if pendingUnlinkContinuation != nil {
            throw NSError(domain: "SessionManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "Host unlink already in progress."])
        }

        try await withCheckedThrowingContinuation { continuation in
            pendingUnlinkContinuation = continuation
            pendingUnlinkTimeout?.invalidate()
            pendingUnlinkTimeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                guard let manager = self else { return }
                Task { @MainActor [manager] in
                    guard let pending = manager.pendingUnlinkContinuation else { return }
                    manager.pendingUnlinkContinuation = nil
                    manager.pendingUnlinkTimeout?.invalidate()
                    manager.pendingUnlinkTimeout = nil
                    pending.resume(throwing: NSError(
                        domain: "SessionManager",
                        code: -9,
                        userInfo: [NSLocalizedDescriptionKey: "Host unlink timed out."]
                    ))
                }
            }
            let manager = self
            Task { @MainActor [manager] in
                do {
                    try await signaling.sendControlMessage([
                        "type": "unlink_host",
                    ])
                } catch {
                    let pending = manager.pendingUnlinkContinuation
                    manager.pendingUnlinkContinuation = nil
                    manager.pendingUnlinkTimeout?.invalidate()
                    manager.pendingUnlinkTimeout = nil
                    pending?.resume(throwing: error)
                }
            }
        }
    }

    public func applyRemoteApps(_ remoteApps: [RemoteApp]) {
        currentRemoteApps = remoteApps
        if remoteApps.first(where: { $0.remoteAppId == "screen" })?.enabled == false {
            stopRelayScreenCapture()
        }
        for (_, session) in sessions {
            session.applyRemoteApps(remoteApps)
        }
        publishRelayRemoteApps(remoteApps)
        publishRelayHello()
    }

    public func broadcastAgentState(_ snapshot: AgentStateSnapshot) {
        for (_, session) in sessions {
            session.sendAgentState(snapshot)
        }
        publishRelayAgentState(snapshot)
    }

    public func sessionCount() -> Int { sessions.count }

    // MARK: - Relay command routing

    private func handleRelayCommand(_ msg: DataChannelMessage, from _: DeviceID?) {
        autoLock.heartbeat()

        switch msg.body {
        case .userInput(let input):
            sendRelayInputToRemoteApp(
                agentId: input.agentId,
                text: input.text,
                submit: input.submitOnSend,
                failureLabel: "message"
            )
        case .quickReply(let reply):
            sendRelayInputToRemoteApp(
                agentId: reply.agentId,
                text: reply.kind.literalText,
                submit: true,
                failureLabel: "quick reply"
            )
        case .interruptRequest(let request):
            guard canPerformRelaySessionAction(agentId: request.agentId) else { return }
            Task { [weak self, controller = remoteAppController, agentId = request.agentId] in
                do {
                    try await controller.interrupt(agentId: agentId)
                } catch {
                    let reason = String(describing: error)
                    await MainActor.run {
                        self?.emitRelaySystemMessage(agentId: agentId, text: "interrupt failed: \(reason)")
                    }
                }
            }
        case .targetSelectionRequest(let request):
            guard canPerformRelaySessionAction(agentId: request.agentId) else { return }
            Task { [weak self, controller = remoteAppController, agentId = request.agentId, targetId = request.targetId] in
                do {
                    try await controller.selectTarget(agentId: agentId, targetId: targetId)
                } catch {
                    let reason = String(describing: error)
                    await MainActor.run {
                        self?.emitRelaySystemMessage(agentId: agentId, text: "switch failed: \(reason)")
                    }
                }
            }
        case .targetRenameRequest(let request):
            guard canPerformRelaySessionAction(agentId: request.agentId) else { return }
            Task { [weak self, controller = remoteAppController, request] in
                do {
                    try await controller.renameTarget(request)
                } catch {
                    let reason = String(describing: error)
                    await MainActor.run {
                        self?.emitRelaySystemMessage(agentId: request.agentId, text: "rename failed: \(reason)")
                    }
                }
            }
        case .agentRuntimeSettingsUpdate(let update):
            guard canPerformRelaySessionAction(agentId: update.agentId) else { return }
            Task { [weak self, controller = remoteAppController, update] in
                do {
                    try await controller.updateRuntimeSettings(update)
                } catch {
                    let reason = String(describing: error)
                    await MainActor.run {
                        self?.emitRelaySystemMessage(agentId: update.agentId, text: "settings failed: \(reason)")
                    }
                }
            }
        case .remoteAppActionRequest(let request):
            handleRemoteAppActionRequest(request)
        case .inputRequestResponse(let response):
            #if os(macOS)
            sessionRemoteAppLogger.info("remote app input response received agentId=\(response.agentId, privacy: .public) requestId=\(response.requestId, privacy: .public) answers=\(response.answers.count, privacy: .public)")
            #endif
            guard canAcceptRelayInput(agentId: response.agentId) else {
                #if os(macOS)
                sessionRemoteAppLogger.notice("remote app input response rejected agentId=\(response.agentId, privacy: .public) requestId=\(response.requestId, privacy: .public)")
                #endif
                return
            }
            Task { [weak self, controller = remoteAppController, response] in
                do {
                    try await controller.respondToInputRequest(response)
                    #if os(macOS)
                    sessionRemoteAppLogger.info("remote app input response accepted agentId=\(response.agentId, privacy: .public) requestId=\(response.requestId, privacy: .public)")
                    #endif
                } catch {
                    let reason = String(describing: error)
                    #if os(macOS)
                    sessionRemoteAppLogger.error("remote app input response failed agentId=\(response.agentId, privacy: .public) requestId=\(response.requestId, privacy: .public) error=\(String(describing: error), privacy: .private)")
                    #endif
                    await MainActor.run {
                        self?.emitRelaySystemMessage(agentId: response.agentId, text: "choice not sent: \(reason)")
                    }
                }
            }
        case .screenPointerInput(let input):
            guard canAcceptRelayInput(agentId: input.agentId) else { return }
            Task { @MainActor [weak self, controller = remoteAppController, screenPointerInputHandler, input] in
                do {
                    if let screenPointerInputHandler {
                        try await screenPointerInputHandler(input)
                    } else {
                        try await controller.performScreenPointerInput(input)
                    }
                } catch {
                    let reason = String(describing: error)
                    self?.emitRelaySystemMessage(agentId: input.agentId, text: "tap failed: \(reason)")
                }
            }
        case .readOnlyModeUpdate(let update):
            autoLock.setReadOnly(update.readOnly)
            publishRelayHello()
        case .heartbeatPing:
            publishRelayHello()
            publishRelayRemoteApps(currentRemoteApps)
        case .imageAttachmentInput(let input):
            guard canAcceptRelayInput(agentId: input.agentId) else { return }
            Task { [weak self] in
                await self?.handleRelayImageAttachment(input)
            }
        case .imageAttachmentChunk(let chunk):
            guard canAcceptRelayInput(agentId: chunk.agentId) else { return }
            Task { [weak self] in
                await self?.handleRelayImageAttachmentChunk(chunk)
            }
        case .fileAttachmentChunk(let chunk):
            guard canAcceptRelayInput(agentId: chunk.agentId) else { return }
            Task { [weak self] in
                await self?.handleRelayFileAttachmentChunk(chunk)
            }
        case .hello,
             .agentState,
             .agentChatMessage,
             .gridLayoutUpdate,
             .remoteAppsUpdate,
             .heartbeatPong,
             .videoTrackHint,
             .redactionPolicyUpdate:
            break
        }
    }

    private func handleRemoteAppActionRequest(_ request: RemoteAppActionRequest) {
        let agentId = RemoteAppDefinition.definition(for: request.remoteAppId)?.agentId ?? request.remoteAppId
        #if os(macOS)
        sessionRemoteAppLogger.info("remote app action received remoteAppId=\(request.remoteAppId, privacy: .public) agentId=\(agentId, privacy: .public) action=\(request.action.rawValue, privacy: .public)")
        #endif
        guard canPerformRelayRemoteAppAction(agentId: agentId, action: request.action) else {
            #if os(macOS)
            sessionRemoteAppLogger.notice("remote app action rejected remoteAppId=\(request.remoteAppId, privacy: .public) agentId=\(agentId, privacy: .public) action=\(request.action.rawValue, privacy: .public)")
            #endif
            return
        }
        let isScreenAction = request.remoteAppId == "screen" || agentId == "screen"
        #if os(macOS)
        sessionRemoteAppLogger.info("remote app action accepted remoteAppId=\(request.remoteAppId, privacy: .public) agentId=\(agentId, privacy: .public) action=\(request.action.rawValue, privacy: .public)")
        #endif

        Task { @MainActor [weak self, controller = remoteAppController, request, agentId, isScreenAction] in
            do {
                try await controller.performRemoteAppAction(request)
                if isScreenAction {
                    await self?.handleRelayScreenAction(request)
                }
            } catch {
                #if os(macOS)
                sessionRemoteAppLogger.error("remote app action failed remoteAppId=\(request.remoteAppId, privacy: .public) agentId=\(agentId, privacy: .public) action=\(request.action.rawValue, privacy: .public) error=\(String(describing: error), privacy: .private)")
                #endif
                let reason = String(describing: error)
                self?.emitRelaySystemMessage(agentId: agentId, text: "app action failed: \(reason)")
            }
        }
    }

    private func handleRelayScreenAction(_ request: RemoteAppActionRequest) async {
        #if os(macOS)
        switch request.action {
        case .disable, .stop, .closeSession:
            stopRelayScreenCapture()
            await relayScreenCaptureReconciler.waitUntilSettled()
        case .enable, .start, .launch, .newSession:
            await startRelayScreenCapture(
                quality: request.screenQuality ?? .readable
            )
        }
        #endif
    }

    private func startRelayScreenCapture(
        quality: RemoteAppActionRequest.ScreenQuality = .readable
    ) async {
        #if os(macOS)
        relayScreenCaptureReconciler.setDesired(quality)
        await relayScreenCaptureReconciler.waitUntilSettled()
        #endif
    }

    private func stopRelayScreenCapture() {
        #if os(macOS)
        relayScreenCaptureReconciler.setDesired(nil)
        #endif
    }

    #if os(macOS)
    private func reconcileRelayScreenCapture(
        quality: RemoteAppActionRequest.ScreenQuality?
    ) async {
        guard let quality, let relay else {
            let capture = relayScreenCapture
            relayScreenCapture = nil
            await capture?.stop()
            return
        }

        if let capture = relayScreenCapture, capture.uses(relay: relay, quality: quality) {
            await startRelayCapture(capture, quality: quality)
            return
        }

        let previousCapture = relayScreenCapture
        relayScreenCapture = nil
        await previousCapture?.stop()

        guard relayScreenCaptureReconciler.desiredValue == quality, self.relay === relay else {
            return
        }
        let capture = relayScreenCaptureFactory("screen", relay, quality)
        relayScreenCapture = capture
        await startRelayCapture(capture, quality: quality)
    }

    private func startRelayCapture(
        _ capture: any RelayScreenCapturing,
        quality: RemoteAppActionRequest.ScreenQuality
    ) async {
        do {
            try await capture.start()
            guard relayScreenCapture === capture,
                  relayScreenCaptureReconciler.desiredValue == quality else {
                return
            }
            let qualityLabel = quality == .readable ? "readable" : "fast"
            remoteAppController.publishRemoteAppStatus(
                remoteAppId: "screen",
                status: .idle,
                detail: "Screen streaming",
                text: "Mac Screen is streaming in \(qualityLabel) mode."
            )
        } catch {
            if relayScreenCapture === capture {
                relayScreenCapture = nil
            }
            await capture.stop()
            guard relayScreenCaptureReconciler.desiredValue == quality else { return }
            remoteAppController.publishRemoteAppStatus(
                remoteAppId: "screen",
                status: .error,
                detail: "Screen unavailable",
                text: "Could not start Mac Screen. Allow Screen Recording for Glasstunnel in System Settings, then retry screen. \(error.localizedDescription)"
            )
            emitRelaySystemMessage(
                agentId: "screen",
                text: "screen fallback failed: \(error.localizedDescription)"
            )
        }
    }
    #endif

    private func sendRelayInputToRemoteApp(
        agentId: AgentID,
        text: String,
        submit: Bool,
        failureLabel: String
    ) {
        guard canAcceptRelayInput(agentId: agentId) else { return }

        Task { [weak self, controller = remoteAppController, agentId, text, submit, failureLabel] in
            do {
                try await controller.sendInput(agentId: agentId, text: text, submit: submit)
            } catch {
                let reason = String(describing: error)
                await MainActor.run {
                    self?.emitRelaySystemMessage(agentId: agentId, text: "\(failureLabel) not sent: \(reason)")
                }
            }
        }
    }

    private func handleRelayImageAttachment(_ input: ImageAttachmentInput) async {
        do {
            let fileURL = try persistRelayImageAttachment(input)
            let prompt = relayAttachmentPrompt(userText: input.text, fileURL: fileURL)
            try await remoteAppController.sendInput(
                agentId: input.agentId,
                text: prompt,
                submit: input.submitOnSend
            )
        } catch {
            emitRelaySystemMessage(agentId: input.agentId, text: "image upload failed: \(error.localizedDescription)")
        }
    }

    private func handleRelayImageAttachmentChunk(_ chunk: ImageAttachmentChunk) async {
        do {
            cleanupStaleRelayImageTransfers()
            if let input = try receiveRelayImageAttachmentChunk(chunk) {
                await handleRelayImageAttachment(input)
            }
        } catch {
            relayImageTransfers.removeValue(forKey: chunk.transferId)
            emitRelaySystemMessage(agentId: chunk.agentId, text: "image upload failed: \(error.localizedDescription)")
        }
    }

    private func handleRelayFileAttachmentChunk(_ chunk: FileAttachmentChunk) async {
        do {
            cleanupStaleRelayFileAttachmentBatches()
            if let batch = try receiveRelayFileAttachmentChunk(chunk) {
                let prompt = relayAttachmentPrompt(userText: batch.text, fileURLs: batch.fileURLs)
                try await remoteAppController.sendInput(
                    agentId: batch.agentId,
                    text: prompt,
                    submit: batch.submitOnSend
                )
            }
        } catch {
            relayFileAttachmentBatches.removeValue(forKey: chunk.batchId)
            emitRelaySystemMessage(agentId: chunk.agentId, text: "file upload failed: \(error.localizedDescription)")
        }
    }

    private func receiveRelayImageAttachmentChunk(_ chunk: ImageAttachmentChunk) throws -> ImageAttachmentInput? {
        guard chunk.totalBytes > 0 else {
            throw RelayAttachmentError.invalidChunk("missing total size")
        }
        guard chunk.totalBytes <= Self.maxRelayAttachmentBytes else {
            throw RelayAttachmentError.tooLarge(limit: Self.maxRelayAttachmentBytes)
        }
        guard chunk.chunkCount > 0, chunk.chunkCount <= Self.maxRelayAttachmentChunks else {
            throw RelayAttachmentError.invalidChunk("invalid chunk count")
        }
        guard chunk.chunkIndex >= 0, chunk.chunkIndex < chunk.chunkCount else {
            throw RelayAttachmentError.invalidChunk("invalid chunk index")
        }
        guard !chunk.bytes.isEmpty else {
            throw RelayAttachmentError.invalidChunk("empty chunk")
        }

        var transfer = relayImageTransfers[chunk.transferId] ?? PendingRelayImageTransfer(
            transferId: chunk.transferId,
            agentId: chunk.agentId,
            text: chunk.text,
            filename: chunk.filename,
            mimeType: chunk.mimeType,
            totalBytes: chunk.totalBytes,
            chunkCount: chunk.chunkCount,
            submitOnSend: chunk.submitOnSend
        )
        guard transfer.matches(chunk) else {
            throw RelayAttachmentError.invalidChunk("inconsistent transfer metadata")
        }

        transfer.chunks[chunk.chunkIndex] = chunk.bytes
        guard transfer.receivedBytes <= transfer.totalBytes else {
            throw RelayAttachmentError.invalidChunk("received too many bytes")
        }

        relayImageTransfers[chunk.transferId] = transfer
        guard transfer.isComplete else { return nil }

        var bytes = Data()
        bytes.reserveCapacity(transfer.totalBytes)
        for index in 0..<transfer.chunkCount {
            guard let piece = transfer.chunks[index] else { return nil }
            bytes.append(piece)
        }
        guard bytes.count == transfer.totalBytes else {
            throw RelayAttachmentError.invalidChunk("assembled size mismatch")
        }

        relayImageTransfers.removeValue(forKey: chunk.transferId)
        return ImageAttachmentInput(
            agentId: transfer.agentId,
            text: transfer.text,
            filename: transfer.filename,
            mimeType: transfer.mimeType,
            bytes: bytes,
            submitOnSend: transfer.submitOnSend
        )
    }

    private func receiveRelayFileAttachmentChunk(_ chunk: FileAttachmentChunk) throws -> RelayFileAttachmentBatchInput? {
        guard chunk.totalBytes > 0 else {
            throw RelayAttachmentError.invalidChunk("missing total size")
        }
        guard chunk.totalBytes <= Self.maxRelayAttachmentBytes else {
            throw RelayAttachmentError.tooLarge(limit: Self.maxRelayAttachmentBytes)
        }
        guard chunk.fileCount > 0, chunk.fileCount <= Self.maxRelayAttachmentFiles else {
            throw RelayAttachmentError.invalidChunk("invalid file count")
        }
        guard chunk.fileIndex >= 0, chunk.fileIndex < chunk.fileCount else {
            throw RelayAttachmentError.invalidChunk("invalid file index")
        }
        guard chunk.chunkCount > 0, chunk.chunkCount <= Self.maxRelayAttachmentChunks else {
            throw RelayAttachmentError.invalidChunk("invalid chunk count")
        }
        guard chunk.chunkIndex >= 0, chunk.chunkIndex < chunk.chunkCount else {
            throw RelayAttachmentError.invalidChunk("invalid chunk index")
        }
        guard !chunk.bytes.isEmpty else {
            throw RelayAttachmentError.invalidChunk("empty chunk")
        }

        var batch = relayFileAttachmentBatches[chunk.batchId] ?? PendingRelayFileAttachmentBatch(
            batchId: chunk.batchId,
            agentId: chunk.agentId,
            text: chunk.text,
            fileCount: chunk.fileCount,
            submitOnSend: chunk.submitOnSend
        )
        guard batch.matches(chunk) else {
            throw RelayAttachmentError.invalidChunk("inconsistent batch metadata")
        }

        var transfer = batch.transfers[chunk.fileIndex] ?? PendingRelayFileTransfer(
            transferId: chunk.transferId,
            fileIndex: chunk.fileIndex,
            filename: chunk.filename,
            mimeType: chunk.mimeType,
            totalBytes: chunk.totalBytes,
            chunkCount: chunk.chunkCount
        )
        guard transfer.matches(chunk) else {
            throw RelayAttachmentError.invalidChunk("inconsistent file metadata")
        }
        guard batch.declaredBytes(replacing: transfer) <= Self.maxRelayAttachmentBatchBytes else {
            throw RelayAttachmentError.batchTooLarge(limit: Self.maxRelayAttachmentBatchBytes)
        }

        transfer.chunks[chunk.chunkIndex] = chunk.bytes
        guard transfer.receivedBytes <= transfer.totalBytes else {
            throw RelayAttachmentError.invalidChunk("received too many bytes")
        }

        if transfer.isComplete, batch.fileURLs[chunk.fileIndex] == nil {
            let bytes = try assembleRelayFileTransfer(transfer)
            let fileURL = try persistRelayAttachment(
                filename: transfer.filename,
                mimeType: transfer.mimeType,
                bytes: bytes
            )
            batch.fileURLs[chunk.fileIndex] = fileURL
        }

        batch.transfers[chunk.fileIndex] = transfer
        relayFileAttachmentBatches[chunk.batchId] = batch
        guard batch.isComplete else { return nil }

        let urls = (0..<batch.fileCount).compactMap { batch.fileURLs[$0] }
        guard urls.count == batch.fileCount else { return nil }

        relayFileAttachmentBatches.removeValue(forKey: chunk.batchId)
        return RelayFileAttachmentBatchInput(
            agentId: batch.agentId,
            text: batch.text,
            fileURLs: urls,
            submitOnSend: batch.submitOnSend
        )
    }

    private func assembleRelayFileTransfer(_ transfer: PendingRelayFileTransfer) throws -> Data {
        var bytes = Data()
        bytes.reserveCapacity(transfer.totalBytes)
        for index in 0..<transfer.chunkCount {
            guard let piece = transfer.chunks[index] else {
                throw RelayAttachmentError.invalidChunk("missing chunk")
            }
            bytes.append(piece)
        }
        guard bytes.count == transfer.totalBytes else {
            throw RelayAttachmentError.invalidChunk("assembled size mismatch")
        }
        return bytes
    }

    private func cleanupStaleRelayImageTransfers() {
        let cutoff = Date().addingTimeInterval(-Self.relayAttachmentTransferTTL)
        relayImageTransfers = relayImageTransfers.filter { _, transfer in
            transfer.createdAt >= cutoff
        }
    }

    private func cleanupStaleRelayFileAttachmentBatches() {
        let cutoff = Date().addingTimeInterval(-Self.relayAttachmentTransferTTL)
        relayFileAttachmentBatches = relayFileAttachmentBatches.filter { _, batch in
            batch.createdAt >= cutoff
        }
    }

    private func persistRelayImageAttachment(_ input: ImageAttachmentInput) throws -> URL {
        return try persistRelayAttachment(
            filename: input.filename,
            mimeType: input.mimeType,
            bytes: input.bytes
        )
    }

    private func persistRelayAttachment(filename: String, mimeType: String, bytes: Data) throws -> URL {
        guard !bytes.isEmpty else { throw RelayAttachmentError.emptyPayload }
        if bytes.count > Self.maxRelayAttachmentBytes {
            throw RelayAttachmentError.tooLarge(limit: Self.maxRelayAttachmentBytes)
        }

        let fm = FileManager.default
        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("Glasstunnel", isDirectory: true)
            .appendingPathComponent("Uploads", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let ext = relayFileExtension(mimeType: mimeType, filename: filename)
        let stem = sanitizedRelayStem(for: filename)
        let timestamp = Self.relayAttachmentTimestampFormatter.string(from: Date())
        let nonce = UUID().uuidString.prefix(8).lowercased()
        let fileURL = directory.appendingPathComponent("\(timestamp)-\(stem)-\(nonce).\(ext)")
        try bytes.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func relayAttachmentPrompt(userText: String, fileURL: URL) -> String {
        return relayAttachmentPrompt(userText: userText, fileURLs: [fileURL])
    }

    private func relayAttachmentPrompt(userText: String, fileURLs: [URL]) -> String {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let note: String
        if fileURLs.count == 1, let location = fileURLs.first?.path {
            note = "Attached file on this Mac: \(location)"
        } else {
            let locations = fileURLs.map { "- \($0.path)" }.joined(separator: "\n")
            note = "Attached files on this Mac:\n\(locations)"
        }
        if trimmed.isEmpty {
            return fileURLs.count == 1
                ? "Please inspect this uploaded file.\n\(note)"
                : "Please inspect these uploaded files.\n\(note)"
        }
        return "\(trimmed)\n\n\(note)"
    }

    private func relayFileExtension(mimeType: String, filename: String) -> String {
        let raw = URL(fileURLWithPath: filename).pathExtension.lowercased()
        let filtered = String(raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.prefix(12))
        if !filtered.isEmpty { return filtered }

        switch mimeType.lowercased() {
        case "application/gzip": return "gz"
        case "application/json": return "json"
        case "application/jsonl": return "jsonl"
        case "application/msword": return "doc"
        case "application/pdf": return "pdf"
        case "application/postscript": return "ai"
        case "application/rtf": return "rtf"
        case "application/vnd.apple.keynote": return "key"
        case "application/vnd.apple.numbers": return "numbers"
        case "application/vnd.apple.pages": return "pages"
        case "application/vnd.ms-excel": return "xls"
        case "application/vnd.ms-powerpoint": return "ppt"
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation": return "pptx"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": return "xlsx"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": return "docx"
        case "application/x-tar": return "tar"
        case "application/xml": return "xml"
        case "application/yaml": return "yaml"
        case "application/zip": return "zip"
        case "audio/aiff": return "aiff"
        case "audio/mpeg": return "mp3"
        case "audio/mp4": return "m4a"
        case "audio/wav": return "wav"
        case "image/bmp": return "bmp"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/svg+xml": return "svg"
        case "text/css": return "css"
        case "text/csv": return "csv"
        case "text/html": return "html"
        case "text/javascript": return "js"
        case "text/markdown": return "md"
        case "text/plain": return "txt"
        case "text/typescript": return "ts"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "video/webm": return "webm"
        case "video/x-msvideo": return "avi"
        default: return "bin"
        }
    }

    private func sanitizedRelayStem(for filename: String) -> String {
        let raw = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let filtered = raw.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                return Character(scalar)
            }
            return "-"
        }
        let collapsed = String(filtered)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return collapsed.isEmpty ? "upload" : String(collapsed.prefix(48))
    }

    private enum RelayAttachmentError: LocalizedError {
        case emptyPayload
        case tooLarge(limit: Int)
        case batchTooLarge(limit: Int)
        case invalidChunk(String)

        var errorDescription: String? {
            switch self {
            case .emptyPayload:
                return "the selected file was empty"
            case .tooLarge(let limit):
                return "the selected file exceeds the \(limit / (1024 * 1024)) MB limit"
            case .batchTooLarge(let limit):
                return "the selected files exceed the \(limit / (1024 * 1024)) MB total limit"
            case .invalidChunk(let reason):
                return "the file transfer was invalid: \(reason)"
            }
        }
    }

    private static let maxRelayAttachmentBytes = 25 * 1024 * 1024
    private static let maxRelayAttachmentBatchBytes = 100 * 1024 * 1024
    private static let maxRelayAttachmentFiles = 20
    private static let maxRelayAttachmentChunks = 1024
    private static let relayAttachmentTransferTTL: TimeInterval = 600
    private static let relayAttachmentTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private struct PendingRelayImageTransfer {
        let transferId: String
        let agentId: AgentID
        let text: String
        let filename: String
        let mimeType: String
        let totalBytes: Int
        let chunkCount: Int
        let submitOnSend: Bool
        let createdAt = Date()
        var chunks: [Int: Data] = [:]

        var receivedBytes: Int {
            chunks.values.reduce(0) { $0 + $1.count }
        }

        var isComplete: Bool {
            chunks.count == chunkCount
        }

        func matches(_ chunk: ImageAttachmentChunk) -> Bool {
            transferId == chunk.transferId &&
                agentId == chunk.agentId &&
                text == chunk.text &&
                filename == chunk.filename &&
                mimeType == chunk.mimeType &&
                totalBytes == chunk.totalBytes &&
                chunkCount == chunk.chunkCount &&
                submitOnSend == chunk.submitOnSend
        }
    }

    private struct RelayFileAttachmentBatchInput {
        let agentId: AgentID
        let text: String
        let fileURLs: [URL]
        let submitOnSend: Bool
    }

    private struct PendingRelayFileAttachmentBatch {
        let batchId: String
        let agentId: AgentID
        let text: String
        let fileCount: Int
        let submitOnSend: Bool
        let createdAt = Date()
        var transfers: [Int: PendingRelayFileTransfer] = [:]
        var fileURLs: [Int: URL] = [:]

        var isComplete: Bool {
            fileURLs.count == fileCount
        }

        func declaredBytes(replacing transfer: PendingRelayFileTransfer) -> Int {
            transfers.reduce(transfer.totalBytes) { total, item in
                let (fileIndex, existing) = item
                return fileIndex == transfer.fileIndex ? total : total + existing.totalBytes
            }
        }

        func matches(_ chunk: FileAttachmentChunk) -> Bool {
            batchId == chunk.batchId &&
                agentId == chunk.agentId &&
                text == chunk.text &&
                fileCount == chunk.fileCount &&
                submitOnSend == chunk.submitOnSend
        }
    }

    private struct PendingRelayFileTransfer {
        let transferId: String
        let fileIndex: Int
        let filename: String
        let mimeType: String
        let totalBytes: Int
        let chunkCount: Int
        var chunks: [Int: Data] = [:]

        var receivedBytes: Int {
            chunks.values.reduce(0) { $0 + $1.count }
        }

        var isComplete: Bool {
            chunks.count == chunkCount
        }

        func matches(_ chunk: FileAttachmentChunk) -> Bool {
            transferId == chunk.transferId &&
                fileIndex == chunk.fileIndex &&
                filename == chunk.filename &&
                mimeType == chunk.mimeType &&
                totalBytes == chunk.totalBytes &&
                chunkCount == chunk.chunkCount
        }
    }

    private func canAcceptRelayInput(agentId: AgentID) -> Bool {
        if autoLock.isReadOnly {
            emitRelaySystemMessage(agentId: agentId, text: "input blocked: read-only mode is on")
            return false
        }
        if autoLock.isLocked {
            emitRelaySystemMessage(agentId: agentId, text: "input blocked: Glasstunnel is locked")
            return false
        }
        return true
    }

    private func canPerformRelaySessionAction(agentId: AgentID) -> Bool {
        if autoLock.isLocked {
            emitRelaySystemMessage(agentId: agentId, text: "action blocked: Glasstunnel is locked")
            return false
        }
        return true
    }

    private func canPerformRelayRemoteAppAction(agentId: AgentID, action: RemoteAppActionRequest.Action) -> Bool {
        if Self.allowsRelayRemoteAppAction(action, locked: autoLock.isLocked) {
            return true
        }
        emitRelaySystemMessage(agentId: agentId, text: "action blocked: Glasstunnel is locked")
        return false
    }

    nonisolated static func allowsRelayRemoteAppAction(_ action: RemoteAppActionRequest.Action, locked: Bool) -> Bool {
        if !locked { return true }
        switch action {
        case .disable, .stop, .closeSession:
            return true
        case .enable, .start, .launch, .newSession:
            return false
        }
    }

    private func emitRelaySystemMessage(agentId: AgentID, text: String) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let app = currentRemoteApps.first { $0.agentId == agentId }
        let message = AgentChatMessage(
            messageId: "\(agentId)-relay-system-\(now)",
            role: .system,
            text: text,
            atUnixMs: now
        )
        let snapshot = AgentStateSnapshot(
            agentId: agentId,
            agentLabel: app?.displayName ?? agentId,
            adapterKind: app?.adapterKind ?? .unspecified,
            status: .error,
            statusDetail: text,
            recentMessages: [message],
            lastActivityUnixMs: now,
            hasVideoTrack: app?.hasVideo ?? false,
            remoteAppId: app?.remoteAppId
        )
        broadcastAgentState(snapshot)
    }

    // MARK: - Envelope routing

    private func handleEnvelope(_ env: Envelope) {
        guard let device = registry.get(env.fromDeviceId), !device.revoked else {
            return
        }
        guard env.hasValidSignature(publicKey: device.publicKey) else {
            return
        }
        registry.updateLastSeen(env.fromDeviceId)

        switch env.payload {
        case .sdpAnswer(let answer):
            Task { await handleSdpAnswer(answer, from: env.fromDeviceId) }
        case .iceCandidate(let candidate):
            Task { await handleIce(candidate, from: env.fromDeviceId) }
        case .ping:
            // Phone announcing "I am online, please start a WebRTC session."
            Task { await initiateWebRTC(to: env.fromDeviceId) }
        case .sdpOffer, .pushRegister, .agentStateEvent, .pong, .protoError:
            break
        }
    }

    private func initiateWebRTC(to phoneDeviceId: DeviceID) async {
        guard let signaling else { return }
        if let existing = sessions.removeValue(forKey: phoneDeviceId) {
            let stopTask = existing.stop()
            existing.peer.close()
            await stopTask.value
        }
        let sessionID = UUID().uuidString
        let peer: WebRTCPeer
        do {
            peer = try WebRTCPeer(
                remoteDeviceID: phoneDeviceId,
                iceServers: buildIceServers(),
                sessionID: sessionID
            )
        } catch {
            onState?(.error("WebRTC setup failed: \(error.localizedDescription)"))
            return
        }
        let session = Session(
            peer: peer,
            phoneDeviceID: phoneDeviceId,
            hostDeviceKey: deviceKey,
            signaling: signaling,
            autoLock: autoLock,
            redactor: redactor,
            remoteAppController: remoteAppController
        )
        sessions[phoneDeviceId] = session

        peer.onLocalICECandidate = { [weak self] candidate in
            let iceCandidate = IceCandidate(
                candidate: candidate.sdp,
                sdpMid: candidate.sdpMid ?? "",
                sdpMlineIndex: candidate.sdpMLineIndex,
                sessionId: sessionID
            )
            guard let manager = self else { return }
            Task { @MainActor [manager, iceCandidate] in
                await manager.sendIce(iceCandidate, to: phoneDeviceId)
            }
        }
        peer.onState = { [weak self] state in
            guard let manager = self else { return }
            Task { @MainActor [manager] in
                guard manager.sessions[phoneDeviceId] === session else { return }
                switch state {
                case .connected:
                    manager.onPeerConnected?(phoneDeviceId)
                    manager.sessions[phoneDeviceId]?.start(hostDeviceLabel: manager.hostDeviceLabel)
                case .closed, .failed:
                    let stopTask = manager.sessions[phoneDeviceId]?.stop()
                    manager.sessions.removeValue(forKey: phoneDeviceId)
                    manager.onPeerDisconnected?(phoneDeviceId)
                    await stopTask?.value
                default: break
                }
            }
        }

        do {
            await session.prepareMediaForOffer()
            let offer = try await peer.createOffer()
            let env = Envelope(
                fromDeviceId: deviceKey.deviceId,
                toDeviceId: phoneDeviceId,
                payload: .sdpOffer(SdpOffer(sdp: offer.sdp, sessionId: sessionID))
            )
            try await signaling.send(env)
        } catch {
            let stopTask = session.stop()
            sessions.removeValue(forKey: phoneDeviceId)
            await stopTask.value
            onState?(.error("WebRTC offer failed: \(error.localizedDescription)"))
        }
    }

    private func handleSdpAnswer(_ answer: SdpAnswer, from phoneDeviceId: DeviceID) async {
        guard let session = sessions[phoneDeviceId] else { return }
        guard session.peer.sessionID == answer.sessionId else { return }
        let remote = RTCSessionDescription(type: .answer, sdp: answer.sdp)
        try? await session.peer.setRemoteDescription(remote)
    }

    private func handleIce(_ candidate: IceCandidate, from phoneDeviceId: DeviceID) async {
        guard let session = sessions[phoneDeviceId] else { return }
        guard session.peer.sessionID == candidate.sessionId else { return }
        let ice = RTCIceCandidate(sdp: candidate.candidate, sdpMLineIndex: candidate.sdpMlineIndex, sdpMid: candidate.sdpMid.isEmpty ? nil : candidate.sdpMid)
        try? await session.peer.add(remoteCandidate: ice)
    }

    private func sendIce(_ candidate: IceCandidate, to phoneDeviceId: DeviceID) async {
        guard let signaling else { return }
        let env = Envelope(
            fromDeviceId: deviceKey.deviceId,
            toDeviceId: phoneDeviceId,
            payload: .iceCandidate(candidate)
        )
        try? await signaling.send(env)
    }

    private func handleControlMessage(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }
        switch type {
        case "host_identity":
            if let identity = Self.hostIdentity(fromControlMessage: msg) {
                onHostIdentity?(identity)
            }
        case "account_device_authorized":
            authorizeAccountDevice(msg)
        case "link_code_created":
            if let code = msg["code"] as? String {
                let linkCode = LinkCode(
                    code: code,
                    expiresAt: parseISODate(msg["expires_at"] as? String)
                )
                onLinkCode?(linkCode)
                pendingLinkCodeContinuation?.resume(returning: linkCode)
                pendingLinkCodeContinuation = nil
                pendingLinkCodeTimeout?.invalidate()
                pendingLinkCodeTimeout = nil
            }
        case "approval_requested":
            guard
                let requestID = msg["request_id"] as? String,
                let requesterDeviceID = msg["requester_device_id"] as? String,
                let requesterPublicKeyB64 = msg["requester_public_key_b64"] as? String
            else {
                return
            }
            onApprovalRequested?(ApprovalRequest(
                id: requestID,
                requesterDeviceID: requesterDeviceID,
                requesterPublicKeyB64: requesterPublicKeyB64,
                requesterLabel: Self.nonEmpty(msg["requester_label"] as? String) ?? "This device",
                requestedAt: parseISODate(msg["requested_at"] as? String)
            ))
        case "link_code_error":
            if let pendingLinkCodeContinuation {
                self.pendingLinkCodeContinuation = nil
                pendingLinkCodeTimeout?.invalidate()
                pendingLinkCodeTimeout = nil
                pendingLinkCodeContinuation.resume(throwing: NSError(
                    domain: "SessionManager",
                    code: -4,
                    userInfo: [NSLocalizedDescriptionKey: (msg["reason"] as? String) ?? "Could not create link code."]
                ))
            }
            onState?(.error((msg["reason"] as? String) ?? "Could not create link code."))
        case "approval_recorded":
            if let ok = msg["ok"] as? Bool, !ok {
                onState?(.error((msg["reason"] as? String) ?? "Approval decision failed."))
            }
        case "host_unlinked":
            let ok = (msg["ok"] as? Bool) ?? false
            if ok {
                pendingUnlinkContinuation?.resume()
                pendingUnlinkContinuation = nil
                pendingUnlinkTimeout?.invalidate()
                pendingUnlinkTimeout = nil
            } else {
                if let pendingUnlinkContinuation {
                    self.pendingUnlinkContinuation = nil
                    pendingUnlinkTimeout?.invalidate()
                    pendingUnlinkTimeout = nil
                    pendingUnlinkContinuation.resume(throwing: NSError(
                        domain: "SessionManager",
                        code: -5,
                        userInfo: [NSLocalizedDescriptionKey: (msg["reason"] as? String) ?? "Could not sign out this Mac."]
                    ))
                }
                onState?(.error((msg["reason"] as? String) ?? "Could not sign out this Mac."))
            }
        default:
            break
        }
    }

    nonisolated static func hostIdentity(fromControlMessage msg: [String: Any]) -> HostIdentity? {
        guard msg["type"] as? String == "host_identity" else { return nil }
        return HostIdentity(
            linked: (msg["linked"] as? Bool) ?? false,
            userID: msg["user_id"] as? String,
            email: Self.nonEmpty(msg["email"] as? String),
            displayName: Self.nonEmpty(msg["display_name"] as? String),
            avatarURL: Self.nonEmpty(msg["avatar_url"] as? String)
        )
    }

    private func authorizeAccountDevice(_ msg: [String: Any]) {
        guard
            let requesterDeviceID = Self.nonEmpty(msg["requester_device_id"] as? String),
            let publicKeyB64 = Self.nonEmpty(msg["requester_public_key_b64"] as? String),
            let publicKey = Data(base64Encoded: publicKeyB64)
        else {
            return
        }

        guard DeviceKey.deviceId(fromRawPublicKey: publicKey) == requesterDeviceID else {
            return
        }

        if registry.isRevoked(requesterDeviceID) {
            return
        }

        let paired = DeviceRegistry.PairedDevice(
            deviceId: requesterDeviceID,
            publicKey: publicKey,
            label: Self.nonEmpty(msg["requester_label"] as? String) ?? "Signed-in device",
            pairedAt: parseISODate(msg["paired_at"] as? String) ?? Date()
        )

        do {
            try registry.add(paired)
            onPaired?(paired)
        } catch {
            onState?(.error("Could not save account device: \(error.localizedDescription)"))
        }
    }

    nonisolated static func makeIceServers(
        stunURLs: [String] = GlasstunnelProtocol.defaultStunURLs,
        turnURL: String,
        turnUsername: String?,
        turnPassword: String?
    ) -> [RTCIceServer] {
        var servers = stunURLs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { RTCIceServer(urlStrings: [$0]) }

        let turnURL = turnURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let turnUsername = turnUsername?.trimmingCharacters(in: .whitespacesAndNewlines)
        let turnPassword = turnPassword?.trimmingCharacters(in: .whitespacesAndNewlines)
        if
            !turnURL.isEmpty,
            let turnUsername, !turnUsername.isEmpty,
            let turnPassword, !turnPassword.isEmpty
        {
            servers.append(RTCIceServer(
                urlStrings: [turnURL],
                username: turnUsername,
                credential: turnPassword
            ))
        }
        return servers
    }

    private func buildIceServers() -> [RTCIceServer] {
        Self.makeIceServers(
            turnURL: turnURL,
            turnUsername: turnUsername,
            turnPassword: turnPassword
        )
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func parseISODate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return Self.iso8601Formatter.date(from: value)
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
