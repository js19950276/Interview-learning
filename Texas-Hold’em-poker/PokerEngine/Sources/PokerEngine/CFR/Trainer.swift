import Foundation

/// 外部采样 MCCFR（spec 阶段 2b §5）。单线程确定性：第 i 迭代 rng 独立播种。
public enum Trainer {
    public static let huConfig = GameConfig(playerCount: 2, startingStack: 20_000,
                                            format: .cash(sb: 10, bb: 20))

    public static func train(_ bp: inout Blueprint, iterations: UInt64, seed: UInt64,
                             from: UInt64 = 0,
                             onProgress: ((UInt64, Int) -> Void)? = nil) {
        for i in from..<(from + iterations) {
            var iterRng = SeededGenerator(seed: seed &* 0x9E37_79B9_7F4A_7C15 &+ i)
            let traverser = Int(i % 2)
            let handSeed = iterRng.next()
            let state = GameState.start(config: huConfig, seed: handSeed)
            _ = walk(state, bp: &bp, traverser: traverser, pi: 1.0, rng: &iterRng)
            bp.tickIteration()
            if let cb = onProgress, (i - from + 1) % 100_000 == 0 { cb(i + 1, bp.entries.count) }
        }
        if let cb = onProgress, iterations > 0, iterations % 100_000 != 0 {
            cb(from + iterations, bp.entries.count)
        }
    }

    /// 返回 traverser 的效用；π 为 traverser 自身到达概率。rng 全程穿线（无静态可变状态）：
    /// 训练方全分支按槽位顺序共用消费；对手采样顺序消费——同种子同迭代序列确定。
    private static func walk(_ state: GameState, bp: inout Blueprint,
                             traverser: Int, pi: Double,
                             rng: inout SeededGenerator) -> Double {
        if state.street == .handOver {
            return Double(state.players[traverser].stack - 20_000)
        }
        guard let actor = state.actorSeat else {
            return Double(state.players[traverser].stack - 20_000)
        }
        let legal = legalActions(state)
        let ladder = ladderActions(legal, state: state)
        let slots = Abstraction.slots(for: ladder, legal: legal)
        let key = Abstraction.infoKey(state, seat: actor)
        bp.seedRegret(key: key, slots: slots)
        let sigma = bp.currentStrategy(key: key, slots: slots)

        if actor == traverser {
            bp.addStrategy(key: key, slots: slots, probs: sigma, weight: pi)
            var utils: [Double] = []
            var nodeUtil = 0.0
            for (i, s) in slots.enumerated() {
                var child = state
                child.apply(s.action)
                let u = walk(child, bp: &bp, traverser: traverser, pi: pi * sigma[i], rng: &rng)
                utils.append(u)
                nodeUtil += sigma[i] * u
            }
            bp.addRegret(key: key, slots: slots, deltas: utils.map { $0 - nodeUtil })
            return nodeUtil
        } else {
            let r = sampleIndex(sigma, rng: &rng)
            var child = state
            child.apply(slots[r].action)
            return walk(child, bp: &bp, traverser: traverser, pi: pi, rng: &rng)
        }
    }

    static func sampleIndex(_ probs: [Double], rng: inout SeededGenerator) -> Int {
        let total = probs.reduce(0, +)
        let r = Double(rng.next() % 1_000_000) / 1_000_000 * total
        var acc = 0.0
        for (i, p) in probs.enumerated() {
            acc += p
            if r < acc { return i }
        }
        return probs.count - 1
    }
}
