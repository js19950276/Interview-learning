import Foundation

#if DEBUG
/// 种子随机数发生器:同一种子产生同一决策序列,失败可复现。
nonisolated struct SplitMix64: RandomNumberGenerator, Equatable, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// 双模拟器自动对局的机器人决策。
/// 全部选择走种子随机(输入先排序保证确定性),同局种子可完整复现;
/// 兜底永远选 pass,保证对局必然推进到终局。
nonisolated struct ScriptHarnessBot: Sendable {
    struct ActionPick: Equatable, Sendable {
        let cardID: String
        let action: GameCore.ActionKind
    }

    private var rng: SplitMix64

    init(seed: UInt64) {
        rng = SplitMix64(seed: seed)
    }

    /// 默认种子:房间号的 FNV-1a 哈希,同一房间对局路径固定,便于回归。
    static func defaultSeed(roomID: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in roomID.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return hash
    }

    /// 解析启动参数 `-local-harness-seed <uint64>`;供脚本换种子探索不同对局。
    static func seed(from arguments: [String]) -> UInt64? {
        guard let index = arguments.firstIndex(of: "-local-harness-seed"),
              arguments.indices.contains(index + 1),
              let seed = UInt64(arguments[index + 1]) else { return nil }
        return seed
    }

    /// 从"每张牌可用动作"里随机挑一个(卡,动作)组合。
    /// 排除 pass(留作兜底)与 forcedSale(不属于主动回合动作);无可选组合时返回 nil。
    mutating func pickAction(byCardID: [String: [GameCore.ActionKind]]) -> ActionPick? {
        let pairs = byCardID
            .flatMap { cardID, kinds in
                kinds
                    .filter { $0 != .pass && $0 != .forcedSale }
                    .map { ActionPick(cardID: cardID, action: $0) }
            }
            .sorted { ($0.cardID, $0.action.rawValue) < ($1.cardID, $1.action.rawValue) }
        return pairs.randomElement(using: &rng)
    }

    /// 兜底 pass:从快照的 trivialOptions 里随机挑一张可弃的牌。
    mutating func pickPassCard(_ options: [GameCore.ActionOption]) -> String? {
        let cardIDs = options
            .filter { $0.action == .pass }
            .compactMap(\.cardIDs.first)
            .sorted()
        return cardIDs.randomElement(using: &rng)
    }

    /// 合法动作多步流中随机挑下一步选择;空列表返回 nil(走不通,由调用方换路)。
    mutating func pickChoice(_ choices: [GameCore.LegalChoice]) -> GameCore.LegalChoice? {
        choices.randomElement(using: &rng)
    }
}
#endif
