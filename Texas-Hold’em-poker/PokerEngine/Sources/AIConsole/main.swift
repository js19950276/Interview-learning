import Foundation
import PokerEngine

// blueprint:hu 的默认加载路径（battle/bench 共用；--blueprint 可覆盖）。
var blueprintPath = "blueprint-hu.json"

@MainActor
func makeAI(_ spec: String) -> (any PokerAI)? {
    let parts = spec.split(separator: ":")
    guard parts.count == 2 else { return nil }
    switch (String(parts[0]), String(parts[1])) {
    case ("heuristic", let g):
        guard let agg = Double(g) else { return nil }
        return HeuristicAI(aggression: agg)
    case ("pimc", "easy"): return PIMCAI.easy
    case ("pimc", "normal"): return PIMCAI.normal
    case ("pimc", "hard"): return PIMCAI.hard
    case ("pimc", "hell"): return PIMCAI.hell
    case ("blueprint", _):
        do {
            let bp = try Blueprint.load(from: URL(fileURLWithPath: blueprintPath))
            return BlueprintAI(blueprint: bp)
        } catch {
            print("blueprint load failed: \(blueprintPath) (\(error))")
            exit(2)
        }
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

// 零参数默认进入 battle（默认参数集）。
let sub = args.first ?? "battle"
if !args.isEmpty { args.removeFirst() }
let aSpec = flag("--a", default: "pimc:normal")
let bSpec = flag("--b", default: "heuristic:0.5")
let table = flag("--table", default: "hu") == "hu" ? BattleTable.headsUp : .sixMax
let hands = Int(flag("--hands", default: "1000")) ?? 1000
let seed = UInt64(flag("--seed", default: "42")) ?? 42
let concurrency = Int(flag("--concurrency",
                           default: String(ProcessInfo.processInfo.activeProcessorCount))) ?? 1
blueprintPath = flag("--blueprint", default: blueprintPath)

func ci95(_ xs: [Double]) -> Double {
    let n = xs.count
    let mean = xs.reduce(0, +) / Double(n)
    let v = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(1, n - 1))
    return 1.96 * v.squareRoot() / Double(n).squareRoot() * 100
}

switch sub {
case "battle":
    guard let a = makeAI(aSpec), let b = makeAI(bSpec) else {
        print("unknown ai spec (use heuristic:0.5 | pimc:easy|normal|hard|hell | blueprint:hu)"); exit(2)
    }
    let t0 = Date()
    let outcomes = await runBattle(a: a, b: b, table: table, hands: hands,
                                   seedBase: seed, concurrency: concurrency)
    let elapsed = Date().timeIntervalSince(t0)
    let aDeltas = sideMeanDeltas(outcomes, forA: true).map { $0 / 20.0 }
    let bDeltas = sideMeanDeltas(outcomes, forA: false).map { $0 / 20.0 }
    let aBB = aDeltas.reduce(0, +) / Double(hands) * 100
    let bBB = bDeltas.reduce(0, +) / Double(hands) * 100
    print("hands=\(hands) table=\(table == .headsUp ? "hu" : "six") seed=\(seed) concurrency=\(concurrency) elapsed=\(String(format: "%.1f", elapsed))s")
    print(String(format: "bb/100[%@]=%+.2f ±%.2f", aSpec, aBB, ci95(aDeltas)))
    print(String(format: "bb/100[%@]=%+.2f ±%.2f", bSpec, bBB, ci95(bDeltas)))
case "bench":
    // --ai 为 bench 的文档化入参（README/Task 7）；未提供时回落到 --a。
    guard let a = makeAI(flag("--ai", default: aSpec)) else { print("unknown ai"); exit(2) }
    // PIMC 自对战会在数手内打光 20000 筹码 → 现金局会话结束（tournamentOver），
    // 后续手循环空转。基准测试需要持续样本：会话结束即重开一桌（种子 = seed+h）。
    func freshTable(_ h: Int) -> GameState {
        GameState.start(config: GameConfig(playerCount: 2, startingStack: 20_000,
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
case "train":
    // 分段训练：每段长 --checkpoint-every，段界即 checkpoint 点。Trainer 并行路径的
    // onProgress 只在整段结束时回调一次——若做单次全长调用，满核模式下要到全部跑完才
    // 落盘，进程中断则一无所获；分段让任意 concurrency 下中断后都有最近 checkpoint 可
    // --resume（串行分段与单次全长调用逐字节一致；并行分段仍对同参数逐字节确定）。
    let trainIters = UInt64(flag("--iterations", default: "0")) ?? 0
    guard trainIters > 0 else { print("train: --iterations N (>0) required"); exit(2) }
    let fromFlag = UInt64(flag("--from", default: "0")) ?? 0
    let checkpointEvery = UInt64(flag("--checkpoint-every", default: "1000000")) ?? 1_000_000
    guard checkpointEvery > 0 else { print("train: --checkpoint-every must be > 0"); exit(2) }
    let outPath = flag("--out", default: "")
    let resumePath = flag("--resume", default: "")
    var bp = Blueprint()
    var from = fromFlag
    if !resumePath.isEmpty {
        do { bp = try Blueprint.load(from: URL(fileURLWithPath: resumePath)) }
        catch { print("train: --resume load failed: \(resumePath) (\(error))"); exit(2) }
        // 续训：迭代计数从 checkpoint 文件继续（显式更大的 --from 仍可跳段，保持确定性）。
        from = max(from, bp.iterations)
        print("resumed iterations=\(bp.iterations) keys=\(bp.entries.count) from=\(resumePath)")
    }
    let outURL = outPath.isEmpty ? nil : URL(fileURLWithPath: outPath)
    var done: UInt64 = 0
    while done < trainIters {
        let seg = min(checkpointEvery, trainIters - done)
        Trainer.train(&bp, iterations: seg, seed: seed, from: from + done, concurrency: concurrency) { iter, keys in
            print("iter=\(iter) keys=\(keys)")
        }
        done += seg
        // checkpoint 失败不中断训练（后续段仍可能成功落盘），但必须可见而非静默吞掉。
        if let url = outURL {
            do { try bp.save(to: url) } catch { print("checkpoint save failed: \(error)") }
        }
    }
    var sizeText = "n/a"
    if let url = outURL,
       let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
       let size = attrs[.size] as? NSNumber {
        sizeText = "\(size.int64Value)B"
    }
    print("summary iterations=\(bp.iterations) keys=\(bp.entries.count) out=\(outPath.isEmpty ? "(none)" : outPath) size=\(sizeText)")
default:
    print("usage: AIConsole battle|train|bench --a pimc:normal|blueprint:hu --b heuristic:0.5 --table hu|six --hands N --seed S --concurrency C --blueprint path (train: --iterations N [--from N] [--checkpoint-every N] --out path [--resume path]) (bench: --ai pimc:hard|hell)")
}
