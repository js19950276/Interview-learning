public struct LegalActions: Equatable, Sendable {
    public let seat: Int
    public let canCheck: Bool
    public let canCall: Bool
    public let callAmount: Int
    /// 可用的激进动作总额区间（bet=x 与 raiseTo=x 同为“本轮投入总额”）。nil = 不能下注/加注。
    public let betRange: ClosedRange<Int>?
    public let isRaiseContext: Bool   // 面对下注（true）还是无人下注（false），供 UI 标签
}

/// 当前行动者的合法动作。
public func legalActions(_ state: GameState) -> LegalActions {
    guard let seat = state.actorSeat,
          [.preflop, .flop, .turn, .river].contains(state.street)
    else {
        return LegalActions(seat: state.actorSeat ?? -1, canCheck: false, canCall: false,
                            callAmount: 0, betRange: nil, isRaiseContext: false)
    }
    let p = state.players[seat]
    let toCall = max(0, state.currentBet - p.streetContribution)
    let allInTotal = p.streetContribution + p.stack
    // 家规：已行动过且此后只发生不足额加注 → 不得再加注（spec §4.3）
    let mayAggress = !p.hasActed || state.lastAggressionFullRaise

    var range: ClosedRange<Int>? = nil
    if mayAggress && allInTotal > state.currentBet {
        // T5 评审裁决：下界统一为 currentBet + minRaiseIncrement（无人下注时 currentBet=0，自然 = 最小下注大盲；
        // 大盲 option 时 currentBet=盲注额，正确给出 2×盲注起）
        let fullRaiseTo = state.currentBet + state.minRaiseIncrement
        range = min(fullRaiseTo, allInTotal)...allInTotal
    }
    return LegalActions(seat: seat,
                        canCheck: toCall == 0,
                        canCall: toCall > 0,
                        callAmount: min(toCall, p.stack),
                        betRange: range,
                        isRaiseContext: toCall > 0)
}

public func isLegal(_ action: PlayerAction, in legal: LegalActions) -> Bool {
    switch action {
    case .fold: return true
    case .check: return legal.canCheck
    case .call: return legal.canCall
    case .bet(let x), .raiseTo(let x): return legal.betRange?.contains(x) ?? false
    }
}
