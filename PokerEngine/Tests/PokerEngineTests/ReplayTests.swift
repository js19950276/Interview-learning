import XCTest
@testable import PokerEngine

final class ReplayTests: XCTestCase {
    /// 随机打完整整手牌（全合法随机动作），结束后记录 → 重放 → 逐字段相等。
    func testReplayWholeHandEquality() {
        let cfg = GameConfig(playerCount: 6, startingStack: 2000, format: .cash(sb: 10, bb: 20))
        for seed in UInt64(1)...20 {
            var s = GameState.start(config: cfg, seed: seed * 100)
            var rng = SeededGenerator(seed: seed)
            while s.street != .handOver {
                let legal = legalActions(s)
                var pick: PlayerAction
                let roll = Int(rng.next() % 100)
                if let range = legal.betRange, roll < 20 {
                    let span = range.upperBound - range.lowerBound
                    pick = .raiseTo(range.lowerBound + Int(rng.next() % UInt64(max(1, span))))
                } else if legal.canCall, roll < 60 { pick = .call }
                else if legal.canCheck { pick = .check }
                else if legal.canCall { pick = .call }
                else { pick = .fold }
                s.apply(pick)
            }
            let replayed = HandHistory.replay(HandHistory.record(from: s))
            XCTAssertEqual(replayed, s, "seed \(seed)")
        }
    }

    func testReplaySNGHandWithElevatedBlinds() {
        let sng = SNGConfig(buyIn: 1000, startingStack: 1500,
                            levels: [BlindLevel(sb: 10, bb: 20, hands: 2), BlindLevel(sb: 50, bb: 100, hands: 5)],
                            payouts: [0.5, 0.3, 0.2])
        let cfg = GameConfig(playerCount: 3, startingStack: 1500, format: .sng(sng))
        var s = GameState.start(config: cfg, seed: 77, stacks: [900, 2100, 1500], buttonSeat: 0, handNumber: 5)
        XCTAssertEqual(s.currentBet, 100)   // 第 6 手 → 第二档 50/100
        var rng = SeededGenerator(seed: 99)
        while s.street != .handOver {
            let legal = legalActions(s)
            if let range = legal.betRange, rng.next() % 4 == 0 {
                s.apply(.raiseTo(range.upperBound))
            } else if legal.canCall { s.apply(.call) }
            else if legal.canCheck { s.apply(.check) }
            else { s.apply(.fold) }
        }
        XCTAssertEqual(HandHistory.replay(HandHistory.record(from: s)), s)
    }

    func testRecordMidHandReplaysToSameMoment() {
        var s = GameState.start(config: GameConfig(playerCount: 3, startingStack: 1000, format: .cash(sb: 10, bb: 20)),
                                seed: 88, buttonSeat: 0)
        s.apply(.call)
        let snapshot = HandHistory.record(from: s)   // 记录此刻
        s.apply(.call); s.apply(.check)              // 继续打
        XCTAssertEqual(HandHistory.replay(snapshot).actions, snapshot.actions)   // 重放到记录时刻
        XCTAssertNotEqual(HandHistory.replay(snapshot), s)                        // 而不是打完之后
    }
}
