import Foundation

public struct HandOutcome: Equatable, Sendable {
    public let handIndex: Int
    public let seatDeltas: [Int]
    public init(handIndex: Int, seatDeltas: [Int]) {
        self.handIndex = handIndex; self.seatDeltas = seatDeltas
    }
}

public struct BattleReport: Equatable, Sendable {
    public let hands: Int
    public let perSeatBB100: [Double]
    public let perSeatCI: [Double]
}

public enum BattleTable: Sendable {
    case headsUp, sixMax
    public var playerCount: Int { self == .headsUp ? 2 : 6 }
}

/// 无头对战（spec §5）：每手独立重置（现金局 1000bb＝20000 筹码、盲注 10/20，spec §1）。
/// 手 i 的种子 = seedBase &+ UInt64(i)，与执行顺序无关；并发用 TaskGroup 分段
/// （每段只写自己的区间，协调者按原下标归位——结果与 concurrency 值无关）。
/// a 的起始席位 = handIndex % n 轮转：headsUp 即偶数手 seat0、奇数手 seat1。
public func runBattle(a: any PokerAI, b: any PokerAI, table: BattleTable,
                      hands: Int, seedBase: UInt64, concurrency: Int) async -> [HandOutcome] {
    precondition(hands > 0 && concurrency > 0)
    var results = [HandOutcome?](repeating: nil, count: hands)
    let chunk = max(1, (hands + concurrency - 1) / concurrency)
    await withTaskGroup(of: [HandOutcome].self) { group in
        var lo = 0
        while lo < hands {
            let hi = min(hands, lo + chunk)
            // Swift 6 区域隔离：闭包不得捕获循环中可变的 lo——先物化为不可变区间再进 child task。
            let range = lo..<hi
            group.addTask {
                range.map { playOneHand(a: a, b: b, table: table, handIndex: $0, seedBase: seedBase) }
            }
            lo = hi
        }
        for await slice in group {
            for o in slice { results[o.handIndex] = o }
        }
    }
    return results.map { $0! }
}

func playOneHand(a: any PokerAI, b: any PokerAI, table: BattleTable,
                 handIndex: Int, seedBase: UInt64) -> HandOutcome {
    let n = table.playerCount
    let rotate = handIndex % n
    var s = GameState.start(config: GameConfig(playerCount: n, startingStack: 20_000,   // 1000bb（bb=20）
                                               format: .cash(sb: 10, bb: 20)),
                            seed: seedBase &+ UInt64(truncatingIfNeeded: handIndex),
                            stacks: Array(repeating: 20_000, count: n),
                            buttonSeat: (handIndex / n) % n)
    var counter = 0
    while s.street != .handOver, let actor = s.actorSeat, counter < 500 {
        let ai = ((actor - rotate + n) % n) % 2 == 0 ? a : b
        s.apply(ai.decide(s, seat: actor))
        counter += 1
    }
    assert(s.street == .handOver, "battle hand did not terminate (action cap?)")
    return HandOutcome(handIndex: handIndex,
                       seatDeltas: (0..<n).map { s.players[$0].stack - 20_000 })
}

/// 按方聚合：a 方 = 各手中 rotate 偶数偏移席位的均值，b 方 = 奇数偏移席位的均值（rotate = handIndex % n）。
/// headsUp 时等价于原单席聚合；六人桌用满每方 3 席，a/b 互为相反数（零和镜像）。
public func sideMeanDeltas(_ outcomes: [HandOutcome], forA: Bool) -> [Double] {
    outcomes.map { o -> Double in
        let n = o.seatDeltas.count
        let rotate = o.handIndex % n
        let seats = (0..<n).filter { ((($0 - rotate + n) % n) % 2 == 0) == forA }
        let sum = seats.reduce(0) { $0 + o.seatDeltas[$1] }
        return Double(sum) / Double(seats.count)
    }
}

/// per-seat bb/100 ± 95% CI（正态近似；bb = 大盲 20）。
public func summarizeBattle(_ outcomes: [HandOutcome]) -> BattleReport {
    precondition(!outcomes.isEmpty)
    let n = outcomes.count
    let seats = outcomes[0].seatDeltas.count
    var bb100: [Double] = []
    var ci: [Double] = []
    for seat in 0..<seats {
        let deltas = outcomes.map { Double($0.seatDeltas[seat]) / 20.0 }
        let mean = deltas.reduce(0, +) / Double(n)
        let variance = deltas.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(1, n - 1))
        bb100.append(mean * 100)
        ci.append(1.96 * variance.squareRoot() / Double(n).squareRoot() * 100)
    }
    return BattleReport(hands: n, perSeatBB100: bb100, perSeatCI: ci)
}
