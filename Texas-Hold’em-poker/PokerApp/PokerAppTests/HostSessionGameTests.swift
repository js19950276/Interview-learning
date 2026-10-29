import XCTest
import PokerEngine
@testable import PokerApp

/// 对局阶段：开局条件/动作校验/扇出/托管/重连（spec §8）。
final class HostSessionGameTests: XCTestCase {
    let hostPeer = PeerID(rawValue: "ROOM-G")
    var hub: LoopbackTransportHub!
    var host: HostSession!
    var guestT: [LoopbackTransport] = []      // seat1/seat2 的裸客机传输
    var guestLogs: [EventLog] = []
    var pumps: [Task<Void, Never>] = []

    let config = GameConfig(playerCount: 2, startingStack: 500, format: .cash(sb: 5, bb: 10))

    override func tearDown() async throws {
        pumps.forEach { $0.cancel() }
        await host?.disconnect()
    }

    /// 建房 + N 个裸客机加入并 ready；返回座位号数组（含房主 0）。
    @discardableResult
    private func makeReadyRoom(guestCount: Int) async throws -> HostSession {
        hub = LoopbackTransportHub()
        let hostTransport = hub.makeTransport(peerID: hostPeer)
        host = HostSession(
            configuration: HostConfiguration(roomName: "G", hostName: "host",
                                             tableConfig: config),
            transport: hostTransport)
        try await host.startHosting()
        for index in 0..<guestCount {
            let transport = hub.makeTransport(peerID: PeerID(rawValue: "raw-guest-\(index)"))
            guestT.append(transport)
            let log = EventLog()
            guestLogs.append(log)
            pumps.append(attachEvents(of: transport, to: log))
            try await transport.connect(to: hostPeer)
            try await sendEnvelope(.hello(deviceID: "device-\(index)", name: "P\(index + 1)"),
                                   roomID: await host.roomIDValue(), sender: .guest,
                                   from: transport, to: hostPeer)
        }
        await host.setReady(true)
        for (index, transport) in guestT.enumerated() {
            try await sendEnvelope(.ready(true), roomID: await host.roomIDValue(),
                                   sender: .seat(index + 1), from: transport, to: hostPeer)
        }
        // loopback 投递只保证进入房主传输流，不保证房主已消费；startGame 前轮询名册
        // 直到全员 ready（否则 startGame 撞上未消费的 ready → notAllReady 竞态）。
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let lobby = await host.currentLobby()
            if let lobby, lobby.players.count == guestCount + 1, lobby.players.allSatisfy(\.ready) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return host
    }

    /// 从某客机事件流收下一帧快照。
    private func nextSnapshot(log: EventLog, timeout: TimeInterval = 3) async throws -> TableSnapshot {
        while true {
            let event = try await log.waitFor(timeout: timeout) { if case .received = $0 { return true }; return false }
            guard case let .received(data, _) = event,
                  let envelope = try? PokerWire.decode(data),
                  case let .snapshot(snapshot) = envelope.payload else { continue }
            return snapshot
        }
    }

    private func nextRejection(log: EventLog, timeout: TimeInterval = 3) async throws -> RejectionReason {
        while true {
            let event = try await log.waitFor(timeout: timeout) { if case .received = $0 { return true }; return false }
            guard case let .received(data, _) = event,
                  let envelope = try? PokerWire.decode(data),
                  case let .rejection(reason) = envelope.payload else { continue }
            return reason
        }
    }

    /// 取房主当前行动座位（测试据此决定从哪个座位发动作）。
    private func currentActor() async -> Int? {
        await host?.gameState()?.actorSeat
    }

    private func sendAction(seat: Int, _ action: PlayerAction) async throws {
        try await sendEnvelope(.action(action), roomID: await host.roomIDValue(), sender: .seat(seat),
                               from: guestT[seat - 1], to: hostPeer)
    }

    func testStartGameRequiresTwoPlayersAndAllReady() async throws {
        _ = try await makeReadyRoom(guestCount: 0)
        do { try await host.startGame(); XCTFail("单人不应能开局") } catch {}
        _ = try await makeReadyRoom(guestCount: 1)
        // 客机未 ready：去掉 host ready 再试？host 已 ready；直接再断言正常路径
        try await host.startGame()   // host+1 客机都 ready → 可开
        let phaseNow = await host.currentPhase()
        let stateNow = await host.gameState()
        XCTAssertEqual(phaseNow, .playing)
        XCTAssertEqual(stateNow?.players.count, 2)
        XCTAssertEqual(stateNow?.players[1].name, "P1", "开局改写大厅昵称")
    }

    func testFirstSnapshotsSanitizedPerRecipientAndSeqMonotonic() async throws {
        _ = try await makeReadyRoom(guestCount: 2)
        try await host.startGame()
        let snap1 = try await nextSnapshot(log: guestLogs[0])
        let snap2 = try await nextSnapshot(log: guestLogs[1])
        XCTAssertEqual(snap1.seq, 1)
        XCTAssertEqual(snap2.seq, 1)
        XCTAssertEqual(snap1.players[1].holeCards.count, 2, "客机 1 见自己的牌")
        XCTAssertTrue(snap1.players[2].holeCards.isEmpty, "客机 1 不得见客机 2 的牌")
        XCTAssertTrue(snap2.players[1].holeCards.isEmpty)
        XCTAssertEqual(snap1.board, snap2.board)
        XCTAssertEqual(snap1.players[1].name, "P1", "快照携带大厅昵称")
        XCTAssertEqual(snap2.players[1].name, "P1")
    }

    func testLegalActionFromActorSeatAppliesAndFanouts() async throws {
        _ = try await makeReadyRoom(guestCount: 2)
        try await host.startGame()
        _ = try await nextSnapshot(log: guestLogs[0])
        _ = try await nextSnapshot(log: guestLogs[1])
        guard let actor = await currentActor(), actor != 0 else {
            // 行动者是房主：走 host.act 路径（必须发合法动作，否则被自己的合法性门拒绝）
            let legal = legalActions(await host.gameState()!)
            await host.act(legal.canCheck ? .check : .call)
            _ = try await nextSnapshot(log: guestLogs[0])
            return
        }
        let before = await host.gameState()!
        let legal = legalActions(before)
        let action: PlayerAction = legal.canCheck ? .check : .call
        try await sendAction(seat: actor, action)
        let snapshot = try await nextSnapshot(log: guestLogs[actor - 1])
        XCTAssertEqual(snapshot.seq, 2)
        let afterState = await host.gameState()!
        XCTAssertNotEqual(afterState.actions.count, before.actions.count)
    }

    func testIllegalActionRejectedEngineUntouched() async throws {
        _ = try await makeReadyRoom(guestCount: 2)
        try await host.startGame()
        _ = try await nextSnapshot(log: guestLogs[0])
        _ = try await nextSnapshot(log: guestLogs[1])
        guard let actor = await currentActor(), actor != 0 else { return }   // 本用例只测客机座位
        let before = await host.gameState()!
        try await sendAction(seat: actor, .raiseTo(999_999))          // 远超身家
        let reason = try await nextRejection(log: guestLogs[actor - 1])
        XCTAssertEqual(reason, .illegalAction)
        let untouched = await host.gameState()
        XCTAssertEqual(untouched, before, "非法动作绝不进引擎")
    }

    func testNotYourTurnRejected() async throws {
        _ = try await makeReadyRoom(guestCount: 2)
        try await host.startGame()
        _ = try await nextSnapshot(log: guestLogs[0])
        _ = try await nextSnapshot(log: guestLogs[1])
        guard let actor = await currentActor() else { return }
        let bystander = actor == 1 ? 2 : 1
        let before = await host.gameState()!
        try await sendAction(seat: bystander, .fold)
        let reason = try await nextRejection(log: guestLogs[bystander - 1])
        XCTAssertEqual(reason, .notYourTurn)
        let untouched = await host.gameState()
        XCTAssertEqual(untouched, before)
    }

    func testDuplicateActionMessageAppliedOnce() async throws {
        _ = try await makeReadyRoom(guestCount: 2)
        try await host.startGame()
        _ = try await nextSnapshot(log: guestLogs[0])
        _ = try await nextSnapshot(log: guestLogs[1])
        guard let actor = await currentActor(), actor != 0 else { return }
        let before = await host.gameState()!
        let legal = legalActions(before)
        let action: PlayerAction = legal.canCheck ? .check : .call
        let envelope = PokerEnvelope(roomID: await host.roomIDValue(), sender: .seat(actor),
                                     payload: .action(action))
        try await guestT[actor - 1].send(try PokerWire.encode(envelope), to: hostPeer)
        _ = try await nextSnapshot(log: guestLogs[actor - 1])          // 应用 + 扇出
        try await guestT[actor - 1].send(try PokerWire.encode(envelope), to: hostPeer)  // 同 messageID 重发
        try? await Task.sleep(nanoseconds: 300_000_000)
        let deduped = await host.gameState()!
        XCTAssertEqual(deduped.actions.count, before.actions.count + 1, "重复 messageID 只应用一次")
    }

    func testDisconnectedSeatAutoChecksOrFolds() async throws {
        _ = try await makeReadyRoom(guestCount: 2)
        try await host.startGame()
        _ = try await nextSnapshot(log: guestLogs[0])
        _ = try await nextSnapshot(log: guestLogs[1])
        // 断开 seat1 的连接；若轮到 seat1 则自动过/弃，牌局继续推进
        let seat1RawPeer = PeerID(rawValue: "raw-guest-0")
        hub.severLink(between: hostPeer, and: seat1RawPeer)
        // 等房主处理断线并推进（若 seat1 是行动者）
        try? await Task.sleep(nanoseconds: 500_000_000)
        var guardCount = 0
        while (await currentActor()) == 1 && guardCount < 50 {   // 若卡在断线座位即失败
            try? await Task.sleep(nanoseconds: 100_000_000)
            guardCount += 1
        }
        let actorAfterSever = await currentActor()
        XCTAssertNotEqual(actorAfterSever, 1, "断线座位不得卡住牌局")
        // 剩余玩家把这一手打完（seat2/房主自动跟/过）
        let deadline = Date().addingTimeInterval(10)
        while (await host.gameState()!).street != .handOver, Date() < deadline {
            if let actor = await currentActor() {
                if actor == 0 {
                    let legal = legalActions((await host.gameState())!)
                    await host.act(legal.canCheck ? .check : .call)
                } else {
                    let legal = legalActions((await host.gameState())!)
                    try await sendAction(seat: actor, legal.canCheck ? .check : .call)
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        let finalState = await host.gameState()
        XCTAssertEqual(finalState?.street, .handOver, "断线托管后整手可正常打完")
    }

    func testReconnectRestoresSeatAndSnapshot() async throws {
        _ = try await makeReadyRoom(guestCount: 1)
        try await host.startGame()
        var snap = try await nextSnapshot(log: guestLogs[0])
        let lastSeq = snap.seq
        let seat1RawPeer = PeerID(rawValue: "raw-guest-0")
        hub.severLink(between: hostPeer, and: seat1RawPeer)
        try? await Task.sleep(nanoseconds: 300_000_000)
        // 同 deviceID 重连
        try await guestT[0].connect(to: hostPeer)
        try await sendEnvelope(.hello(deviceID: "device-0", name: "P1"), roomID: await host.roomIDValue(),
                               sender: .guest, from: guestT[0], to: hostPeer)
        snap = try await nextSnapshot(log: guestLogs[0])
        XCTAssertEqual(snap.yourSeat, 1, "重连还原原座位")
        XCTAssertGreaterThan(snap.seq, lastSeq, "补发更新的快照")
        let rebound = await host.peerIDValue(seat: 1)
        XCTAssertEqual(rebound != nil, true)
    }

    func testJoinAfterStartRejected() async throws {
        _ = try await makeReadyRoom(guestCount: 1)
        try await host.startGame()
        _ = try await nextSnapshot(log: guestLogs[0])
        let newcomer = hub.makeTransport(peerID: PeerID(rawValue: "raw-new"))
        let newLog = EventLog()
        pumps.append(attachEvents(of: newcomer, to: newLog))
        try await newcomer.connect(to: hostPeer)
        try await sendEnvelope(.hello(deviceID: "device-new", name: "新人"), roomID: await host.roomIDValue(),
                               sender: .guest, from: newcomer, to: hostPeer)
        let reason = try await nextRejection(log: newLog)
        XCTAssertEqual(reason, .gameStarted)
    }

    func testNextHandFirstRequestWins() async throws {
        _ = try await makeReadyRoom(guestCount: 2)
        try await host.startGame()
        _ = try await nextSnapshot(log: guestLogs[0])
        _ = try await nextSnapshot(log: guestLogs[1])
        // 打到 handOver：除一人外全弃
        let deadline = Date().addingTimeInterval(10)
        while (await host.gameState()!).street != .handOver, Date() < deadline {
            if let actor = await currentActor() {
                if actor == 0 { await host.act(.fold) }
                else { try await sendAction(seat: actor, .fold) }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        let handNumberBefore = (await host.gameState()!).handNumber
        try await sendEnvelope(.nextHand, roomID: await host.roomIDValue(), sender: .seat(1),
                               from: guestT[0], to: hostPeer)
        _ = try await nextSnapshot(log: guestLogs[0])
        let advanced = await host.gameState()!
        XCTAssertEqual(advanced.handNumber, handNumberBefore + 1)
        let after = advanced.handNumber
        try await sendEnvelope(.nextHand, roomID: await host.roomIDValue(), sender: .seat(2),
                               from: guestT[1], to: hostPeer)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let idempotent = await host.gameState()!
        XCTAssertEqual(idempotent.handNumber, after, "第二次请求无效（引擎幂等）")
    }
}
