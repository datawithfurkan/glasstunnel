import Foundation
import Network

/// A loopback stand-in for the hosted signaling Worker that speaks the real
/// WebSocket handshake of `SignalingClient` and `RelayClient`. Every socket
/// (the relay connects to the same host) gets `server_hello`, must answer
/// with a host `client_auth`, and then receives `auth_ok` followed by the
/// control messages set for the current phase. Signatures are not checked.
final class LocalSignalingServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LocalSignalingServer")
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var messagesAfterAuth: [Data] = []
    private var authenticatedCount = 0
    private var startContinuation: CheckedContinuation<URL, Error>?

    init() throws {
        let parameters = NWParameters.tcp
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Starts listening on loopback and returns the signaling URL.
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            queue.async { [self] in
                startContinuation = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    self?.listenerStateChanged(state)
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: queue)
            }
        }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        guard let continuation = startContinuation else { return }
        switch state {
        case .ready:
            startContinuation = nil
            continuation.resume(returning: URL(string: "ws://127.0.0.1:\(listener.port?.rawValue ?? 0)/signal")!)
        case .failed(let error):
            startContinuation = nil
            continuation.resume(throwing: error)
        default:
            break
        }
    }

    /// The control messages every socket receives after `auth_ok` from now on.
    func setMessagesAfterAuth(_ messages: [[String: Any]]) {
        let encoded = messages.map { try! JSONSerialization.data(withJSONObject: $0) }
        queue.sync { messagesAfterAuth = encoded }
    }

    /// Drops every open socket, as a network change or a Worker restart does.
    func dropAllConnections() {
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    /// Sockets that completed the `client_auth` handshake so far.
    var authenticatedSocketCount: Int {
        queue.sync { authenticatedCount }
    }

    func stop() {
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
            listener.cancel()
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, case .ready = state else { return }
            self.send(["type": "server_hello", "nonce": Self.nonce()], on: connection)
            self.awaitClientAuth(on: connection)
        }
        connection.start(queue: queue)
    }

    private func awaitClientAuth(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            guard error == nil,
                  let content,
                  let message = try? JSONSerialization.jsonObject(with: content) as? [String: Any],
                  message["type"] as? String == "client_auth",
                  message["role"] as? String == "host"
            else {
                connection.cancel()
                return
            }
            self.authenticatedCount += 1
            self.send(["type": "auth_ok", "device_id": message["device_id"] as? String ?? "", "at": 0], on: connection)
            for data in self.messagesAfterAuth {
                self.send(data, on: connection)
            }
            self.discardIncoming(on: connection)
        }
    }

    /// Reads and ignores what the Mac sends after authenticating (relay
    /// state, keepalive pings) until the socket closes.
    private func discardIncoming(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard error == nil, content != nil else { return }
            self?.discardIncoming(on: connection)
        }
    }

    private func send(_ object: [String: Any], on connection: NWConnection) {
        send(try! JSONSerialization.data(withJSONObject: object), on: connection)
    }

    private func send(_ data: Data, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    private static func nonce() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
    }
}
