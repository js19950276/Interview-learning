/// AI 对手接口。实现必须只依据自己座位的可见信息决策（不偷看他人底牌）。
public protocol PokerAI: Sendable {
    func decide(_ state: GameState, seat: Int) -> PlayerAction
}
