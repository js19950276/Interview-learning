import XCTest
import PhoneProtocol
@testable import BridgeCore

final class IndexTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gc-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ path: String, _ content: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func testGrokIndexFixture() throws {
        let grokHome = root.appendingPathComponent("grok").path
        let encoded = "%2FUsers%2Fme%2Fcode"
        let summaryA = """
        {"info":{"id":"aaa","cwd":"/Users/me/code"},"generated_title":"Alpha",
         "updated_at":"2026-10-15T08:04:02.840615Z","last_active_at":"2026-10-15T08:04:02.840615Z"}
        """
        let summarySub = """
        {"info":{"id":"child","cwd":"/Users/me/code"},"session_summary":"sub work",
         "session_kind":"subagent_resume","parent_session_id":"aaa",
         "updated_at":"2026-10-16T08:04:02.840615Z"}
        """
        let summaryNoLog = """
        {"info":{"id":"nolog","cwd":"/Users/me/code"},"generated_title":"No log",
         "updated_at":"2026-10-14T08:04:02.840615Z"}
        """
        try write("grok/sessions/\(encoded)/aaa/summary.json", summaryA)
        try write("grok/sessions/\(encoded)/aaa/updates.jsonl", "{}\n")
        try write("grok/sessions/\(encoded)/child/summary.json", summarySub)
        try write("grok/sessions/\(encoded)/nolog/summary.json", summaryNoLog)

        let indexer = GrokIndex(home: grokHome, binaries: AgentBinaries(grokOverride: "/usr/bin/true"))
        let rows = indexer.scan()
        XCTAssertEqual(rows.count, 3)
        let child = rows.first { $0.nativeId == "child" }
        XCTAssertEqual(child?.parentNativeId, "aaa")
        XCTAssertNil(rows.first { $0.nativeId == "aaa" }?.parentNativeId)
        let nolog = rows.first { $0.nativeId == "nolog" }
        XCTAssertEqual(nolog?.emptyHistory, true)
        XCTAssertEqual(nolog?.resumable, true)
        // ISO-8601 fractional seconds parse to epoch ms.
        let a = rows.first { $0.nativeId == "aaa" }
        XCTAssertGreaterThan(a?.updatedAt ?? 0, 1_700_000_000_000)

        // Missing binary flips resumable off.
        let missingBinary = GrokIndex(home: grokHome, binaries: AgentBinaries(grokOverride: "/nonexistent/grok"))
        XCTAssertTrue(missingBinary.scan().allSatisfy { !$0.resumable })
    }

    func testDshIndexFixture() throws {
        let dshHome = root.appendingPathComponent("dsh").path
        let encoded = "--Users-me-code--"
        let logPath = "dsh/sessions/\(encoded)/session-8b9ca437-0000-0000-0000-4bc8ea9857a2/session.v4.jsonl.zstd"
        try write(logPath, Data([0x28, 0xB5, 0x2F, 0xFD]).base64EncodedString())
        let projcache = """
        {"version":7,"record":{"identity":{"formatVersion":4,"createdAt":1792589749715,
          "cwd":"/Users/me/code","isSeeded":false,"inheritedEventCount":0},
          "rows":{"title":{"ver":1,"seq":10,"val":"My DSH Session"},
            "sessionListMetadata":{"ver":1,"seq":10,"val":{"blank":true,"lastPromptAt":1792589900000}}}}}
        """
        try write("dsh/storages/session_projcache/sessions/session-8b9ca437-0000-0000-0000-4bc8ea9857a2.json", projcache)
        try write("dsh/storages/workspace.json", """
        {"unit":{"name":"workspace","version":2},"global":{"initialized":true,
         "workspaceIds":["w"],"archivedSessionIds":[],"pinnedSessionIds":[]},
         "tables":{"workspaces":{"w":{"path":"/Users/me/code","title":"code","sessionIds":["session-8b9ca437-0000-0000-0000-4bc8ea9857a2"]}}}}
        """)

        let indexer = DshIndex(home: dshHome, binaries: AgentBinaries(dshOverride: "/usr/bin/true"))
        let rows = indexer.scan()
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertEqual(row.cwd, "/Users/me/code")
        XCTAssertEqual(row.title, "My DSH Session")
        XCTAssertEqual(row.updatedAt, 1_792_589_900_000)
        XCTAssertTrue(row.resumable)
        XCTAssertNil(row.resumableError)

        // Unsupported version → unavailable with the right code.
        let badCache = projcache.replacingOccurrences(of: "\"formatVersion\":4", with: "\"formatVersion\":0")
        try write("dsh/storages/session_projcache/sessions/session-8b9ca437-0000-0000-0000-4bc8ea9857a2.json", badCache)
        let bad = DshIndex(home: dshHome, binaries: AgentBinaries(dshOverride: "/usr/bin/true")).scan()
        XCTAssertEqual(bad[0].resumable, false)
        XCTAssertEqual(bad[0].resumableError, "unsupported_session_version")
    }

    func testClaudeIndexMissingDirectoryIsEmpty() {
        let rows = ClaudeIndex(projectsRoot: root.appendingPathComponent("nope-claude").path).scan()
        XCTAssertTrue(rows.isEmpty)
    }

    func testClaudeIndexExistingFilesNeedFixture() throws {
        try write("claude-projects/my-project/3f2a7c1e-1111-2222-3333-444455556666.jsonl", "{\"x\":1}\n")
        let rows = ClaudeIndex(projectsRoot: root.appendingPathComponent("claude-projects").path).scan()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].resumable, false)
        XCTAssertEqual(rows[0].resumableError, "claude_history_needs_fixture")
        XCTAssertEqual(rows[0].cwd, "", "never guess cwd from the slug")
    }

    func testCodexTitleFallbackOrder() {
        XCTAssertEqual(CodexIndex.title(name: "N", title: "T", preview: "P", firstUserMessage: "F", id: "id12345678"), "N")
        XCTAssertEqual(CodexIndex.title(name: "", title: "T", preview: "P", firstUserMessage: "F", id: "id12345678"), "T")
        XCTAssertEqual(CodexIndex.title(name: "", title: "", preview: "P", firstUserMessage: "F", id: "id12345678"), "P")
        XCTAssertEqual(CodexIndex.title(name: "", title: "", preview: "", firstUserMessage: "", id: "id12345678"), "id123456")
    }

    func testCodexRolloutSiblingResolution() throws {
        // rollout_path points at a missing .jsonl; the .zst sibling exists.
        let zst = root.appendingPathComponent("rollout-x.jsonl.zst")
        try Data([1]).write(to: zst)
        XCTAssertEqual(CodexIndex.resolveRollout(zst.path.deletingSuffix(".zst")), zst.path)
        XCTAssertEqual(CodexIndex.resolveRollout("/definitely/missing.jsonl"), "/definitely/missing.jsonl")
    }

    func testIndexStoreAggregationAndAllowlist() throws {
        let grokHome = root.appendingPathComponent("g2").path
        try write("g2/sessions/%2FUsers%2Fme%2Fcode/aaa/summary.json", """
        {"info":{"id":"aaa","cwd":"/Users/me/code"},"generated_title":"Alpha",
         "updated_at":"2026-10-15T08:04:02.840615Z"}
        """)
        try write("g2/sessions/%2FUsers%2Fme%2Fcode/child/summary.json", """
        {"info":{"id":"child","cwd":"/Users/me/code"},"session_summary":"sub",
         "session_kind":"subagent","parent_session_id":"aaa","updated_at":"2026-10-16T08:04:02Z"}
        """)
        // Outside the allowlist:
        try write("g2/sessions/%2FUsers%2Fme%2Fother/bbb/summary.json", """
        {"info":{"id":"bbb","cwd":"/Users/me/other"},"generated_title":"Elsewhere",
         "updated_at":"2026-10-17T08:04:02Z"}
        """)

        let support = root.appendingPathComponent("support")
        let realCodeDir = root.appendingPathComponent("real/code")
        try FileManager.default.createDirectory(at: realCodeDir, withIntermediateDirectories: true)
        let realRoot = try XCTUnwrap(Allowlist.normalizeRoot(realCodeDir.deletingLastPathComponent().path, explicitRootAllowed: false))
        let realAllowlist = Allowlist(roots: [realRoot], allowRoot: false, seededFromSessions: true, seedPromptAnswered: true)

        // Rebuild grok rows against real paths.
        try write("g2/sessions/x/session-1/summary.json", """
        {"info":{"id":"s1","cwd":"\(realCodeDir.path)"},"generated_title":"In Allow",
         "updated_at":"2026-10-15T08:04:02Z"}
        """)
        try write("g2/sessions/y/session-2/summary.json", """
        {"info":{"id":"s2","cwd":"\(root.path)/outside"},"generated_title":"Out",
         "updated_at":"2026-10-16T08:04:02Z"}
        """)

        let store = IndexStore(
            appSupportDirectory: support,
            allowlist: realAllowlist,
            indexers: [GrokIndex(home: grokHome, binaries: AgentBinaries(grokOverride: "/usr/bin/true"))]
        )
        store.refresh()

        let projects = store.projects(filter: .all)
        XCTAssertEqual(projects.count, 1, "outside project must be filtered")
        XCTAssertEqual(projects[0].canonicalPath, CanonicalPath.realpath(realCodeDir.path))

        let pid = projects[0].projectId
        let conversations = store.conversations(projectId: pid, filter: .all, limit: 100)
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(try XCTUnwrap(conversations.first).conversationId, "grok:s1")

        // Agent filter with no grok rows hides the project.
        XCTAssertTrue(store.projects(filter: .codex).isEmpty)

        // Cache round trip: a fresh store loads from sqlite.
        let reloaded = IndexStore(
            appSupportDirectory: support,
            allowlist: realAllowlist,
            indexers: []
        )
        XCTAssertEqual(reloaded.projects(filter: .all).count, 1)
        XCTAssertEqual(reloaded.conversations(projectId: pid, filter: .all, limit: 100).count, 1)
    }
}

extension String {
    func deletingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
