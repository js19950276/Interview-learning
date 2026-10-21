import XCTest
@testable import PokerEngine

final class FormatsTests: XCTestCase {
    func testCashBlindsConstant() {
        let f = GameFormat.cash(sb: 5, bb: 10)
        XCTAssertEqual(currentBlinds(for: f, handNumber: 0).bb, 10)
        XCTAssertEqual(currentBlinds(for: f, handNumber: 999).sb, 5)
    }

    func testSNGBlindEscalationByHandCount() {
        let sng = SNGConfig(buyIn: 1000, startingStack: 1500,
                            levels: [BlindLevel(sb: 10, bb: 20, hands: 10),
                                     BlindLevel(sb: 25, bb: 50, hands: 10)],
                            payouts: [0.5, 0.3, 0.2])
        let f = GameFormat.sng(sng)
        // 手 0-9 → 10/20；手 10-19 → 25/50；手 20+ 沿用最后一档
        XCTAssertEqual(currentBlinds(for: f, handNumber: 0).sb, 10)
        XCTAssertEqual(currentBlinds(for: f, handNumber: 9).bb, 20)
        XCTAssertEqual(currentBlinds(for: f, handNumber: 10).sb, 25)
        XCTAssertEqual(currentBlinds(for: f, handNumber: 19).bb, 50)
        XCTAssertEqual(currentBlinds(for: f, handNumber: 25).bb, 50)
    }

    func testEffectiveStackPerFormat() {
        let cash = GameConfig(playerCount: 2, startingStack: 2000, format: .cash(sb: 5, bb: 10))
        XCTAssertEqual(cash.effectiveStack, 2000)
        let sng = GameConfig(playerCount: 2, startingStack: 999,
                             format: .sng(SNGConfig(buyIn: 100, startingStack: 1500,
                                                    levels: [BlindLevel(sb: 10, bb: 20, hands: 8)],
                                                    payouts: [0.6, 0.4])))
        XCTAssertEqual(sng.effectiveStack, 1500)   // SNG 以 sng.startingStack 为准
    }
}
