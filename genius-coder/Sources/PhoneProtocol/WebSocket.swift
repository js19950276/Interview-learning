import Foundation
import CryptoKit
import Security

/// Incremental WebSocket frame codec shared by the bridge (server) and the
/// phone (client). Handles fragmentation of both frames and messages,
/// ping/pong and close. Text frames only carry UTF-8 JSON for our protocol.
public final class WebSocketFrameCodec: @unchecked Sendable {
    public enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    public struct IncomingMessage {
        public enum Payload {
            case text(Data)
            case binary(Data)
            case close(code: UInt16?, reason: Data)
        }
        public var payload: Payload
        public init(payload: Payload) { self.payload = payload }
    }

    public enum DecodeResult {
        case needMoreData
        case message(IncomingMessage)
        case control(Opcode, Data)
    }

    private let isClient: Bool
    private var buffer = Data()
    private var fragmentedPayload = Data()
    private var fragmentedOpcode: Opcode?
    private var closed = false

    public init(isClient: Bool) {
        self.isClient = isClient
    }

    public var isClosed: Bool { closed }

    // MARK: decoding

    public func append(_ data: Data) {
        buffer.append(data)
    }

    /// Try to decode the next message from the buffered stream.
    public func decodeNext() -> DecodeResult {
        guard !closed else { return .needMoreData }
        while true {
            guard buffer.count >= 2 else { return .needMoreData }
            let b0 = buffer[buffer.startIndex]
            let b1 = buffer[buffer.index(after: buffer.startIndex)]
            let fin = (b0 & 0x80) != 0
            let rsv = (b0 & 0x70) != 0
            guard !rsv else {
                closed = true
                return .message(IncomingMessage(payload: .close(code: 1002, reason: Data())))
            }
            guard let opcode = Opcode(rawValue: b0 & 0x0F) else {
                closed = true
                return .message(IncomingMessage(payload: .close(code: 1002, reason: Data())))
            }
            let masked = (b1 & 0x80) != 0
            var len = Int(b1 & 0x7F)
            var offset = 2
            if len == 126 {
                guard buffer.count >= offset + 2 else { return .needMoreData }
                len = Int(buffer[buffer.index(buffer.startIndex, offsetBy: offset)]) << 8
                    | Int(buffer[buffer.index(buffer.startIndex, offsetBy: offset + 1)])
                offset += 2
            } else if len == 127 {
                guard buffer.count >= offset + 8 else { return .needMoreData }
                len = 0
                for i in 0..<8 {
                    len = len << 8 | Int(buffer[buffer.index(buffer.startIndex, offsetBy: offset + i)])
                }
                // Sanity: our messages are at most a few MB.
                guard len >= 0, len <= 64 * 1024 * 1024 else {
                    closed = true
                    return .message(IncomingMessage(payload: .close(code: 1009, reason: Data())))
                }
                offset += 8
            }
            // A server must reject masked... actually clients MUST mask, servers MUST NOT.
            // We accept both shapes to stay tolerant of the peer implementation.
            var maskKey: [UInt8]? = nil
            if masked {
                guard buffer.count >= offset + 4 else { return .needMoreData }
                let ks = buffer.index(buffer.startIndex, offsetBy: offset)
                maskKey = [buffer[ks], buffer[buffer.index(after: ks)], buffer[buffer.index(ks, offsetBy: 2)], buffer[buffer.index(ks, offsetBy: 3)]]
                offset += 4
            }
            guard buffer.count >= offset + len else { return .needMoreData }
            var payload = buffer.subdata(in: buffer.index(buffer.startIndex, offsetBy: offset)..<buffer.index(buffer.startIndex, offsetBy: offset + len))
            if let mask = maskKey {
                var unmasked = Data(capacity: payload.count)
                for (i, byte) in payload.enumerated() {
                    unmasked.append(byte ^ mask[i % 4])
                }
                payload = unmasked
            }
            buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: offset + len))

            switch opcode {
            case .close:
                closed = true
                let code: UInt16? = payload.count >= 2
                    ? UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.index(after: payload.startIndex)])
                    : nil
                return .message(IncomingMessage(payload: .close(code: code, reason: payload.count > 2 ? payload.dropFirst(2) : Data())))
            case .ping, .pong:
                return .control(opcode, payload)
            case .text, .binary:
                if fin && fragmentedOpcode == nil {
                    return .message(IncomingMessage(payload: opcode == .text ? .text(payload) : .binary(payload)))
                }
                if fragmentedOpcode == nil { fragmentedOpcode = opcode }
                fragmentedPayload.append(payload)
                if fin {
                    let op = fragmentedOpcode ?? .text
                    let full = fragmentedPayload
                    fragmentedPayload = Data()
                    fragmentedOpcode = nil
                    return .message(IncomingMessage(payload: op == .text ? .text(full) : .binary(full)))
                }
                continue
            case .continuation:
                guard fragmentedOpcode != nil else {
                    closed = true
                    return .message(IncomingMessage(payload: .close(code: 1002, reason: Data())))
                }
                fragmentedPayload.append(payload)
                if fin {
                    let op = fragmentedOpcode ?? .text
                    let full = fragmentedPayload
                    fragmentedPayload = Data()
                    fragmentedOpcode = nil
                    return .message(IncomingMessage(payload: op == .text ? .text(full) : .binary(full)))
                }
                continue
            }
        }
    }

    // MARK: encoding

    private func encodeFrame(opcode: Opcode, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode.rawValue)
        let maskBit: UInt8 = isClient ? 0x80 : 0x00
        if payload.count < 126 {
            frame.append(maskBit | UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(maskBit | 126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(maskBit | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((payload.count >> shift) & 0xFF))
            }
        }
        if isClient {
            var key = [UInt8](repeating: 0, count: 4)
            let status = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
            if status != errSecSuccess {
                key = [UInt8](randomBytes4())
            }
            frame.append(contentsOf: key)
            for (i, byte) in payload.enumerated() {
                frame.append(byte ^ key[i % 4])
            }
        } else {
            frame.append(payload)
        }
        return frame
    }

    private func randomBytes4() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        return bytes
    }

    public func encodeText(_ data: Data) -> Data {
        encodeFrame(opcode: .text, payload: data)
    }

    public func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        encodeFrame(opcode: .text, payload: try JSONEncoder().encode(value))
    }

    public func encodeClose(code: UInt16 = 1000) -> Data {
        var payload = Data()
        payload.append(UInt8((code >> 8) & 0xFF))
        payload.append(UInt8(code & 0xFF))
        return encodeFrame(opcode: .close, payload: payload)
    }

    public func encodePong(_ payload: Data) -> Data {
        encodeFrame(opcode: .pong, payload: payload)
    }

    public func encodePing(_ payload: Data = Data()) -> Data {
        encodeFrame(opcode: .ping, payload: payload)
    }
}

// MARK: - Handshake

public enum WebSocketHandshake {
    public static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// `Sec-WebSocket-Accept` = base64(SHA1(key + guid)).
    public static func acceptValue(for key: String) -> String {
        let combined = key + guid
        let digest = Insecure.SHA1.hash(data: Data(combined.utf8))
        return Data(digest).base64EncodedString()
    }

    public static func newClientKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return Data(bytes).base64EncodedString()
    }

    public static func clientRequest(host: String, port: UInt16, key: String) -> Data {
        var req = "GET / HTTP/1.1\r\n"
        req += "Host: \(host):\(port)\r\n"
        req += "Upgrade: websocket\r\n"
        req += "Connection: Upgrade\r\n"
        req += "Sec-WebSocket-Key: \(key)\r\n"
        req += "Sec-WebSocket-Version: 13\r\n"
        req += "\r\n"
        return Data(req.utf8)
    }

    public static func serverAccept(clientKey: String) -> Data {
        let response = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(acceptValue(for: clientKey))\r\n"
            + "\r\n"
        return Data(response.utf8)
    }

    public struct ParsedClientRequest {
        public var websocketKey: String
        public var path: String
    }

    /// Parse the HTTP upgrade request arriving on the server.
    public static func parseClientRequest(_ data: Data) -> ParsedClientRequest? {
        guard let text = String(data: data, encoding: .utf8),
              let headerEnd = text.range(of: "\r\n\r\n") else { return nil }
        let head = String(text[..<headerEnd.lowerBound])
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        var key: String?
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let name = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "sec-websocket-key" {
                key = kv[1].trimmingCharacters(in: .whitespaces)
            }
        }
        guard let key, !key.isEmpty else { return nil }
        return ParsedClientRequest(websocketKey: key, path: parts[1])
    }

    /// Validate the server's 101 response on the client side. Returns any
    /// trailing bytes that arrived after the handshake.
    public static func parseServerResponse(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8),
              let headerEnd = text.range(of: "\r\n\r\n") else { return nil }
        let head = String(text[..<headerEnd.lowerBound])
        guard head.contains("101") else { return nil }
        let after = text[headerEnd.upperBound...]
        return Data(after.utf8)
    }
}
