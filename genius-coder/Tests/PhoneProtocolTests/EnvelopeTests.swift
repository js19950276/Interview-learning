import XCTest
import CryptoKit
@testable import PhoneProtocol

final class EnvelopeTests: XCTestCase {
    func testRoundTrip() throws {
        let env = WireEnvelope.request(id: "8f1c", method: "conversation.send", body: .object(["conversationId": .string("grok:6f0e")]))
        let data = try env.encoded()
        let back = try WireEnvelope.decode(data)
        XCTAssertEqual(back, env)
    }

    func testVersionMismatchRejected() throws {
        let json = #"{"v":2,"type":"req","id":"1","method":"ping"}"#
        XCTAssertThrowsError(try WireEnvelope.decode(Data(json.utf8)))
    }

    func testSignatureInputBytes() {
        // Spec PR1: signature input is rawNonce || utf8(bridgeId), no length prefix.
        let nonce = Data((0..<32).map { UInt8($0 & 0xFF) })
        let bridgeId = "br_01"
        let input = AuthSignatureInput.bytes(nonce: nonce, bridgeId: bridgeId)
        XCTAssertEqual(input.count, 32 + 5)
        XCTAssertEqual(input.prefix(32), nonce)
        XCTAssertEqual(input.suffix(5), Data("br_01".utf8))
    }

    func testEd25519SignVerifyOverSpecBytes() throws {
        let key = Curve25519.Signing.PrivateKey()
        let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let input = AuthSignatureInput.bytes(nonce: nonce, bridgeId: "br_9f")
        let sig = try key.signature(for: input)
        XCTAssertTrue(key.publicKey.isValidSignature(sig, for: input))
        // deviceId is not part of the signed bytes:
        let other = AuthSignatureInput.bytes(nonce: nonce, bridgeId: "br_XX")
        XCTAssertFalse(key.publicKey.isValidSignature(sig, for: other))
    }

    func testBase64URLRoundTrip() {
        let data = Data((0..<64).map { UInt8(($0 * 7) & 0xFF) })
        let encoded = Base64URL.encode(data)
        XCTAssertFalse(encoded.contains("=") || encoded.contains("+") || encoded.contains("/"))
        XCTAssertEqual(Base64URL.decode(encoded), data)
    }

    func testConversationIDRoundTrip() {
        let id = ConversationID(rawValue: "codex:01a11a84-ace7-7e30-88c3-f8bcc2a97c79")!
        XCTAssertEqual(id.agent, .codex)
        XCTAssertEqual(id.nativeID, "01a11a84-ace7-7e30-88c3-f8bcc2a97c79")
        XCTAssertEqual(id.rawValue, "codex:01a11a84-ace7-7e30-88c3-f8bcc2a97c79")
        XCTAssertNil(ConversationID(rawValue: "bogus"))
    }

    func testProjectIDShape() {
        let pid = ProjectID(canonicalPath: "/Users/me/code")!
        XCTAssertTrue(pid.rawValue.hasPrefix("proj_"))
        XCTAssertEqual(pid.rawValue.count, 5 + 16)
    }
}
