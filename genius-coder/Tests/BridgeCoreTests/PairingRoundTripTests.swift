import XCTest
import CryptoKit
@testable import BridgeCore
@testable import PhoneProtocol

/// End-to-end over loopback (debug aid): TLS pinning, WebSocket upgrade,
/// auth.enroll → auth.finish, then an authenticated ping.
final class PairingRoundTripTests: XCTestCase {
    func testEnrollFinishPingOverLoopbackTLS() async throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("gc-pairing-\(UUID().uuidString)")
        let server = BridgeServer(appSupportDirectory: support)
        server.bindAddressesOverride = [
            InterfaceLocator.BindAddress(address: "127.0.0.1", kind: .lan, interfaceName: "lo0")
        ]
        server.apiHandler = { session, method, body, completion in
            XCTAssertEqual(method, PhoneMethod.ping.rawValue)
            completion(.success(JSONValue.from(PingResponse(
                bridgeId: session.delegate?.bridgeIdentity ?? "",
                serverTime: 42
            ))))
        }
        let port = server.start()
        let boundPort = try XCTUnwrap(port, "listener should bind on loopback")
        defer { server.stop() }

        // The QR payload the menu bar would show.
        let qr = try XCTUnwrap(server.makePairingQR())
        XCTAssertEqual(qr.port, boundPort)
        XCTAssertEqual(qr.hosts.first?.address, "127.0.0.1")

        let client = BridgePhoneClient()
        let key = Curve25519.Signing.PrivateKey()
        client.connect(configuration: .init(
            host: "127.0.0.1",
            port: boundPort,
            certificateFingerprint: qr.fp,
            bridgeId: qr.bridgeId,
            deviceId: "dev_test",
            signingKey: key
        ))

        // Wait for TLS + WebSocket readiness (pinning accepted our self-signed cert).
        for _ in 0..<100 where client.state() != .connected {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(client.state(), .connected)

        // Enroll with the one-time token, signing the returned nonce.
        let enrolled = await client.enroll(scanned: qr, deviceId: "dev_test", name: "Test Phone")
        guard case .success = enrolled else {
            return XCTFail("enroll failed: \(enrolled)")
        }

        let ping = await client.request(PhoneMethod.ping.rawValue)
        XCTAssertEqual(ping.type, .res)
        XCTAssertEqual(ping.ok, true)

        client.disconnect()
    }

    func testTokenIsSingleUse() {
        let tokens = ClockTokens()
        let token = tokens.issuePairingToken()
        XCTAssertTrue(tokens.redeemPairingToken(token))
        XCTAssertFalse(tokens.redeemPairingToken(token), "token must be single-use")
    }

    func testNonceIsSingleUse() {
        let tokens = ClockTokens()
        let nonce = tokens.issueNonce()
        XCTAssertNotNil(tokens.consumeNonce(nonce))
        XCTAssertNil(tokens.consumeNonce(nonce), "nonce must be single-use")
    }

    func testNonceRoundTripShape() {
        let tokens = ClockTokens()
        let nonce = tokens.issueNonce()
        let raw = Base64URL.decode(nonce)
        XCTAssertEqual(raw?.count, 32)
    }

    func testCertificateIsStableAndPinnable() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("gc-cert-\(UUID().uuidString)")
        let store = CertStore(directory: support)
        let first = try store.loadOrCreate()
        let second = try CertStore(directory: support).loadOrCreate()
        XCTAssertEqual(first.fingerprintHex, second.fingerprintHex, "cert must persist")
        XCTAssertEqual(first.fingerprintHex.count, 64)
        // The certificate must carry our CN.
        let summary = SecCertificateCopySubjectSummary(first.certificate) as String?
        XCTAssertEqual(summary, "genius-coder-bridge")
    }

    func testTailscaleRangeChecks() {
        XCTAssertTrue(InterfaceLocator.isTailscaleIPv4("100.101.102.103"))
        XCTAssertFalse(InterfaceLocator.isTailscaleIPv4("100.64.0.1") == false)
        XCTAssertFalse(InterfaceLocator.isTailscaleIPv4("192.168.1.5"))
        XCTAssertFalse(InterfaceLocator.isTailscaleIPv4("101.0.0.1"), "100.128+ is outside /10")
        XCTAssertTrue(InterfaceLocator.isTailscaleIPv6("fd7a:115c:a1e0::1"))
        XCTAssertFalse(InterfaceLocator.isTailscaleIPv6("fe80::1"))
    }
}
