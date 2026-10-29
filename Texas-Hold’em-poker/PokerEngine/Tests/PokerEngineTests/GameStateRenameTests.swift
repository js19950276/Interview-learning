import XCTest
@testable import PokerEngine

/// 联机昵称覆写：展示元数据的唯一写入口（players 为 internal(set)，App 不能直写）。
final class GameStateRenameTests: XCTestCase {
    func testRenamePlayerOverwritesNameAndIgnoresBounds() {
        var s = GameState.start(config: GameConfig(playerCount: 2, startingStack: 500,
                                                   format: .cash(sb: 5, bb: 10)), seed: 3)
        XCTAssertEqual(s.players[1].name, "座位 2")
        s.renamePlayer(seat: 1, to: "阿明")
        XCTAssertEqual(s.players[1].name, "阿明")
        s.renamePlayer(seat: 9, to: "幽灵")   // 越界安全忽略，不得崩溃
        XCTAssertEqual(s.players.count, 2)
        s.renamePlayer(seat: 0, to: "名字超过十二个字会被截断掉")
        XCTAssertEqual(s.players[0].name.count, 12)
    }
}
