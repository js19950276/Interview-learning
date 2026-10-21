import XCTest
@testable import PokerEngine

final class BattleTests: XCTestCase {
    /// 同 AI 对打：每手筹码守恒，双方 per-seat bb/100 互为相反数、CI 相同。
    func testConservationAndMirrorStats() async {
        let outcomes = await runBattle(a: HeuristicAI(aggression: 0.5), b: HeuristicAI(aggression: 0.5),
                                       table: .headsUp, hands: 60, seedBase: 1000, concurrency: 1)
        XCTAssertEqual(outcomes.count, 60)
        for o in outcomes { XCTAssertEqual(o.seatDeltas.reduce(0, +), 0, "hand \(o.handIndex)") }
        let report = summarizeBattle(outcomes)
        XCTAssertEqual(report.hands, 60)
        XCTAssertEqual(report.perSeatBB100[0] + report.perSeatBB100[1], 0, accuracy: 1e-9)
        XCTAssertEqual(report.perSeatCI[0], report.perSeatCI[1], accuracy: 1e-9)
    }

    /// Review Focus #4：并发不改变结果（种子与执行顺序解耦）。
    func testConcurrencyDoesNotChangeResults() async {
        let a = HeuristicAI(aggression: 0.5), b = HeuristicAI(aggression: 0.3)
        let seq = await runBattle(a: a, b: b, table: .headsUp, hands: 40, seedBase: 77, concurrency: 1)
        let par = await runBattle(a: a, b: b, table: .headsUp, hands: 40, seedBase: 77, concurrency: 4)
        XCTAssertEqual(seq, par)
    }

    /// Review Focus #5（方向）：极强 vs 全弃，强方 bb/100 显著为正。
    struct AlwaysFold: PokerAI { func decide(_ s: GameState, seat: Int) -> PlayerAction { .fold } }
    struct AlwaysShove: PokerAI {
        func decide(_ s: GameState, seat: Int) -> PlayerAction {
            let legal = legalActions(s)
            if let r = legal.betRange { return .raiseTo(r.upperBound) }
            return legal.canCall ? .call : .check
        }
    }
    func testStrongBeatsAlwaysFoldDirectionally() async {
        let outcomes = await runBattle(a: AlwaysShove(), b: AlwaysFold(),
                                       table: .headsUp, hands: 200, seedBase: 5, concurrency: 1)
        var aBB = 0.0
        for o in outcomes { aBB += Double(o.seatDeltas[o.handIndex % 2]) / 20.0 }
        XCTAssertGreaterThan(aBB / Double(outcomes.count) * 100, 10)   // 极端构造应远超 +10bb/100
    }

    /// 统计公式钉死：常量样本 CI=0；交替样本均值/CI 正确。
    func testSummarizeMathPinned() {
        let constant = (0..<4).map { HandOutcome(handIndex: $0, seatDeltas: [20, -20]) }
        let r1 = summarizeBattle(constant)
        XCTAssertEqual(r1.perSeatBB100[0], 100, accuracy: 1e-9)   // 每手 +1bb → +100bb/100手
        XCTAssertEqual(r1.perSeatCI[0], 0, accuracy: 1e-9)        // 零方差
        let alternating = (0..<4).map { HandOutcome(handIndex: $0, seatDeltas: [$0 % 2 == 0 ? 40 : -20, $0 % 2 == 0 ? -40 : 20]) }
        let r2 = summarizeBattle(alternating)
        XCTAssertEqual(r2.perSeatBB100[0], 50, accuracy: 1e-9)    // 均值 +0.5bb/手
        XCTAssertGreaterThan(r2.perSeatCI[0], 0)
    }

    /// sixMax：6 席、a/b 各 3 席、守恒。
    func testSixMaxSeats() async {
        let outcomes = await runBattle(a: HeuristicAI(aggression: 0.5), b: HeuristicAI(aggression: 0.5),
                                       table: .sixMax, hands: 24, seedBase: 9, concurrency: 1)
        XCTAssertEqual(outcomes.first?.seatDeltas.count, 6)
        for o in outcomes { XCTAssertEqual(o.seatDeltas.reduce(0, +), 0) }
    }

    /// 六人桌按方聚合：a 用满 3 席、a/b 镜像互反（headsUp 退化为单席）。
    func testSideMeanDeltasMirrorSixMax() {
        // 构造 6 手已知结果：每手 a 方三席合计 +60、b 方三席合计 -60（均分到席）
        let outcomes = (0..<6).map { i -> HandOutcome in
            let rotate = i % 6
            var deltas = [Int](repeating: 0, count: 6)
            for s in 0..<6 {
                let isA = ((s - rotate + 6) % 6) % 2 == 0
                deltas[s] = isA ? 20 : -20
            }
            return HandOutcome(handIndex: i, seatDeltas: deltas)
        }
        let a = sideMeanDeltas(outcomes, forA: true)
        let b = sideMeanDeltas(outcomes, forA: false)
        XCTAssertEqual(a, [Double](repeating: 20, count: 6))
        XCTAssertEqual(b, [Double](repeating: -20, count: 6))
        // headsUp 退化：a 的锚位 = handIndex % n（hand0→seat0，hand1→seat1）
        let hu = [HandOutcome(handIndex: 0, seatDeltas: [30, -30]),
                  HandOutcome(handIndex: 1, seatDeltas: [-30, 30])]
        XCTAssertEqual(sideMeanDeltas(hu, forA: true), [30, 30])    // hand0 a=seat0(+30)，hand1 a=seat1(+30)
        XCTAssertEqual(sideMeanDeltas(hu, forA: false), [-30, -30])
    }
}
