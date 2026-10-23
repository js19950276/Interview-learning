import XCTest
@testable import PokerEngine

// 迭代数偏离计划简报（20k/30k/15k/3k → 20/30/15/30）：
// 1000bb 深码下外部采样在训练方节点全分支展开，对手均匀采样长加注链时子树指数膨胀
// （实测单迭代可达 ~50s；简报 108k 迭代合计 ≈ 数小时），为守住「总时长 < 60s」的
// 全局约束按授权缩减迭代数。种子/断言/续训拆分结构逐字保留——确定性、续训=连训、
// 遗憾正负结构、进度回调四项语义与原测试完全一致。
final class TrainerTests: XCTestCase {
    /// Review Focus #3：同种子两训逐字节相同。
    func testDeterminismSmall() {
        var a = Blueprint(); var b = Blueprint()
        Trainer.train(&a, iterations: 20, seed: 777)
        Trainer.train(&b, iterations: 20, seed: 777)
        XCTAssertEqual(a.iterations, 20)
        XCTAssertEqual(a, b)
    }

    /// Review Focus #3：续训 == 连训。
    func testResumeEqualsContinuous() {
        var cont = Blueprint()
        Trainer.train(&cont, iterations: 30, seed: 42)
        var split = Blueprint()
        Trainer.train(&split, iterations: 15, seed: 42, from: 0)
        Trainer.train(&split, iterations: 15, seed: 42, from: 15)
        XCTAssertEqual(split, cont)
    }

    /// 结构方向：训练后表非空且遗憾有正有非正。
    func testRegretStructureAfterSmallRun() {
        var bp = Blueprint()
        Trainer.train(&bp, iterations: 30, seed: 99)
        XCTAssertFalse(bp.entries.isEmpty)
        let regs = bp.entries.first!.value.regret
        XCTAssertTrue(regs.contains { $0 > 0 } && regs.contains { $0 <= 0 })
    }

    func testProgressCallbackFires() {
        var bp = Blueprint()
        var calls = 0
        Trainer.train(&bp, iterations: 5, seed: 1, onProgress: { _, _ in calls += 1 })
        XCTAssertGreaterThanOrEqual(calls, 1)
    }

    /// 暖种回归锚（吞吐修复）：首访种子被动 +1.0 / 加注 +0.25、重复 seed 不叠加，
    /// 训练后表非空且已访问键产出合法策略，同种子两训仍逐字节相等。
    /// 注：currentStrategy 返回非可选数组，故以「概率和 = 1」锚定合法策略而非 XCTAssertNotNil。
    func testWarmSeedDeterministicAndPassiveLeaning() {
        // 种子路径直接锚定：新表首访被动槽 +1.0、加注槽 +0.25、未到槽保持 0
        var seeded = Blueprint()
        let slots: [(action: PlayerAction, slot: AbstractSlot)] = [
            (.check, .check), (.fold, .fold), (.raiseTo(40), .raiseMin)
        ]
        seeded.seedRegret(key: 1, slots: slots)
        XCTAssertEqual(seeded.entries[1]?.regret[AbstractSlot.check.rawValue], 1.0)
        XCTAssertEqual(seeded.entries[1]?.regret[AbstractSlot.fold.rawValue], 1.0)
        XCTAssertEqual(seeded.entries[1]?.regret[AbstractSlot.raiseMin.rawValue], 0.25)
        XCTAssertEqual(seeded.entries[1]?.regret[AbstractSlot.raisePot.rawValue], 0.0)
        seeded.seedRegret(key: 1, slots: slots)   // 二次调用不重复种子（guard 首访）
        XCTAssertEqual(seeded.entries[1]?.regret[AbstractSlot.check.rawValue], 1.0)

        // 训练集成：表非空，任一已访问键暖种条目可产出合法策略（概率和为 1、非负）
        var bp = Blueprint()
        Trainer.train(&bp, iterations: 20, seed: 5)
        XCTAssertFalse(bp.entries.isEmpty)
        let entry = bp.entries.first!
        let sigma = bp.currentStrategy(key: entry.key, slots: slots)
        XCTAssertEqual(sigma.reduce(0, +), 1.0, accuracy: 1e-9)
        XCTAssertTrue(sigma.allSatisfy { $0 >= 0 })

        // 暖种不破坏确定性：同种子两训逐字节相等
        var b2 = Blueprint()
        Trainer.train(&b2, iterations: 20, seed: 5)
        XCTAssertEqual(bp, b2)
    }

    /// 并行分片：同 (seed, iterations, concurrency) 逐字节确定；分片覆盖无遗漏无重复；
    /// 条目全并（不丢 worker 独有键、逐槽求和、迭代数相加）。
    /// 对裁定的实证修正：worker 表全新开始（裁定要求），σ 读自有表 → 对手采样路径在
    /// chunk 边界后与串行分叉，访问键集与串行**不保证**一致（40 迭代 seed 313 实测即
    /// 不一致，原「键集合一致/ulp 差」断言失败）；跨 concurrency 差异是结构性的。
    /// 故「条目全并」语义改为以 Blueprint.merge 直接锚定（独有键不丢 + 元素求和）。
    func testParallelDeterministicAndComplete() {
        var a = Blueprint(), b = Blueprint()
        Trainer.train(&a, iterations: 40, seed: 313, concurrency: 4)
        Trainer.train(&b, iterations: 40, seed: 313, concurrency: 4)
        XCTAssertEqual(a, b)                 // 同参逐字节确定
        XCTAssertEqual(a.iterations, 40)     // 分片覆盖无遗漏无重复（Σ分片 = 40）
        XCTAssertFalse(a.entries.isEmpty)

        // 合并完整性：共有键逐槽元素求和、worker 独有键不丢、迭代数相加
        let slots: [(action: PlayerAction, slot: AbstractSlot)] = [
            (.check, .check), (.raiseTo(40), .raiseMin)
        ]
        var w0 = Blueprint(), w1 = Blueprint()
        w0.addRegret(key: 7, slots: slots, deltas: [1.0, 2.0])
        w0.addStrategy(key: 7, slots: slots, probs: [0.5, 0.5], weight: 2.0)
        w0.tickIteration()
        w1.addRegret(key: 7, slots: slots, deltas: [10.0, 20.0])     // 共有键
        w1.addRegret(key: 9, slots: slots, deltas: [100.0, 200.0])   // 仅 w1 有的键
        w1.tickIteration(); w1.tickIteration()
        w0.merge(w1)
        XCTAssertEqual(Set(w0.entries.keys), [7, 9])
        XCTAssertEqual(w0.iterations, 3)
        XCTAssertEqual(w0.entries[7]?.regret[AbstractSlot.check.rawValue], 11.0)      // 1+10
        XCTAssertEqual(w0.entries[7]?.regret[AbstractSlot.raiseMin.rawValue], 22.0)   // 2+20
        XCTAssertEqual(w0.entries[9]?.regret[AbstractSlot.check.rawValue], 100.0)     // 独有键原值保留
        XCTAssertEqual(w0.entries[7]?.strategySum[AbstractSlot.check.rawValue], 1.0)  // 2.0×0.5，缺失侧按 0
    }
}
