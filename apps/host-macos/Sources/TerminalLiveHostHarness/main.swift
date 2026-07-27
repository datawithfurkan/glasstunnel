import Foundation
import Darwin
import GTCapture
import GTProtocol
import GTSecurity
import GTTransport

@main
struct TerminalLiveHostHarness {
    @MainActor
    static func main() async {
        do {
            let env = ProcessInfo.processInfo.environment
            let deviceKey = try DeviceKeyStore(environment: env).getOrCreate()
            let defaults = UserDefaults(suiteName: "TerminalLiveHostHarness.\(deviceKey.deviceId)") ?? .standard
            defaults.set([], forKey: "remoteApps.enabled.v1")
            defaults.set(true, forKey: "remoteApps.terminalDefaultEnabled.v1")

            let remoteApps = RemoteAppController(defaults: defaults)
            let syntheticScreenEnabled = env["GT_TERMINAL_LIVE_SYNTHETIC_SCREEN"] == "1"
            remoteApps.setScreenRecordingAvailable(syntheticScreenEnabled)
            let windowRefreshTask = startWindowRefresh(remoteApps: remoteApps)
            let syntheticScreenProbe = SyntheticScreenProbe()
            let screenCaptureFactory: RelayScreenCaptureFactory?
            if syntheticScreenEnabled {
                screenCaptureFactory = { agentId, relay, quality in
                    SyntheticRelayScreenCapture(
                        agentId: agentId,
                        relay: relay,
                        quality: quality,
                        probe: syntheticScreenProbe
                    )
                }
            } else {
                screenCaptureFactory = nil
            }
            let screenPointerInputHandler: ScreenPointerInputHandler?
            if syntheticScreenEnabled {
                let handler: ScreenPointerInputHandler = { input in
                    syntheticScreenProbe.record(input)
                }
                screenPointerInputHandler = handler
            } else {
                screenPointerInputHandler = nil
            }

            let autoLock = AutoLock(idleTimeout: 120)
            let signalingURL = URL(string: env["GT_TERMINAL_LIVE_SIGNALING_URL"] ?? GlasstunnelProtocol.defaultSignalingURL.absoluteString)!
            let hostLabel = env["GT_TERMINAL_LIVE_HOST_LABEL"] ?? "Terminal live smoke host"
            let manager = SessionManager(
                deviceKey: deviceKey,
                signalingURL: signalingURL,
                turnURL: "",
                hostDeviceLabel: hostLabel,
                autoLock: autoLock,
                registry: DeviceRegistry(fileURL: temporaryRegistryURL(deviceID: deviceKey.deviceId)),
                remoteAppController: remoteApps,
                screenPointerInputHandler: screenPointerInputHandler,
                relayScreenCaptureFactory: screenCaptureFactory
            )

            remoteApps.onRemoteAppsChanged = { apps in
                Task { @MainActor in
                    manager.applyRemoteApps(apps)
                }
            }
            remoteApps.onAgentState = { snapshot in
                Task { @MainActor in
                    manager.broadcastAgentState(snapshot)
                }
            }
            manager.onState = { state in
                Task { @MainActor in
                    print("STATE \(stateLabel(state))")
                    fflush(stdout)
                }
            }
            manager.onHostIdentity = { identity in
                Task { @MainActor in
                    if identity.linked {
                        print("HOST_LINKED \(identity.email ?? identity.userID ?? "linked")")
                        fflush(stdout)
                    }
                }
            }

            print("HOST_DEVICE_ID \(deviceKey.deviceId)")
            fflush(stdout)

            try await manager.start()
            let linkCode = try await manager.createAccountLinkCode()
            print("LINK_CODE \(linkCode.code)")
            fflush(stdout)

            let seconds = UInt64(env["GT_TERMINAL_LIVE_HOST_SECONDS"].flatMap(UInt64.init) ?? 120)
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            windowRefreshTask.cancel()
            manager.stop()
        } catch {
            print("HARNESS_ERROR \(error.localizedDescription)")
            fflush(stdout)
            exit(1)
        }
    }

    @MainActor
    private static func startWindowRefresh(remoteApps: RemoteAppController) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                do {
                    remoteApps.updateWindows(try await WindowCatalog.refresh())
                } catch {
                    remoteApps.updateWindows([])
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private static func temporaryRegistryURL(deviceID: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("glasstunnel-terminal-live-\(deviceID)-devices.json")
    }

    private static func stateLabel(_ state: SessionManager.State) -> String {
        switch state {
        case .idle:
            return "idle"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .error(let message):
            return "error:\(message)"
        }
    }
}

private final class SyntheticScreenProbe: @unchecked Sendable {
    struct Snapshot {
        let count: Int
        let x: Double
        let y: Double
        let action: String
    }

    private let lock = NSLock()
    private var pointerCount = 0
    private var lastX = 0.0
    private var lastY = 0.0
    private var lastAction = "none"

    func record(_ input: ScreenPointerInput) {
        lock.lock()
        pointerCount += 1
        lastX = input.x
        lastY = input.y
        lastAction = input.action.rawValue
        let snapshot = Snapshot(count: pointerCount, x: lastX, y: lastY, action: lastAction)
        lock.unlock()

        print(
            "SCREEN_POINTER \(snapshot.count) "
                + "\(String(format: "%.3f", snapshot.x)) "
                + "\(String(format: "%.3f", snapshot.y)) \(snapshot.action)"
        )
        fflush(stdout)
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(count: pointerCount, x: lastX, y: lastY, action: lastAction)
    }
}

private final class SyntheticRelayScreenCapture: RelayScreenCapturing, @unchecked Sendable {
    private let agentId: AgentID
    private let relay: RelayClient
    private let quality: RemoteAppActionRequest.ScreenQuality
    private let probe: SyntheticScreenProbe
    private let lock = NSLock()
    private var streamTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var isRunning = false

    init(
        agentId: AgentID,
        relay: RelayClient,
        quality: RemoteAppActionRequest.ScreenQuality,
        probe: SyntheticScreenProbe
    ) {
        self.agentId = agentId
        self.relay = relay
        self.quality = quality
        self.probe = probe
    }

    func uses(relay: RelayClient, quality: RemoteAppActionRequest.ScreenQuality) -> Bool {
        self.relay === relay && self.quality == quality
    }

    func start() async throws {
        guard let activeGeneration = beginRunning() else { return }

        do {
            try await publishFrame(sequence: 1, generation: activeGeneration)
        } catch {
            invalidate(activeGeneration)
            throw error
        }
        let task = Task { [weak self] in
            var sequence: Int64 = 2
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                try? await self?.publishFrame(sequence: sequence, generation: activeGeneration)
                sequence += 1
            }
        }

        if !install(task: task, generation: activeGeneration) {
            task.cancel()
        }
    }

    func stop() async {
        let task = markStopped()
        task?.cancel()
        await task?.value
    }

    private func publishFrame(sequence: Int64, generation: UInt64) async throws {
        guard isCurrent(generation) else { return }
        let dimensions = quality == .readable ? (width: 640, height: 360) : (width: 320, height: 180)
        let fill = sequence.isMultiple(of: 2) ? "#0b7cff" : "#22c55e"
        let pointer = probe.snapshot()
        let pointerText = "Pointers \(pointer.count) \(String(format: "%.3f", pointer.x)) \(String(format: "%.3f", pointer.y)) \(pointer.action)"
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(dimensions.width)" height="\(dimensions.height)">
          <rect width="100%" height="100%" fill="#111827"/>
          <rect x="24" y="24" width="\(dimensions.width - 48)" height="\(dimensions.height - 48)" rx="16" fill="\(fill)"/>
          <text x="50%" y="50%" fill="white" font-family="sans-serif" font-size="28" text-anchor="middle">Glasstunnel \(sequence)</text>
          <text x="50%" y="60%" fill="white" font-family="sans-serif" font-size="16" text-anchor="middle">\(pointerText)</text>
        </svg>
        """
        let message = RelayScreenFrameMessage(
            agentId: agentId,
            mimeType: "image/svg+xml",
            width: dimensions.width,
            height: dimensions.height,
            bytes: Data(svg.utf8),
            sequence: sequence,
            atUnixMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        try await relay.publishScreenFrame(message)
        if sequence <= 2 || sequence.isMultiple(of: 20) {
            print("SCREEN_FRAME \(quality.rawValue) \(sequence)")
            fflush(stdout)
        }
    }

    private func isCurrent(_ expectedGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning && generation == expectedGeneration
    }

    private func beginRunning() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return nil }
        isRunning = true
        generation &+= 1
        return generation
    }

    private func install(task: Task<Void, Never>, generation expectedGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning, generation == expectedGeneration else { return false }
        streamTask = task
        return true
    }

    private func markStopped() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        isRunning = false
        generation &+= 1
        defer { streamTask = nil }
        return streamTask
    }

    private func invalidate(_ expectedGeneration: UInt64) {
        lock.lock()
        if generation == expectedGeneration {
            isRunning = false
            generation &+= 1
        }
        lock.unlock()
    }
}
