import XCTest
@testable import PokerApp
import PokerEngine

@MainActor
final class GameViewModelTests: XCTestCase {
    func testFullHandRunsAndProducesResult() async {
        let vm = GameViewModel(config: GameConfig(playerCount: 3, startingStack: 1000,
                                                  format: .cash(sb: 10, bb: 20)),
                               seed: 51, thinkMilliseconds: 1)
        for _ in 0..<300 {
            if vm.isHandOver || vm.isSessionOver { break }
            if vm.humanLegal != nil {
                await vm.act(.fold)      // 人类永远弃牌，最快推进
            } else {
                await vm.driveBots()
            }
        }
        XCTAssertTrue(vm.isHandOver || vm.isSessionOver)
        XCTAssertNotNil(vm.state.handResult)
    }

    func testNextHandCapturesLastResultAndAdvances() async {
        let vm = GameViewModel(config: GameConfig(playerCount: 3, startingStack: 1000,
                                                  format: .cash(sb: 10, bb: 20)),
                               seed: 52, thinkMilliseconds: 1)
        while !(vm.isHandOver || vm.isSessionOver) {
            if vm.humanLegal != nil { await vm.act(.fold) }
            else { await vm.driveBots() }
        }
        let first = vm.state.handResult
        let before = vm.state.handNumber
        if !vm.isSessionOver {
            await vm.nextHand()
            XCTAssertEqual(vm.state.handNumber, before + 1)
            XCTAssertEqual(vm.state.street, .preflop)
            XCTAssertEqual(vm.lastResult, first)   // 上一手结果被留存
        }
    }
}
