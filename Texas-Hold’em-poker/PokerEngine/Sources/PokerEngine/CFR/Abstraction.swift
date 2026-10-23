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

    // MARK: 序列桶 63（预裁决三元组：注池比 3 × 我方投入 3 × 池相对对数下注规模 7；< 64 保 6 位键域）
    // 池相对对数分档（诊断升级路径第 2 级）：旧 bet 档为绝对筹码 {≤2bb, ≤6bb, 无界 else}，
    // 翻后池盲（40 注入 2000 池与 40 池同档）、翻前 >6bb 无界——7bb 加注与 1000bb 全下同键
    // （seqprobe：加注至 140/1000/5000/20000 应答键逐字节相同），CFR 据此收敛出 jam-heavy 蓝图。
    // 新 betRel 以「下注前底池」(potTotal − currentBet，诊断公式 max(1,·)) 为基准的 ×2 对数梯：
    // {0 无下注, <0.5×, <1×, <2×, <4×, <8×, ≥8×}——控制裁决边界 {0.5,1,2,4} 全保留，
    // 顶端再补一档 8×（7bb 开池 = 7×池前落入 <8×，全下 ≥8×），使裁决自身的回归判据
    // 「7bb 加注 ≠ 1000bb 全下键」可满足；翻前 2-3bb 开池(<4×)/4-8bb 大开池(4-8×)/巨型全下(≥8×)分层。
    // 注：直接用 currentBet/potTotal 会使 <2×、<4×、≥4× 三档恒死（potTotal 含下注者已推入的
    // currentBet，恒有 currentBet ≤ potTotal——与下方 ratio 死档同一条证明）。
    public static func sequenceBucket(_ state: GameState, seat: Int) -> Int {
        let p = state.players[seat]
        // 池比 3 档（死档修复）：原 4 档的 ratio=3（currentBet > potTotal）不可达——
        // potTotal 含下注者已推入的 currentBet，恒有 currentBet ≤ potTotal（引擎验证成立）。
        let ratio: Int
        if state.currentBet == 0 { ratio = 0 }
        else if state.currentBet * 2 <= state.potTotal { ratio = 1 }
        else { ratio = 2 }
        let mine: Int
        if p.streetContribution == 0 { mine = 0 }
        else if p.streetContribution < state.currentBet { mine = 1 }
        else { mine = 2 }
        let potBefore = max(1, state.potTotal - state.currentBet)   // 下注前底池（响应者视角）
        let betRel: Int
        if state.currentBet == 0 { betRel = 0 }
        else if state.currentBet * 2 < potBefore { betRel = 1 }     // <0.5×池
        else if state.currentBet < potBefore { betRel = 2 }         // <1×池
        else if state.currentBet < potBefore * 2 { betRel = 3 }     // <2×池
        else if state.currentBet < potBefore * 4 { betRel = 4 }     // <4×池
        else if state.currentBet < potBefore * 8 { betRel = 5 }     // <8×池
        else { betRel = 6 }                                         // ≥8×池（巨型超额/全下域）
        return ((ratio * 3) + mine) * 7 + betRel
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
