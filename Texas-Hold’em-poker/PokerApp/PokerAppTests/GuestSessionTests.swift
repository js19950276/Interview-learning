import XCTest
import PokerEngine
@testable import PokerApp

/// GuestSession × HostSession 在 Loopback 上的端到端对打。
final class GuestSessionTests: XCTestCase {
    let hostPeer = PeerID(rawValue: "ROOM-E2E")
    var hub: LoopbackTransportHub!
    var host: HostSession!
    var guests: [GuestSession] = []
    var guestLogs: [GuestUpdateLog] = []
    var guestPumps: [Task<Void, Never>] = []

    override func tearDown() async throws {
        guestPumps.forEach { $0.cancel() }
        for guest in guests { await guest.leave() }
        await host?.disconnect()
    }

    /// 注册一台客机：建常驻泵把 updates 流收入专属 log。
    /// AsyncStream 单消费者——取消挂起中的消费者会终止整条流，故泵必须全程常驻，
    /// 各次等待共用同一 log（waitFor 按序消费，旧帧被丢弃）。
    private func register(_ guest: GuestSession) {
        guests.append(guest)
        let log = GuestUpdateLog()
        guestLogs.append(log)
        guestPumps.append(Task {
            for await update in await guest.updates { await log.record(update) }
        })
    }

    private func makeRoom(guestCount: Int) async throws {
        hub = LoopbackTransportHub()
        let hostTransport = hub.makeTransport(peerID: hostPeer)
        host = HostSession(
            configuration: HostConfiguration(
                roomName: "E2E", hostName: "host",
                tableConfig: GameConfig(playerCount: 2, startingStack: 500, format: .cash(sb: 5, bb: 10))),
            transport: hostTransport)
        try await host.startHosting()
        for index in 0..<guestCount {
            let transport = hub.makeTransport(peerID: PeerID(rawValue: "device-\(index)"))
            register(GuestSession(roomID: await host.roomIDValue(), deviceID: "device-\(index)",
                                  displayName: "G\(index)", transport: transport))
        }
    }

    private func firstUpdate(_ guest: GuestSession, timeout: TimeInterval = 3,
                             where predicate: @Sendable @escaping (GuestUpdate) -> Bool) async throws -> GuestUpdate {
        guard let index = guests.firstIndex(where: { $0 === guest }) else { throw TestTimeout() }
        return try await guestLogs[index].waitFor(timeout: timeout, predicate)
    }

    /// startGame 前轮询名册直到全员 ready：loopback 投递只保证进入房主传输流，
    /// 不保证房主已消费，直接开局会撞 notAllReady 竞态（同 HostSessionGameTests 的处理）。
    private func awaitAllReady() async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let lobby = await host.currentLobby()
            if let lobby, !lobby.players.isEmpty, lobby.players.allSatisfy(\.ready) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testJoinReadyStartActEndToEnd() async throws {
        try await makeRoom(guestCount: 2)
        try await guests[0].join()
        try await guests[1].join()
        let seat0 = await guests[0].seatValue()
        let seat1 = await guests[1].seatValue()
        XCTAssertEqual(seat0, 1)
        XCTAssertEqual(seat1, 2)
        let joined = try await firstUpdate(guests[0]) { if case .joined = $0 { return true }; return false }
        guard case let .joined(seat) = joined else { return XCTFail() }
        XCTAssertEqual(seat, 1)

        await guests[0].setReady(true)
        await guests[1].setReady(true)
        await host.setReady(true)
        try await awaitAllReady()
        try await host.startGame()

        var snapshot = try await firstUpdate(guests[0]) { if case .snapshot = $0 { return true }; return false }
        guard case let .snapshot(snap) = snapshot else { return XCTFail() }
        XCTAssertEqual(snap.yourSeat, 1)
        let phase0 = await guests[0].phaseValue()
        XCTAssertEqual(phase0, .playing)
        XCTAssertEqual(snap.players[1].holeCards.count, 2)

        // 行动透传：谁行动谁发 check/call，打到 handOver
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let state = await host.gameState()!
            if state.street == .handOver { break }
            guard let actor = state.actorSeat else { break }
            let legal = legalActions(state)
            let action: PlayerAction = legal.canCheck ? .check : .call
            if actor == 0 { await host.act(action) }
            else { await guests[actor - 1].act(action) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        snapshot = try await firstUpdate(guests[0]) {
            if case let .snapshot(s) = $0 { return s.street == .handOver }
            return false
        }
        guard case let .snapshot(final) = snapshot else { return XCTFail() }
        XCTAssertEqual(final.street, .handOver)
        XCTAssertEqual(final.handResult?.awards.isEmpty, false)

        // nextHand 透传
        await guests[0].requestNextHand()
        let newHand = try await firstUpdate(guests[0]) {
            if case let .snapshot(s) = $0 { return s.handNumber == 1 && s.street != .handOver }
            return false
        }
        guard case let .snapshot(next) = newHand else { return XCTFail() }
        XCTAssertEqual(next.handNumber, 1)
    }

    func testReconnectAfterSeverResumes() async throws {
        try await makeRoom(guestCount: 1)
        try await guests[0].join()
        await guests[0].setReady(true)
        await host.setReady(true)
        try await awaitAllReady()
        try await host.startGame()
        _ = try await firstUpdate(guests[0]) { if case .snapshot = $0 { return true }; return false }

        // 随机发牌可能让客机恰为行动者：此时断线会被房主托管推进（seq 前进），
        // 「同 seq 补发被丢弃」的前提（引擎冻结）被破坏。先把行动权让回房主
        // （或打完本手）再断线，此后 host 引擎不再变更，seq 冻结。
        let settleDeadline = Date().addingTimeInterval(10)
        while Date() < settleDeadline {
            let state = await host.gameState()!
            if state.street == .handOver || state.actorSeat == nil || state.actorSeat == 0 { break }
            let legal = legalActions(state)
            await guests[0].act(legal.canCheck ? .check : .call)
            _ = try await firstUpdate(guests[0]) { if case .snapshot = $0 { return true }; return false }
        }
        let seqBeforeSever = await guests[0].latestSnapshot()?.seq

        // 断线：客机收到 .disconnected 并进入重连循环；Loopback 端点保留 → 循环重拨成功。
        // sever 按客机拨号名（roomID）起链：GuestSession 连的是 roomID 别名而非 hostPeer，
        // 客机侧 connectedPeers 里存的是 roomID，sever 键必须与之一致才能送达 .disconnected。
        let roomID = await host.roomIDValue()
        hub.severLink(between: PeerID(rawValue: roomID), and: PeerID(rawValue: "device-0"))
        _ = try await firstUpdate(guests[0]) { if case .disconnected = $0 { return true }; return false }

        // 重连循环 1s 起；welcome(.joined) 即确认重连成功。host 重连路径补发的是同 seq 的当前快照，
        // 客机按 seq 门丢弃——「快照不回退不重复」就是断言点
        _ = try await firstUpdate(guests[0], timeout: 8) {
            if case .joined = $0 { return true }
            return false
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let phaseAfterReconnect = await guests[0].phaseValue()
        let snapshotSeq = await guests[0].latestSnapshot()?.seq
        let snapshotSeat = await guests[0].latestSnapshot()?.yourSeat
        XCTAssertEqual(phaseAfterReconnect, .playing, "重连后恢复对局态")
        XCTAssertEqual(snapshotSeq, seqBeforeSever, "同 seq 补发被丢弃，快照不回退不重复")
        XCTAssertEqual(snapshotSeat, 1, "座位还原")
    }

    func testJoinAfterStartRejected() async throws {
        try await makeRoom(guestCount: 1)
        try await guests[0].join()
        await guests[0].setReady(true)
        await host.setReady(true)
        try await awaitAllReady()
        try await host.startGame()
        _ = try await firstUpdate(guests[0]) { if case .snapshot = $0 { return true }; return false }

        let lateTransport = hub.makeTransport(peerID: PeerID(rawValue: "late"))
        register(GuestSession(roomID: await host.roomIDValue(), deviceID: "late-device",
                              displayName: "迟到", transport: lateTransport))
        let late = guests.last!
        do {
            try await late.join()
            XCTFail("开局后加入应被拒")
        } catch {
            let latePhase = await late.phaseValue()
            XCTAssertEqual(latePhase, .ended)
        }
        let rejected = try await firstUpdate(late) { if case .rejected = $0 { return true }; return false }
        guard case let .rejected(reason) = rejected else { return XCTFail() }
        XCTAssertEqual(reason, .gameStarted)
    }
}
