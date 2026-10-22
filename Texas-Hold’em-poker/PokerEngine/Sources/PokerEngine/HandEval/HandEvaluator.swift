public enum HandEvaluator {
    /// 公开入口：路由到 FastEval（与 evaluateLegacy 全等，FastEvalTests 钉死）。
    public static func evaluate(_ cards: [Card]) -> HandRank {
        FastEval.evaluate(cards)
    }

    /// 评估 5–7 张牌的最优 5 张牌型。
    static func evaluateLegacy(_ cards: [Card]) -> HandRank {
        precondition((5...7).contains(cards.count))
        let ranks = cards.map { $0.rank.rawValue }          // 2...14
        let rankCounts = Dictionary(ranks.map { ($0, 1) }, uniquingKeysWith: +)
        let byCount = Dictionary(grouping: rankCounts.filter { $0.value > 1 }) { $0.value }
        let quads = (byCount[4] ?? []).map(\.key).sorted(by: >)
        let trips = (byCount[3] ?? []).map(\.key).sorted(by: >)
        let pairs = (byCount[2] ?? []).map(\.key).sorted(by: >)

        // 同花 / 同花顺：任一花色 ≥5 张（同花顺是全局最大，直接返回）
        var flushRank: HandRank?
        for suit in Suit.allCases {
            let suited = cards.filter { $0.suit == suit }.map { $0.rank.rawValue }
            if suited.count >= 5 {
                let desc = suited.sorted(by: >)
                if let high = straightHigh(in: desc) {
                    return .init(.straightFlush, [high])
                }
                flushRank = .init(.flush, Array(desc.prefix(5)))
            }
        }

        if let q = quads.first {
            let kicker = ranks.filter { $0 != q }.max() ?? 0
            return .init(.fourOfAKind, [q, kicker])
        }
        // 葫芦：三条 + 对子（两个三条时较小者当对子）
        if let t = trips.first {
            let pairForBoat = pairs.first ?? trips.dropFirst().first
            if let p = pairForBoat { return .init(.fullHouse, [t, p]) }
        }
        if let f = flushRank { return f }
        if let high = straightHigh(in: ranks) {
            return .init(.straight, [high])
        }
        if let t = trips.first {
            let kickers = ranks.filter { $0 != t }.sorted(by: >)
            return .init(.threeOfAKind, [t] + kickers.prefix(2))
        }
        if pairs.count >= 2 {
            let kick = ranks.filter { $0 != pairs[0] && $0 != pairs[1] }.max() ?? 0
            return .init(.twoPair, [pairs[0], pairs[1], kick])
        }
        if let p = pairs.first {
            let kickers = ranks.filter { $0 != p }.sorted(by: >)
            return .init(.onePair, [p] + kickers.prefix(3))
        }
        return .init(.highCard, ranks.sorted(by: >))
    }

    /// 给一组点数（可含重复），返回最高顺子的最高张；A 可当 1（轮子顺）。无顺子返回 nil。
    static func straightHigh(in ranks: [Int]) -> Int? {
        var present = Set(ranks)
        if present.contains(14) { present.insert(1) }
        for high in stride(from: 14, through: 5, by: -1) {
            let low = high - 4
            if (low...high).allSatisfy({ present.contains($0) }) { return high }
        }
        return nil
    }
}
