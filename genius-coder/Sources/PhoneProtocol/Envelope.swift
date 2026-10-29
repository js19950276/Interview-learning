import Foundation

/// Outer wire frame for the phone ⇄ bridge WebSocket JSON protocol.
///
/// Spec: text frames, UTF-8 JSON, one object per frame.
/// `v` must be 1; anything else is rejected with `unsupported_protocol`.
public struct WireEnvelope: Codable, Equatable, Sendable {
    public var v: Int
    public var type: FrameType
    /// Correlation id, present on `req`, `res` and `err`.
    public var id: String?
    /// Method name, present on `req` and on `event`.
    public var method: String?
    /// Payload, present on `req`, `res`, `event` and optionally `err`.
    public var body: JSONValue?
    /// Only on `res`: whether the request succeeded.
    public var ok: Bool?
    /// Only on `err`: machine-readable error code from the spec table.
    public var code: String?
    /// Only on `err`: human message, never contains rollout paths, env vars or tokens.
    public var message: String?

    public init(
        v: Int = 1,
        type: FrameType,
        id: String? = nil,
        method: String? = nil,
        body: JSONValue? = nil,
        ok: Bool? = nil,
        code: String? = nil,
        message: String? = nil
    ) {
        self.v = v
        self.type = type
        self.id = id
        self.method = method
        self.body = body
        self.ok = ok
        self.code = code
        self.message = message
    }

    public enum FrameType: String, Codable, Sendable {
        case req
        case res
        case event
        case err
    }

    public static func request(id: String, method: String, body: JSONValue? = nil) -> WireEnvelope {
        WireEnvelope(type: .req, id: id, method: method, body: body)
    }

    public static func response(id: String, ok: Bool, body: JSONValue? = nil) -> WireEnvelope {
        WireEnvelope(type: .res, id: id, ok: ok, body: body)
    }

    public static func event(method: String, body: JSONValue?) -> WireEnvelope {
        WireEnvelope(type: .event, method: method, body: body)
    }

    public static func error(id: String?, code: String, message: String) -> WireEnvelope {
        WireEnvelope(type: .err, id: id, code: code, message: message)
    }

    public enum CodingKeys: String, CodingKey {
        case v, type, id, method, body, ok, code, message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        guard v == 1 else { throw PhoneProtocolError.unsupportedProtocol }
        type = try c.decode(FrameType.self, forKey: .type)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        method = try c.decodeIfPresent(String.self, forKey: .method)
        body = try c.decodeIfPresent(JSONValue.self, forKey: .body)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok)
        code = try c.decodeIfPresent(String.self, forKey: .code)
        message = try c.decodeIfPresent(String.self, forKey: .message)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> WireEnvelope {
        try JSONDecoder().decode(WireEnvelope.self, from: data)
    }
}

public enum PhoneProtocolError: Error, Equatable {
    case unsupportedProtocol
    case malformedFrame(String)
}
