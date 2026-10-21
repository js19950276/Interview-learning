import XCTest
@testable import PokerEngine

final class LegalActionsTests: XCTestCase {
    let cash3 = GameConfig(playerCount: 3, startingStack: 1000, format: .cash(sb: 10, bb: 20))

    func testPreflopFirstToAct() {
        let s = GameState.start(config: cash3, seed: 3, buttonSeat: 0)
        // 按钮 0 → SB 1 → BB 2，UTG = 座位 0
        let legal = legalActions(s)
        XCTAssertTrue(isLegal(.fold, in: legal))
        XCTAssertFalse(isLegal(.check, in: legal))       // 面对大盲
        XCTAssertTrue(isLegal(.call, in: legal))
        XCTAssertEqual(legal.callAmount, 20)
        XCTAssertEqual(legal.betRange?.lowerBound, 40)   // 最小加注到 2BB
        XCTAssertEqual(legal.betRange?.upperBound, 1000) // 全下 = 0 已投 + 1000
        XCTAssertTrue(legal.isRaiseContext)
    }

    // TASK6-DEFERRED（依赖 apply，Task 6 Step 4 恢复）:
    // testBigBlindOptionIsCheckOrRaise
    // testPostflopBetRangeAndCheck

    func testShortStackCanOnlyShove() {
        // 按钮位（也是 UTG）只剩 25：翻前加注只有 all-in 一个档
        let cfg = GameConfig(playerCount: 3, startingStack: 1000, format: .cash(sb: 10, bb: 20))
        let s = GameState.start(config: cfg, seed: 3, stacks: [25, 1000, 1000], buttonSeat: 0)
        let legal = legalActions(s)
        XCTAssertEqual(legal.callAmount, 20)
        XCTAssertEqual(legal.betRange, 25...25)          // 全下加注到 25
    }

    func testCannotRaiseWhenOnlyEnoughToCall() {
        // 剩 20 正好够跟注 → 无加注区间
        let cfg = GameConfig(playerCount: 3, startingStack: 1000, format: .cash(sb: 10, bb: 20))
        let s = GameState.start(config: cfg, seed: 3, stacks: [20, 1000, 1000], buttonSeat: 0)
        let legal = legalActions(s)
        XCTAssertNil(legal.betRange)
        XCTAssertTrue(isLegal(.call, in: legal))
        XCTAssertFalse(isLegal(.check, in: legal))
    }
}
