import Foundation
import Network
import CryptoKit
import PhoneProtocol

/// The bridge's phone-facing server: one TLS `NWListener` per enabled
/// interface (LAN + Tailscale), Bonjour on the LAN listener, per-connection
/// auth, and method routing into the API handler.
public final class BridgeServer: PhoneSession.Delegate, @unchecked Sendable {
    public static let bonjourType = "_geniuscoder._tcp"
    public static let portRange: ClosedRange<UInt16> = 8787...8797

    public let pairingStore: PairingStore
    public let tokens = ClockTokens()
    private let certStore: CertStore
    private let queue = DispatchQueue(label: "genius-coder.bridgeserver")
    private var listeners: [NWListener] = []
    private var sessions: [PhoneSession] = []
    private var identity: CertStore.Identity?
    private var boundPort: UInt16?
    private var bindAddresses: [InterfaceLocator.BindAddress] = []

    /// Set by the app layer to route authenticated method calls.
    public var apiHandler: (@Sendable (PhoneSession, String, JSONValue?, @escaping (Result<JSONValue?, PhoneErrorCode>) -> Void) -> Void)?
    public var onAuthenticatedSession: (@Sendable (PhoneSession) -> Void)?
    public var onSessionClosed: (@Sendable (PhoneSession) -> Void)?

    /// LAN listener is advertised with Bonjour; both switches live in the
    /// menu bar and default on when the interface exists.
    public var lanEnabled = true
    public var tailscaleEnabled = true
    /// Test hook: force the bind addresses (e.g. loopback). Loopback is a
    /// Mac-side debug aid only, never a substitute for device acceptance.
    public var bindAddressesOverride: [InterfaceLocator.BindAddress]?

    public init(appSupportDirectory: URL) {
        self.certStore = CertStore(directory: appSupportDirectory)
        self.pairingStore = PairingStore(directory: appSupportDirectory)
    }

    /// Start listeners; returns the bound port or nil when nothing bound.
    @discardableResult
    public func start() -> UInt16? {
        let identity: CertStore.Identity
        do {
            identity = try certStore.loadOrCreate()
        } catch {
            BridgeLog.net.error("cert identity failed: \(error.localizedDescription)")
            return nil
        }
        self.identity = identity
        pairingStore.bindFingerprint(identity.fingerprintHex)

        let addresses = bindAddressesOverride ?? InterfaceLocator().currentBindAddresses()
        bindAddresses = addresses.filter { addr in
            switch addr.kind {
            case .lan: return lanEnabled
            case .tailscale: return tailscaleEnabled
            }
        }
        guard !bindAddresses.isEmpty else {
            BridgeLog.net.error("no eligible interfaces to listen on")
            return nil
        }

        let port = bindPort(on: bindAddresses, identity: identity)
        boundPort = port
        return port
    }

    public func stop() {
        queue.sync {
            for listener in listeners {
                listener.cancel()
            }
            listeners.removeAll()
            for session in sessions {
                session.close()
            }
        }
    }

    private func bindPort(on addresses: [InterfaceLocator.BindAddress], identity: CertStore.Identity) -> UInt16? {
        // Find a port that accepts the first address, then bind the rest on it.
        for port in Self.portRange {
            if let first = addresses.first, bind(address: first, port: port, identity: identity, advertiseBonjour: first.kind == .lan) != nil {
                for rest in addresses.dropFirst() {
                    _ = bind(address: rest, port: port, identity: identity, advertiseBonjour: false)
                }
                BridgeLog.net.info("listening on \(addresses.map(\.address).joined(separator: ", ")) port \(port)")
                return port
            }
        }
        return nil
    }

    private func bind(
        address: InterfaceLocator.BindAddress,
        port: UInt16,
        identity: CertStore.Identity,
        advertiseBonjour: Bool
    ) -> NWListener? {
        guard let secIdentity = makeSecIdentity(identity) else {
            BridgeLog.net.error("cannot build sec_identity for TLS")
            return nil
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)

        let params = NWParameters(tls: tls)
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(address.address), port: NWEndpoint.Port(rawValue: port)!)

        guard let listener = try? NWListener(using: params) else {
            return nil
        }
        if advertiseBonjour {
            listener.service = NWListener.Service(
                name: "genius-coder",
                type: Self.bonjourType,
                txtRecord: NWTXTRecord([
                    "bridgeId": pairingStore.bridgeId,
                    "fp": String(identity.fingerprintHex.prefix(16)),
                ])
            )
        }
        let kind = address.kind.rawValue
        var ready = false
        let semaphore = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                ready = true
                semaphore.signal()
            case .failed:
                semaphore.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let session = PhoneSession(connection: connection, listenerKind: kind)
            session.delegate = self
            self.queue.async {
                self.sessions.append(session)
            }
            session.start()
        }
        self.queue.sync {
            listener.start(queue: queue)
        }
        _ = semaphore.wait(timeout: .now() + 3)
        if ready {
            self.queue.sync {
                self.listeners.append(listener)
            }
            return listener
        }
        listener.cancel()
        return nil
    }

    private func makeSecIdentity(_ identity: CertStore.Identity) -> sec_identity_t? {
        guard let secIdentityRef = SecIdentityCreate(nil, identity.certificate, identity.privateKey) else {
            return nil
        }
        return sec_identity_create(secIdentityRef)
    }

    // MARK: - QR payload

    /// Extra hosts merged into the QR (Layer ② embedded tailscale).
    public var extraQRHosts: [PairingQRPayload.Host] = []

    /// Build the one-time pairing QR payload (hosts cover LAN + Tailscale).
    public func makePairingQR() -> PairingQRPayload? {
        guard let identity, let boundPort else { return nil }
        var hosts = bindAddresses.map { addr in
            PairingQRPayload.Host(address: addr.address, kind: addr.kind.rawValue)
        }
        for extra in extraQRHosts where !hosts.contains(where: { $0.address == extra.address }) {
            hosts.append(extra)
        }
        return PairingQRPayload(
            bridgeId: pairingStore.bridgeId,
            fp: identity.fingerprintHex,
            hosts: hosts,
            port: boundPort,
            token: tokens.issuePairingToken(),
            exp: Date().addingTimeInterval(EventLimits.pairingTokenTTLSeconds).timeIntervalSince1970
        )
    }

    public var advertisement: BridgeAdvertisement? {
        guard let identity else { return nil }
        return BridgeAdvertisement(bridgeId: pairingStore.bridgeId, certFingerprint: identity.fingerprintHex)
    }

    // MARK: - PhoneSession.Delegate

    public var bridgeIdentity: String { pairingStore.bridgeId }

    public func issueNonce() -> String {
        tokens.issueNonce()
    }

    public func consumeNonce(_ nonce: String) -> Data? {
        tokens.consumeNonce(nonce)
    }

    public func phoneSession(_ session: PhoneSession, shouldEnrollWithToken token: String, device: PhoneSession.EnrollCandidate) -> Bool {
        // Token first (single use, monotonic 5 min), then replace the device key.
        guard tokens.redeemPairingToken(token) else { return false }
        guard let raw = Data(base64Encoded: device.publicKeyBase64),
              (try? Curve25519.Signing.PublicKey(rawRepresentation: raw)) != nil else {
            return false
        }
        pairingStore.enrollDevice(PairingStore.PairedDevice(
            deviceId: device.deviceId,
            name: device.name,
            publicKey: device.publicKeyBase64,
            createdAt: Date().timeIntervalSince1970
        ))
        BridgeLog.net.info("paired device \(device.deviceId) (\(device.name))")
        return true
    }

    public func phoneSession(_ session: PhoneSession, publicKeyForDevice deviceId: String) -> Curve25519.Signing.PublicKey? {
        pairingStore.deviceKey(deviceId: deviceId)
    }

    public func phoneSession(
        _ session: PhoneSession,
        handle method: String,
        body: JSONValue?,
        completion: @escaping (Result<JSONValue?, PhoneErrorCode>) -> Void
    ) {
        guard let apiHandler else {
            completion(.failure(.internalError))
            return
        }
        apiHandler(session, method, body, completion)
    }

    public func phoneSessionDidAuthenticate(_ session: PhoneSession) {
        BridgeLog.net.info("session authenticated (\(session.listenerKind))")
        onAuthenticatedSession?(session)
    }

    public func phoneSessionDidClose(_ session: PhoneSession) {
        queue.async { [weak self] in
            self?.sessions.removeAll { $0.id == session.id }
        }
        onSessionClosed?(session)
    }

    public func allSessions() -> [PhoneSession] {
        queue.sync { sessions }
    }
}

import os

/// os_log wrapper. Never logs prompt text or approval details.
public enum BridgeLog {
    public static let subsystem = "com.local.geniuscoder"
    public static let net = Logger(subsystem: subsystem, category: "net")
    public static let index = Logger(subsystem: subsystem, category: "index")
    public static let codex = Logger(subsystem: subsystem, category: "codex")
    public static let grok = Logger(subsystem: subsystem, category: "grok")
    public static let claude = Logger(subsystem: subsystem, category: "claude")
    public static let dsh = Logger(subsystem: subsystem, category: "dsh")
}
