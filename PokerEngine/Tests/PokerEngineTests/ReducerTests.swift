import XCTest
@testable import PokerEngine

final class ReducerTests: XCTestCase {
    let cash3 = GameConfig(playerCount: 3, startingStack: 1000, format: .cash(sb: 10, bb: 20))

    func testFoldFoldUncontestedWin() {
        var s = GameState.start(config: cash3, seed: 11, buttonSeat: 0)
        s.apply(.fold)   // 座位 0
        s.apply(.fold)   // 座位 1 (SB) —— 只剩 BB
        XCTAssertEqual(s.street, .handOver)
        XCTAssertEqual(s.handResult?.awards.first?.winners, [2])
        XCTAssertEqual(s.handResult?.awards.first?.amount, 30)
        XCTAssertEqual(s.players[2].stack, 1010)   // 投 20 收 30，净 +10（T6 修正：1000-20+30=1010，原计划常量 1000 与本测试 amount==30 自相矛盾）
        XCTAssertNil(s.actorSeat)
    }

    func testCallCallCheckBetRaiseFlow() {
        var s = GameState.start(config: cash3, seed: 11, buttonSeat: 0)
        s.apply(.call)    // 0 → 20
        s.apply(.call)    // 1 (SB) → 20
        s.apply(.check)   // 2 (BB) option
        XCTAssertEqual(s.street, .flop)
        XCTAssertEqual(s.board.count, 3)
        XCTAssertEqual(s.potTotal, 60)
        XCTAssertEqual(s.actorSeat, 1)             // 翻牌从 SB（座位 1）开始
        s.apply(.bet(30))                          // SB 下注 30
        XCTAssertEqual(s.currentBet, 30)
        XCTAssertEqual(s.minRaiseIncrement, 30)
        XCTAssertTrue(s.lastAggressionFullRaise)
        s.apply(.fold)                             // BB 弃
        s.apply(.raiseTo(60))                      // 座位 0 加注到 60
        let legal = legalActions(s)                // 座位 1 面对 60
        XCTAssertFalse(legal.canCheck)
        XCTAssertEqual(legal.betRange?.lowerBound, 90)    // 60 + 最小加注量 30（T6 修正：标准最小加注=上一足额加注量 60-30=30；原计划 120 混淆了“加注到”与“加注量”）
        s.apply(.fold)
        XCTAssertEqual(s.street, .handOver)
        // 底池 = 翻前 60 + SB 30 + 0 的 60 = 150；座位 0 总投入 80，收回 150
        XCTAssertEqual(s.players[0].stack, 1000 - 80 + 150)
    }

    func testHeadsUpPostflopButtonActsSecond() {
        var s = GameState.start(config: GameConfig(playerCount: 2, startingStack: 1000, format: .cash(sb: 5, bb: 10)), seed: 12, buttonSeat: 0)
        s.apply(.call)    // 按钮/SB 跟
        s.apply(.check)   // BB check
        XCTAssertEqual(s.street, .flop)
        XCTAssertEqual(s.actorSeat, 1)   // 翻后按钮后行动
    }

    func testUnderRaiseAllInDoesNotReopen() {
        // Review Focus #2：座位 0 下注 100（足额），座位 2 (BB) 短码全下加注到 125（增量 25 < 80）
        var s = GameState.start(config: cash3, seed: 13, stacks: [500, 500, 125], buttonSeat: 0)
        s.apply(.bet(100))          // 座位 0 下注 100（足额，minRaiseIncrement → 80）
        s.apply(.fold)              // 座位 1 (SB) 弃
        s.apply(.raiseTo(125))      // 座位 2 全下总额 125（盲注 20 + 剩余 105），不足额加注
        XCTAssertEqual(s.players[2].status, .allIn)
        XCTAssertEqual(s.currentBet, 125)
        XCTAssertFalse(s.lastAggressionFullRaise)
        let legal = legalActions(s)  // 轮到 0：只能跟 25 或弃
        XCTAssertFalse(legal.canCheck)
        XCTAssertEqual(legal.callAmount, 25)
        XCTAssertNil(legal.betRange) // 不得再加注
        s.apply(.call)
        // 0 跟后：0 active、2 allIn → runout → handOver（Task 7 showdown 填充前 street 已到 handOver? 空壳不分配 → 该断言 Task 7 后成立，此处只断言不再轮到任何人下注街）
        XCTAssertTrue(s.street == .handOver || s.street == .river)
    }

    func testAllInRunoutDealsAllStreets() {
        var s = GameState.start(config: GameConfig(playerCount: 2, startingStack: 1000, format: .cash(sb: 5, bb: 10)), seed: 14, buttonSeat: 0)
        s.apply(.raiseTo(1000))     // 按钮/SB 全下
        s.apply(.call)              // BB 跟全下
        // 双方 all-in → runout 发完五张 → showdown 分配（T7 起直接断言）
        XCTAssertEqual(s.board.count, 5)
        XCTAssertEqual(s.street, .handOver)
        XCTAssertFalse(s.handResult!.awards.isEmpty)
    }

    func testStreetChangeResetsBettingState() {
        var s = GameState.start(config: cash3, seed: 11, buttonSeat: 0)
        s.apply(.call); s.apply(.call); s.apply(.check)   // 进翻牌
        s.apply(.check); s.apply(.check); s.apply(.check) // 翻牌全过
        XCTAssertEqual(s.street, .turn)
        XCTAssertEqual(s.board.count, 4)
        XCTAssertEqual(s.currentBet, 0)
        XCTAssertEqual(s.minRaiseIncrement, 20)
    }

    func testFoldedSmallBlindNotFirstActorPostflop() {
        // 回归钉：SB 弃牌后，翻牌首行动者必须跳过 SB
        var s = GameState.start(config: cash3, seed: 15, buttonSeat: 0)
        s.apply(.call)    // 0
        s.apply(.fold)    // 1 (SB) 弃
        s.apply(.check)   // 2 (BB) → flop
        XCTAssertEqual(s.street, .flop)
        XCTAssertEqual(s.actorSeat, 2)   // 从按钮顺时针：1 已弃 → 轮到 2
    }
}
