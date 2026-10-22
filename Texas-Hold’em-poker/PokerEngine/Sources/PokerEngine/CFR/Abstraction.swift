/// 蓝图信息抽象（spec 阶段 2b §4）：牌桶 × 纹理 × 序列 → UInt64 键；7 槽位动作映射。
/// `raiseMin` 为设计性死位：自「去最小加注档」修复起，多档加注位点不再由
/// `Abstraction.slots(for:legal:)` 填充（仅剩单档=全下的位点不经过该档）；
/// 保留枚举位以兼容既有表的 7 槽位下标布局。
public enum AbstractSlot: Int, CaseIterable, Codable, Sendable {
    case fold = 0, check, call, raiseMin, raiseHalf, raisePot, allIn
}

public enum Abstraction {
    // MARK: 翻前 169 规范桶（对子 0..12 / 同花 13..90 / 不同花 91..168）
    public static func preflopBucket(_ hole: [Card]) -> Int {
        let a = hole[0].rank.rawValue, b = hole[1].rank.rawValue
        let hi = max(a, b), lo = min(a, b)
        if hi == lo { return hi - 2 }
        // 非对子组合索引（78 个）：sum_{h=3}^{hi-1}(h-2) + (lo-2)
        let combo = (3..<hi).reduce(0) { $0 + ($1 - 2) } + (lo - 2)
        let suited = hole[0].suit == hole[1].suit
        return 13 + (suited ? 0 : 78) + combo
    }

    // MARK: 翻后强度 12 桶（类别为主 + 顶对细分）
    public static func strengthBucket(_ rank: HandRank, board: [Card]) -> Int {
        let boardMax = board.map { $0.rank.rawValue }.max() ?? 0
        let top = rank.tiebreakers.first ?? 0
        switch rank.category {
        case .highCard: return top >= 11 ? 1 : 0                       // J+ 高 vs 低高
        case .onePair: return top >= boardMax ? 4 : (top * 2 >= boardMax ? 3 : 2)  // 顶对+/中对/低对
        case .twoPair: return 5
        case .threeOfAKind: return 6
        case .straight: return 7
        case .flush: return 8
        case .fullHouse: return 9
        case .fourOfAKind: return 10
        case .straightFlush: return 11
        }
    }

    // MARK: 纹理 8 桶（配对 × 三同花 × 三连张）
    public static func textureBucket(_ board: [Card]) -> Int {
        guard board.count >= 3 else { return 0 }
        let rankCounts = Dictionary(board.map { ($0.rank.rawValue, 1) }, uniquingKeysWith: +)
        let paired = rankCounts.values.contains { $0 >= 2 }
        let suitCounts = Dictionary(grouping: board, by: \.suit).mapValues(\.count)
        let flush3 = (suitCounts.values.max() ?? 0) >= 3
        let ranks = Array(Set(board.map { $0.rank.rawValue })).sorted()
        var connected = false
        if ranks.count >= 3 {
            for i in 2..<ranks.count where ranks[i] == ranks[i - 1] + 1 && ranks[i - 1] == ranks[i - 2] + 1 {
                connected = true; break
            }
            if ranks.last == 14, ranks.contains(2), ranks.contains(3) { connected = true }  // A-2-3 轮子连张
        }
        return (paired ? 1 : 0) | (flush3 ? 2 : 0) | (connected ? 4 : 0)
    }

    // MARK: 序列桶 48（预裁决三元组：注池比 4 × 我方投入 3 × 下注规模 4）
    public static func sequenceBucket(_ state: GameState, seat: Int) -> Int {
        let p = state.players[seat]
        let pot = max(1, state.potTotal)
        let ratio: Int
        if state.currentBet == 0 { ratio = 0 }
        else if state.currentBet * 2 <= pot { ratio = 1 }
        else if state.currentBet <= pot { ratio = 2 }
        else { ratio = 3 }
        let mine: Int
        if p.streetContribution == 0 { mine = 0 }
        else if p.streetContribution < state.currentBet { mine = 1 }
        else { mine = 2 }
        let bet: Int
        if state.currentBet == 0 { bet = 0 }
        else if state.currentBet <= 40 { bet = 1 }        // ≤2bb
        else if state.currentBet <= 120 { bet = 2 }       // ≤6bb
        else { bet = 3 }
        return ((ratio * 3) + mine) * 4 + bet
    }

    // MARK: 信息键 street(2) | bucket(9) | seq(6)
    // 桶域 0..264（翻前 0..168；翻后 169 + 强度12×纹理8 = 169..264）需 9 位：
    // 8 位布局会让 桶 ≥256（四条/同花顺翻牌）溢出侵占 street 位造成键碰撞，故 street 移至 bit 15。
    public static func infoKey(_ state: GameState, seat: Int) -> UInt64 {
        let street: Int
        switch state.street { case .preflop: street = 0; case .flop: street = 1; case .turn: street = 2; default: street = 3 }
        let bucket: Int
        if state.street == .preflop {
            bucket = preflopBucket(state.players[seat].holeCards)
        } else {
            let rank = HandEvaluator.evaluate(state.players[seat].holeCards + state.board)
            bucket = 169 + strengthBucket(rank, board: state.board) * 8 + textureBucket(state.board)
        }
        let seq = sequenceBucket(state, seat: seat)
        return UInt64(street) << 15 | UInt64(bucket) << 6 | UInt64(seq)
    }

    public static func decodeKey(_ k: UInt64) -> (street: Int, bucket: Int, seq: Int) {
        (Int((k >> 15) & 0x3), Int((k >> 6) & 0x1FF), Int(k & 0x3F))
    }

    // MARK: 档位 → 槽位（求解器式下注抽象：≥2 加注档时丢弃最低（最小加注）档，
    // 保留档按位映射 [½池, 满池, 全下]——加注尺寸几何增长，加注战争深度有界。
    // ladderActions（冻结）仍是档位来源，本层只做抽象过滤，不重算档位。）
    // 全下判定优先于最小加注：单点区间（短码仅剩全下一档）首档即末档，须落 .allIn。
    public static func slots(for ladder: [PlayerAction], legal: LegalActions) -> [(action: PlayerAction, slot: AbstractSlot)] {
        var out: [(action: PlayerAction, slot: AbstractSlot)] = []
        let raiseTotal = ladder.filter { act in
            if case .bet = act { return true }
            if case .raiseTo = act { return true }
            return false
        }.count
        let dropMin = raiseTotal >= 2          // 多档位点丢弃最小加注档
        let kept = dropMin ? raiseTotal - 1 : raiseTotal
        var raiseCount = 0                     // ladder 内加注档原始序号
        for act in ladder {
            switch act {
            case .fold: out.append((act, .fold))
            case .check: out.append((act, .check))
            case .call: out.append((act, .call))
            case .bet, .raiseTo:
                if dropMin && raiseCount == 0 {
                    raiseCount += 1
                    continue   // 最小加注档：不映射任何槽位（.raiseMin 死位由设计产生）
                }
                let p = raiseCount - (dropMin ? 1 : 0)   // 保留档内位置
                let slot: AbstractSlot
                if p == kept - 1 { slot = .allIn }
                else if p == 0 { slot = .raiseHalf }
                else { slot = .raisePot }   // kept == 3 的中位档（满池）
                out.append((act, slot))
                raiseCount += 1
            }
        }
        return out
    }
}
