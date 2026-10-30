import Foundation
import Network
import CryptoKit
import Security

/// Phone-side bridge client: dials out over `NWConnection` + TLS with
/// ECDSA P-256 certificate pinning (SHA-256 comparison), performs the
/// WebSocket upgrade, then speaks the envelope protocol.
///
/// The phone only ever talks to the bridge (spec: 手机只跟 bridge 说话).
public final class BridgePhoneClient: @unchecked Sendable {
    public enum ClientState: Equatable, Sendable {
        case idle
        case connecting
        case connected
        case disconnected(reason: String)
    }

    public struct Configuration: Sendable {
        public var host: String
        public var port: UInt16
        /// Hex SHA-256 of the pinned leaf certificate.
        public var certificateFingerprint: String
        public var bridgeId: String
        public var deviceId: String
        /// Ed25519 private key used for auth.finish.
        public var signingKey: Curve25519.Signing.PrivateKey

        public init(
            host: String,
            port: UInt16,
            certificateFingerprint: String,
            bridgeId: String,
            deviceId: String,
            signingKey: Curve25519.Signing.PrivateKey
        ) {
            self.host = host
            self.port = port
            self.certificateFingerprint = certificateFingerprint
            self.bridgeId = bridgeId
            self.deviceId = deviceId
            self.signingKey = signingKey
        }
    }

    public var onStateChange: (@Sendable (ClientState) -> Void)?
    public var onEvent: (@Sendable (WireEnvelope) -> Void)?

    private let queue = DispatchQueue(label: "genius-coder.phoneclient")
    private var connection: NWConnection?
    private var codec = WebSocketFrameCodec(isClient: true)
    private var pendingRequests: [String: CheckedContinuation<WireEnvelope, Never>] = [:]
    private var nextRequestId = 0
    private let stateLock = NSLock()
    private var currentState: ClientState = .idle
    private var activeConfiguration: Configuration?
    private var handshaked = false
    private var partialHandshake = Data()

    public init() {}

    public func state() -> ClientState {
        stateLock.lock(); defer { stateLock.unlock() }
        return currentState
    }

    public var configuration: Configuration? {
        queue.sync { activeConfiguration }
    }

    private func setState(_ s: ClientState) {
        stateLock.lock()
        currentState = s
        stateLock.unlock()
        onStateChange?(s)
    }

    // MARK: TLS with pinning

    private func tlsOptions(fingerprint: String) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trustRef, complete in
            let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first else {
                complete(false)
                return
            }
            let data = SecCertificateCopyData(leaf) as Data
            let hex = SHA256Helper.hex(data)
            // Pin first: a chain-valid cert that is not ours is still rejected.
            complete(hex.caseInsensitiveCompare(fingerprint) == .orderedSame)
        }, queue)
        return tls
    }

    // MARK: connection lifecycle

    public func connect(configuration: Configuration) {
        queue.async { [weak self] in
            guard let self else { return }
            self.activeConfiguration = configuration
            self.setState(.connecting)
            self.startConnection(with: configuration)
        }
    }

    private func startConnection(with configuration: Configuration) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: tlsOptions(fingerprint: configuration.certificateFingerprint))
        params.includePeerToPeer = false
        let conn = NWConnection(
            host: NWEndpoint.Host(configuration.host),
            port: NWEndpoint.Port(rawValue: configuration.port) ?? 8787,
            using: params
        )
        self.connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendClientHandshake()
            case .failed(let error):
                self.failAllPending()
                self.setState(.disconnected(reason: error.localizedDescription))
            case .cancelled:
                self.failAllPending()
                self.setState(.disconnected(reason: "cancelled"))
            default:
                break
            }
        }
        receiveLoop(conn)
        conn.start(queue: queue)
    }

    public func disconnect() {
        queue.async { [weak self] in
            self?.connection?.cancel()
            self?.connection = nil
            self?.failAllPending()
            self?.setState(.disconnected(reason: "closed by app"))
        }
    }

    private func sendClientHandshake() {
        guard let configuration = activeConfiguration else { return }
        handshaked = false
        partialHandshake = Data()
        codec = WebSocketFrameCodec(isClient: true)
        let key = WebSocketHandshake.newClientKey()
        let req = WebSocketHandshake.clientRequest(host: configuration.host, port: configuration.port, key: key)
        connection?.send(content: req, completion: .contentProcessed { [weak self] _ in })
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.queue.async { self.ingest(data) }
            }
            if error == nil && !isComplete {
                self.receiveLoop(conn)
            } else {
                self.queue.async {
                    self.failAllPending()
                    self.setState(.disconnected(reason: error?.localizedDescription ?? "eof"))
                }
            }
        }
    }

    private func ingest(_ data: Data) {
        if handshaked {
            codec.append(data)
            drainFrames()
            return
        }
        partialHandshake.append(data)
        guard let extra = WebSocketHandshake.parseServerResponse(partialHandshake) else {
            if partialHandshake.count > 8192 {
                connection?.cancel()
            }
            return
        }
        handshaked = true
        partialHandshake = Data()
        setState(.connected)
        if !extra.isEmpty {
            codec.append(extra)
            drainFrames()
        }
    }

    private func drainFrames() {
        while true {
            switch codec.decodeNext() {
            case .needMoreData:
                return
            case .control(let op, let payload):
                if op == .ping {
                    connection?.send(content: codec.encodePong(payload), completion: .contentProcessed { _ in })
                }
            case .message(let msg):
                switch msg.payload {
                case .text(let data):
                    guard let envelope = try? WireEnvelope.decode(data) else { continue }
                    if (envelope.type == .res || envelope.type == .err),
                       let id = envelope.id,
                       let continuation = pendingRequests.removeValue(forKey: id) {
                        continuation.resume(returning: envelope)
                    } else {
                        onEvent?(envelope)
                    }
                case .binary:
                    continue
                case .close:
                    connection?.cancel()
                    return
                }
            }
        }
    }

    private func failAllPending() {
        for (_, c) in pendingRequests {
            c.resume(returning: WireEnvelope.error(id: nil, code: "disconnected", message: "connection lost"))
        }
        pendingRequests.removeAll()
    }

    // MARK: sending

    public func sendRaw(envelope: WireEnvelope) {
        queue.async { [weak self] in
            guard let self, self.handshaked, let data = try? envelope.encoded() else { return }
            self.connection?.send(content: self.codec.encodeText(data), completion: .contentProcessed { _ in })
        }
    }

    /// Fire a request and await the matching res/err by id. First of
    /// response-or-timeout wins.
    public func request(_ method: String, body: JSONValue? = nil, timeout: TimeInterval = 15) async -> WireEnvelope {
        nextRequestId += 1
        let id = "ph_\(nextRequestId)"
        let envelope = WireEnvelope.request(id: id, method: method, body: body)
        return await withTaskGroup(of: WireEnvelope.self) { group in
            group.addTask { [weak self] in
                await withCheckedContinuation { (continuation: CheckedContinuation<WireEnvelope, Never>) in
                    guard let self else {
                        continuation.resume(returning: WireEnvelope.error(id: id, code: "disconnected", message: "client gone"))
                        return
                    }
                    self.queue.async {
                        self.pendingRequests[id] = continuation
                        guard self.handshaked, let data = try? envelope.encoded() else {
                            if let c = self.pendingRequests.removeValue(forKey: id) {
                                c.resume(returning: WireEnvelope.error(id: id, code: "disconnected", message: "not connected"))
                            }
                            return
                        }
                        self.connection?.send(content: self.codec.encodeText(data), completion: .contentProcessed { _ in })
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return WireEnvelope.error(id: id, code: "timeout", message: "request timed out")
            }
            let first = await group.next() ?? WireEnvelope.error(id: id, code: "timeout", message: "request timed out")
            group.cancelAll()
            // If the timeout won, release a late registration.
            self.queue.async {
                if let c = self.pendingRequests.removeValue(forKey: id) {
                    c.resume(returning: WireEnvelope.error(id: id, code: "timeout", message: "request timed out"))
                }
            }
            return first
        }
    }

    // MARK: pairing and auth flows

    /// Full pairing flow against a freshly scanned QR payload. Generates the
    /// device Ed25519 key, calls auth.enroll with the one-time token, then
    /// signs the returned nonce with `rawNonce || utf8(bridgeId)`.
    public func enroll(scanned: PairingQRPayload, deviceId: String, name: String) async -> Result<Configuration, PhoneErrorCode> {
        let key = Curve25519.Signing.PrivateKey()
        let publicKeyB64 = key.publicKey.rawRepresentation.base64EncodedString()
        let body = JSONValue.from(AuthEnrollRequest(
            token: scanned.token,
            deviceId: deviceId,
            publicKey: publicKeyB64,
            name: name
        ))
        let res = await request(PhoneMethod.authEnroll.rawValue, body: body)
        guard res.type == .res, res.ok == true, let resBody = res.body else {
            return .failure((res.code).flatMap(PhoneErrorCode.init(rawValue:)) ?? .pairingRejected)
        }
        guard let resp: AuthEnrollResponse = try? resBody.asDecode(AuthEnrollResponse.self),
              let nonceRaw = Base64URL.decode(resp.nonce), nonceRaw.count == 32 else {
            return .failure(.malformedRequest)
        }
        guard let signature = try? key.signature(for: AuthSignatureInput.bytes(nonce: nonceRaw, bridgeId: resp.bridgeId)) else {
            return .failure(.internalError)
        }
        let finishBody = JSONValue.from(AuthFinishRequest(deviceId: deviceId, signature: Base64URL.encode(signature)))
        let finishRes = await request(PhoneMethod.authFinish.rawValue, body: finishBody)
        guard finishRes.type == .res, finishRes.ok == true else {
            return .failure((finishRes.code).flatMap(PhoneErrorCode.init(rawValue:)) ?? .unauthenticated)
        }
        var cfg = activeConfiguration ?? Configuration(
            host: scanned.hosts.first?.address ?? "127.0.0.1",
            port: scanned.port,
            certificateFingerprint: scanned.fp,
            bridgeId: resp.bridgeId,
            deviceId: deviceId,
            signingKey: key
        )
        cfg.signingKey = key
        cfg.bridgeId = resp.bridgeId
        cfg.deviceId = deviceId
        cfg.certificateFingerprint = scanned.fp
        cfg.port = scanned.port
        if let host = scanned.hosts.first { cfg.host = host.address }
        queue.sync(execute: { activeConfiguration = cfg })
        return .success(cfg)
    }

    /// Normal auth flow for an already-paired device.
    public func authenticate() async -> Bool {
        guard let configuration = queue.sync(execute: { activeConfiguration }) else { return false }
        let helloBody = JSONValue.from(AuthHelloRequest(deviceId: configuration.deviceId))
        let hello = await request(PhoneMethod.authHello.rawValue, body: helloBody)
        guard hello.type == .res, hello.ok == true,
              let helloBodyValue = hello.body,
              let resp: AuthHelloResponse = try? helloBodyValue.asDecode(AuthHelloResponse.self),
              let nonce = Base64URL.decode(resp.nonce), nonce.count == 32 else { return false }
        guard let sig = try? configuration.signingKey.signature(
            for: AuthSignatureInput.bytes(nonce: nonce, bridgeId: resp.bridgeId)
        ) else { return false }
        let finishBody = JSONValue.from(AuthFinishRequest(
            deviceId: configuration.deviceId,
            signature: Base64URL.encode(sig)
        ))
        let finish = await request(PhoneMethod.authFinish.rawValue, body: finishBody)
        return finish.type == .res && (finish.ok ?? false)
    }
}
