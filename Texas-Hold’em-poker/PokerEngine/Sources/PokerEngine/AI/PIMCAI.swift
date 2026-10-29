import Foundation

/// PIMC 搜索型决策器（spec 阶段 2a §4.2/§4.3）：
/// 每迭代独立采样平行世界 × 根带 UCB1 × rollout 至终局 × 跨动作平均 EV。
/// 每次迭代都重新 `resampled` 一个全新世界，因此同一动作跨迭代的重复评估是
/// 真实 i.i.d. 样本；预算语义：worlds × iterationsPerWorld = 每次决策的
/// 独立世界样本总数（rollout 策略确定性导致的伪重复不复存在）。
/// fold 的 EV 结构性为 0（筹码冻结）不发 rollout；时间预算到点完成当前迭代即截断。
public struct PIMCAI: PokerAI {
    public var worlds: Int
    public var iterationsPerWorld: Int
    public var exploreC: Double
    public var timeBudgetMs: Int?
    public var rollout: any PokerAI
    /// 地狱难度：对手行为感知世界过滤（默认关闭，既有预设行为冻结不变）。
    public var opponentFilter: Bool

    public init(worlds: Int, iterationsPerWorld: Int,
                exploreC: Double = 1.4, timeBudgetMs: Int? = nil,
                rollout: (any PokerAI)? = nil, opponentFilter: Bool = false) {
        self.worlds = max(1, worlds)
        self.iterationsPerWorld = max(1, iterationsPerWorld)
        self.exploreC = exploreC
        self.timeBudgetMs = timeBudgetMs
        self.rollout = rollout ?? HeuristicAI(aggression: 0.5)
        self.opponentFilter = opponentFilter
    }

    public static let easy = PIMCAI(worlds: 8, iterationsPerWorld: 25, timeBudgetMs: 300)
    public static let normal = PIMCAI(worlds: 16, iterationsPerWorld: 64, timeBudgetMs: 1000)
    public static let hard = PIMCAI(worlds: 32, iterationsPerWorld: 125, timeBudgetMs: 1500)
    /// 地狱：32k 样本（256×125）+ 对手意图感知采样——对手真金投入约束其重采样持牌，
    /// 修「重采样均匀化对手范围 → 面对大注高估胜率」（PIMC 0.598 vs 真实 0.140）的偏差。
    public static let hell = PIMCAI(worlds: 256, iterationsPerWorld: 125, timeBudgetMs: 2500,
                                    opponentFilter: true)

    public func decide(_ state: GameState, seat: Int) -> PlayerAction {
        let legal = legalActions(state)
        let ladder = ladderActions(legal, state: state)
        guard ladder.count > 1 else { return ladder.first ?? .fold }

        var rng = SeededGenerator(seed: state.seed &* 0x9E37_79B9_7F4A_7C15
                                    &+ UInt64(state.handNumber)
                                    &+ UInt64(truncatingIfNeeded: seat) &* 97
                                    &+ UInt64(state.actions.count) &* 31)
        let start = Date()
        let myStack = state.players[seat].stack
        let myTotal = myStack + state.players[seat].handContribution   // 决策时点我方总额
        var sums = [Double](repeating: 0, count: ladder.count)
        var counts = [Int](repeating: 0, count: ladder.count)

        for _ in 0..<worlds {
            if let budgetMs = timeBudgetMs,
               Date().timeIntervalSince(start) * 1000 > Double(budgetMs) { break }
            for _ in 0..<iterationsPerWorld {
                if let budgetMs = timeBudgetMs,
                   Date().timeIntervalSince(start) * 1000 > Double(budgetMs) { break }
                var world = state.resampled(from: seat, using: &rng)
                // 对手意图感知采样：不可信世界（对手大额投入却持垃圾）就地重采样，
                // 最多 8 次尝试、第 8 次无论真假保留（退化兜底，绝不死循环）。
                // 重采样消费同一 rng 流——同种子仍逐位确定。
                if opponentFilter {
                    var attempts = 1
                    while attempts < 8, !Self.worldIsPlausible(world, seat: seat,
                                                                effectiveStack: myTotal) {
                        world = state.resampled(from: seat, using: &rng)
                        attempts += 1
                    }
                }
                if let fi = ladder.firstIndex(of: .fold) {
                    counts[fi] += 1   // fold EV 恒 0，仅记账不发 rollout
                }
                guard let idx = selectRootAction(ladder: ladder, sums: sums, counts: counts,
                                                 total: counts.reduce(0, +)) else { break }
                world.apply(ladder[idx])
                var counter = 0
                while world.street != .handOver, let actor = world.actorSeat, counter < 200 {
                    world.apply(rollout.decide(world, seat: actor))
                    counter += 1
                }
                sums[idx] += Double(world.players[seat].stack - myStack)
                counts[idx] += 1
            }
        }
        var best = ladder.firstIndex(of: .fold) ?? 0   // 全负 EV 时回退 fold（均值 0）
        var bestMean = 0.0                              // fold 基线
        for i in ladder.indices where counts[i] > 0 && ladder[i] != .fold {
            let mean = sums[i] / Double(counts[i])
            if mean > bestMean + 1e-9 { bestMean = mean; best = i }
        }
        return ladder[best]
    }

    /// 根带 UCB1：未试的非 fold 动作优先；随后 mean + c·√(ln N / n)。返回 nil = 无可行动作。
    private func selectRootAction(ladder: [PlayerAction], sums: [Double],
                                  counts: [Int], total: Int) -> Int? {
        for i in ladder.indices where counts[i] == 0 && ladder[i] != .fold { return i }
        var best: Int?; var bestUCB = -Double.infinity
        for i in ladder.indices where counts[i] > 0 && ladder[i] != .fold {
            let mean = sums[i] / Double(counts[i])
            let ucb = mean + exploreC * sqrt(log(Double(max(1, total))) / Double(counts[i]))
            if ucb > bestUCB { bestUCB = ucb; best = i }
        }
        return best
    }

    /// Chen 记分基准（HeuristicAI.chenScore 为同模块 internal，直接复用成文实现）。
    private static let chenBasis = HeuristicAI(aggression: 0.5)

    /// 对手行为感知的世界合理性（地狱难度）：
    /// 对手的真金投入是对其持牌范围的强约束，均匀重采样会系统性高估面对大注的胜率。
    /// `effectiveStack` 传决策者本手总额（stack+handContribution）；每个对手的双边
    /// 有效筹码 = min(我方总额, 对手总额)。弃牌/淘汰者与无牌者不校验（其投入已无意图）。
    /// 两条拒绝规则（整数运算避免截断：≥0.25 即 4·invested ≥ eff；≥0.60 即 5·invested ≥ 3·eff）：
    /// 1. 仅翻后：投入 ≥25% 有效筹码而成牌不足顶对（Abstraction.strengthBucket < 4）；
    /// 2. 任意街：投入 ≥60% 有效筹码而翻前质量 Chen < 6（垃圾级起点）。
    /// 跳过：盲注被迫全下（allIn 且投入 ≤ 大盲——非自愿投入无意图）与盲注级投入（<25%）。
    static func worldIsPlausible(_ world: GameState, seat: Int, effectiveStack: Int) -> Bool {
        let bb = currentBlinds(for: world.config.format, handNumber: world.handNumber).bb
        for i in world.players.indices {
            guard i != seat else { continue }
            let opp = world.players[i]
            guard opp.status != .folded, opp.status != .eliminated,
                  opp.holeCards.count == 2 else { continue }
            let invested = opp.handContribution
            let eff = min(effectiveStack, opp.stack + opp.handContribution)
            guard eff > 0 else { continue }
            if opp.status == .allIn && invested <= bb { continue }   // 盲注被迫全下
            // 规则 1：翻后大额投入却无顶对级成牌（强度桶 < 4）
            if world.street != .preflop, world.board.count >= 3, invested * 4 >= eff {
                let rank = HandEvaluator.evaluate(opp.holeCards + world.board)
                if Abstraction.strengthBucket(rank, board: world.board) < 4 { return false }
            }
            // 规则 2：巨额投入却翻前垃圾（Chen < 6）
            if invested * 5 >= eff * 3, chenBasis.chenScore(opp.holeCards) < 6 { return false }
        }
        return true
    }
}

/// 档位阶梯（spec §4.3）：[check, call, fold, 最小, ½池, 满池, 全下] ∩ 合法者，clamp 去重。
/// 数组顺序即平手裁决的保守优先序。
func ladderActions(_ legal: LegalActions, state: GameState) -> [PlayerAction] {
    var acts: [PlayerAction] = []
    if legal.canCheck { acts.append(.check) }
    if legal.canCall { acts.append(.call) }
    acts.append(.fold)
    if let range = legal.betRange {
        let toCall = legal.callAmount
        let half = state.currentBet + (state.potTotal + toCall) / 2
        let pot = state.currentBet + (state.potTotal + toCall)
        var seen = Set<Int>()
        for t in [range.lowerBound, half, pot, range.upperBound] {
            let clamped = min(max(t, range.lowerBound), range.upperBound)
            guard !seen.contains(clamped) else { continue }
            seen.insert(clamped)
            acts.append(legal.isRaiseContext ? .raiseTo(clamped) : .bet(clamped))
        }
    }
    return acts
}
