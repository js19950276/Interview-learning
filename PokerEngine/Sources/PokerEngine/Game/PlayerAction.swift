/// 玩家行动。bet 与 raiseTo 在引擎内部统一按“本轮投入总额”解释（见 Reducer）。
public enum PlayerAction: Equatable, Sendable, Codable {
    case fold
    case check
    case call
    case bet(Int)
    case raiseTo(Int)
}

public struct SeatAction: Equatable, Sendable, Codable {
    public let seat: Int
    public let action: PlayerAction
    public init(seat: Int, action: PlayerAction) { self.seat = seat; self.action = action }
}
