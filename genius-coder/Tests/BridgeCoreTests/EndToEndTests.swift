import XCTest
import CryptoKit
import PhoneProtocol
@testable import BridgeCore

/// Full-stack integration over loopback TLS: server + phone client, pairing,
/// ping, project/conversation lists and read-only opens against fixtures.
final class EndToEndTests: XCTestCase {
    func testPairListOpenOverLoopback() async throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("gc-e2e-\(UUID().uuidString)")
        let grokHome = support.appendingPathComponent("grok").path
        let encoded = "%2FUsers%2Fme%2Fcode"
        let summary = """
        {"info":{"id":"e2e-1","cwd":"/Users/me/code"},"generated_title":"E2E Fixture",
         "updated_at":"2026-10-15T08:04:02.840615Z"}
        """
        let dir = support.appendingPathComponent("grok/sessions/\(encoded)/e2e-1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try summary.write(to: dir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        try "{\"timestamp\":1,\"method\":\"session/update\",\"params\":{\"sessionId\":\"e2e-1\",\"update\":{\"sessionUpdate\":\"user_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"round trip\"}}}}\n"
            .write(to: dir.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)

        let allowlist = Allowlist(roots: ["/Users/me/code"], seededFromSessions: true, seedPromptAnswered: true)
        allowlist.save(to: support)
        let app = BridgeApp(
            appSupport: support,
            indexers: [
                CodexIndex(home: support.appendingPathComponent("codex").path),
                GrokIndex(home: grokHome, binaries: AgentBinaries(grokOverride: "/usr/bin/true")),
                ClaudeIndex(projectsRoot: support.appendingPathComponent("claude").path),
                DshIndex(home: support.appendingPathComponent("dsh").path),
            ]
        )
        app.server.bindAddressesOverride = [
            InterfaceLocator.BindAddress(address: "127.0.0.1", kind: .lan, interfaceName: "lo0")
        ]
        let port = try XCTUnwrap(app.startNetwork(), "server should bind loopback")
        defer { app.stop() }

        let qr = try XCTUnwrap(app.server.makePairingQR())
        let client = BridgePhoneClient()
        client.connect(configuration: .init(
            host: "127.0.0.1",
            port: port,
            certificateFingerprint: qr.fp,
            bridgeId: qr.bridgeId,
            deviceId: "dev_e2e",
            signingKey: Curve25519.Signing.PrivateKey()
        ))
        for _ in 0..<100 where client.state() != .connected {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(client.state(), .connected, "TLS pinning + WebSocket upgrade")

        let enrolled = await client.enroll(scanned: qr, deviceId: "dev_e2e", name: "E2E Phone")
        guard case .success = enrolled else { return XCTFail("enroll failed: \(enrolled)") }

        let ping = await client.request(PhoneMethod.ping.rawValue)
        XCTAssertEqual(ping.ok, true)

        let projectsRes = await client.request(PhoneMethod.projectsList.rawValue, body: JSONValue.from(ProjectsListRequest()))
        XCTAssertEqual(projectsRes.ok, true)
        let projects = try XCTUnwrap(try? projectsRes.body?.asDecode(ProjectsListResponse.self))
        XCTAssertEqual(projects.projects.count, 1)
        XCTAssertEqual(projects.projects.first?.counts["grok"], 1)

        let pid = try XCTUnwrap(projects.projects.first).projectId
        let listRes = await client.request(
            PhoneMethod.conversationsList.rawValue,
            body: JSONValue.from(ConversationsListRequest(projectId: pid))
        )
        let conversations = try XCTUnwrap(try? listRes.body?.asDecode(ConversationsListResponse.self))
        XCTAssertEqual(conversations.conversations.first?.conversationId, "grok:e2e-1")

        let openRes = await client.request(
            PhoneMethod.conversationOpen.rawValue,
            body: JSONValue.from(ConversationOpenRequest(conversationId: "grok:e2e-1"))
        )
        XCTAssertEqual(openRes.ok, true, "open must succeed: \(openRes.code ?? "")")
        let opened = try XCTUnwrap(try? openRes.body?.asDecode(ConversationOpenResponse.self))
        XCTAssertEqual(opened.state.phase, .idle)
        XCTAssertEqual(opened.events.first?.text, "round trip")

        // Send is switch-gated → send_disabled (spec: 默认关闭).
        let sendRes = await client.request(
            PhoneMethod.conversationSend.rawValue,
            body: JSONValue.from(ConversationSendRequest(conversationId: "grok:e2e-1", clientMessageId: "cm_e2e", text: "hi"))
        )
        XCTAssertEqual(sendRes.code, PhoneErrorCode.sendDisabled.rawValue)

        client.disconnect()
    }
}
