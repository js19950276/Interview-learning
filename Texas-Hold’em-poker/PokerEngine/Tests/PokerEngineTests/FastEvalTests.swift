import XCTest
@testable import PokerEngine

final class FastEvalTests: XCTestCase {
    /// 全等性质：随机 5/6/7 张 × 5000 组合，FastEval 与 legacy 逐位相等（Review Focus #1）。
    func testEquivalenceWithLegacyOnRandomCards() {
        var rng = SeededGenerator(seed: 20261022)
        for _ in 0..<5_000 {
            var deck = Deck(rng: &rng)
            for count in [5, 6, 7] {
                let cards = (0..<count).map { _ in deck.draw() }
                let fast = FastEval.evaluate(cards)
                let legacy = HandEvaluator.evaluateLegacy(cards)
                XCTAssertEqual(fast.value, legacy.value, "cards=\(cards.map(\.description))")
                XCTAssertEqual(fast.category, legacy.category)
                XCTAssertEqual(fast.tiebreakers, legacy.tiebreakers)
            }
        }
    }

    /// 专项：轮子顺家族与皇家（最易错类）。code = (rank-2)*4 + suit（spade=0）。
    func testWheelFamilyEquivalence() {
        let cases: [[Int]] = [
            [48, 0, 4, 8, 12],            // A♠2♠3♠4♠5♠ 同花轮子（5 高同花顺）
            [48, 1, 5, 9, 13],            // 轮子（非同花）
            [48, 0, 4, 8, 40],            // A♠2♠3♠4♠Q♠：A234 缺 5 不成顺（A 高同花）
            [32, 36, 40, 44, 48],         // T♠J♠Q♠K♠A♠ 皇家同花顺（最高同花顺路径）
            [44, 45, 46, 47, 48],         // K♠K♥K♦K♣A♠ 四条+踢脚
            [12, 16, 20, 24, 28, 29, 30]  // 5♠6♠7♠8♠9♠+99 同花顺（5-9）
        ]
        for codes in cases {
            let cards = codes.map(Card.init(code:))
            XCTAssertEqual(FastEval.evaluate(cards).value,
                           HandEvaluator.evaluateLegacy(cards).value, "codes=\(codes)")
        }
    }

    /// 吞吐基准：数量级记录（measure 仅记录，不断言绝对值）。
    func testThroughputMagnitude() {
        var rng = SeededGenerator(seed: 7)
        let hands = (0..<2_000).map { _ in
            var d = Deck(rng: &rng)
            return (0..<7).map { _ in d.draw() }
        }
        measure { for h in hands { _ = FastEval.evaluate(h) } }
    }
}
