import Foundation

/// 外部采样 MCCFR（spec 阶段 2b §5）。单线程确定性：第 i 迭代 rng 独立播种。
public enum Trainer {
    public static let huConfig = GameConfig(playerCount: 2, startingStack: 20_000,
                                            format: .cash(sb: 10, bb: 20))

    /// 训练 `iterations` 个迭代（区间 `[from, from + iterations)`）。
    ///
    /// 确定性语义：同 (seed, iterations, from, concurrency) → 结果逐字节相同。
    /// 注意：不同 concurrency 结果**结构性不同**（非仅浮点求和顺序）——worker 从全新表
    /// 开始，σ 读自有表，对手采样路径在 chunk 边界后与串行分叉（已实证：键集即不一致）。
    ///
    /// - Parameters:
    ///   - concurrency: `<= 1` 走串行路径（行为与历史版本逐字节一致）。`> 1` 时把
    ///     迭代区间切成 `concurrency` 个 contiguous 分片——k 号分片长
    ///     `iterations/concurrency + (k < iterations%concurrency ? 1 : 0)`，覆盖无遗漏
    ///     无重复——各 worker 在**独立大栈线程**中训练进自有全新 `Blueprint`（第 i
    ///     迭代 rng 只依赖 seed 与 i，迭代间 rng 独立，分片不改任何单迭代的播种），
    ///     再按 worker 序 0..k-1 确定性合并进 `bp`（见 `Blueprint.merge`；暖种随
    ///     worker 各自首访发生并被求和——已接受的确定性代价）。
    ///     实现偏差（实证强制）：裁定原要求 TaskGroup；协作池线程栈仅 ~512KB，实测
    ///     1000bb 深手 `walk` 递归溢出（SIGBUS/栈保护页命中），故改用显式 64MB 栈
    ///     的 Foundation Thread（串行路径一直运行在 8MB 主栈上，量级一致才安全）。
    ///   - onProgress: 并行路径结束时回调一次（总迭代数、合并后键数）；分片内部进度不外抛。
    public static func train(_ bp: inout Blueprint, iterations: UInt64, seed: UInt64,
                             from: UInt64 = 0,
                             concurrency: Int = 1,
                             onProgress: ((UInt64, Int) -> Void)? = nil) {
        guard concurrency > 1, iterations > 0 else {
            for i in from..<(from + iterations) {
                runIteration(&bp, seed: seed, i: i)
                if let cb = onProgress, (i - from + 1) % 100_000 == 0 { cb(i + 1, bp.entries.count) }
            }
            if let cb = onProgress, iterations > 0, iterations % 100_000 != 0 {
                cb(from + iterations, bp.entries.count)
            }
            return
        }

        // contiguous 分片：k 号分片 = [start, start+count)，尺寸尽量均等且确定。
        let workerCount = min(concurrency, Int(clamping: iterations))
        let quotient = iterations / UInt64(workerCount)
        let remainder = iterations % UInt64(workerCount)
        var chunks: [(start: UInt64, count: UInt64)] = []
        chunks.reserveCapacity(workerCount)
        var cursor = from
        for k in 0..<workerCount {
            let size = quotient + (UInt64(k) < remainder ? 1 : 0)
            chunks.append((start: cursor, count: size))
            cursor &+= size
        }

        // 每 worker 一条显式 64MB 栈线程（虚拟内存惰性提交，仅按需落页）：
        // 协作池线程栈 ~512KB，实测深手 walk 递归命中栈保护页（SIGBUS，崩溃报告
        // "Could not determine thread index for stack guard region"）——TaskGroup 方案被实证否决。
        // worker 表全新开始：暖种在各 worker 首访时各自发生，合并连同种子一起求和。
        // 各 worker 只写自有 BlueprintBox（互不相交），DispatchGroup.wait 汇合——无共享可变状态。
        let boxes = chunks.map { _ in BlueprintBox() }
        let group = DispatchGroup()
        for (k, chunk) in chunks.enumerated() {
            group.enter()
            let box = boxes[k]
            let thread = Thread {
                var worker = Blueprint()
                for i in chunk.start..<(chunk.start + chunk.count) {
                    runIteration(&worker, seed: seed, i: i)
                }
                box.store(worker)
                group.leave()
            }
            thread.stackSize = 64 * 1024 * 1024
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        group.wait()

        // 按 worker 序 0..k-1 合并：跨表浮点累加顺序固定 → 逐字节可复现。
        for box in boxes { bp.merge(box.load()) }
        if let cb = onProgress { cb(from + iterations, bp.entries.count) }
    }

    /// 单迭代（训练方全分支 / 对手采样）。rng 只依赖 (seed, i)：串行与分片 worker 共用同一段走查。
    private static func runIteration(_ bp: inout Blueprint, seed: UInt64, i: UInt64) {
        var iterRng = SeededGenerator(seed: seed &* 0x9E37_79B9_7F4A_7C15 &+ i)
        let traverser = Int(i % 2)
        let handSeed = iterRng.next()
        let state = GameState.start(config: huConfig, seed: handSeed)
        _ = walk(state, bp: &bp, traverser: traverser, pi: 1.0, rng: &iterRng)
        bp.tickIteration()
    }

    /// 返回 traverser 的效用；π 为 traverser 自身到达概率。rng 全程穿线（无静态可变状态）：
    /// 训练方全分支按槽位顺序共用消费；对手采样顺序消费——同种子同迭代序列确定。
    private static func walk(_ state: GameState, bp: inout Blueprint,
                             traverser: Int, pi: Double,
                             rng: inout SeededGenerator) -> Double {
        // 终局效用基线派生自配置（原硬编码 20_000 与 huConfig.startingStack 隐式耦合）
        let baseStack = Double(huConfig.startingStack)
        if state.street == .handOver {
            return Double(state.players[traverser].stack) - baseStack
        }
        guard let actor = state.actorSeat else {
            return Double(state.players[traverser].stack) - baseStack
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

/// worker 线程 → 调用线程的单表转移盒子：store 一次（worker 线程）→ group.wait 汇合后
/// load（调用线程，按序）。NSLock 保证 happens-before；@unchecked Sendable 仅限该 set-once 使用点。
private final class BlueprintBox: @unchecked Sendable {
    private let lock = NSLock()
    private var table: Blueprint?
    func store(_ t: Blueprint) { lock.lock(); table = t; lock.unlock() }
    func load() -> Blueprint { lock.lock(); defer { lock.unlock() }; return table! }
}
