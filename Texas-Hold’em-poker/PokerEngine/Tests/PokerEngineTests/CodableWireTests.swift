import XCTest
@testable import PokerEngine

/// 联机 wire 类型 Codable 往返等价（spec §4：五个纯值类型加 Codable，无行为变化）。
final class CodableWireTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func testLegalActionsRoundTrip() throws {
        let legal = LegalActions(seat: 3, canCheck: false, canCall: true, callAmount: 120,
                                 betRange: 240...360, isRaiseContext: true)
        XCTAssertEqual(try roundTrip(legal), legal)
        let noBet = LegalActions(seat: 1, canCheck: true, canCall: false, callAmount: 0,
                                 betRange: nil, isRaiseContext: false)
        XCTAssertEqual(try roundTrip(noBet), noBet)
    }

    func testHandResultFromShowdownRoundTrips() throws {
        // 两人一路过牌/跟注到摊牌，拿到含 ranks 的真实 HandResult
        var s = GameState.start(config: GameConfig(playerCount: 2, startingStack: 500,
                                                   format: .cash(sb: 5, bb: 10)), seed: 11)
        while s.street != .handOver {
            if s.actorSeat != nil {
                let legal = legalActions(s)
                s.apply(legal.canCheck ? .check : .call)
            }
        }
        let result = try XCTUnwrap(s.handResult)
        XCTAssertFalse(result.awards[0].ranks.isEmpty, "摊牌局应有 ranks")
        XCTAssertEqual(try roundTrip(result), result)
    }

    func testPlayerStatusRoundTrip() throws {
        for status in [PlayerStatus.active, .folded, .allIn, .eliminated] {
            XCTAssertEqual(try roundTrip(status), status)
        }
    }

    func testTournamentPayoutRoundTrip() throws {
        let payout = TournamentPayout(seat: 2, place: 1, amount: 1400)
        XCTAssertEqual(try roundTrip(payout), payout)
    }
}
