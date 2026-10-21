import XCTest
@testable import PokerEngine

final class NextHandTests: XCTestCase {
    func testCashButtonRotationAcrossHands() {
        let cfg = GameConfig(playerCount: 4, startingStack: 1000, format: .cash(sb: 5, bb: 10))
        var s = GameState.start(config: cfg, seed: 31, buttonSeat: 0)
        s.apply(.fold); s.apply(.fold); s.apply(.fold)   // 只剩 BB 收池
        XCTAssertEqual(s.street, .handOver)
        s.nextHand()
        XCTAssertEqual(s.handNumber, 1)
        XCTAssertEqual(s.buttonSeat, 1)
        XCTAssertEqual(s.street, .preflop)
    }

    func testSNGBlindLevelAdvancesAtHandTen() {
        let sng = SNGConfig(buyIn: 1000, startingStack: 1500,
                            levels: [BlindLevel(sb: 10, bb: 20, hands: 10),
                                     BlindLevel(sb: 25, bb: 50, hands: 10)],
                            payouts: [0.5, 0.3, 0.2])
        let s = GameState.start(config: GameConfig(playerCount: 3, startingStack: 1500, format: .sng(sng)),
                                seed: 32, buttonSeat: 0, handNumber: 10)
        XCTAssertEqual(s.currentBet, 50)    // 0-based 10 → 第二档
        XCTAssertEqual(s.minRaiseIncrement, 50)
    }

    /// 3 人 SNG：座位 2 (BB) 只有 15（< 盲注 20）→ 发牌即全下；
    /// 座位 0 弃、座位 1 (SB) 加注后手牌自动 runout（2 已 allIn 无需再行动）。
    func testSNGEliminationRecordsPlaceAndGameContinues() {
        let sng = SNGConfig(buyIn: 100, startingStack: 300,
                            levels: [BlindLevel(sb: 10, bb: 20, hands: 50)], payouts: [0.6, 0.4])
        var s = GameState.start(config: GameConfig(playerCount: 3, startingStack: 300, format: .sng(sng)),
                                seed: 33, stacks: [1000, 300, 15], buttonSeat: 0)
        s.apply(.fold)          // 座位 0
        s.apply(.raiseTo(60))   // 座位 1 (SB)；座位 2 已盲注全下 → 自动 runout
        XCTAssertEqual(s.street, .handOver)
        s.nextHand()
        if s.players[2].stack == 0 {
            XCTAssertEqual(s.players[2].finishPlace, 3)
            XCTAssertEqual(s.players[2].status, .eliminated)
            XCTAssertEqual(s.players.filter { $0.status != .eliminated }.count, 2)
        } else {
            XCTAssertEqual(s.players.filter { $0.status == .eliminated }.count, 0)  // 2 赢下主池存活
        }
    }

    /// Review Focus #4（名次 + 奖金取整合并验证）：
    /// 三人翻前全下（0 深筹横扫时 1、2 同手淘汰）。发牌随机，用种子循环找到必然触发
    /// 「0 横扫三池」的种子，然后钉死：手初 500 的拿 place 2、100 的拿 place 3；
    /// 333×3 买入 → 池 999，[0.5,0.3,0.2] → 499/299/199，余 2 归第 1 名 → 501/299/199。
    func testSameHandMultiBustPlacesAndPayoutRounding() {
        let sng = SNGConfig(buyIn: 333, startingStack: 500,
                            levels: [BlindLevel(sb: 10, bb: 20, hands: 50)], payouts: [0.5, 0.3, 0.2])
        let cfg = GameConfig(playerCount: 3, startingStack: 500, format: .sng(sng))
        for seed in UInt64(1)...30 {
            var s = GameState.start(config: cfg, seed: seed, stacks: [2000, 500, 100], buttonSeat: 0)
            s.apply(.raiseTo(2000))   // 0 全下
            s.apply(.call)            // 1 全下 500
            s.apply(.call)            // 2 全下 100
            XCTAssertEqual(s.street, .handOver)
            s.nextHand()
            guard s.tournamentOver else { continue }   // 本种子未横扫三池，换下一个
            XCTAssertEqual(s.players[0].finishPlace, 1)
            XCTAssertEqual(s.players[1].finishPlace, 2)   // 手初 500 > 100 → 名次靠前
            XCTAssertEqual(s.players[2].finishPlace, 3)
            XCTAssertEqual(s.tournamentPayouts.map(\.place), [1, 2, 3])
            XCTAssertEqual(s.tournamentPayouts.first?.amount, 501)
            XCTAssertEqual(s.tournamentPayouts.dropFirst().map(\.amount).sorted(), [199, 299])
            XCTAssertEqual(s.tournamentPayouts.reduce(0) { $0 + $1.amount }, 999)
            return
        }
        XCTFail("30 个种子均未出现 0 横扫三池（未触发同手双淘汰），扩大种子范围后重试")
    }

    /// 现金局破产者同样淘汰、无奖金；仅剩 1 人 → 会话结束。
    func testCashBustMarksEliminated() {
        var s = GameState.start(config: GameConfig(playerCount: 2, startingStack: 1000, format: .cash(sb: 5, bb: 10)),
                                seed: 36, stacks: [1000, 10], buttonSeat: 0)
        // 座位 1 (BB) 只有 10 → 盲注即全下；座位 0 (SB/按钮) 全下后自动 runout
        s.apply(.raiseTo(1000))
        XCTAssertEqual(s.street, .handOver)
        s.nextHand()
        if s.players[1].stack == 0 {
            XCTAssertEqual(s.players[1].status, .eliminated)
            XCTAssertTrue(s.tournamentOver)
            XCTAssertTrue(s.tournamentPayouts.isEmpty)
        }
    }
}
