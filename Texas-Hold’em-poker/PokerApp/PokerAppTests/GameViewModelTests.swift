import XCTest
@testable import PokerApp
import PokerEngine

/// 脚本 AI：能过牌就过牌、否则跟注——两个机器人必然过牌到河牌摊牌，
/// 确定性地制造 preflop→flop→turn→river 三次街道切换（人类秒弃不参与）。
private struct AlwaysPassAI: PokerAI {
    func decide(_ state: GameState, seat: Int) -> PlayerAction {
        let legal = legalActions(state)
        if legal.canCheck { return .check }
        if legal.canCall { return .call }
        return .fold
    }
}

/// 模拟搜索型 AI 的真实计算开销（PIMC 各档预算 0.3~2.5s/决策）。
private struct SlowSearchAI: PokerAI {
    func decide(_ state: GameState, seat: Int) -> PlayerAction {
        Thread.sleep(forTimeInterval: 2)
        let legal = legalActions(state)
        if legal.canCheck { return .check }
        if legal.canCall { return .call }
        return .fold
    }
}

@MainActor
final class GameViewModelTests: XCTestCase {
    func testFullHandRunsAndProducesResult() async {
        let vm = GameViewModel(config: GameConfig(playerCount: 3, startingStack: 1000,
                                                  format: .cash(sb: 10, bb: 20)),
                               seed: 51, thinkMilliseconds: 1, streetPauseMilliseconds: 1)
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
                               seed: 52, thinkMilliseconds: 1, streetPauseMilliseconds: 1)
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

    /// 新街道发出后、下一个机器人行动前应有额外停顿：
    /// 人类全程过牌/跟注留在手内（弃牌会触发快进、无节奏可言），
    /// 街道停顿设 300ms，打到河牌共 3 次切换，总耗时应 ≥ 300ms（Task.sleep 只保证下界，断言不抖动）。
    func testStreetRevealPausesBeforeNextBotAction() async {
        let bots = [1: AlwaysPassAI() as any PokerAI, 2: AlwaysPassAI() as any PokerAI]
        let vm = GameViewModel(config: GameConfig(playerCount: 3, startingStack: 1000,
                                                  format: .cash(sb: 10, bb: 20)),
                               seed: 51, bots: bots,
                               thinkMilliseconds: 1, streetPauseMilliseconds: 300)
        let start = ContinuousClock.now
        while !(vm.isHandOver || vm.isSessionOver) {
            if let legal = vm.humanLegal {
                await vm.act(legal.canCheck ? .check : .call)   // 人类留在手内，节奏保持
            } else {
                await vm.driveBots()
            }
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertEqual(vm.state.board.count, 5, "被动 AI 应打到河牌，否则本测试空转")
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(300))
    }

    /// 街道停顿设 0ms 时同样的牌局应几乎瞬时完成——证明耗时来自停顿而非调度开销。
    func testZeroStreetPauseRunsFast() async {
        let bots = [1: AlwaysPassAI() as any PokerAI, 2: AlwaysPassAI() as any PokerAI]
        let vm = GameViewModel(config: GameConfig(playerCount: 3, startingStack: 1000,
                                                  format: .cash(sb: 10, bb: 20)),
                               seed: 51, bots: bots,
                               thinkMilliseconds: 1, streetPauseMilliseconds: 1)
        let start = ContinuousClock.now
        while !(vm.isHandOver || vm.isSessionOver) {
            if vm.humanLegal != nil { await vm.act(.fold) }
            else { await vm.driveBots() }
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(300))
    }

    /// 人类弃牌后，剩余机器人的对局应跳过节奏停顿直接快进到本手结果
    /// （若仍按节奏打完：弃牌后 2 机器人 ×300ms ×3 街道 + 2×300ms 街道停顿 ≈ 2.4s，远超断言上限）。
    func testBotsFastForwardAfterHumanFolds() async {
        let bots = [1: AlwaysPassAI() as any PokerAI, 2: AlwaysPassAI() as any PokerAI]
        let vm = GameViewModel(config: GameConfig(playerCount: 3, startingStack: 1000,
                                                  format: .cash(sb: 10, bb: 20)),
                               seed: 51, bots: bots,
                               thinkMilliseconds: 300, streetPauseMilliseconds: 300)
        let start = ContinuousClock.now
        while !(vm.isHandOver || vm.isSessionOver) {
            if vm.humanLegal != nil { await vm.act(.fold) }
            else { await vm.driveBots() }
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertEqual(vm.state.board.count, 5, "被动 AI 应打到河牌（非空转）")
        XCTAssertLessThan(elapsed, .milliseconds(900))
    }

    /// 观战快进不只跳过停顿，还必须绕开搜索型 AI 的纯计算时间：
    /// 慢 AI（2s/决策）在人类弃牌后绝不应再被调用，整手应在 1s 内结束（若未换替身将 ≥4s）。
    func testSpectatorBotsSkipExpensiveSearch() async {
        let bots = [1: SlowSearchAI() as any PokerAI, 2: SlowSearchAI() as any PokerAI]
        let vm = GameViewModel(config: GameConfig(playerCount: 3, startingStack: 1000,
                                                  format: .cash(sb: 10, bb: 20)),
                               seed: 51, bots: bots,
                               thinkMilliseconds: 1, streetPauseMilliseconds: 1)
        let start = ContinuousClock.now
        while !(vm.isHandOver || vm.isSessionOver) {
            if vm.humanLegal != nil { await vm.act(.fold) }
            else { await vm.driveBots() }
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertTrue(vm.isHandOver)
        XCTAssertLessThan(elapsed, .milliseconds(1000), "弃牌后不应再等慢速搜索决策")
    }
}
