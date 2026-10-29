import XCTest
@testable import PokerEngine

final class PIMCAITests: XCTestCase {
    func c(_ s: String) -> Card {
        let r = Array(s)[0], su = Array(s)[1]
        let rank = ["2","3","4","5","6","7","8","9","T","J","Q","K","A"].firstIndex(of: String(r))!
        let suit = ["s","h","d","c"].firstIndex(of: String(su))!
        return Card(rank: Rank(rawValue: rank + 2)!, suit: Suit(rawValue: suit)!)
    }
    let cash3 = GameConfig(playerCount: 3, startingStack: 1000, format: .cash(sb: 10, bb: 20))

    func testLadderClampsDedupesAndSinglePoint() {
        let s = GameState.start(config: cash3, seed: 3, buttonSeat: 0)
        let ladder = ladderActions(legalActions(s), state: s)
        XCTAssertTrue(ladder.contains(.call))
        XCTAssertFalse(ladder.contains(.check))          // 面对大盲无 check
        XCTAssertEqual(ladder.first, .call)              // 保守序：call 最优先
        XCTAssertTrue(ladder.contains(.fold))
        for action in ladder {
            if case .raiseTo(let t) = action { XCTAssertTrue((40...1000).contains(t), "t=\(t)") }
            if case .bet(let t) = action { XCTAssertTrue((40...1000).contains(t), "t=\(t)") }
        }
        // 单点区间 → 激进档仅全下一档（Review Focus #3）
        let short = GameState.start(config: cash3, seed: 3, stacks: [25, 1000, 1000], buttonSeat: 0)
        let raises = ladderActions(legalActions(short), state: short).filter {
            if case .raiseTo = $0 { return true }; return false
        }
        XCTAssertEqual(raises, [.raiseTo(25)])
    }

    func testPreflopAANeverFoldsAndTrashFolds() {
        var s = GameState.start(config: cash3, seed: 41, buttonSeat: 0)
        s.players[s.actorSeat!].holeCards = [c("Ah"), c("Ad")]
        let a = PIMCAI.normal.decide(s, seat: s.actorSeat!)
        if case .fold = a { XCTFail("AA 翻前不应弃牌：\(a)") }

        var t = GameState.start(config: cash3, seed: 42, buttonSeat: 0)
        t.players[t.actorSeat!].holeCards = [c("7d"), c("2c")]
        XCTAssertEqual(PIMCAI.easy.decide(t, seat: t.actorSeat!), .fold)
    }

    /// Review Focus #3/#5：12 局随机采样，每手每个决策恒合法；同局面决策确定。
    func testAlwaysLegalAndDeterministic() {
        let cfg = GameConfig(playerCount: 4, startingStack: 1000, format: .cash(sb: 10, bb: 20))
        let ai = PIMCAI(worlds: 4, iterationsPerWorld: 8)
        for seed in UInt64(1)...12 {
            var s = GameState.start(config: cfg, seed: seed * 13)
            while s.street != .handOver {
                let legal = legalActions(s)
                let decision = ai.decide(s, seat: s.actorSeat!)
                XCTAssertTrue(isLegal(decision, in: legal), "seed \(seed): \(decision) vs \(legal)")
                s.apply(decision)
            }
        }
        let s0 = GameState.start(config: cfg, seed: 999)
        XCTAssertEqual(ai.decide(s0, seat: s0.actorSeat!), ai.decide(s0, seat: s0.actorSeat!))
    }

    func testPresetsMatchSpec() {
        XCTAssertEqual(PIMCAI.easy.worlds, 8); XCTAssertEqual(PIMCAI.easy.iterationsPerWorld, 25)
        XCTAssertEqual(PIMCAI.normal.worlds, 16); XCTAssertEqual(PIMCAI.normal.iterationsPerWorld, 64)
        XCTAssertEqual(PIMCAI.hard.worlds, 32); XCTAssertEqual(PIMCAI.hard.iterationsPerWorld, 125)
    }

    /// 时间预算截断路径：极小预算下决策仍合法（修复轮改动的路径）。
    func testTinyTimeBudgetStillLegal() {
        let s = GameState.start(config: GameConfig(playerCount: 2, startingStack: 2000, format: .cash(sb: 10, bb: 20)),
                                seed: 123, buttonSeat: 0)
        let ai = PIMCAI(worlds: 16, iterationsPerWorld: 64, timeBudgetMs: 1)   // 必然截断
        let decision = ai.decide(s, seat: s.actorSeat!)
        XCTAssertTrue(isLegal(decision, in: legalActions(s)))
    }

    // MARK: - 地狱难度：对手行为感知世界过滤

    let huCfg = GameConfig(playerCount: 2, startingStack: 20_000, format: .cash(sb: 10, bb: 20))

    /// 单挑局：对手（座位1=BB）翻前直接全下 20000，座位0 面对全下待决策。
    private func jamState() -> GameState {
        var s = GameState.start(config: huCfg, seed: 5, stacks: [20_000, 20_000], buttonSeat: 0)
        s.apply(.call)             // 座位0（SB）平跟
        s.apply(.raiseTo(20_000))  // 座位1（BB）直接全下
        XCTAssertEqual(s.players[1].status, .allIn)
        XCTAssertEqual(s.players[1].handContribution, 20_000)
        return s
    }

    /// 过滤谓词直接单测：构造世界后改写对手底牌（players 为 internal(set)）。
    func testOpponentFilterRejectsImplausibleWorlds() {
        let eff = 20_000   // min(我方 19980+20, 对手 0+20000)

        // (a) 对手全下 20000（≥60% 有效筹码）却重采样出 7♦2♣（Chen −1.5 < 6）→ 拒绝
        var jam = jamState()
        jam.players[0].holeCards = [c("Ac"), c("Kd")]
        jam.players[1].holeCards = [c("7d"), c("2c")]
        XCTAssertFalse(PIMCAI.worldIsPlausible(jam, seat: 0, effectiveStack: eff), "(a) 垃圾牌全下不可信")

        // (b) 同局面重采样出 A♠K♠（Chen 12 ≥ 6）→ 接受
        var jam2 = jamState()
        jam2.players[0].holeCards = [c("Ac"), c("Kd")]
        jam2.players[1].holeCards = [c("As"), c("Ks")]
        XCTAssertTrue(PIMCAI.worldIsPlausible(jam2, seat: 0, effectiveStack: eff), "(b) 大牌全下可信")

        // (c) 对手仅盲注级投入（BB 20，全场盲注 SB10+BB20）持 7♦2♣ → 过滤跳过，接受
        var blind = GameState.start(config: huCfg, seed: 5, stacks: [20_000, 20_000], buttonSeat: 0)
        blind.players[0].holeCards = [c("Ac"), c("Kd")]
        blind.players[1].holeCards = [c("7d"), c("2c")]
        XCTAssertTrue(PIMCAI.worldIsPlausible(blind, seat: 0, effectiveStack: eff), "(c) 盲注投入无意图信息")

        // (d) 翻后对手投入 6020（≥25% 有效筹码、<60%）持底对（bucket 2 < 4）→ 拒绝（规则1）
        // 单挑翻后 BB（座位1）先行动：平跟→BB 检查看翻牌→BB 下注 6000，座位0 待决策。
        var post = GameState.start(config: huCfg, seed: 5, stacks: [20_000, 20_000], buttonSeat: 0)
        post.apply(.call)         // 座位0（SB）平跟
        post.apply(.check)        // 座位1（BB）检查选项 → 翻牌
        post.apply(.bet(6_000))   // 座位1 翻牌先手下注（本手共投 20+6000）
        XCTAssertEqual(post.street, .flop)
        XCTAssertEqual(post.players[1].handContribution, 6_020)
        var bottom = post
        bottom.players[0].holeCards = [c("Ac"), c("Kd")]
        bottom.players[1].holeCards = [c("2c"), c("5h")]
        bottom.board = [c("9s"), c("7d"), c("2h")]   // 底对 2
        XCTAssertFalse(PIMCAI.worldIsPlausible(bottom, seat: 0, effectiveStack: eff), "(d) 大额投入底对不可信")

        // (e) 对照：同样投入但顶对（bucket 4）→ 接受（bucket<4 边界 + 规则2 需 ≥60% 不触发）
        var top = post
        top.players[0].holeCards = [c("Ac"), c("Kd")]
        top.players[1].holeCards = [c("9h"), c("5h")]
        top.board = [c("9s"), c("7d"), c("2h")]      // 顶对 9
        XCTAssertTrue(PIMCAI.worldIsPlausible(top, seat: 0, effectiveStack: eff), "(e) 顶对投入可信")
    }

    func testHellPresetMatchesSpec() {
        XCTAssertEqual(PIMCAI.hell.worlds, 256)
        XCTAssertEqual(PIMCAI.hell.iterationsPerWorld, 125)
        XCTAssertEqual(PIMCAI.hell.timeBudgetMs, 2500)
        XCTAssertTrue(PIMCAI.hell.opponentFilter)
    }

    /// 过滤开启（含重采样路径）后决策仍恒合法且确定。
    func testFilterOnStillLegalAndDeterministic() {
        let cfg = GameConfig(playerCount: 4, startingStack: 1000, format: .cash(sb: 10, bb: 20))
        let ai = PIMCAI(worlds: 8, iterationsPerWorld: 8, opponentFilter: true)
        for seed in UInt64(1)...6 {
            var s = GameState.start(config: cfg, seed: seed * 13)
            while s.street != .handOver {
                let legal = legalActions(s)
                let decision = ai.decide(s, seat: s.actorSeat!)
                XCTAssertTrue(isLegal(decision, in: legal), "seed \(seed): \(decision) vs \(legal)")
                s.apply(decision)
            }
        }
        let s0 = GameState.start(config: cfg, seed: 999)
        XCTAssertEqual(ai.decide(s0, seat: s0.actorSeat!), ai.decide(s0, seat: s0.actorSeat!))
    }

    /// 既有预设冻结：过滤关闭、预算不变。
    func testExistingPresetsKeepOpponentFilterOff() {
        XCTAssertFalse(PIMCAI.easy.opponentFilter)
        XCTAssertFalse(PIMCAI.normal.opponentFilter)
        XCTAssertFalse(PIMCAI.hard.opponentFilter)
        XCTAssertEqual(PIMCAI.easy.timeBudgetMs, 300)
        XCTAssertEqual(PIMCAI.normal.timeBudgetMs, 1000)
        XCTAssertEqual(PIMCAI.hard.timeBudgetMs, 1500)
    }
}
