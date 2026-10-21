import XCTest
@testable import PokerEngine

final class PIMCAITests: XCTestCase {
    func c(_ s: String) -> Card {
        let r = Array(s)[0], su = Array(s)[1]
        let rank = ["2","3","4","5","6","7","8","9","T","J","Q","K","A"].firstIndex(of: String(r))!
        let suit = ["s","h","d","c"].firstIndex(of: String(su))!
        return Card(rank: Rank(rawValue: rank + 2)!, suit: Suit(rawValue: suit)!)
    }
    let cash3 = GameConfig(playerCount: 3, startingStack: 1000, format: .cash(sb: 10, bb: 20))

    func testLadderClampsDedupesAndSinglePoint() {
        let s = GameState.start(config: cash3, seed: 3, buttonSeat: 0)
        let ladder = ladderActions(legalActions(s), state: s)
        XCTAssertTrue(ladder.contains(.call))
        XCTAssertFalse(ladder.contains(.check))          // 面对大盲无 check
        XCTAssertEqual(ladder.first, .call)              // 保守序：call 最优先
        XCTAssertTrue(ladder.contains(.fold))
        for action in ladder {
            if case .raiseTo(let t) = action { XCTAssertTrue((40...1000).contains(t), "t=\(t)") }
            if case .bet(let t) = action { XCTAssertTrue((40...1000).contains(t), "t=\(t)") }
        }
        // 单点区间 → 激进档仅全下一档（Review Focus #3）
        let short = GameState.start(config: cash3, seed: 3, stacks: [25, 1000, 1000], buttonSeat: 0)
        let raises = ladderActions(legalActions(short), state: short).filter {
            if case .raiseTo = $0 { return true }; return false
        }
        XCTAssertEqual(raises, [.raiseTo(25)])
    }

    func testPreflopAANeverFoldsAndTrashFolds() {
        var s = GameState.start(config: cash3, seed: 41, buttonSeat: 0)
        s.players[s.actorSeat!].holeCards = [c("Ah"), c("Ad")]
        let a = PIMCAI.normal.decide(s, seat: s.actorSeat!)
        if case .fold = a { XCTFail("AA 翻前不应弃牌：\(a)") }

        var t = GameState.start(config: cash3, seed: 42, buttonSeat: 0)
        t.players[t.actorSeat!].holeCards = [c("7d"), c("2c")]
        XCTAssertEqual(PIMCAI.easy.decide(t, seat: t.actorSeat!), .fold)
    }

    /// Review Focus #3/#5：12 局随机采样，每手每个决策恒合法；同局面决策确定。
    func testAlwaysLegalAndDeterministic() {
        let cfg = GameConfig(playerCount: 4, startingStack: 1000, format: .cash(sb: 10, bb: 20))
        let ai = PIMCAI(worlds: 4, iterationsPerWorld: 8)
        for seed in UInt64(1)...12 {
            var s = GameState.start(config: cfg, seed: seed * 13)
            while s.street != .handOver {
                let legal = legalActions(s)
                let decision = ai.decide(s, seat: s.actorSeat!)
                XCTAssertTrue(isLegal(decision, in: legal), "seed \(seed): \(decision) vs \(legal)")
                s.apply(decision)
            }
        }
        let s0 = GameState.start(config: cfg, seed: 999)
        XCTAssertEqual(ai.decide(s0, seat: s0.actorSeat!), ai.decide(s0, seat: s0.actorSeat!))
    }

    func testPresetsMatchSpec() {
        XCTAssertEqual(PIMCAI.easy.worlds, 8); XCTAssertEqual(PIMCAI.easy.iterationsPerWorld, 25)
        XCTAssertEqual(PIMCAI.normal.worlds, 16); XCTAssertEqual(PIMCAI.normal.iterationsPerWorld, 64)
        XCTAssertEqual(PIMCAI.hard.worlds, 32); XCTAssertEqual(PIMCAI.hard.iterationsPerWorld, 125)
    }
}
