import Foundation
import CryptoKit

/// Minimal JSON value so envelope bodies can stay schema-light on the wire
/// while remaining strongly typed at the edges via `asDecode`.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unsupported JSON value")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // MARK: convenience accessors

    public var isNull: Bool { if case .null = self { return true }; return false }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var intValue: Int64? {
        if case .int(let i) = self { return i }
        if case .double(let d) = self { return Int64(exactly: d.rounded()) }
        return nil
    }
    public var doubleValue: Double? {
        if case .double(let d) = self { return d }
        if case .int(let i) = self { return Double(i) }
        return nil
    }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var dictionaryValue: [String: JSONValue]? { objectValue }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard let a = arrayValue, index >= 0, index < a.count else { return nil }
        return a[index]
    }

    /// Decode a strongly-typed value out of this JSON.
    public func asDecode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }

    /// Wrap any Encodable into a JSONValue.
    public static func from<T: Encodable>(_ value: T) -> JSONValue {
        (try? JSONEncoder().encode(value)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .null
    }

    public static func stringMap(_ dict: [String: String]) -> JSONValue {
        .object(dict.mapValues { .string($0) })
    }
}

// MARK: - Small helpers shared by both ends

public enum SHA256Helper {
    public static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func raw(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

/// Signing input for `auth.finish` (spec: 网络 → 配对, step 5):
/// the 32 raw nonce bytes directly concatenated with the UTF-8 bytes of
/// `bridgeId`. No length prefix. `deviceId` is NOT part of the signed bytes.
public enum AuthSignatureInput {
    public static func bytes(nonce: Data, bridgeId: String) -> Data {
        nonce + Data(bridgeId.utf8)
    }
}
