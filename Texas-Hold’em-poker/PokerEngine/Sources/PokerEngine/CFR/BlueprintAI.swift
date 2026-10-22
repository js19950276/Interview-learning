/// 蓝图查表 AI：平均策略采样；未命中键回退 PIMCAI.easy（spec 阶段 2b §6）。
public struct BlueprintAI: PokerAI {
    public let blueprint: Blueprint
    public var seedSalt: UInt64
    private let fallback = PIMCAI.easy

    public init(blueprint: Blueprint, seedSalt: UInt64 = 0) {
        self.blueprint = blueprint
        self.seedSalt = seedSalt
    }

    public func decide(_ state: GameState, seat: Int) -> PlayerAction {
        guard let actor = state.actorSeat, actor == seat else { return .fold }
        let legal = legalActions(state)
        let ladder = ladderActions(legal, state: state)
        let slots = Abstraction.slots(for: ladder, legal: legal)
        let key = Abstraction.infoKey(state, seat: seat)
        guard let probs = blueprint.averageStrategy(key: key, slots: slots), !probs.isEmpty else {
            return fallback.decide(state, seat: seat)
        }
        var rng = SeededGenerator(seed: state.seed &* 0x51ED_2701
                                    &+ UInt64(state.handNumber) &* 31
                                    &+ UInt64(truncatingIfNeeded: seat) &* 97
                                    &+ UInt64(state.actions.count) &* 7
                                    &+ seedSalt)
        let total = probs.reduce(0, +)
        let r = Double(rng.next() % 1_000_000) / 1_000_000 * total
        var acc = 0.0
        for (i, p) in probs.enumerated() {
            acc += p
            if r < acc { return slots[i].action }
        }
        return slots[slots.count - 1].action
    }
}
