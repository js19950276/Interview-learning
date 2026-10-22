import XCTest
@testable import PokerEngine

final class BlueprintAITests: XCTestCase {
    /// Review Focus #1/#2：端到端——小训练后的蓝图 ≥90% 查表命中且决策恒合法。
    func testEndToEndHitsTrainedTable() {
        var bp = Blueprint()
        Trainer.train(&bp, iterations: 3_000, seed: 123)
        let ai = BlueprintAI(blueprint: bp)
        var s = GameState.start(config: Trainer.huConfig, seed: 456, buttonSeat: 0)
        var hits = 0, total = 0
        while s.street != .handOver, total < 200 {
            let key = Abstraction.infoKey(s, seat: s.actorSeat!)
            let legal = legalActions(s)
            let slots = Abstraction.slots(for: ladderActions(legal, state: s), legal: legal)
            let decision = ai.decide(s, seat: s.actorSeat!)
            XCTAssertTrue(isLegal(decision, in: legal))          // 查表或回退都恒合法
            if bp.averageStrategy(key: key, slots: slots) != nil { hits += 1 }
            s.apply(decision)
            total += 1
        }
        XCTAssertGreaterThanOrEqual(hits * 10, total * 9)   // ≥90% 命中证明训练键==对战键（容忍稀有线）
    }

    func testEmptyBlueprintFallsBackLegally() {
        let ai = BlueprintAI(blueprint: Blueprint())   // 空表 → 全部回退
        let cfg = GameConfig(playerCount: 2, startingStack: 2000, format: .cash(sb: 10, bb: 20))
        for seed in UInt64(1)...8 {
            var s = GameState.start(config: cfg, seed: seed * 31)
            while s.street != .handOver {
                let legal = legalActions(s)
                let decision = ai.decide(s, seat: s.actorSeat!)
                XCTAssertTrue(isLegal(decision, in: legal))
                s.apply(decision)
            }
        }
    }

    func testDecisionDeterministic() {
        var bp = Blueprint()
        Trainer.train(&bp, iterations: 2_000, seed: 9)
        let ai = BlueprintAI(blueprint: bp)
        let s = GameState.start(config: Trainer.huConfig, seed: 77, buttonSeat: 0)
        XCTAssertEqual(ai.decide(s, seat: s.actorSeat!), ai.decide(s, seat: s.actorSeat!))
    }
}
