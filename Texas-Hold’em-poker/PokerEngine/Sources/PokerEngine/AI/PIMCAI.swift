import Foundation

/// PIMC 搜索型决策器（spec 阶段 2a §4.2/§4.3）：
/// 采样平行世界 × 每世界根带 UCB1 × rollout 至终局 × 跨世界平均 EV；
/// fold 的 EV 结构性为 0（筹码冻结）不发 rollout；时间预算到点完成当前世界即截断。
public struct PIMCAI: PokerAI {
    public var worlds: Int
    public var iterationsPerWorld: Int
    public var exploreC: Double
    public var timeBudgetMs: Int?
    public var rollout: any PokerAI

    public init(worlds: Int, iterationsPerWorld: Int,
                exploreC: Double = 1.4, timeBudgetMs: Int? = nil,
                rollout: (any PokerAI)? = nil) {
        self.worlds = max(1, worlds)
        self.iterationsPerWorld = max(1, iterationsPerWorld)
        self.exploreC = exploreC
        self.timeBudgetMs = timeBudgetMs
        self.rollout = rollout ?? HeuristicAI(aggression: 0.5)
    }

    public static let easy = PIMCAI(worlds: 8, iterationsPerWorld: 25, timeBudgetMs: 300)
    public static let normal = PIMCAI(worlds: 16, iterationsPerWorld: 64, timeBudgetMs: 1000)
    public static let hard = PIMCAI(worlds: 32, iterationsPerWorld: 125, timeBudgetMs: 1500)

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
        var sums = [Double](repeating: 0, count: ladder.count)
        var counts = [Int](repeating: 0, count: ladder.count)

        for _ in 0..<worlds {
            if let budgetMs = timeBudgetMs,
               Date().timeIntervalSince(start) * 1000 > Double(budgetMs) { break }
            let world = state.resampled(from: seat, using: &rng)
            if let fi = ladder.firstIndex(of: .fold) {
                counts[fi] += iterationsPerWorld   // fold EV 恒 0，仅记账不发 rollout
            }
            for _ in 0..<iterationsPerWorld {
                guard let idx = selectRootAction(ladder: ladder, sums: sums, counts: counts,
                                                 total: counts.reduce(0, +)) else { break }
                var w = world
                w.apply(ladder[idx])
                var counter = 0
                while w.street != .handOver, let actor = w.actorSeat, counter < 200 {
                    w.apply(rollout.decide(w, seat: actor))
                    counter += 1
                }
                sums[idx] += Double(w.players[seat].stack - myStack)
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
