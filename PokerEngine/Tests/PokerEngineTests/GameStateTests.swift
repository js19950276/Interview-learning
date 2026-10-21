import XCTest
@testable import PokerEngine

final class GameStateTests: XCTestCase {
    let cash6 = GameConfig(playerCount: 6, startingStack: 2000, format: .cash(sb: 10, bb: 20))

    func testStartDealsTwoCardsEachAndPostsBlinds() {
        let s = GameState.start(config: cash6, seed: 1)
        XCTAssertEqual(s.street, .preflop)
        XCTAssertEqual(s.players.filter { $0.holeCards.count == 2 }.count, 6)
        XCTAssertEqual(s.players.map(\.handContribution).reduce(0, +), 30)   // 10+20
        XCTAssertEqual(s.currentBet, 20)
        XCTAssertEqual(s.minRaiseIncrement, 20)
        // 6 人桌：按钮+1 是 SB，+2 是 BB，UTG = BB+1 先行动
        XCTAssertEqual(s.players[(s.buttonSeat + 1) % 6].streetContribution, 10)
        XCTAssertEqual(s.players[(s.buttonSeat + 2) % 6].streetContribution, 20)
        XCTAssertEqual(s.actorSeat, (s.buttonSeat + 3) % 6)
        XCTAssertEqual(s.potTotal, 30)
    }

    func testHeadsUpButtonIsSmallBlindAndActsFirst() {
        let s = GameState.start(config: GameConfig(playerCount: 2, startingStack: 1500, format: .cash(sb: 5, bb: 10)), seed: 2, buttonSeat: 0)
        XCTAssertEqual(s.players[s.buttonSeat].streetContribution, 5)          // 按钮=SB
        XCTAssertEqual(s.players[(s.buttonSeat + 1) % 2].streetContribution, 10)
        XCTAssertEqual(s.actorSeat, s.buttonSeat)                              // 翻前按钮先行动
    }

    func testDeterminismSameSeedSameState() {
        let a = GameState.start(config: cash6, seed: 777)
        let b = GameState.start(config: cash6, seed: 777)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, GameState.start(config: cash6, seed: 778))
    }

    func testStacksOverrideForReplay() {
        let s = GameState.start(config: cash6, seed: 5, stacks: [100, 500, 900, 1300, 1700, 2000], buttonSeat: 2, handNumber: 3)
        XCTAssertEqual(s.players[0].stack, 100)
        XCTAssertEqual(s.buttonSeat, 2)
        XCTAssertEqual(s.handNumber, 3)
        XCTAssertEqual(s.currentBet, 20)   // cash 恒定盲注
    }

    func testShortBigBlindPostsAllIn() {
        // BB 只有 8，不足大盲 20 → 全下投入 8，currentBet 仍是名义 20
        let cfg = GameConfig(playerCount: 3, startingStack: 2000, format: .cash(sb: 10, bb: 20))
        let s = GameState.start(config: cfg, seed: 9, stacks: [2000, 2000, 8], buttonSeat: 0)
        XCTAssertEqual(s.players[2].stack, 0)          // 按钮 0 → SB 1 → BB 2
        XCTAssertEqual(s.players[2].handContribution, 8)
        XCTAssertEqual(s.players[2].status, .allIn)
        XCTAssertEqual(s.currentBet, 20)
    }
}
