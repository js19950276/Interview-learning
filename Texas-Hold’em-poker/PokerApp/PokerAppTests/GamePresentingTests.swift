import XCTest
import PokerEngine
@testable import PokerApp

/// 本地 VM 满足联机渲染协议：单机路径行为零变化的前提下接入统一 GameView。
@MainActor
final class GamePresentingTests: XCTestCase {
    func testGameViewModelConforms() {
        let vm = GameViewModel(config: GameConfig(playerCount: 2, startingStack: 500,
                                                  format: .cash(sb: 5, bb: 10)), seed: 3)
        let presenter: any GamePresenting = vm
        let surface = presenter.surface
        XCTAssertNotNil(surface)
        XCTAssertEqual(surface?.seats.count, 2)
        XCTAssertEqual(surface?.yourSeat, 0)
        XCTAssertEqual(surface?.street, .preflop)
        XCTAssertEqual(presenter.isHandOver, false)
        XCTAssertEqual(presenter.isSessionOver, false)
        XCTAssertNil(presenter.lastResult)
        // humanLegal 与 VM 原逻辑一致（翻牌前行动者未必是 seat0，仅验证协议通道）
        XCTAssertEqual(presenter.humanLegal == nil, vm.humanLegal == nil)
    }

    func testSnapshotSurfaceExposesSameMembers() {
        var s = GameState.start(config: GameConfig(playerCount: 2, startingStack: 500,
                                                   format: .cash(sb: 5, bb: 10)), seed: 3)
        _ = s.actorSeat
        let snap = TableSnapshot.make(from: s, recipient: 1, seq: 1)
        let surface: any TableSurface = snap
        XCTAssertEqual(surface.seats.count, 2)
        XCTAssertEqual(surface.yourSeat, 1)
        XCTAssertEqual(surface.format, s.config.format)
        XCTAssertEqual(surface.currentBet, s.currentBet)
        XCTAssertEqual(surface.handNumber, s.handNumber)
        XCTAssertEqual(surface.seatPlayer(0)?.holdsCards, true)
    }
}
