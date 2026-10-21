import XCTest
@testable import PokerEngine

final class CardDeckTests: XCTestCase {
    func testCardEncodingRoundTrip() {
        for code in 0..<52 {
            let card = Card(code: code)
            XCTAssertEqual(card.code, code)
            XCTAssertEqual(Card(rank: card.rank, suit: card.suit), card)
        }
    }

    func testRankSuitBasics() {
        let aceSpades = Card(rank: .ace, suit: .spade)
        XCTAssertEqual(aceSpades.rank.rawValue, 14)
        XCTAssertEqual(aceSpades.suit, .spade)
        XCTAssertTrue(Rank.two < Rank.ace)
        XCTAssertEqual(Suit.allCases.count, 4)
        XCTAssertEqual(Rank.allCases.count, 13)
    }

    func testSeededGeneratorDeterministic() {
        var a = SeededGenerator(seed: 42)
        var b = SeededGenerator(seed: 42)
        var c = SeededGenerator(seed: 43)
        let sa = (0..<8).map { _ in a.next() }
        let sb = (0..<8).map { _ in b.next() }
        let sc = (0..<8).map { _ in c.next() }
        XCTAssertEqual(sa, sb)
        XCTAssertNotEqual(sa, sc)
    }

    func testDeckHas52UniqueCardsInStableOrderPerSeed() {
        var rng1 = SeededGenerator(seed: 7)
        var rng2 = SeededGenerator(seed: 7)
        let deck1 = Deck(rng: &rng1)
        var d1 = deck1
        var d2 = Deck(rng: &rng2)
        XCTAssertEqual(d1.count, 52)
        var seen = Set<Card>()
        while d1.count > 0 { seen.insert(d1.draw()) }
        XCTAssertEqual(seen.count, 52)
        XCTAssertEqual(d2.draw(), deck1.peekTop())
    }

    func testDeckEqualityComparesRemainingOrder() {
        var rngA = SeededGenerator(seed: 9)
        var rngB = SeededGenerator(seed: 9)
        var a = Deck(rng: &rngA)
        var b = Deck(rng: &rngB)
        XCTAssertEqual(a, b)
        _ = a.draw()
        XCTAssertNotEqual(a, b)
        _ = b.draw()
        XCTAssertEqual(a, b)
    }
}
