import XCTest
import PhoneProtocol
@testable import BridgeCore

/// Conversation state machine + API surface over fixtures (no real agents).
final class ConversationFlowTests: XCTestCase {
    func makeApp() throws -> (BridgeApp, support: URL, grokHome: String) {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("gc-flow-\(UUID().uuidString)")
        let grokHome = support.appendingPathComponent("grok").path
        let encoded = "%2FUsers%2Fme%2Fcode"
        let summary = """
        {"info":{"id":"sess-a","cwd":"/Users/me/code"},"generated_title":"Fixture",
         "updated_at":"2026-10-15T08:04:02.840615Z"}
        """
        let dir = support.appendingPathComponent("grok/sessions/\(encoded)/sess-a")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try summary.write(to: dir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        try "{\"timestamp\":1,\"method\":\"session/update\",\"params\":{\"sessionId\":\"sess-a\",\"update\":{\"sessionUpdate\":\"user_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"hi\"}}}}\n{\"timestamp\":2,\"method\":\"session/update\",\"params\":{\"sessionId\":\"sess-a\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"hello \"}}}}\n"
            .write(to: dir.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)
        let allowlist = Allowlist(roots: ["/Users/me/code"], allowRoot: false, seededFromSessions: true, seedPromptAnswered: true)
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
        return (app, support, grokHome)
    }

    func testOpenServesNewestPageOldestFirst() throws {
        let (app, _, _) = try makeApp()
        let result = app.conversations.open(conversationId: "grok:sess-a")
        guard case .success(let response) = result else {
            return XCTFail("open failed: \(result)")
        }
        XCTAssertEqual(response.conversation.agent, .grok)
        XCTAssertEqual(response.conversation.resumable, true)
        XCTAssertEqual(response.state.phase, .idle)
        XCTAssertEqual(response.state.writer, .none)
        // Oldest event first (spec: events 数组按时间正序).
        XCTAssertEqual(response.events.first?.kind, .userMessage)
        XCTAssertEqual(response.events.first?.text, "hi")
        XCTAssertEqual(response.events.last?.kind, .assistantTextDelta)
        XCTAssertEqual(response.nextSeq, 3)
    }

    func testSendDisabledByDefault() throws {
        let (app, _, _) = try makeApp()
        let result = app.conversations.send(conversationId: "grok:sess-a", clientMessageId: "cm_1", text: "continue")
        guard case .failure(let code) = result else {
            return XCTFail("send must be gated by the switch")
        }
        XCTAssertEqual(code, .sendDisabled)
    }

    func testUnknownConversationNotFound() throws {
        let (app, _, _) = try makeApp()
        guard case .failure(let code) = app.conversations.open(conversationId: "grok:nope") else {
            return XCTFail("expected notFound")
        }
        XCTAssertEqual(code, .notFound)
    }

    func testIdempotentClientMessageId() throws {
        let (app, support, _) = try makeApp()
        app.conversations.setSendSwitch(.grok, true, saveTo: support)
        // Grok binary exists in fixtures? send spawns a real process — avoid
        // by pointing at a benign absolute binary that fails fast.
        let first = app.conversations.send(conversationId: "grok:sess-a", clientMessageId: "cm_dup", text: "x")
        guard case .success = first else { return XCTFail("first send accepted: \(first)") }
        // Wait briefly so the idempotency entry is registered.
        Thread.sleep(forTimeInterval: 0.2)
        let second = app.conversations.send(conversationId: "grok:sess-a", clientMessageId: "cm_dup", text: "x")
        guard case .success = second else { return XCTFail("duplicate must be a no-op success: \(second)") }
    }

    func testApprovalOptionValidation() throws {
        let (app, _, _) = try makeApp()
        guard case .failure(let code) = app.conversations.approve(
            conversationId: "grok:sess-a", approvalId: "ap_1", optionId: "acceptForSession"
        ) else {
            return XCTFail("acceptForSession must be rejected")
        }
        XCTAssertEqual(code, .malformedRequest)
    }

    func testPagerCursorsAndOrdering() {
        var events: [ConversationEvent] = []
        for i in 0..<250 {
            events.append(ConversationEvent(seq: Int64(i + 1), kind: .assistantTextDelta, text: "chunk \(i) "))
        }
        let pager = HistoryPager(events: events)
        let newest = pager.newestPage()
        XCTAssertLessThanOrEqual(newest.events.count, EventLimits.historyPageEventCount)
        XCTAssertEqual(newest.events.first?.seq, Int64(251 - newest.events.count), "oldest first inside page")
        guard let cursor = newest.olderCursor else {
            return XCTFail("250 events must paginate")
        }
        guard let older = pager.page(cursor: cursor) else {
            return XCTFail("cursor must decode")
        }
        XCTAssertTrue(older.events.allSatisfy { $0.seq < (newest.events.first?.seq ?? 0) })
        XCTAssertEqual(HistoryPager.decode("bogus!!"), nil)
    }

    func testCatchUpRingDrivesReopenDecision() throws {
        let (app, _, _) = try makeApp()
        _ = app.conversations.open(conversationId: "grok:sess-a")
        // Emit through the manager to fill live events + ring.
        let result = app.conversations.send(conversationId: "grok:sess-a", clientMessageId: "cm_ring", text: "go")
        if case .failure = result {
            // Switch off: enable then emit directly.
        }
        app.conversations.setSendSwitch(.grok, true, saveTo: app.appSupport)
        var ring = CatchUpRing()
        for i in 0..<(EventLimits.catchUpRingEventCount + 5) {
            ring.append(ConversationEvent(seq: Int64(i + 1), kind: .assistantTextDelta, text: "x"))
        }
        XCTAssertTrue(ring.shouldReopen(afterSeq: 3))
        XCTAssertFalse(ring.shouldReopen(afterSeq: Int64(EventLimits.catchUpRingEventCount + 10)))
    }
}
