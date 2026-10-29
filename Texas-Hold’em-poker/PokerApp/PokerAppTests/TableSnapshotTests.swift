import XCTest
import PokerEngine
@testable import PokerApp

/// spec §7 脱敏规则：对手手牌永不出现在网络上；亮牌规则与单机 UI 一致。
final class TableSnapshotTests: XCTestCase {
    let config = GameConfig(playerCount: 3, startingStack: 1000, format: .cash(sb: 10, bb: 20))

    /// 三人全部过牌/跟注到摊牌。
    private func showdownState(seed: UInt64) -> GameState {
        var s = GameState.start(config: config, seed: seed)
        while s.street != .handOver {
            if let _ = s.actorSeat {
                let legal = legalActions(s)
                s.apply(legal.canCheck ? .check : .call)
            }
        }
        return s
    }

    func testMidHandSnapshotHidesOpponentCards() {
        let s = GameState.start(config: config, seed: 5)   // 翻牌前即取快照
        let snap = TableSnapshot.make(from: s, recipient: 1, seq: 1)
        XCTAssertEqual(snap.players[1].holeCards.count, 2, "接收者看到自己的手牌")
        for seat in [0, 2] {
            XCTAssertTrue(snap.players[seat].holdsCards, "对手有牌但不可见")
            XCTAssertTrue(snap.players[seat].holeCards.isEmpty, "对手手牌绝不外发（抓包也不行）")
        }
        XCTAssertEqual(snap.yourSeat, 1)
        XCTAssertEqual(snap.seq, 1)
        XCTAssertEqual(snap.potTotal, s.potTotal)
        XCTAssertEqual(snap.board, s.board)
    }

    func testYourLegalMatchesEngineOnlyOnYourTurn() {
        let s = GameState.start(config: config, seed: 5)
        let actor = s.actorSeat!
        let snapActor = TableSnapshot.make(from: s, recipient: actor, seq: 1)
        XCTAssertEqual(snapActor.yourLegal, legalActions(s))
        let snapOther = TableSnapshot.make(from: s, recipient: (actor + 1) % 3, seq: 1)
        XCTAssertNil(snapOther.yourLegal, "未轮到接收者时不附带")
    }

    func testShowdownRevealsContendersButNotFolder() {
        // 先打到只剩两人摊牌：第三人翻牌前弃牌
        var s = GameState.start(config: config, seed: 9)
        // 推进必须用合法动作：面对下注时 .check 会被引擎按非法动作断言+弃牌处理
        while s.actorSeat != 2 {
            let legal = legalActions(s)
            s.apply(legal.canCheck ? .check : .call)
        }
        s.apply(.fold)
        while s.street != .handOver {
            if s.actorSeat != nil {
                let legal = legalActions(s)
                s.apply(legal.canCheck ? .check : .call)
            }
        }
        XCTAssertEqual(s.street, .handOver)
        let foldedSeat = 2
        let snap = TableSnapshot.make(from: s, recipient: 0, seq: 3)
        for player in snap.players where player.seat != foldedSeat {
            XCTAssertFalse(player.holeCards.isEmpty, "摊牌局未弃牌者亮牌（含接收者之外的人）")
        }
        XCTAssertTrue(snap.players[foldedSeat].holeCards.isEmpty, "弃牌者 muck 不亮")
    }

    func testUncontestedWinRevealsNothing() {
        var s = GameState.start(config: config, seed: 9)
        while s.actorSeat != 2 {
            let legal = legalActions(s)
            s.apply(legal.canCheck ? .check : .call)
        }
        s.apply(.fold)
        while s.actorSeat != nil { s.apply(.fold) }   // 只剩一人，直接收池
        XCTAssertEqual(s.handResult?.awards.first?.ranks.isEmpty, true, "全员弃牌局无 ranks")
        let snap = TableSnapshot.make(from: s, recipient: 0, seq: 4)
        for player in snap.players where player.seat != 0 {
            XCTAssertTrue(player.holeCards.isEmpty, "非摊牌结束（uncontested）任何人不亮牌")
        }
        XCTAssertEqual(snap.players[0].holeCards.count, 2, "接收者始终看得到自己")
    }

    func testSnapshotCodableRoundTrip() throws {
        let s = showdownState(seed: 13)
        let snap = TableSnapshot.make(from: s, recipient: 1, seq: 42)
        let data = try JSONEncoder().encode(snap)
        XCTAssertEqual(try JSONDecoder().decode(TableSnapshot.self, from: data), snap)
    }

    func testGameStateConformsToTableSurface() {
        let s = GameState.start(config: config, seed: 5)
        let surface: any TableSurface = s
        XCTAssertEqual(surface.seats.count, 3)
        XCTAssertEqual(surface.yourSeat, s.config.humanSeat)
        XCTAssertEqual(surface.format, s.config.format)
        XCTAssertEqual(surface.potTotal, s.potTotal)
        XCTAssertNotNil(surface.seatPlayer(1))
        XCTAssertNil(surface.seatPlayer(99))
    }
}
