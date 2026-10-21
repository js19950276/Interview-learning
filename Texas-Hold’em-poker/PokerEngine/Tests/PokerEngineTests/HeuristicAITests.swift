import XCTest
@testable import PokerEngine

final class HeuristicAITests: XCTestCase {
    func c(_ s: String) -> Card {
        let r = Array(s)[0], su = Array(s)[1]
        let rank = ["2","3","4","5","6","7","8","9","T","J","Q","K","A"].firstIndex(of: String(r))!
        let suit = ["s","h","d","c"].firstIndex(of: String(su))!
        return Card(rank: Rank(rawValue: rank + 2)!, suit: Suit(rawValue: suit)!)
    }

    func testAAtoOpenRaises() {
        var s = GameState.start(config: GameConfig(playerCount: 6, startingStack: 2000, format: .cash(sb: 10, bb: 20)),
                                seed: 41, buttonSeat: 0)
        s.players[s.actorSeat!].holeCards = [c("Ah"), c("Ad")]
        let ai = HeuristicAI(aggression: 0.5)
        let a = ai.decide(s, seat: s.actorSeat!)
        if case .bet = a { } else if case .raiseTo = a { } else { XCTFail("AA 翻前应加注，得到 \(a)") }
    }

    func testTrashFoldsToFacingRaise() {
        var s = GameState.start(config: GameConfig(playerCount: 6, startingStack: 2000, format: .cash(sb: 10, bb: 20)),
                                seed: 42, buttonSeat: 0)
        s.players[s.actorSeat!].holeCards = [c("7d"), c("2c")]
        let ai = HeuristicAI(aggression: 0.5)
        XCTAssertEqual(ai.decide(s, seat: s.actorSeat!), .fold)
    }

    func testFreeCheckWhenNoBet() {
        var s = GameState.start(config: GameConfig(playerCount: 3, startingStack: 1000, format: .cash(sb: 10, bb: 20)),
                                seed: 43, buttonSeat: 0)
        s.apply(.call); s.apply(.call)                    // 到 BB option，toCall = 0
        s.players[s.actorSeat!].holeCards = [c("7d"), c("2c")]
        let ai = HeuristicAI(aggression: 0.5)
        XCTAssertEqual(ai.decide(s, seat: s.actorSeat!), .check)
    }

    /// Review Focus #5：随机局面采样，AI 输出恒在合法集合（重点覆盖 betRange 为 nil）。
    func testAlwaysLegalOnRandomStates() {
        let cfg = GameConfig(playerCount: 4, startingStack: 1000, format: .cash(sb: 10, bb: 20))
        var sawNoRaiseContext = false
        for seed in UInt64(1)...50 {
            var s = GameState.start(config: cfg, seed: seed * 7)
            let ai = HeuristicAI(aggression: Double(seed % 5) / 4)
            while s.street != .handOver {
                let legal = legalActions(s)
                if legal.betRange == nil { sawNoRaiseContext = true }
                let decision = ai.decide(s, seat: s.actorSeat!)
                XCTAssertTrue(isLegal(decision, in: legal), "seed \(seed) \(decision) vs \(legal)")
                s.apply(decision)
            }
        }
        XCTAssertTrue(sawNoRaiseContext, "采样未覆盖不能加注的局面，扩大采样")
    }
}
