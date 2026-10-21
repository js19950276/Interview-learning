/// 一档盲注等级：小盲/大盲/持续手数。
public struct BlindLevel: Equatable, Sendable, Codable {
    public let sb: Int, bb: Int, hands: Int
    public init(sb: Int, bb: Int, hands: Int) { self.sb = sb; self.bb = bb; self.hands = hands }
}

/// 单桌锦标赛配置。payouts 为名次比例（降序，总和 1）。
public struct SNGConfig: Equatable, Sendable, Codable {
    public var buyIn: Int
    public var startingStack: Int
    public var levels: [BlindLevel]
    public var payouts: [Double]

    public init(buyIn: Int, startingStack: Int, levels: [BlindLevel], payouts: [Double]) {
        self.buyIn = buyIn; self.startingStack = startingStack
        self.levels = levels; self.payouts = payouts
    }

    /// 结构校验：等级非空且合法；比例非空、总和为 1（容差 1e-9）、降序。
    public static func validated(_ c: SNGConfig) -> SNGConfig {
        precondition(!c.levels.isEmpty)
        precondition(c.levels.allSatisfy { $0.sb > 0 && $0.bb >= $0.sb && $0.hands > 0 })
        precondition(!c.payouts.isEmpty && abs(c.payouts.reduce(0, +) - 1) < 1e-9)
        precondition(zip(c.payouts, c.payouts.dropFirst()).allSatisfy { $0.0 >= $0.1 })
        return c
    }
}

/// 对局形式：现金局（固定盲注）或 SNG。
public enum GameFormat: Equatable, Sendable, Codable {
    case cash(sb: Int, bb: Int)
    case sng(SNGConfig)
}

public struct GameConfig: Equatable, Sendable, Codable {
    public var playerCount: Int      // 2...9
    public var startingStack: Int    // 现金局初始筹码
    public var format: GameFormat
    public var humanSeat: Int        // 单机人类座位，其余为 AI

    public init(playerCount: Int, startingStack: Int, format: GameFormat, humanSeat: Int = 0) {
        self.playerCount = playerCount; self.startingStack = startingStack
        self.format = format; self.humanSeat = humanSeat
    }

    /// 开局每人筹码：现金局用 startingStack，SNG 用 sng.startingStack。
    public var effectiveStack: Int {
        switch format {
        case .cash: return startingStack
        case .sng(let s): return s.startingStack
        }
    }
}

/// 按手号查当前盲注。SNG 按等级表累加推进，超出表尾沿用最后一档。
public func currentBlinds(for format: GameFormat, handNumber: Int) -> (sb: Int, bb: Int) {
    switch format {
    case .cash(let sb, let bb): return (sb, bb)
    case .sng(let cfg):
        var remaining = handNumber
        for level in cfg.levels {
            if remaining < level.hands { return (level.sb, level.bb) }
            remaining -= level.hands
        }
        let last = cfg.levels.last!
        return (last.sb, last.bb)
    }
}
