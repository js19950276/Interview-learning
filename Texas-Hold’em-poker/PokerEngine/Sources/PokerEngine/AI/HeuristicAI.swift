/// 启发式基线：翻前 Chen 公式，翻后成牌等级 + 听牌加成，底池赔率决策。
public struct HeuristicAI: PokerAI {
    public var aggression: Double   // 0...1
    public init(aggression: Double = 0.5) { self.aggression = aggression }

    public func decide(_ state: GameState, seat: Int) -> PlayerAction {
        let legal = legalActions(state)
        var rng = SeededGenerator(seed: state.seed &* 6_364_136_223_846_793_005
                                    &+ UInt64(state.handNumber)
                                    &+ UInt64(truncatingIfNeeded: seat) &* 97)
        let r = Double(rng.next() % 1000) / 1000.0
        let me = state.players[seat]
        let pot = state.potTotal

        let equity: Double
        if state.street == .preflop {
            equity = 0.25 + chenScore(me.holeCards) * 0.035
        } else {
            equity = postflopStrength(me.holeCards + state.board, street: state.street)
        }

        let raiseThreshold = 0.78 - aggression * 0.08
        if let range = legal.betRange, equity > raiseThreshold {
            // 区间过窄（不足额全下封顶）或极强牌：直接全下，避免"差一点全下"的尴尬额度；
            // 100bb 深度下常规加注按池注比例定大小，永不触发本分支，抽样无法覆盖
            // betRange == nil 的局面（全下后面对者的 allInTotal == currentBet）。
            if range.upperBound - range.lowerBound < 5 || equity >= raiseThreshold + 0.10 {
                return .raiseTo(range.upperBound)
            }
            let raw = Int(Double(pot + 2 * legal.callAmount) * (0.6 + r * 0.5))
            let target = min(max(raw, range.lowerBound), range.upperBound)
            return legal.isRaiseContext ? .raiseTo(target) : .bet(target)
        }
        if legal.canCall, legal.callAmount > 0 {
            let odds = Double(legal.callAmount) / Double(max(1, pot + legal.callAmount))
            let margin = 0.04 - aggression * 0.06
            return equity >= odds + margin ? .call : .fold
        }
        return legal.canCheck ? .check : .fold
    }

    /// Chen 公式（成文实现）：AA=20、KK=16、…、72o≈-1.5。
    func chenScore(_ cards: [Card]) -> Double {
        guard cards.count == 2 else { return 5 }
        let a = cards[0].rank.rawValue, b = cards[1].rank.rawValue
        let hi = Double(max(a, b)), lo = Double(min(a, b))
        var s: Double
        switch hi {
        case 14: s = 10; case 13: s = 8; case 12: s = 7; case 11: s = 6
        default: s = hi / 2
        }
        if a == b { s = max(5, s * 2) }
        if cards[0].suit == cards[1].suit { s += 2 }
        if a != b {
            let gap = Int(hi - lo) - 1
            if gap == 1 { s -= 1 } else if gap == 2 { s -= 2 }
            else if gap == 3 { s -= 4 } else if gap >= 4 { s -= 5 }
            if gap <= 1 && hi < 12 { s += 1 }   // 连张且都 < Q 的顺子潜力
        }
        return s
    }

    /// 翻后强度：成牌类别 + 顶张 + 听牌加成，压到 0.02...0.98。
    func postflopStrength(_ cards: [Card], street: Street) -> Double {
        let rank = HandEvaluator.evaluate(cards)
        var s = 0.30 + Double(rank.category.rawValue) * 0.075
        s += Double(rank.tiebreakers.first ?? 0) / 14.0 * 0.08
        if street == .flop || street == .turn {
            let suitCounts = Dictionary(grouping: cards, by: \.suit).mapValues(\.count)
            if (suitCounts.values.max() ?? 0) == 4 { s += 0.12 }   // 同花听牌
            let uniq = Set(cards.map { $0.rank.rawValue }).sorted()
            var run = 1, best = 1
            for i in 1..<uniq.count {
                run = uniq[i] == uniq[i - 1] + 1 ? run + 1 : 1
                best = max(best, run)
            }
            if best >= 4 { s += 0.08 }                              // 两头顺听牌
        }
        return min(max(s, 0.02), 0.98)
    }
}
