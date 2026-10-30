import Foundation
import Network
import CryptoKit
import PhoneProtocol

/// One authenticated-or-not phone connection on the bridge.
/// Handles the WebSocket upgrade, the auth.hello / auth.enroll / auth.finish
/// state machine, then forwards method calls to the delegate.
///
/// Before `auth.finish` completes, every method except the auth methods and
/// `ping` is answered with `unauthenticated` (spec: 握手).
public final class PhoneSession: @unchecked Sendable {
    public enum AuthState: Equatable {
        case unauthenticated
        case nonceIssued(deviceId: String)
        case authenticated(deviceId: String)
    }

    public protocol Delegate: AnyObject {
        var bridgeIdentity: String { get }
        /// Issue a single-use 32-byte nonce (base64url).
        func issueNonce() -> String
        /// Consume the pending nonce; nil when expired or reused.
        func consumeNonce(_ nonce: String) -> Data?
        /// Validate the enroll token (single use, 5 min) and register the device.
        /// Returns true when accepted.
        func phoneSession(_ session: PhoneSession, shouldEnrollWithToken token: String, device: EnrollCandidate) -> Bool
        /// Resolve the Ed25519 public key for a deviceId, or nil if unknown.
        func phoneSession(_ session: PhoneSession, publicKeyForDevice deviceId: String) -> Curve25519.Signing.PublicKey?
        /// Route an authenticated method call.
        func phoneSession(
            _ session: PhoneSession,
            handle method: String,
            body: JSONValue?,
            completion: @escaping (Result<JSONValue?, PhoneErrorCode>) -> Void
        )
        func phoneSessionDidAuthenticate(_ session: PhoneSession)
        func phoneSessionDidClose(_ session: PhoneSession)
    }

    public struct EnrollCandidate {
        public var deviceId: String
        public var name: String
        public var publicKeyBase64: String
        public init(deviceId: String, name: String, publicKeyBase64: String) {
            self.deviceId = deviceId
            self.name = name
            self.publicKeyBase64 = publicKeyBase64
        }
    }

    public weak var delegate: Delegate?
    private let queue = DispatchQueue(label: "genius-coder.phonesession")
    private let connection: NWConnection
    private var codec = WebSocketFrameCodec(isClient: false)
    private var authState: AuthState = .unauthenticated
    private var pendingNonce: String?
    private var upgraded = false
    private var partialRequest = Data()
    private var sessionClosed = false
    /// Kind of the listener this session arrived on (lan / tailscale).
    public let listenerKind: String
    public let id = UUID().uuidString

    init(connection: NWConnection, listenerKind: String) {
        self.connection = connection
        self.listenerKind = listenerKind
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveLoop()
            case .failed, .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.ingest(data)
            }
            if error == nil && !isComplete {
                self.receiveLoop()
            } else {
                self.close()
            }
        }
    }

    private func ingest(_ data: Data) {
        if !upgraded {
            partialRequest.append(data)
            guard let parsed = WebSocketHandshake.parseClientRequest(partialRequest) else {
                if partialRequest.count > 16_384 {
                    connection.cancel()
                }
                return
            }
            upgraded = true
            partialRequest = Data()
            connection.send(content: WebSocketHandshake.serverAccept(clientKey: parsed.websocketKey), completion: .contentProcessed { [weak self] _ in })
            return
        }
        codec.append(data)
        while true {
            switch codec.decodeNext() {
            case .needMoreData:
                return
            case .control(let op, let payload):
                if op == .ping {
                    connection.send(content: codec.encodePong(payload), completion: .contentProcessed { _ in })
                }
            case .message(let message):
                switch message.payload {
                case .text(let frameData):
                    if let envelope = try? WireEnvelope.decode(frameData) {
                        handle(envelope: envelope)
                    }
                case .binary:
                    continue
                case .close:
                    connection.cancel()
                    return
                }
            }
        }
    }

    // MARK: envelope routing

    private func handle(envelope: WireEnvelope) {
        guard envelope.type == .req, let method = envelope.method else {
            return
        }
        let id = envelope.id ?? "unknown"

        switch method {
        case PhoneMethod.authEnroll.rawValue:
            handleEnroll(envelope: envelope, id: id)
        case PhoneMethod.authHello.rawValue:
            handleHello(envelope: envelope, id: id)
        case PhoneMethod.authFinish.rawValue:
            handleFinish(envelope: envelope, id: id)
        case PhoneMethod.ping.rawValue:
            let body = JSONValue.from(PingResponse(
                bridgeId: delegate?.bridgeIdentity ?? "",
                serverTime: Int64(Date().timeIntervalSince1970 * 1000)
            ))
            send(.response(id: id, ok: true, body: body))
        default:
            guard case .authenticated = authState else {
                send(.error(id: id, code: PhoneErrorCode.unauthenticated.rawValue, message: "complete auth.finish first"))
                return
            }
            delegate?.phoneSession(self, handle: method, body: envelope.body) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    switch result {
                    case .success(let body):
                        self.send(.response(id: id, ok: true, body: body))
                    case .failure(let code):
                        self.send(.error(id: id, code: code.rawValue, message: code.localizedDescription))
                    }
                }
            }
        }
    }

    private func handleEnroll(envelope: WireEnvelope, id: String) {
        guard let body = envelope.body,
              let req: AuthEnrollRequest = try? body.asDecode(AuthEnrollRequest.self) else {
            send(.error(id: id, code: PhoneErrorCode.malformedRequest.rawValue, message: "bad auth.enroll body"))
            return
        }
        guard Data(base64Encoded: req.publicKey) != nil else {
            send(.error(id: id, code: PhoneErrorCode.malformedRequest.rawValue, message: "publicKey is not base64"))
            return
        }
        let candidate = EnrollCandidate(
            deviceId: req.deviceId,
            name: req.name,
            publicKeyBase64: req.publicKey
        )
        guard let delegate, delegate.phoneSession(self, shouldEnrollWithToken: req.token, device: candidate) else {
            send(.error(id: id, code: PhoneErrorCode.pairingRejected.rawValue, message: "token invalid, expired or used"))
            return
        }
        pendingNonce = delegate.issueNonce()
        authState = .nonceIssued(deviceId: req.deviceId)
        send(.response(id: id, ok: true, body: JSONValue.from(AuthEnrollResponse(bridgeId: delegate.bridgeIdentity, nonce: pendingNonce ?? ""))))
    }

    private func handleHello(envelope: WireEnvelope, id: String) {
        guard let body = envelope.body,
              let req: AuthHelloRequest = try? body.asDecode(AuthHelloRequest.self) else {
            send(.error(id: id, code: PhoneErrorCode.malformedRequest.rawValue, message: "bad auth.hello body"))
            return
        }
        guard req.protocolVersion == 1 else {
            send(.error(id: id, code: PhoneErrorCode.unsupportedProtocol.rawValue, message: "protocol must be 1"))
            return
        }
        guard let delegate, delegate.phoneSession(self, publicKeyForDevice: req.deviceId) != nil else {
            send(.error(id: id, code: PhoneErrorCode.unauthenticated.rawValue, message: "unknown device"))
            return
        }
        pendingNonce = delegate.issueNonce()
        authState = .nonceIssued(deviceId: req.deviceId)
        send(.response(id: id, ok: true, body: JSONValue.from(AuthHelloResponse(nonce: pendingNonce ?? "", bridgeId: delegate.bridgeIdentity))))
    }

    private func handleFinish(envelope: WireEnvelope, id: String) {
        guard let body = envelope.body,
              let req: AuthFinishRequest = try? body.asDecode(AuthFinishRequest.self),
              let delegate else {
            send(.error(id: id, code: PhoneErrorCode.malformedRequest.rawValue, message: "bad auth.finish body"))
            return
        }
        guard case .nonceIssued(let device) = authState, device == req.deviceId else {
            send(.error(id: id, code: PhoneErrorCode.unauthenticated.rawValue, message: "device changed mid-handshake"))
            return
        }
        guard let nonceString = pendingNonce,
              let nonceRaw = delegate.consumeNonce(nonceString) else {
            authState = .unauthenticated
            pendingNonce = nil
            send(.error(id: id, code: PhoneErrorCode.unauthenticated.rawValue, message: "nonce expired or reused"))
            return
        }
        guard let key = delegate.phoneSession(self, publicKeyForDevice: req.deviceId),
              let sig = Base64URL.decode(req.signature),
              key.isValidSignature(sig, for: AuthSignatureInput.bytes(nonce: nonceRaw, bridgeId: delegate.bridgeIdentity)) else {
            authState = .unauthenticated
            pendingNonce = nil
            send(.error(id: id, code: PhoneErrorCode.unauthenticated.rawValue, message: "signature check failed"))
            return
        }
        pendingNonce = nil
        authState = .authenticated(deviceId: req.deviceId)
        send(.response(id: id, ok: true, body: JSONValue.from(AuthFinishResponse(bridgeId: delegate.bridgeIdentity))))
        delegate.phoneSessionDidAuthenticate(self)
    }

    // MARK: outbound

    public func send(_ envelope: WireEnvelope) {
        queue.async { [weak self] in
            guard let self, !self.sessionClosed, let data = try? envelope.encoded() else { return }
            self.connection.send(content: self.codec.encodeText(data), completion: .contentProcessed { [weak self] _ in })
        }
    }

    public func close() {
        queue.async { [weak self] in
            guard let self, !self.sessionClosed else { return }
            self.sessionClosed = true
            self.connection.cancel()
            self.delegate?.phoneSessionDidClose(self)
        }
    }

    public var isAuthenticated: Bool {
        queue.sync {
            if case .authenticated = authState { return true }
            return false
        }
    }
}

extension PhoneErrorCode: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthenticated: return "not authenticated"
        case .pairingRejected: return "pairing token invalid"
        case .unsupportedProtocol: return "unsupported protocol version"
        case .cliMissing: return "agent binary missing"
        case .authExpired: return "agent login expired"
        case .sessionUnreadable: return "session log unreadable"
        case .unsupportedSessionVersion: return "unsupported session version"
        case .unsupportedMethod: return "method not supported by agent"
        case .claudeHistoryNeedsFixture: return "claude history parser needs a fixture"
        case .emptyHistory: return "no history on disk"
        case .notResumable: return "conversation is not resumable"
        case .sendDisabled: return "sending disabled for this agent"
        case .writerLocked: return "another writer holds this session"
        case .goalRearmedBlocked: return "goal rearmed after resume; cancelled"
        case .approvalDeniedDisconnected: return "approval timed out while disconnected"
        case .unsupportedServerRequest: return "unsupported server request was refused"
        case .tooManyLiveSessions: return "too many live sessions"
        case .adapterFailed: return "agent adapter failed"
        case .notFound: return "not found"
        case .malformedRequest: return "malformed request"
        case .internalError: return "internal error"
        }
    }
}
