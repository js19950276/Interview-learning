import CryptoKit
import Foundation

extension GameCore {
    nonisolated enum CanonicalChecksum {
        static func sha256<T: Encodable>(_ value: T) throws -> String {
            let data = try JSONEncoder.canonical.encode(value)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}
