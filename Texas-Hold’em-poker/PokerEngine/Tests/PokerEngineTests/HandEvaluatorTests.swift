import XCTest
@testable import PokerEngine

final class HandEvaluatorTests: XCTestCase {
    // 便捷构造："As" = A♠
    func c(_ s: String) -> Card {
        let r = Array(s)[0], su = Array(s)[1]
        let rank = ["2","3","4","5","6","7","8","9","T","J","Q","K","A"].firstIndex(of: String(r))!
        let suit = ["s","h","d","c"].firstIndex(of: String(su))!
        return Card(rank: Rank(rawValue: rank + 2)!, suit: Suit(rawValue: suit)!)
    }
    func cards(_ s: String) -> [Card] { s.split(separator: " ").map { c(String($0)) } }

    func testCategoryOrdering() {
        let royal = cards("As Ks Qs Js Ts")
        let quads = cards("9c 9d 9h 9s 2c")
        let boat  = cards("8c 8d 8h Kc Kd")
        let flush = cards("Ah Th 7h 5h 2h")
        let straight = cards("9c 8d 7h 6s 5c")
        let trips = cards("7c 7d 7h Kc 2d")
        let twoPair = cards("Kc Kd 7h 7s 3c")
        let pair = cards("Ac Ad Kc 9h 5d")
        let high = cards("Ac Jd 8h 5c 3d")
        XCTAssertGreaterThan(HandEvaluator.evaluate(royal).value, HandEvaluator.evaluate(quads).value)
        XCTAssertGreaterThan(HandEvaluator.evaluate(quads).value, HandEvaluator.evaluate(boat).value)
        XCTAssertGreaterThan(HandEvaluator.evaluate(boat).value, HandEvaluator.evaluate(flush).value)
        XCTAssertGreaterThan(HandEvaluator.evaluate(flush).value, HandEvaluator.evaluate(straight).value)
        XCTAssertGreaterThan(HandEvaluator.evaluate(straight).value, HandEvaluator.evaluate(trips).value)
        XCTAssertGreaterThan(HandEvaluator.evaluate(trips).value, HandEvaluator.evaluate(twoPair).value)
        XCTAssertGreaterThan(HandEvaluator.evaluate(twoPair).value, HandEvaluator.evaluate(pair).value)
        XCTAssertGreaterThan(HandEvaluator.evaluate(pair).value, HandEvaluator.evaluate(high).value)
        XCTAssertEqual(HandEvaluator.evaluate(royal).category, .straightFlush)
    }

    func testWheelStraightAndSteelWheel() {
        // A-2-3-4-5 是 5 高顺子，不是高牌
        let wheel = HandEvaluator.evaluate(cards("Ah 2c 3d 4s 5h"))
        XCTAssertEqual(wheel.category, .straight)
        XCTAssertEqual(wheel.tiebreakers[0], 5)
        // A-5 同花顺按 5 高同花顺，且低于 6 高同花顺
        let steel = HandEvaluator.evaluate(cards("Ah 2h 3h 4h 5h"))
        let sixHigh = HandEvaluator.evaluate(cards("6h 2h 3h 4h 5h"))
        XCTAssertEqual(steel.category, .straightFlush)
        XCTAssertEqual(steel.tiebreakers[0], 5)
        XCTAssertLessThan(steel.value, sixHigh.value)
        // A 高顺（TJQKA）高于轮子
        let broadway = HandEvaluator.evaluate(cards("Ah Kc Qd Js Tc"))
        XCTAssertEqual(broadway.tiebreakers[0], 14)
    }

    func testKickerComparisons() {
        let a = HandEvaluator.evaluate(cards("Ac Ad Kc 9h 5d"))   // 一对 A，踢 K-9-5
        let b = HandEvaluator.evaluate(cards("Ah As Qc 9h 5d"))   // 一对 A，踢 Q-9-5
        XCTAssertGreaterThan(a.value, b.value)
        let twoPairLowKicker = HandEvaluator.evaluate(cards("Kc Kd 7h 7s 2c"))
        let twoPairHighKicker = HandEvaluator.evaluate(cards("Kc Kd 7h 7s Ac"))
        XCTAssertGreaterThan(twoPairHighKicker.value, twoPairLowKicker.value)
    }

    func testSevenCardsPickBestFive() {
        // 两对在场但成顺更大
        XCTAssertEqual(HandEvaluator.evaluate(cards("Ah 2c 3d 4s 5h 9c 9d")).category, .straight)
        // 公共牌四条：任何底牌都是四条
        XCTAssertEqual(HandEvaluator.evaluate(cards("9c 9d 9h 9s 2c Ah Kd")).category, .fourOfAKind)
    }

    // 性质测试：直接法必须与参考暴力实现（21 种 5 张组合取最大）一致
    func testEvaluateMatchesBruteForceOnRandomDeals() {
        var rng = SeededGenerator(seed: 20261021)
        func bruteForce7(_ seven: [Card]) -> HandRank {
            var best: HandRank?
            for i in 0..<7 {
                for j in (i + 1)..<7 {
                    let five = seven.enumerated().filter { $0.offset != i && $0.offset != j }.map(\.element)
                    let r = HandEvaluator.evaluate(five)
                    if best == nil || r.value > best!.value { best = r }
                }
            }
            return best!
        }
        for _ in 0..<2_000 {
            var deck = Deck(rng: &rng)
            let seven = (0..<7).map { _ in deck.draw() }
            XCTAssertEqual(HandEvaluator.evaluate(seven).value, bruteForce7(seven).value,
                           "mismatch on \(seven.map(\.description).joined(separator: " "))")
        }
    }

    func testTiebreakersPaddedToFive() {
        XCTAssertEqual(HandEvaluator.evaluate(cards("Ah Kc Qd Js Tc")).tiebreakers.count, 5)
    }
}
