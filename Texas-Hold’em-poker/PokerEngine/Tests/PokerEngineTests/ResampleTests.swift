import XCTest
@testable import PokerEngine

final class ResampleTests: XCTestCase {
    let cash3 = GameConfig(playerCount: 3, startingStack: 1000, format: .cash(sb: 10, bb: 20))

    func testVisiblePreservedAndUnseenPoolCorrect() {
        var s = GameState.start(config: cash3, seed: 41, buttonSeat: 0)
        s.apply(.call); s.apply(.call); s.apply(.check)   // 进翻牌
        var rng = SeededGenerator(seed: 99)
        let world = s.resampled(from: 0, using: &rng)

        // 可见信息逐字段保留（Review Focus #2）
        XCTAssertEqual(world.players[0].holeCards, s.players[0].holeCards)
        XCTAssertEqual(world.board, s.board)
        XCTAssertEqual(world.players.map(\.stack), s.players.map(\.stack))
        XCTAssertEqual(world.players.map(\.handContribution), s.players.map(\.handContribution))
        XCTAssertEqual(world.actions, s.actions)
        XCTAssertEqual(world.street, s.street)
        XCTAssertEqual(world.actorSeat, s.actorSeat)

        // 未知牌守恒：对手 2×2 张 + deck 43 = 47 = 52 - 自己 2 - board 3；与可见牌不相交
        let visible = Set(s.players[0].holeCards).union(s.board)
        var worldCards = Set<Card>()
        for p in world.players where p.seat != 0 { worldCards.formUnion(p.holeCards) }
        worldCards.formUnion(world.deck.cards)
        XCTAssertEqual(worldCards.count, 47)
        XCTAssertTrue(worldCards.isDisjoint(with: visible))
        XCTAssertEqual(world.deck.count, 43)
    }

    func testFoldedOpponentResampled() {
        var s = GameState.start(config: cash3, seed: 42, buttonSeat: 0)
        s.apply(.fold)                                  // 座位 0 弃
        var rng = SeededGenerator(seed: 7)
        let world = s.resampled(from: 1, using: &rng)   // SB(座位1) 视角
        XCTAssertEqual(world.players[0].holeCards.count, 2)   // 已弃牌对手照样重发 2 张
        XCTAssertEqual(world.players[2].holeCards.count, 2)
    }

    func testSameSeedDeterministicAndWorldIsPlayable() {
        var s = GameState.start(config: cash3, seed: 44, buttonSeat: 0)
        s.apply(.call)
        var r1 = SeededGenerator(seed: 5), r2 = SeededGenerator(seed: 5)
        let w1 = s.resampled(from: 2, using: &r1)
        XCTAssertEqual(w1, s.resampled(from: 2, using: &r2))
        // 重采样世界可被引擎完整推进到终局（apply 兼容性；后续街道由重采样 deck 发出）
        var w = w1
        var counter = 0
        while w.street != .handOver, counter < 200 {
            let legal = legalActions(w)
            if legal.canCheck { w.apply(.check) }
            else if legal.canCall { w.apply(.call) }
            else if let r = legal.betRange { w.apply(.raiseTo(r.lowerBound)) }
            else { w.apply(.fold) }
            counter += 1
        }
        XCTAssertEqual(w.street, .handOver)
        XCTAssertEqual(w.board.count, 5)
        XCTAssertEqual(w.players.reduce(0) { $0 + $1.stack }, 1000 * 3)   // 守恒
    }
}
