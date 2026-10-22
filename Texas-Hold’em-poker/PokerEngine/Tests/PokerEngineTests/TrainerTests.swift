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
}
