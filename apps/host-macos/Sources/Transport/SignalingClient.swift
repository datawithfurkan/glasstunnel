import Foundation
import GTProtocol
import GTSecurity

/// Thin WebSocket client for the glasstunnel signaling service. Speaks the
/// handshake described in `apps/signaling/internal/rendezvous`.
///
/// Usage:
///
///     let key = try DeviceKeyStore.shared.getOrCreate()
///     let client = SignalingClient(url: URL(string: "wss://signaling.glasstunnel.io/signal")!, deviceKey: key, role: "host")
///     try await client.connect()
///     client.onEnvelope = { env in ... }
public final class SignalingClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    public enum State: Sendable { case disconnected, connecting, authenticated, error(String) }

    public var onEnvelope: (@Sendable (Envelope) -> Void)?
    public var onState: (@Sendable (State) -> Void)?
    public var onControlMessage: (@Sendable ([String: Any]) -> Void)?

    private let url: URL
    private let deviceKey: DeviceKey
    private let role: String
    private let deviceLabel: String

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var state: State = .disconnected
    private var keepaliveTask: Task<Void, Never>?
    private var intentionallyClosed = false

    public init(url: URL, deviceKey: DeviceKey, role: String = "host", deviceLabel: String? = nil) {
        self.url = url
        self.deviceKey = deviceKey
        self.role = role
        self.deviceLabel = deviceLabel ?? defaultHostDeviceLabel()
        super.init()
    }

    public func connect() async throws {
        onState?(.connecting)
        state = .connecting
        intentionallyClosed = false
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        task.resume()

        let hello = try await receiveJSON()
        guard (hello["type"] as? String) == "server_hello", let nonceB64 = hello["nonce"] as? String,
              let nonce = Data(base64Encoded: nonceB64) else {
            throw SignalingError.protocolMismatch("expected server_hello with nonce")
        }
        let sig = try deviceKey.sign(nonce)
        let authMsg: [String: Any] = [
            "type": "client_auth",
            "device_id": deviceKey.deviceId,
            "public_key": deviceKey.publicKeyRaw.base64EncodedString(),
            "signature": sig.base64EncodedString(),
            "role": role,
            "device_info": deviceLabel,
        ]
        try await sendJSON(authMsg)

        let ack = try await receiveJSON()
        guard (ack["type"] as? String) == "auth_ok" else {
            throw SignalingError.authFailed((ack["error"] as? String) ?? "unknown")
        }
        state = .authenticated
        onState?(.authenticated)

        startKeepalive()
        Task { [weak self] in await self?.readLoop() }
    }

    public func disconnect() {
        intentionallyClosed = true
        stopKeepalive()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        state = .disconnected
        onState?(.disconnected)
    }

    public func send(_ envelope: Envelope) async throws {
        let signed = try envelope.signed(using: deviceKey)
        let data = try ProtocolCodec.encode(signed)
        guard let s = String(data: data, encoding: .utf8) else { throw SignalingError.encoding }
        guard let task else { throw SignalingError.notConnected }
        do {
            try await task.send(.string(s))
        } catch {
            state = .error(error.localizedDescription)
            onState?(.error(error.localizedDescription))
            throw error
        }
    }

    public func sendControlMessage(_ obj: [String: Any]) async throws {
        try await sendJSON(obj)
    }

    // MARK: - IO

    private func readLoop() async {
        guard let task else { return }
        while true {
            do {
                let msg = try await task.receive()
                switch msg {
                case .string(let s):
                    handleIncoming(s)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) { handleIncoming(s) }
                @unknown default: break
                }
            } catch {
                stopKeepalive()
                if intentionallyClosed {
                    state = .disconnected
                    onState?(.disconnected)
                } else {
                    state = .error(error.localizedDescription)
                    onState?(.error(error.localizedDescription))
                }
                return
            }
        }
    }

    private func handleIncoming(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        if let env = try? ProtocolCodec.decode(Envelope.self, from: data) {
            onEnvelope?(env)
            return
        }

        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            onControlMessage?(obj)
            return
        }
    }

    private func sendJSON(_ obj: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else { throw SignalingError.encoding }
        guard let task else { throw SignalingError.notConnected }
        do {
            try await task.send(.string(s))
        } catch {
            state = .error(error.localizedDescription)
            onState?(.error(error.localizedDescription))
            throw error
        }
    }

    private func startKeepalive() {
        stopKeepalive()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                do {
                    try await self.sendJSON([
                        "type": "ping",
                        "at": Int(Date().timeIntervalSince1970 * 1000),
                    ])
                } catch {
                    return
                }
            }
        }
    }

    private func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    private func receiveJSON() async throws -> [String: Any] {
        guard let task else { throw SignalingError.notConnected }
        let msg = try await task.receive()
        let data: Data
        switch msg {
        case .string(let s): data = s.data(using: .utf8) ?? Data()
        case .data(let d): data = d
        @unknown default: data = Data()
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SignalingError.protocolMismatch("expected JSON object")
        }
        return obj
    }
}

public enum SignalingError: Error, Sendable {
    case protocolMismatch(String)
    case authFailed(String)
    case notConnected
    case encoding
}

public func defaultHostDeviceLabel() -> String {
    #if os(macOS)
    return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    #else
    return ProcessInfo.processInfo.hostName
    #endif
}
