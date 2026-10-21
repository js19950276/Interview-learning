/// 一手牌的完整重建材料：起点 + 种子 + 动作序列。record 是调用时刻的快照。
public struct HandHistory: Equatable, Sendable, Codable {
    public let seed: UInt64
    public let config: GameConfig
    public let initialStacks: [Int]
    public let buttonSeat: Int
    public let handNumber: Int
    public let actions: [SeatAction]

    public init(seed: UInt64, config: GameConfig, initialStacks: [Int],
                buttonSeat: Int, handNumber: Int, actions: [SeatAction]) {
        self.seed = seed; self.config = config; self.initialStacks = initialStacks
        self.buttonSeat = buttonSeat; self.handNumber = handNumber; self.actions = actions
    }

    public static func record(from state: GameState) -> HandHistory {
        HandHistory(seed: state.seed, config: state.config,
                    initialStacks: state.players.map(\.stackAtHandStart),
                    buttonSeat: state.buttonSeat, handNumber: state.handNumber,
                    actions: state.actions)
    }

    /// 重建：同起点同种子，逐个 apply 已记录动作（到记录时刻）。
    public static func replay(_ h: HandHistory) -> GameState {
        var s = GameState.start(config: h.config, seed: h.seed,
                                stacks: h.initialStacks, buttonSeat: h.buttonSeat,
                                handNumber: h.handNumber)
        for sa in h.actions { s.apply(sa.action) }
        return s
    }
}
