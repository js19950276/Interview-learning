/// 零字典快评估：数组计数 + 位掩码顺子。与 HandEvaluator.evaluateLegacy 逐位全等（FastEvalTests 钉死）。
enum FastEval {
    static func evaluate(_ cards: [Card]) -> HandRank {
        precondition((5...7).contains(cards.count))
        var rankCount = [Int](repeating: 0, count: 15)
        var suitCount = [Int](repeating: 0, count: 4)
        var mask = 0
        for card in cards {
            let r = card.rank.rawValue
            rankCount[r] += 1
            suitCount[card.suit.rawValue] += 1
            mask |= 1 << r
        }

        // 同花 / 同花顺：任一花色 ≥5 张
        var flushStraightHigh: Int?
        var flushTop5: [Int] = []
        for s in 0..<4 where suitCount[s] >= 5 {
            var suitedMask = 0
            for card in cards where card.suit.rawValue == s {
                suitedMask |= 1 << card.rank.rawValue
            }
            if let high = straightHigh(mask: suitedMask) {
                flushStraightHigh = high
            } else {
                var top: [Int] = []
                for r in stride(from: 14, through: 2, by: -1) where suitedMask & (1 << r) != 0 {
                    top.append(r)
                    if top.count == 5 { break }
                }
                flushTop5 = top
            }
        }
        if let high = flushStraightHigh {
            return .init(.straightFlush, [high])
        }

        var quadRank = 0
        for r in stride(from: 14, through: 2, by: -1) where rankCount[r] == 4 { quadRank = r; break }
        if quadRank > 0 {
            var kicker = 0
            for r in stride(from: 14, through: 2, by: -1) where r != quadRank && rankCount[r] > 0 {
                kicker = r; break
            }
            return .init(.fourOfAKind, [quadRank, kicker])
        }
        var tripRanks: [Int] = []
        var pairRanks: [Int] = []
        for r in stride(from: 14, through: 2, by: -1) {
            if rankCount[r] == 3 { tripRanks.append(r) }
            else if rankCount[r] == 2 { pairRanks.append(r) }
        }
        if let t = tripRanks.first {
            let pairForBoat = pairRanks.first ?? (tripRanks.count > 1 ? tripRanks[1] : nil)
            if let p = pairForBoat { return .init(.fullHouse, [t, p]) }
        }
        if !flushTop5.isEmpty { return .init(.flush, flushTop5) }
        if let high = straightHigh(mask: mask) {
            return .init(.straight, [high])
        }
        if let t = tripRanks.first {
            var kickers: [Int] = []
            for r in stride(from: 14, through: 2, by: -1) where r != t && rankCount[r] > 0 {
                kickers.append(r)
                if kickers.count == 2 { break }
            }
            return .init(.threeOfAKind, [t] + kickers)
        }
        if pairRanks.count >= 2 {
            var kicker = 0
            for r in stride(from: 14, through: 2, by: -1)
            where r != pairRanks[0] && r != pairRanks[1] && rankCount[r] > 0 { kicker = r; break }
            return .init(.twoPair, [pairRanks[0], pairRanks[1], kicker])
        }
        if let p = pairRanks.first {
            var kickers: [Int] = []
            for r in stride(from: 14, through: 2, by: -1) where r != p && rankCount[r] > 0 {
                kickers.append(r)
                if kickers.count == 3 { break }
            }
            return .init(.onePair, [p] + kickers)
        }
        var top: [Int] = []
        for r in stride(from: 14, through: 2, by: -1) where rankCount[r] > 0 {
            top.append(r)
            if top.count == 5 { break }
        }
        return .init(.highCard, top)
    }

    /// 位掩码顺子：A 可当 1（置 bit 1）。返回最高顺子顶张。
    static func straightHigh(mask: Int) -> Int? {
        var m = mask
        if m & (1 << 14) != 0 { m |= 1 << 1 }
        for high in stride(from: 14, through: 5, by: -1) {
            let window = 0b11111 << (high - 4)
            if m & window == window { return high }
        }
        return nil
    }
}
