import XCTest
import PhoneProtocol
@testable import BridgeCore

final class AllowlistTests: XCTestCase {
    func testSiblingDirectoriesNeverMatch() {
        // Spec PR1: `/Users/me/code` must not match `/Users/me/code-evil`
        // or `/Users/me/code.bak`.
        let allowlist = Allowlist(roots: ["/Users/me/code"], allowRoot: false)
        XCTAssertTrue(allowlist.matches(canonicalPath: "/Users/me/code"))
        XCTAssertTrue(allowlist.matches(canonicalPath: "/Users/me/code/repo"))
        XCTAssertTrue(allowlist.matches(canonicalPath: "/Users/me/code/a/b/c"))
        XCTAssertFalse(allowlist.matches(canonicalPath: "/Users/me/code-evil"))
        XCTAssertFalse(allowlist.matches(canonicalPath: "/Users/me/code.bak"))
        XCTAssertFalse(allowlist.matches(canonicalPath: "/Users/me/cod"))
        XCTAssertFalse(allowlist.matches(canonicalPath: "/Users/me"))
        XCTAssertFalse(allowlist.matches(canonicalPath: "/"))
    }

    func testMultipleRootsAndRootAllowance() {
        let allowlist = Allowlist(roots: ["/a", "/b/c"], allowRoot: false)
        XCTAssertTrue(allowlist.matches(canonicalPath: "/a/x"))
        XCTAssertTrue(allowlist.matches(canonicalPath: "/b/c"))
        XCTAssertFalse(allowlist.matches(canonicalPath: "/b"))
        let allowEverything = Allowlist(roots: [], allowRoot: true)
        XCTAssertTrue(allowEverything.matches(canonicalPath: "/anything"))
    }

    func testNormalizeRootRejectsRelativeAndRoot() {
        XCTAssertNil(Allowlist.normalizeRoot("relative/path", explicitRootAllowed: false))
        XCTAssertNil(Allowlist.normalizeRoot("/", explicitRootAllowed: false))
        XCTAssertNotNil(Allowlist.normalizeRoot("/", explicitRootAllowed: true))
        XCTAssertEqual(Allowlist.normalizeRoot("/tmp/../private/tmp", explicitRootAllowed: false), "/private/tmp")
    }

    func testRoundTripPersistence() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gc-allowlist-\(UUID().uuidString)")
        var allowlist = Allowlist(roots: ["/Users/me/code"])
        allowlist.save(to: dir)
        let loaded = Allowlist.load(from: dir)
        XCTAssertEqual(loaded, allowlist)
    }

    func testCanonicalizePromotesGitRoot() throws {
        // Build a real git repo with a nested dir; canonicalize must promote.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("gc-canonical-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("repo")
        let nested = repo.appendingPathComponent("nested/deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "--quiet", repo.path]
        try git.run(); git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0, "git init must succeed for the fixture")

        let promoted = CanonicalPath.canonicalize(cwd: nested.path)
        XCTAssertEqual(promoted.path, CanonicalPath.realpath(repo.path))
        XCTAssertEqual(promoted.missing, false)

        let missing = CanonicalPath.canonicalize(cwd: base.appendingPathComponent("nope").path)
        XCTAssertEqual(missing.missing, true)
        try? FileManager.default.removeItem(at: base)
    }

    func testSeederSkipsMissingAndClaude() {
        let seeder = AllowlistSeeder()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gc-seed-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let roots = seeder.candidateRoots(from: [
            (cwd: tmp, agent: .grok),
            (cwd: "/root/definitely/not/here", agent: .codex),
            (cwd: "/somewhere/claude/only", agent: .claude),
        ])
        XCTAssertEqual(roots, [CanonicalPath.realpath(tmp)])
        let refused = seeder.applyRefusal(Allowlist())
        XCTAssertTrue(refused.seedPromptAnswered)
        XCTAssertFalse(refused.seededFromSessions)
        XCTAssertTrue(refused.roots.isEmpty)
        try? FileManager.default.removeItem(atPath: tmp)
    }
}
