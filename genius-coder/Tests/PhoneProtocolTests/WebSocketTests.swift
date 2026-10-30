import XCTest
@testable import PhoneProtocol

final class WebSocketTests: XCTestCase {
    func testAcceptValue() {
        // RFC 6455 example.
        XCTAssertEqual(
            WebSocketHandshake.acceptValue(for: "dGhlIHNhbXBsZSBub25jZQ=="),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        )
    }

    func testServerAcceptMatchesClientParse() throws {
        let key = WebSocketHandshake.newClientKey()
        let accept = WebSocketHandshake.acceptValue(for: key)
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        XCTAssertNotNil(WebSocketHandshake.parseServerResponse(Data(response.utf8)))
    }

    func testParseClientRequest() throws {
        let key = WebSocketHandshake.newClientKey()
        let req = WebSocketHandshake.clientRequest(host: "192.168.1.10", port: 8787, key: key)
        let parsed = WebSocketHandshake.parseClientRequest(req)
        XCTAssertEqual(parsed?.websocketKey, key)
        XCTAssertEqual(parsed?.path, "/")
    }

    func testFrameRoundTripText() throws {
        let server = WebSocketFrameCodec(isClient: false)
        let client = WebSocketFrameCodec(isClient: true)
        let payload = Data(#"{"v":1,"type":"req","id":"1","method":"ping"}"#.utf8)
        let wire = client.encodeText(payload)
        client.append(Data()) // no-op
        // Feed client-encoded (masked) frame into server codec.
        var sink = WebSocketFrameCodec(isClient: false)
        sink.append(wire)
        guard case .message(let msg) = sink.decodeNext(), case .text(let text) = msg.payload else {
            return XCTFail("expected text message")
        }
        XCTAssertEqual(text, payload)
        // And server-encoded (unmasked) frame into client codec.
        var sink2 = WebSocketFrameCodec(isClient: true)
        sink2.append(server.encodeText(payload))
        guard case .message(let msg2) = sink2.decodeNext(), case .text(let text2) = msg2.payload else {
            return XCTFail("expected text message 2")
        }
        XCTAssertEqual(text2, payload)
    }

    func testFragmentedLargeMessage() {
        let codec = WebSocketFrameCodec(isClient: false)
        let big = Data(repeating: 0x61, count: 300_000)
        let frame = codec.encodeText(big)
        // Split the wire bytes into odd chunks to exercise buffering.
        var sink = WebSocketFrameCodec(isClient: false)
        var idx = frame.startIndex
        while idx < frame.endIndex {
            let step = min(777, frame.distance(from: idx, to: frame.endIndex))
            let next = frame.index(idx, offsetBy: step)
            sink.append(frame.subdata(in: idx..<next))
            idx = next
        }
        guard case .message(let msg) = sink.decodeNext(), case .text(let text) = msg.payload else {
            return XCTFail("expected big text message")
        }
        XCTAssertEqual(text.count, 300_000)
    }

    func testPingPongEncode() {
        let codec = WebSocketFrameCodec(isClient: true)
        let pong = codec.encodePong(Data([1, 2, 3]))
        var sink = WebSocketFrameCodec(isClient: false)
        sink.append(pong)
        guard case .control(let op, let payload) = sink.decodeNext() else { return XCTFail("expected control") }
        XCTAssertEqual(op, .pong)
        XCTAssertEqual(payload, Data([1, 2, 3]))
    }
}
