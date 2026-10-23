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
        // 与 Trainer 走查共用同一采样例程（同 %-1e6 算术，诊断已验证两实现逐行等价）。
        let idx = Trainer.sampleIndex(probs, rng: &rng)
        return slots[idx].action
    }
}
