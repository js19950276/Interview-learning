import Foundation
import Security
import CryptoKit
import PhoneProtocol

/// Pairing state persisted as `pairing.json` (mode 0600) under the bridge's
/// Application Support directory. Holds the bridge id, certificate
/// fingerprint and exactly one valid device (spec Key Decision 12).
public final class PairingStore {
    public struct PairedDevice: Codable, Equatable {
        public var deviceId: String
        public var name: String
        /// Base64 raw Ed25519 public key.
        public var publicKey: String
        public var createdAt: Double
        public var revokedAt: Double?

        public init(deviceId: String, name: String, publicKey: String, createdAt: Double, revokedAt: Double? = nil) {
            self.deviceId = deviceId
            self.name = name
            self.publicKey = publicKey
            self.createdAt = createdAt
            self.revokedAt = revokedAt
        }
    }

    public struct Persisted: Codable, Equatable {
        public var bridgeId: String
        public var certificateFingerprint: String
        public var device: PairedDevice?
    }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "genius-coder.pairing")
    private var state: Persisted

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("pairing.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            state = decoded
        } else {
            let bytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
            state = Persisted(
                bridgeId: "br_" + bytes.map { String(format: "%02x", $0) }.joined(),
                certificateFingerprint: "",
                device: nil
            )
        }
    }

    public var current: Persisted {
        queue.sync { state }
    }

    public var bridgeId: String { current.bridgeId }

    public func setCertificateFingerprint(_ fp: String) {
        queue.async { [fileURL] in
            self.state.certificateFingerprint = fp
            self.persistLocked(fileURL: fileURL)
        }
    }

    public func bindFingerprint(_ fp: String) {
        queue.sync {
            state.certificateFingerprint = fp
            persistLocked(fileURL: fileURL)
        }
    }

    /// Register the single valid device, replacing any previous one.
    public func enrollDevice(_ device: PairedDevice) {
        queue.sync {
            state.device = device
            persistLocked(fileURL: fileURL)
        }
    }

    public func revokeDevice() {
        queue.sync {
            if state.device != nil {
                state.device?.revokedAt = Date().timeIntervalSince1970
                state.device = nil
                persistLocked(fileURL: fileURL)
            }
        }
    }

    /// Verified public key for a device id, or nil when unknown/revoked.
    public func deviceKey(deviceId: String) -> Curve25519.Signing.PublicKey? {
        let s = current
        guard let device = s.device, device.deviceId == deviceId, device.revokedAt == nil,
              let raw = Data(base64Encoded: device.publicKey) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    private func persistLocked(fileURL: URL) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

/// In-memory, monotonic-clock, single-use tokens and nonces.
/// Wall-clock changes never revive an expired token (spec: 网络 → 配对).
public final class ClockTokens {
    public struct Pending {
        let digestHex: String
        let issuedAt: ContinuousClock.Instant
    }

    private let clock = ContinuousClock()
    private let queue = DispatchQueue(label: "genius-coder.clocktokens")
    private var pairingToken: Pending?
    private var issuedNonces: [String: Pending] = [:]
    private let nonceTTL: Duration
    private let tokenTTL: Duration

    public init(
        tokenTTL: Duration = .seconds(Int64(EventLimits.pairingTokenTTLSeconds)),
        nonceTTL: Duration = .seconds(Int64(EventLimits.nonceTTLSeconds))
    ) {
        self.tokenTTL = tokenTTL
        self.nonceTTL = nonceTTL
    }

    /// Generate the one-time pairing token shown in the QR code.
    /// Only its SHA-256 stays in memory; a bridge restart clears it.
    public func issuePairingToken() -> String {
        let raw = randomBytes(32)
        let token = raw.map { String(format: "%02x", $0) }.joined()
        queue.sync {
            pairingToken = Pending(digestHex: SHA256Helper.hex(raw), issuedAt: clock.now)
        }
        return token
    }

    /// Single-use, 5-minute (monotonic) redemption of the pairing token.
    /// The token on the wire is the hex of the 32 raw bytes; only the
    /// SHA-256 of the raw bytes was kept in memory.
    public func redeemPairingToken(_ token: String) -> Bool {
        queue.sync {
            guard let pending = pairingToken else { return false }
            guard clock.now - pending.issuedAt < tokenTTL else {
                pairingToken = nil
                return false
            }
            guard let raw = Data(hexEncoded: token), raw.count == 32 else {
                return false
            }
            pairingToken = nil
            return SHA256Helper.hex(raw) == pending.digestHex
        }
    }

    public var hasLivePairingToken: Bool {
        queue.sync {
            guard let pending = pairingToken else { return false }
            if clock.now - pending.issuedAt >= tokenTTL {
                return false
            }
            return true
        }
    }

    /// Issue a fresh 32-byte auth nonce (base64url on the wire).
    public func issueNonce() -> String {
        let raw = randomBytes(32)
        let digest = SHA256Helper.hex(raw)
        queue.sync {
            issuedNonces[digest] = Pending(digestHex: digest, issuedAt: clock.now)
            if issuedNonces.count > 64 {
                let cutoff = clock.now - nonceTTL
                issuedNonces = issuedNonces.filter { $0.value.issuedAt > cutoff }
            }
        }
        return Base64URL.encode(raw)
    }

    /// Single-use nonce consumption with 60s monotonic TTL.
    public func consumeNonce(_ base64url: String) -> Data? {
        guard let raw = Base64URL.decode(base64url), raw.count == 32 else { return nil }
        let digest = SHA256Helper.hex(raw)
        return queue.sync {
            guard let pending = issuedNonces.removeValue(forKey: digest) else { return nil }
            guard clock.now - pending.issuedAt < nonceTTL else { return nil }
            return raw
        }
    }
}

func randomBytes(_ count: Int) -> Data {
    var data = Data(count: count)
    _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
    return data
}

extension Data {
    init?(hexEncoded string: String) {
        let chars = Array(string.lowercased().utf8)
        guard chars.count % 2 == 0 else { return nil }
        func value(_ c: UInt8) -> Int? {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(c - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return Int(c - UInt8(ascii: "a") + 10)
            default: return nil
            }
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let hi = value(chars[index]), let lo = value(chars[index + 1]) else { return nil }
            bytes.append(UInt8(hi << 4 | lo))
            index += 2
        }
        self = Data(bytes)
    }
}
