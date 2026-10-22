import Foundation

public enum BlueprintError: Error, Equatable {
    case versionMismatch(Int)
    case corrupted
}

/// MCCFR 蓝图策略表：信息键 → 7 槽位的遗憾与平均策略累计。
/// Equatable（T3 编译强制）：Trainer 确定性测试需 XCTAssertEqual 逐字节比对两表。
public struct Blueprint: Codable, Sendable, Equatable {
    public let ladderVersion: Int
    public private(set) var iterations: UInt64
    public private(set) var entries: [UInt64: Entry]
    public static let supportedLadderVersion = 2

    public init(ladderVersion: Int = Blueprint.supportedLadderVersion,
                iterations: UInt64 = 0, entries: [UInt64: Entry] = [:]) {
        self.ladderVersion = ladderVersion
        self.iterations = iterations
        self.entries = entries
    }

    public mutating func tickIteration() { iterations &+= 1 }

    /// 分片并行合并（Trainer concurrency > 1）：条目逐键元素求和（regret / strategySum），
    /// 迭代数累加。只存在于部分 worker 的键不会被丢弃（缺失侧按 0 累加）。
    /// 确定性由调用方保证：必须按 worker 序（0..k-1）顺序合并——同 (seed, iterations,
    /// from, concurrency) 逐字节确定；不同 concurrency 的差异是结构性的（worker 从全新
    /// 表开始，采样路径分叉），非仅浮点求和顺序。
    /// 注意：worker 表各自全新开始，首访暖种在每个访问到该键的 worker 各发生一次，
    /// 合并会把种子也累加（键被 k 个 worker 访问 → k× 种子）——已接受的确定性代价。
    public mutating func merge(_ other: Blueprint) {
        for (key, e) in other.entries {
            var acc = entries[key] ?? Entry()
            for i in e.regret.indices { acc.regret[i] += e.regret[i] }
            for i in e.strategySum.indices { acc.strategySum[i] += e.strategySum[i] }
            entries[key] = acc
        }
        iterations &+= other.iterations
    }

    public mutating func addRegret(key: UInt64, slots: [(action: PlayerAction, slot: AbstractSlot)], deltas: [Double]) {
        var e = entries[key] ?? Entry()
        for (i, s) in slots.enumerated() { e.regret[s.slot.rawValue] += deltas[i] }
        entries[key] = e
    }

    /// 首访暖种（训练吞吐修复）：被动槽 +1.0、加注槽 +0.25 的正遗憾种子。
    /// CFR 后悔更新会主导后续收敛；仅由训练器在键首次出现时调用。
    public mutating func seedRegret(key: UInt64, slots: [(action: PlayerAction, slot: AbstractSlot)]) {
        guard entries[key] == nil else { return }
        var e = Entry()
        for s in slots {
            switch s.slot {
            case .fold, .check, .call: e.regret[s.slot.rawValue] = 1.0
            case .raiseMin, .raiseHalf, .raisePot, .allIn: e.regret[s.slot.rawValue] = 0.25
            }
        }
        entries[key] = e
    }

    public mutating func addStrategy(key: UInt64, slots: [(action: PlayerAction, slot: AbstractSlot)],
                                     probs: [Double], weight: Double) {
        var e = entries[key] ?? Entry()
        for (i, s) in slots.enumerated() { e.strategySum[s.slot.rawValue] += weight * probs[i] }
        entries[key] = e
    }

    /// 遗憾匹配（仅对给定槽位；全非正 → 均匀）。返回与 slots 对齐的概率数组。
    public func currentStrategy(key: UInt64, slots: [(action: PlayerAction, slot: AbstractSlot)]) -> [Double] {
        let e = entries[key]
        let positives = slots.map { max(0, e?.regret[$0.slot.rawValue] ?? 0) }
        let total = positives.reduce(0, +)
        if total <= 0 { return [Double](repeating: 1.0 / Double(slots.count), count: slots.count) }
        return positives.map { $0 / total }
    }

    /// 平均策略（与 slots 对齐）；无记录或零和 → nil。
    public func averageStrategy(key: UInt64, slots: [(action: PlayerAction, slot: AbstractSlot)]) -> [Double]? {
        guard let e = entries[key] else { return nil }
        let sums = slots.map { e.strategySum[$0.slot.rawValue] }
        let total = sums.reduce(0, +)
        guard total > 0 else { return nil }
        return sums.map { $0 / total }
    }

    public func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url)
    }

    public static func load(from url: URL) throws -> Blueprint {
        let data: Data
        let bp: Blueprint
        do {
            data = try Data(contentsOf: url)
            bp = try JSONDecoder().decode(Blueprint.self, from: data)
        } catch { throw BlueprintError.corrupted }
        guard bp.ladderVersion == supportedLadderVersion else {
            throw BlueprintError.versionMismatch(bp.ladderVersion)
        }
        return bp
    }
}

public struct Entry: Codable, Sendable, Equatable {
    public var regret: [Double]
    public var strategySum: [Double]
    init() {
        regret = [Double](repeating: 0, count: AbstractSlot.allCases.count)
        strategySum = [Double](repeating: 0, count: AbstractSlot.allCases.count)
    }
    public init(regret: [Double], strategySum: [Double]) {
        self.regret = regret; self.strategySum = strategySum
    }
}
