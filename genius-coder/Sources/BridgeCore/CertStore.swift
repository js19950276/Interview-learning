import Foundation
import Security
import CryptoKit
import PhoneProtocol

/// Generates and persists the bridge's self-signed ECDSA P-256 TLS identity.
/// The certificate file is `0600`; the private key lives in a keychain-free
/// PKCS#8-ish raw form next to it, also `0600`. The phone pins the leaf's
/// SHA-256, so regenerating invalidates pairing.
public final class CertStore {
    public struct Identity {
        public let certificate: SecCertificate
        public let privateKey: SecKey
        public let fingerprintHex: String
    }

    private let directory: URL
    private let queue = DispatchQueue(label: "genius-coder.certstore")

    public init(directory: URL) {
        self.directory = directory
    }

    private var certURL: URL { directory.appendingPathComponent("bridge-cert.der") }
    private var keyURL: URL { directory.appendingPathComponent("bridge-key.raw") }

    /// Load or create the identity. The certificate is regenerated whenever
    /// the stored key/cert pair is missing or mismatched.
    public func loadOrCreate() throws -> Identity {
        try queue.sync {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let existing = try? loadExisting() {
                return existing
            }
            return try generateAndStore()
        }
    }

    private func loadExisting() throws -> Identity? {
        guard FileManager.default.fileExists(atPath: certURL.path),
              FileManager.default.fileExists(atPath: keyURL.path) else { return nil }
        let certData = try Data(contentsOf: certURL)
        let keyData = try Data(contentsOf: keyURL)
        guard let key = try importECKey(raw: keyData) else { return nil }
        guard let cert = SecCertificateCreateWithData(nil, certData as CFData) else { return nil }
        // The public key in the cert must match the stored private key.
        guard let certKey = SecCertificateCopyKey(cert) else { return nil }
        guard let keyPublic = SecKeyCopyPublicKey(key) else { return nil }
        guard let certPub = Self.externalRepresentation(certKey),
              let keyPub = Self.externalRepresentation(keyPublic),
              certPub == keyPub else { return nil }
        let fp = SHA256Helper.hex(certData)
        return Identity(certificate: cert, privateKey: key, fingerprintHex: fp)
    }

    private func generateAndStore() throws -> Identity {
        // ECDSA P-256 key pair outside any keychain.
        let params: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(params as CFDictionary, &error) else {
            throw BridgeError.certGeneration(error?.takeRetainedValue().localizedDescription ?? "SecKeyCreateRandomKey failed")
        }
        let certData = try buildCertificate(for: key, commonName: "genius-coder-bridge")
        guard let keyData = Self.externalRepresentation(key) else {
            throw BridgeError.certGeneration("missing private key representation")
        }

        try certData.write(to: certURL, options: .atomic)
        try keyData.write(to: keyURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: certURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)

        guard let cert = SecCertificateCreateWithData(nil, certData as CFData) else {
            throw BridgeError.certGeneration("SecCertificateCreateWithData rejected generated DER")
        }
        let fp = SHA256Helper.hex(certData)
        return Identity(certificate: cert, privateKey: key, fingerprintHex: fp)
    }

    private func importECKey(raw: Data) throws -> SecKey? {
        let params: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(raw as CFData, params as CFDictionary, &error) else {
            return nil
        }
        return key
    }

    static func externalRepresentation(_ key: SecKey) -> Data? {
        guard let cf = SecKeyCopyExternalRepresentation(key, nil) else { return nil }
        return cf as Data
    }

    /// Build an X.509 v3 self-signed certificate for an EC P-256 key.
    func buildCertificate(for key: SecKey, commonName: String) throws -> Data {
        guard let pubRaw = Self.externalRepresentation(SecKeyCopyPublicKey(key)!) else {
            throw BridgeError.certGeneration("missing public key representation")
        }
        let pubBytes = [UInt8](pubRaw)

        let name = DER.sequence([
            DER.set([DER.sequence([DER.commonName, DER.utf8String(commonName)])])
        ])

        let spki = DER.sequence([
            DER.sequence([DER.ecPublicKey, DER.prime256v1]),
            DER.bitString(pubBytes),
        ])

        let serial = Int.random(in: 1..<Int(Int32.max))
        let now = Date().addingTimeInterval(-60)
        let later = Date().addingTimeInterval(60 * 60 * 24 * 3650)
        let validity = DER.sequence([DER.utcTime(now), DER.utcTime(later)])

        // basicConstraints CA:false, critical
        let basic = DER.sequence([
            DER.basicConstraints,
            DER.octetString([0x30, 0x00]),
        ])

        let tbs = DER.sequence([
            DER.explicit(0, DER.integer(2)),          // version v3
            DER.integer(serial),
            DER.sequence([DER.ecdsaWithSHA256]),
            name,                                      // issuer (self-signed)
            validity,
            name,                                      // subject
            spki,
            DER.explicit(3, DER.sequence([basic])),   // extensions
        ])

        var signError: Unmanaged<CFError>?
        guard let sigCF = SecKeyCreateSignature(
            key, .ecdsaSignatureMessageX962SHA256, Data(tbs) as CFData, &signError
        ), let sig = sigCF as NSData? as Data? else {
            throw BridgeError.certGeneration(signError?.takeRetainedValue().localizedDescription ?? "sign failed")
        }

        let cert = DER.sequence([
            tbs,
            DER.sequence([DER.ecdsaWithSHA256]),
            DER.bitString([UInt8](sig)),
        ])
        return Data(cert)
    }
}

public enum BridgeError: Error, LocalizedError {
    case certGeneration(String)
    case configDirectoryUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .certGeneration(let why): return "certificate generation failed: \(why)"
        case .configDirectoryUnavailable(let p): return "application support directory unavailable: \(p)"
        }
    }
}
