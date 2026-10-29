import XCTest
import PokerEngine
@testable import PokerApp

/// VM 级端到端：三个 VM（1 房主 + 2 客机）在 Loopback 上完成 入住→ready→开局→行动→handOver→下一手。
@MainActor
final class MultiplayerFlowTests: XCTestCase {
    private let pumpTimeout: TimeInterval = 8

    private func waitUntil(_ condition: @autoclosure () -> Bool, _ message: String,
                           timeout: TimeInterval = 8) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        // 超时抛错中止调用方，避免其继续强解过期状态（对齐 LoopbackHarness 的 TestTimeout 约定）
        XCTFail(message)
        throw TestTimeout()
    }

    func testThreeDevicesFullHand() async throws {
        let hub = LoopbackTransportHub()
        let hostTransport = hub.makeTransport(peerID: PeerID(rawValue: "ROOM-VM"))
        let hostVM = HostGameViewModel(
            configuration: HostConfiguration(
                roomName: "VM", hostName: "房主",
                tableConfig: GameConfig(playerCount: 2, startingStack: 500, format: .cash(sb: 5, bb: 10))),
            transport: hostTransport)
        await hostVM.start()
        try await waitUntil(hostVM.lobby != nil, "房主大厅就绪")

        var guestVMs: [GuestGameViewModel] = []
        for index in 0..<2 {
            let transport = hub.makeTransport(peerID: PeerID(rawValue: "device-\(index)"))
            // 三台设备 → 三个 deviceID（同进程内 LocalIdentity 恒同值，须注入区分；同 deviceID 会被房主视为接管重连）
            let vm = GuestGameViewModel(roomID: hostVM.roomID!, displayName: "G\(index)",
                                        deviceID: "device-\(index)", transport: transport)
            guestVMs.append(vm)
            await vm.join()
        }
        try await waitUntil(guestVMs.allSatisfy { $0.lobby != nil }, "客机进入大厅")
        XCTAssertEqual(guestVMs[0].mySeat, 1)
        XCTAssertEqual(guestVMs[1].mySeat, 2)

        for vm in guestVMs { await vm.setReady(true) }
        await hostVM.setReady(true)
        try await waitUntil(hostVM.canStartGame, "全员 ready")
        await hostVM.startGame()

        try await waitUntil(hostVM.gameState != nil && guestVMs.allSatisfy { $0.snapshot != nil },
                            "三端都进入对局", timeout: pumpTimeout)
        // 客机画面上对手手牌不可见（VM 层隐私）
        for (index, vm) in guestVMs.enumerated() {
            let snap = vm.snapshot!
            for player in snap.players where player.seat != vm.mySeat {
                XCTAssertTrue(player.holeCards.isEmpty, "G\(index) 不得见到他人手牌")
            }
        }

        // 打完一手：行动者所在 VM 发 act
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let state = hostVM.gameState!
            if state.street == .handOver { break }
            guard let actor = state.actorSeat else { break }
            let legal = legalActions(state)
            let action: PlayerAction = legal.canCheck ? .check : .call
            if actor == 0 { await hostVM.act(action) }
            else { await guestVMs[actor - 1].act(action) }
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        try await waitUntil(guestVMs.allSatisfy { $0.snapshot?.street == .handOver },
                            "三端都看到本手结束", timeout: pumpTimeout)
        XCTAssertNotNil(guestVMs[0].snapshot?.handResult)

        // 摊牌后亮牌：非弃牌者的牌在快照里可见
        let snap = guestVMs[0].snapshot!
        let revealed = snap.players.filter { $0.status != .folded && !$0.holeCards.isEmpty }
        XCTAssertFalse(revealed.isEmpty, "摊牌局应有亮牌者")

        // 下一手（客机发起）→ 三端 handNumber+1
        let handBefore = hostVM.gameState!.handNumber
        await guestVMs[0].nextHand()
        try await waitUntil(hostVM.gameState!.handNumber == handBefore + 1
                                && guestVMs.allSatisfy { $0.snapshot?.handNumber == handBefore + 1 },
                            "三端进入下一手", timeout: pumpTimeout)

        for vm in guestVMs { await vm.leave() }
        await hostVM.leave()
    }
}
