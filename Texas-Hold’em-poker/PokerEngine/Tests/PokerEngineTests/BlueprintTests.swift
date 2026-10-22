import XCTest
@testable import PokerEngine

final class BlueprintTests: XCTestCase {
    let slots: [(action: PlayerAction, slot: AbstractSlot)] = [
        (.check, .check), (.fold, .fold), (.raiseTo(60), .raiseMin), (.raiseTo(1000), .allIn)
    ]

    func testRegretMatchingMathPinned() {
        var bp = Blueprint()
        bp.addRegret(key: 1, slots: slots, deltas: [3, 1, 0, -2])
        let sigma = bp.currentStrategy(key: 1, slots: slots)
        XCTAssertEqual(sigma[0], 0.75, accuracy: 1e-12)
        XCTAssertEqual(sigma[1], 0.25, accuracy: 1e-12)
        XCTAssertEqual(sigma[2], 0.0, accuracy: 1e-12)
        bp.addRegret(key: 1, slots: slots, deltas: [1, 3, 0, 0])
        let s2 = bp.currentStrategy(key: 1, slots: slots)
        XCTAssertEqual(s2[0], 0.5, accuracy: 1e-12)   // 4/8
        XCTAssertEqual(s2[1], 0.5, accuracy: 1e-12)
    }

    func testCurrentStrategyUniformWhenNoPositiveRegret() {
        var bp = Blueprint()
        bp.addRegret(key: 2, slots: slots, deltas: [-1, -2, 0, -3])
        XCTAssertEqual(bp.currentStrategy(key: 2, slots: slots), [Double](repeating: 0.25, count: 4))
    }

    /// Review Focus #4：π 加权平均策略的数学钉死。
    func testAverageStrategyWeightedAndNormalized() {
        var bp = Blueprint()
        bp.addStrategy(key: 3, slots: slots, probs: [0.5, 0.5, 0, 0], weight: 1.0)
        bp.addStrategy(key: 3, slots: slots, probs: [0.0, 1.0, 0, 0], weight: 3.0)
        let avg = bp.averageStrategy(key: 3, slots: slots)!
        XCTAssertEqual(avg[0], 0.125, accuracy: 1e-12)  // (0.5×1)/(1+3)
        XCTAssertEqual(avg[1], 0.875, accuracy: 1e-12)
        XCTAssertNil(bp.averageStrategy(key: 999, slots: slots))
    }

    /// Review Focus #5：版本拒载与损坏文件。
    func testCodableRoundTripAndVersionGuard() throws {
        var bp = Blueprint()
        bp.addRegret(key: 42, slots: slots, deltas: [1, 2, 0, 0])
        bp.addStrategy(key: 42, slots: slots, probs: [0.2, 0.8, 0, 0], weight: 2)
        let url = URL(fileURLWithPath: "/tmp/bp-test.json")
        try bp.save(to: url)
        let loaded = try Blueprint.load(from: url)
        // Brief deviation: fold 的 rawValue 是 0（check=1），2×0.8 落在 fold 槽而非下标 1。
        XCTAssertEqual(loaded.entries[42]?.strategySum[AbstractSlot.fold.rawValue] ?? 0, 2 * 0.8, accuracy: 1e-12)
        XCTAssertEqual(loaded.entries[42]?.strategySum[AbstractSlot.check.rawValue] ?? 0, 2 * 0.2, accuracy: 1e-12)
        // 升级路径第 2 级随附：supportedLadderVersion 2→3（序列桶键语义变更：
        // 池相对对数 betRel/修死档/63 桶），版本守卫测试的「未来版本」同步 3→4——
        // 守卫语义不变：任何 ≠ supported 的版本拒载。
        let raw = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\"ladderVersion\":3", with: "\"ladderVersion\":4")
        let bad = URL(fileURLWithPath: "/tmp/bp-bad.json")
        try raw.write(to: bad, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Blueprint.load(from: bad)) { e in
            XCTAssertEqual(e as? BlueprintError, .versionMismatch(4))
        }
        XCTAssertThrowsError(try Blueprint.load(from: URL(fileURLWithPath: "/tmp/definitely-not-there.json"))) { e in
            XCTAssertEqual(e as? BlueprintError, .corrupted)
        }
    }

    /// 终审修复回归：JSON 可解码但条目残缺（regret 数组短于槽位数）必须拒载为
    /// .corrupted——否则查表侧按 slot rawValue 索引 regret/strategySum 会越界崩溃。
    func testLoadRejectsDecodableButShortEntryArrays() throws {
        // regret 仅 2 元素（槽位数 7）、strategySum 完整：解码成功但结构残缺。
        let raw = #"{"ladderVersion":3,"iterations":0,"entries":{"1":{"regret":[0,0],"strategySum":[0,0,0,0,0,0,0]}}}"#
        let url = URL(fileURLWithPath: "/tmp/bp-short-entry.json")
        try raw.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Blueprint.load(from: url)) { e in
            XCTAssertEqual(e as? BlueprintError, .corrupted)
        }
    }
}
