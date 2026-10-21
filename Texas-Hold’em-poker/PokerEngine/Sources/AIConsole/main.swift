import Foundation
import PokerEngine

func makeAI(_ spec: String) -> (any PokerAI)? {
    let parts = spec.split(separator: ":")
    guard parts.count == 2 else { return nil }
    switch (String(parts[0]), String(parts[1])) {
    case ("heuristic", let g): return HeuristicAI(aggression: Double(g) ?? 0.5)
    case ("pimc", "easy"): return PIMCAI.easy
    case ("pimc", "normal"): return PIMCAI.normal
    case ("pimc", "hard"): return PIMCAI.hard
    default: return nil
    }
}

var args = Array(CommandLine.arguments.dropFirst())
// 顶层 var 隐式 MainActor 隔离（Swift 6），嵌套函数需显式标注才能读写。
@MainActor
func flag(_ name: String, default def: String) -> String {
    if let i = args.firstIndex(of: name), i + 1 < args.count {
        let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
    }
    return def
}

// 零参数调用必须默认进入 battle 分支（打印 usage），removeFirst() 对空数组会崩溃。
let sub = args.first ?? "battle"
if !args.isEmpty { args.removeFirst() }
let aSpec = flag("--a", default: "pimc:normal")
let bSpec = flag("--b", default: "heuristic:0.5")
let table = flag("--table", default: "hu") == "hu" ? BattleTable.headsUp : .sixMax
let hands = Int(flag("--hands", default: "1000")) ?? 1000
let seed = UInt64(flag("--seed", default: "42")) ?? 42
let concurrency = Int(flag("--concurrency",
                           default: String(ProcessInfo.processInfo.activeProcessorCount))) ?? 1

func ci95(_ xs: [Double]) -> Double {
    let n = xs.count
    let mean = xs.reduce(0, +) / Double(n)
    let v = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(1, n - 1))
    return 1.96 * v.squareRoot() / Double(n).squareRoot() * 100
}

switch sub {
case "battle":
    guard let a = makeAI(aSpec), let b = makeAI(bSpec) else {
        print("unknown ai spec (use heuristic:0.5 | pimc:easy|normal|hard)"); exit(2)
    }
    let t0 = Date()
    let outcomes = await runBattle(a: a, b: b, table: table, hands: hands,
                                   seedBase: seed, concurrency: concurrency)
    let elapsed = Date().timeIntervalSince(t0)
    let n = table.playerCount
    let aDeltas = outcomes.map { Double($0.seatDeltas[$0.handIndex % n]) / 20.0 }
    let bDeltas = outcomes.map { Double($0.seatDeltas[($0.handIndex % n + 1) % n]) / 20.0 }
    let aBB = aDeltas.reduce(0, +) / Double(hands) * 100
    let bBB = bDeltas.reduce(0, +) / Double(hands) * 100
    print("hands=\(hands) table=\(table == .headsUp ? "hu" : "six") seed=\(seed) concurrency=\(concurrency) elapsed=\(String(format: "%.1f", elapsed))s")
    print(String(format: "bb/100[%@]=%+.2f ±%.2f", aSpec, aBB, ci95(aDeltas)))
    print(String(format: "bb/100[%@]=%+.2f ±%.2f", bSpec, bBB, ci95(bDeltas)))
case "bench":
    // --ai 为 bench 的文档化入参（README/Task 7）；未提供时回落到 --a。
    guard let a = makeAI(flag("--ai", default: aSpec)) else { print("unknown ai"); exit(2) }
    // PIMC 自对战会在数手内打光 10000 筹码 → 现金局会话结束（tournamentOver），
    // 后续手循环空转。基准测试需要持续样本：会话结束即重开一桌（种子 = seed+h）。
    func freshTable(_ h: Int) -> GameState {
        GameState.start(config: GameConfig(playerCount: 2, startingStack: 10_000,
                                           format: .cash(sb: 10, bb: 20)),
                        seed: seed &+ UInt64(h))
    }
    var s = freshTable(0)
    var times: [Double] = []
    var sims = 0
    loop: for h in 0..<hands {
        if s.tournamentOver { s = freshTable(h) }
        while s.street != .handOver, let actor = s.actorSeat {
            if let p = a as? PIMCAI { sims += p.worlds * p.iterationsPerWorld }
            let t0 = DispatchTime.now()
            s.apply(a.decide(s, seat: actor))
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000)
            if times.count >= 400 { break loop }
        }
        s.nextHand()
    }
    times.sort()
    let mean = times.reduce(0, +) / Double(max(1, times.count))
    let p95 = times.isEmpty ? 0 : times[min(times.count - 1, Int(Double(times.count - 1) * 0.95))]
    let totalMs = times.reduce(0, +)
    print("decisions=\(times.count) mean=\(String(format: "%.1f", mean))ms p95=\(String(format: "%.1f", p95))ms totalSims=\(sims) sims/s=\(totalMs > 0 ? Int(Double(sims) / (totalMs / 1000)) : 0)")
default:
    print("usage: AIConsole battle|bench --a pimc:normal --b heuristic:0.5 --table hu|six --hands N --seed S --concurrency C (bench: --ai pimc:hard)")
}
