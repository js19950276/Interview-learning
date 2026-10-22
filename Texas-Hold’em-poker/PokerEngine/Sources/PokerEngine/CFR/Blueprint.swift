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
    public static let supportedLadderVersion = 1

    public init(ladderVersion: Int = Blueprint.supportedLadderVersion,
                iterations: UInt64 = 0, entries: [UInt64: Entry] = [:]) {
        self.ladderVersion = ladderVersion
        self.iterations = iterations
        self.entries = entries
    }

    public mutating func tickIteration() { iterations &+= 1 }

    public mutating func addRegret(key: UInt64, slots: [(action: PlayerAction, slot: AbstractSlot)], deltas: [Double]) {
        var e = entries[key] ?? Entry()
        for (i, s) in slots.enumerated() { e.regret[s.slot.rawValue] += deltas[i] }
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
