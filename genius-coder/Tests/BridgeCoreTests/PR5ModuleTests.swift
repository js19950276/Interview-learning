import XCTest
import Darwin
import PhoneProtocol
@testable import BridgeCore

final class PR5ModuleTests: XCTestCase {

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gc-pr5-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - WriterLock (spec: 写入者锁)

    func testWriterLockInProcessExclusionAndRelease() {
        let lock = WriterLock()
        guard case .acquired(let lease) = lock.acquire(
            conversationId: "c1", lockFile: nil, watchPaths: [], agentProcessNames: [])
        else {
            XCTFail("first acquire must succeed")
            return
        }
        // Same conversation while held: locked by the bridge itself.
        guard case .locked(let byDesktop, let detail) = lock.acquire(
            conversationId: "c1", lockFile: nil, watchPaths: [], agentProcessNames: [])
        else {
            XCTFail("second in-process acquire must be locked")
            return
        }
        XCTAssertFalse(byDesktop)
        XCTAssertEqual(detail, "turn_in_progress")
        // Probe sees the bridge as writer.
        let probe = lock.probe(conversationId: "c1", lockFile: nil, watchPaths: [], agentProcessNames: [])
        XCTAssertEqual(probe.writer, .bridge)

        lease.release()
        guard case .acquired = lock.acquire(
            conversationId: "c1", lockFile: nil, watchPaths: [], agentProcessNames: [])
        else {
            XCTFail("reacquire after release must succeed")
            return
        }
    }

    func testWriterLockDifferentConversationsIndependent() {
        let lock = WriterLock()
        guard case .acquired(let leaseA) = lock.acquire(
            conversationId: "c1", lockFile: nil, watchPaths: [], agentProcessNames: [])
        else {
            XCTFail("c1 acquire must succeed")
            return
        }
        guard case .acquired(let leaseB) = lock.acquire(
            conversationId: "c2", lockFile: nil, watchPaths: [], agentProcessNames: [])
        else {
            XCTFail("c2 acquire must succeed independently")
            return
        }
        XCTAssertTrue(leaseA.conversationId == "c1")
        XCTAssertTrue(leaseB.conversationId == "c2")
        leaseA.release()
        leaseB.release()
    }

    func testWriterLockFlockFileBlocksAcquireAndProbe() throws {
        let dir = try makeTempDir("wl-flock")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lockFile = dir.appendingPathComponent("c1.lock").path
        XCTAssertTrue(FileManager.default.createFile(atPath: lockFile, contents: Data()))

        // A 0-byte file alone is not a lock: probe sees .none.
        let lock = WriterLock()
        XCTAssertEqual(
            lock.probe(conversationId: "c1", lockFile: lockFile, watchPaths: [], agentProcessNames: []).writer,
            .none)

        // Take the flock from the test process (simulating a desktop writer).
        let fd = open(lockFile, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)

        let probe = lock.probe(conversationId: "c1", lockFile: lockFile, watchPaths: [], agentProcessNames: [])
        XCTAssertEqual(probe.writer, .desktop)
        XCTAssertEqual(probe.detail, "writer_locked")

        guard case .locked(let byDesktop, let detail) = lock.acquire(
            conversationId: "c1", lockFile: lockFile, watchPaths: [], agentProcessNames: [])
        else {
            XCTFail("acquire against a flocked file must be locked")
            return
        }
        XCTAssertTrue(byDesktop)
        XCTAssertEqual(detail, "writer_locked")

        flock(fd, LOCK_UN)
        XCTAssertEqual(
            lock.probe(conversationId: "c1", lockFile: lockFile, watchPaths: [], agentProcessNames: []).writer,
            .none)
        guard case .acquired(let lease) = lock.acquire(
            conversationId: "c1", lockFile: lockFile, watchPaths: [], agentProcessNames: [])
        else {
            XCTFail("acquire after flock release must succeed")
            return
        }
        lease.release()
    }

    func testWriterLockLSofDetectsForeignHolder() throws {
        let dir = try makeTempDir("wl-lsof")
        defer { try? FileManager.default.removeItem(at: dir) }
        let watched = dir.appendingPathComponent("session.jsonl").path
        XCTAssertTrue(FileManager.default.createFile(atPath: watched, contents: Data("{}".utf8)))

        // tail -f holds the file open in a foreign pid.
        let tail = Process()
        tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        tail.arguments = ["-f", watched]
        tail.standardOutput = Pipe()
        tail.standardError = Pipe()
        try tail.run()
        defer {
            tail.terminate()
            tail.waitUntilExit()
        }
        Thread.sleep(forTimeInterval: 0.4)

        let lock = WriterLock()
        guard case .locked(let byDesktop, _) = lock.acquire(
            conversationId: "c1", lockFile: nil, watchPaths: [watched], agentProcessNames: [])
        else {
            XCTFail("acquire with a foreign holder must be locked")
            return
        }
        XCTAssertTrue(byDesktop)
        let probe = lock.probe(conversationId: "c1", lockFile: nil, watchPaths: [watched], agentProcessNames: [])
        XCTAssertEqual(probe.writer, .desktop)
    }

    // MARK: - ApprovalCenter (spec: 批准 + 断线 15 秒宽限)

    func testApprovalRegisterResolveSingleUse() {
        let center = ApprovalCenter()
        let id1 = center.register(conversationId: "c1", serverMethod: "codex/exec", payload: nil)
        let id2 = center.register(conversationId: "c1", serverMethod: "codex/exec", payload: nil)
        XCTAssertTrue(id1.hasPrefix("ap_"))
        XCTAssertEqual(id1, "ap_1")
        XCTAssertEqual(id2, "ap_2")

        XCTAssertNil(center.pendingAnswer(approvalId: id1))
        // Invalid options are rejected and leave the approval unanswered.
        XCTAssertFalse(center.resolve(approvalId: id1, optionId: "always_allow"))
        XCTAssertNil(center.pendingAnswer(approvalId: id1))

        XCTAssertTrue(center.resolve(approvalId: id1, optionId: "allow"))
        XCTAssertEqual(center.pendingAnswer(approvalId: id1), "allow")
        // Single-use: a second resolve fails, even with a valid option.
        XCTAssertFalse(center.resolve(approvalId: id1, optionId: "deny"))
        XCTAssertEqual(center.pendingAnswer(approvalId: id1), "allow")
        // Unknown approvals never resolve.
        XCTAssertFalse(center.resolve(approvalId: "ap_999", optionId: "allow"))
        XCTAssertNil(center.pendingAnswer(approvalId: "ap_999"))
    }

    func testApprovalGraceExpiryUsesMonotonicMoments() {
        let clock = ContinuousClock()
        let center = ApprovalCenter(clock: clock)
        let id = center.register(conversationId: "c9", serverMethod: "x", payload: nil)
        let now = clock.now

        // Grace still running: nothing expired.
        center.startGrace(conversationId: "c9", deadline: now.advanced(by: .seconds(EventLimits.approvalGraceSeconds)))
        XCTAssertEqual(center.expiredGraces(now: now), [])
        XCTAssertEqual(center.expiredGraces(now: now.advanced(by: .seconds(EventLimits.approvalGraceSeconds - 1))), [])

        // 16s in: expired, returned once.
        XCTAssertEqual(center.expiredGraces(now: now.advanced(by: .seconds(16))), ["c9"])
        XCTAssertEqual(center.expiredGraces(now: now.advanced(by: .seconds(30))), [])

        // An answered approval must never deny: arm a past grace, resolve first.
        center.startGrace(conversationId: "c9", deadline: now.advanced(by: .seconds(-1)))
        XCTAssertTrue(center.resolve(approvalId: id, optionId: "deny"))
        XCTAssertEqual(center.expiredGraces(now: now), [])
        XCTAssertEqual(center.pendingAnswer(approvalId: id), "deny")
    }

    func testApprovalClassifyMapsVendorMethods() {
        let acp = ApprovalCenter.classify(
            serverMethod: "acp/session.request",
            payload: .stringMap(["sessionId": "s9"]))
        XCTAssertEqual(acp, .acp(sessionId: "s9", request: .stringMap(["sessionId": "s9"])))

        let claude = ApprovalCenter.classify(
            serverMethod: "claude/control_request",
            payload: .stringMap(["requestId": "r1"]))
        XCTAssertEqual(claude, .claude(requestId: "r1"))

        XCTAssertEqual(
            ApprovalCenter.classify(serverMethod: "codex/exec_command", payload: nil),
            .legacyExecCommand)
        XCTAssertEqual(
            ApprovalCenter.classify(serverMethod: "grok/apply_patch", payload: nil),
            .legacyApplyPatch)
        XCTAssertEqual(
            ApprovalCenter.classify(serverMethod: "whatever", payload: nil),
            .server(method: "whatever", payload: nil))
    }

    // MARK: - CatchUpRing (spec: 追赶环)

    func testCatchUpRingCountEviction() {
        var ring = CatchUpRing()
        for seq in 1...2500 {
            ring.append(ConversationEvent(seq: Int64(seq), kind: .status, text: "x"))
        }
        // Kept the newest 2000 (seq 501...2500); the highest dropped seq is 500.
        XCTAssertEqual(ring.droppedSeq, 500)
        XCTAssertTrue(ring.overflowed)
        XCTAssertEqual(ring.count, 2000)

        XCTAssertTrue(ring.shouldReopen(afterSeq: 0))
        XCTAssertTrue(ring.shouldReopen(afterSeq: 499))
        // Everything the phone at 500 lacks was already delivered.
        XCTAssertFalse(ring.shouldReopen(afterSeq: 500))

        let all = ring.events(afterSeq: 0)
        XCTAssertEqual(all.count, 2000)
        XCTAssertEqual(all.first?.seq, 501)
        XCTAssertEqual(all.last?.seq, 2500)
        XCTAssertEqual(ring.events(afterSeq: 2400).map(\.seq), Array(2401...2500))
    }

    func testCatchUpRingByteEviction() {
        var ring = CatchUpRing()
        let mega = String(repeating: "a", count: 1024 * 1024)
        for seq in 1...9 {
            ring.append(ConversationEvent(seq: Int64(seq), kind: .assistantTextDelta, text: mega))
        }
        // 9 * (1 MiB + 64) > 8 MiB: oldest two evicted.
        XCTAssertEqual(ring.droppedSeq, 2)
        XCTAssertEqual(ring.events(afterSeq: 0).count, 7)
        XCTAssertEqual(ring.events(afterSeq: 0).first?.seq, 3)
        XCTAssertTrue(ring.shouldReopen(afterSeq: 0))
    }

    func testCatchUpRingUnderLimitsKeepsEverything() {
        var ring = CatchUpRing()
        for seq in 1...100 {
            ring.append(ConversationEvent(seq: Int64(seq), kind: .toolCall, toolName: "bash", toolPreview: "ls"))
        }
        XCTAssertNil(ring.droppedSeq)
        XCTAssertFalse(ring.overflowed)
        XCTAssertFalse(ring.shouldReopen(afterSeq: 0))
        XCTAssertEqual(ring.events(afterSeq: 90).count, 10)
        XCTAssertEqual(ring.events(afterSeq: 100).count, 0)
    }

    // MARK: - Caffeinate (spec: caffeinate)

    func testCaffeinateReferenceCountingWithoutSpawning() {
        final class FakeHandle: Caffeinate.Handle {
            var shutdownCount = 0
            func shutdown() { shutdownCount += 1 }
        }
        let handle = FakeHandle()
        var spawnCalls: [(String, [String])] = []
        let caffeinate = Caffeinate(spawner: { executable, arguments in
            spawnCalls.append((executable, arguments))
            return handle
        })

        XCTAssertEqual(caffeinate.activeTurnCount, 0)
        caffeinate.beginTurn()
        caffeinate.beginTurn()
        XCTAssertEqual(caffeinate.activeTurnCount, 2)
        XCTAssertEqual(spawnCalls.count, 1, "helper must spawn exactly once for nested turns")
        XCTAssertEqual(spawnCalls[0].0, "/usr/bin/caffeinate")
        XCTAssertEqual(spawnCalls[0].1.first, "-im")
        XCTAssertEqual(spawnCalls[0].1.dropFirst().first, "-w")

        caffeinate.endTurnIfNeeded()
        XCTAssertEqual(handle.shutdownCount, 0, "helper must survive while turns remain")
        caffeinate.endTurnIfNeeded()
        XCTAssertEqual(handle.shutdownCount, 1)
        XCTAssertEqual(caffeinate.activeTurnCount, 0)

        // Extra end is clamped; a new turn spawns again.
        caffeinate.endTurnIfNeeded()
        XCTAssertEqual(handle.shutdownCount, 1)
        caffeinate.beginTurn()
        XCTAssertEqual(spawnCalls.count, 2)
        caffeinate.endTurnIfNeeded()
    }

    // MARK: - ProcessGroups (spec: Mac 进程模型)

    func testProcessGroupsRecordPersistsJSONWithTightPermissions() throws {
        let dir = try makeTempDir("pg-record")
        defer { try? FileManager.default.removeItem(at: dir) }
        let groups = ProcessGroups(directory: dir)

        groups.record(label: "codex:c1", pgid: 123)
        groups.record(label: "grok:g2", pgid: 456)

        let url = dir.appendingPathComponent(ProcessGroups.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let entries = try JSONDecoder().decode([ProcessGroups.Entry].self, from: Data(contentsOf: url))
        XCTAssertEqual(entries, [
            ProcessGroups.Entry(label: "codex:c1", pgid: 123),
            ProcessGroups.Entry(label: "grok:g2", pgid: 456),
        ])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions.map { $0 & 0o777 }, 0o600)

        // Re-recording a label replaces its entry.
        groups.record(label: "codex:c1", pgid: 789)
        let reloaded = ProcessGroups.load(from: dir)
        XCTAssertEqual(reloaded.count, 2)
        XCTAssertEqual(reloaded.first { $0.label == "codex:c1" }?.pgid, 789)

        groups.forget(label: "codex:c1")
        XCTAssertEqual(ProcessGroups.load(from: dir), [ProcessGroups.Entry(label: "grok:g2", pgid: 456)])
    }

    func testReapOrphansOnDeadGroupsJustClearsTheFile() throws {
        let dir = try makeTempDir("pg-dead")
        defer { try? FileManager.default.removeItem(at: dir) }
        let groups = ProcessGroups(directory: dir)
        // pid_max is far below this on macOS; kill(-pgid, 0) is ESRCH.
        groups.record(label: "gone", pgid: 4_000_000)
        groups.reapOrphans(from: dir)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(ProcessGroups.fileName).path),
            "ledger must be cleared after reap")
    }

    func testReapOrphansTerminatesLiveGroup() throws {
        // Spawn sleep into its own process group via posix_spawn (setpgroup).
        var pid: pid_t = 0
        var attrs: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attrs)
        posix_spawnattr_setpgroup(&attrs, 0)
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
        let rc = posix_spawn(&pid, "/bin/sleep", nil, &attrs, &argv, nil)
        posix_spawnattr_destroy(&attrs)
        argv.forEach { if let p = $0 { free(p) } }
        XCTAssertEqual(rc, 0)

        // Reap the child from a helper thread so the group truly empties once
        // SIGTERM lands (a zombie would keep kill(-pgid, 0) succeeding).
        let reaped = expectation(description: "child reaped by waitpid")
        DispatchQueue.global().async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            reaped.fulfill()
        }
        usleep(200_000)
        XCTAssertEqual(kill(-pid, 0), 0, "child group must be alive before reap")

        let dir = try makeTempDir("pg-live")
        defer { try? FileManager.default.removeItem(at: dir) }
        let groups = ProcessGroups(directory: dir)
        groups.record(label: "agent", pgid: pid)
        groups.reapOrphans(from: dir)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(ProcessGroups.fileName).path))
        wait(for: [reaped], timeout: 5)
        usleep(150_000)
        XCTAssertNotEqual(kill(-pid, 0), 0, "child group must be gone after reap")
    }

    func testDrainTerminatesChildProcess() throws {
        let dir = try makeTempDir("pg-drain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let groups = ProcessGroups(directory: dir)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        child.standardOutput = Pipe()
        child.standardError = Pipe()
        try child.run()
        XCTAssertTrue(child.isRunning)

        groups.drain(process: child, label: "test-agent")
        XCTAssertFalse(child.isRunning)
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
    }
}
