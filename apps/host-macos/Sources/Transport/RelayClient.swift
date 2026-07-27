import Foundation
import GTProtocol
import GTSecurity

/// Authenticated host-side WebSocket client for the relay-first transport.
///
/// The relay carries chat/control/state messages through Cloudflare Durable
/// Objects. WebRTC can still be used later for video, but command and snapshot
/// delivery should not depend on a browser tab owning a peer connection.
public final class RelayClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    public enum State: Sendable {
        case disconnected
        case connecting
        case authenticated
        case error(String)
    }

    public var onCommand: (@Sendable (DataChannelMessage, DeviceID?) -> Void)?
    public var onState: (@Sendable (State) -> Void)?

    private let url: URL
    private let deviceKey: DeviceKey
    private let deviceLabel: String

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var state: State = .disconnected
    private var keepaliveTask: Task<Void, Never>?
    private var intentionallyClosed = false

    public init(url: URL, deviceKey: DeviceKey, deviceLabel: String? = nil) {
        self.url = url
        self.deviceKey = deviceKey
        self.deviceLabel = deviceLabel ?? defaultHostDeviceLabel()
        super.init()
    }

    public static func relayURL(from signalingURL: URL, hostDeviceId: DeviceID) -> URL {
        var components = URLComponents(url: signalingURL, resolvingAgainstBaseURL: false)
        components?.path = "/relay"
        components?.queryItems = [
            URLQueryItem(name: "host_device_id", value: hostDeviceId),
        ]
        return components?.url ?? signalingURL
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
        guard
            (hello["type"] as? String) == "server_hello",
            let nonceB64 = hello["nonce"] as? String,
            let nonce = Data(base64Encoded: nonceB64)
        else {
            throw RelayError.protocolMismatch("expected server_hello with nonce")
        }

        let signature = try deviceKey.sign(nonce)
        try await sendJSON([
            "type": "client_auth",
            "device_id": deviceKey.deviceId,
            "public_key": deviceKey.publicKeyRaw.base64EncodedString(),
            "signature": signature.base64EncodedString(),
            "role": "host",
            "device_info": deviceLabel,
        ])

        let ack = try await receiveJSON()
        guard (ack["type"] as? String) == "auth_ok" else {
            throw RelayError.authFailed((ack["error"] as? String) ?? "unknown")
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

    public func publishHello(_ hello: Hello) async throws {
        try await sendEncodable(RelayHelloMessage(hello: hello))
    }

    public func publishRemoteApps(_ remoteApps: [RemoteApp]) async throws {
        try await sendEncodable(RelayRemoteAppsMessage(remoteApps: remoteApps))
    }

    public func publishAgentState(_ snapshot: AgentStateSnapshot) async throws {
        try await sendEncodable(RelayAgentStateMessage(snapshot: snapshot))
    }

    public func publishScreenFrame(_ frame: RelayScreenFrameMessage) async throws {
        try await sendEncodable(frame)
    }

    // MARK: - IO

    private func readLoop() async {
        guard let task else { return }
        while true {
            do {
                let msg = try await task.receive()
                switch msg {
                case .string(let text):
                    handleIncoming(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleIncoming(text)
                    }
                @unknown default:
                    break
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
        guard
            let data = text.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = obj["type"] as? String
        else {
            return
        }

        switch type {
        case "relay_command":
            guard let command = obj["command"] else { return }
            do {
                let commandData = try JSONSerialization.data(withJSONObject: command)
                let message = try ProtocolCodec.decode(DataChannelMessage.self, from: commandData)
                onCommand?(message, obj["client_device_id"] as? String)
            } catch {
                onState?(.error("Could not decode relay command: \(error.localizedDescription)"))
            }
        case "relay_pong":
            break
        case "relay_error":
            onState?(.error((obj["message"] as? String) ?? "Relay error."))
        default:
            break
        }
    }

    private func sendEncodable<T: Encodable>(_ value: T) async throws {
        guard let task else { throw RelayError.notConnected }
        let text = try ProtocolCodec.encodeString(value)
        do {
            try await task.send(.string(text))
        } catch {
            state = .error(error.localizedDescription)
            onState?(.error(error.localizedDescription))
            throw error
        }
    }

    private func sendJSON(_ obj: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else { throw RelayError.encoding }
        guard let task else { throw RelayError.notConnected }
        do {
            try await task.send(.string(text))
        } catch {
            state = .error(error.localizedDescription)
            onState?(.error(error.localizedDescription))
            throw error
        }
    }

    private func receiveJSON() async throws -> [String: Any] {
        guard let task else { throw RelayError.notConnected }
        let msg = try await task.receive()
        let data: Data
        switch msg {
        case .string(let text):
            data = text.data(using: .utf8) ?? Data()
        case .data(let raw):
            data = raw
        @unknown default:
            data = Data()
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RelayError.protocolMismatch("expected JSON object")
        }
        return obj
    }

    private func startKeepalive() {
        stopKeepalive()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self else { return }
                do {
                    try await self.sendJSON([
                        "type": "relay_ping",
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
}

public enum RelayError: Error, Sendable {
    case protocolMismatch(String)
    case authFailed(String)
    case notConnected
    case encoding
}

private struct RelayHelloMessage: Encodable {
    let type = "relay_hello"
    let hello: Hello
}

private struct RelayRemoteAppsMessage: Encodable {
    let type = "relay_remote_apps"
    let remoteApps: [RemoteApp]
}

private struct RelayAgentStateMessage: Encodable {
    let type = "relay_agent_state"
    let snapshot: AgentStateSnapshot
}

public struct RelayScreenFrameMessage: Encodable, Sendable {
    public let type = "relay_screen_frame"
    public let agentId: AgentID
    public let mimeType: String
    public let width: Int
    public let height: Int
    public let bytes: Data
    public let sequence: Int64
    public let atUnixMs: Int64

    public init(
        agentId: AgentID,
        mimeType: String,
        width: Int,
        height: Int,
        bytes: Data,
        sequence: Int64,
        atUnixMs: Int64
    ) {
        self.agentId = agentId
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.bytes = bytes
        self.sequence = sequence
        self.atUnixMs = atUnixMs
    }
}
