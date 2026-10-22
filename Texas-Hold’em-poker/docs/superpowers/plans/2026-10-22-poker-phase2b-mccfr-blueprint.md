# 德州扑克 阶段 2b（MCCFR 蓝图训练）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现外部采样 MCCFR 自博弈训练器、蓝图策略表与 BlueprintAI（查表决策），经 `AIConsole train` 训练出单挑蓝图产物，并完成双基准验收（vs PIMC normal 与 vs heuristic 各 ≥ +10bb/100 且 CI 不含 0）。

**Architecture:** 全部进 `PokerEngine` 包 `CFR/` 模块：训练器直接驱动引擎 reducer 走真实牌局树（值类型状态分支）；抽象信息键（牌桶×纹理×序列）聚合到 7 槽位动作向量；蓝图 JSON 入库并打包进 App 作「大师」档；零第三方依赖红线不变，既有 69 测试一个不动。

**Tech Stack:** Swift 6（严格并发，训练器单线程确定性）；XCTest；手写 CLI。

**Spec:** `Texas-Hold'em-poker/docs/superpowers/specs/2026-10-22-poker-phase2b-mccfr-blueprint-design.md`

## Global Constraints

- 既有引擎 66 + App 3 测试**一个不改、全绿**（回归线 69→75→79→83→86，按各任务新增数递增）。
- 零第三方依赖；引擎与 AIConsole 不得 import SwiftUI/Combine/UIKit/AppKit。
- 既有文件只允许修改：`AIConsole/main.swift`（train 子命令与 blueprint spec 解析）、App 的 `MenuView.swift`/`GameViewModel.swift`（大师档）+ 新增 `PokerApp/PokerApp/Resources/`（蓝图产物）。`ladderActions`、PIMCAI、2a 全部产物**冻结不改**（对照组红线）。
- 蓝图口径：单挑现金、10/20 盲注、20000 筹码（1000bb）；ladderVersion=1 与 `ladderActions` 现行为绑定，不匹配拒绝加载。
- 训练确定性：第 i 次迭代的 rng = `SeededGenerator(seed: trainSeed &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(i))`（每迭代独立、无状态续训）。
- 测试命令一律 `swift test --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build`；路径含 U+2019 引号（git add 用真实字符）。
- 每任务全量回归后提交；提交信息中文 `feat/fix/test/chore: 描述`。
- **预裁决（spec §4.2 的落地修正）**：序列桶改为可从公开状态直接推导的三元组 `(注池比分档 4 × 我方投入状态 3 × 下注规模档 4) = 48 桶`——原设计的「本街加注次数/我是否最后激进者」无法从 GameState 公开 API 恢复；新三元组语义等价（激进度、本轮位置）。信息键位段相应为 street(2bit)|bucket(8bit)|seq(6bit)。

## Review Focus

1. **训练键 ≠ 对战键**（抽象映射两处实现不一致 → 查表永不命中或错桶）→ Task 1 键编码往返测试 + Task 4 端到端 ≥90% 命中率断言。
2. **概率向量非法**（负值/和≠1/采样越界 → 决策崩溃或偏斜）→ Task 2 归一化与遗憾匹配数学钉死 + Task 4 合法性测试。
3. **续训 ≠ 连训**（rng 状态错位 → 蓝图不可复现）→ Task 3 断言「训 2 万+续 2 万 == 直训 4 万」逐字节相等。
4. **平均策略权重错**（未乘训练方到达概率 π → 早手决策过权重）→ Task 2 手工加权数学钉死（0.5×1 vs 1.0×3 → 0.125/0.875）+ Task 3 walk 的 π 乘法语义。
5. **蓝图版本不匹配/损坏文件仍被加载** → Task 2 拒载测试（ladderVersion≠1 抛错）+ Task 6 App 加载失败回退普通档不崩。

---

### Task 1: 信息抽象 Abstraction（牌桶/纹理/序列桶/键编码 + 7 槽位映射）

**Files:**
- Create: `PokerEngine/Sources/PokerEngine/CFR/Abstraction.swift`
- Test: `PokerEngine/Tests/PokerEngineTests/AbstractionTests.swift`

**Interfaces:**
- Consumes: `Card/Rank/Suit`、`HandEvaluator.evaluate`、`legalActions`/`LegalActions`、`ladderActions(_ legal:state:)`（2a 产物，冻结）、`GameState` 公开只读字段
- Produces（T2-T4 消费）:
  - `public enum AbstractSlot: Int, CaseIterable, Codable, Sendable { case fold = 0, check, call, raiseMin, raiseHalf, raisePot, allIn }`（7 槽位）
  - `public enum Abstraction { static func preflopBucket(_ hole: [Card]) -> Int（0..<169）; static func strengthBucket(_ rank: HandRank, board: [Card]) -> Int（0..<12）; static func textureBucket(_ board: [Card]) -> Int（0..<8）; static func sequenceBucket(_ state: GameState, seat: Int) -> Int（0..<48）; static func infoKey(_ state: GameState, seat: Int) -> UInt64; static func decodeKey(_ k: UInt64) -> (street: Int, bucket: Int, seq: Int); static func slots(for ladder: [PlayerAction], legal: LegalActions) -> [(action: PlayerAction, slot: AbstractSlot)] }`
  - slots 语义：fold→.fold、check→.check、call→.call；加注档按 ladder 内顺序映射——首个加注档→.raiseMin、末个→.allIn、中间按 .raiseHalf/.raisePot；去重归并后按保守序取靠前者。

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import PokerEngine

final class AbstractionTests: XCTestCase {
    func c(_ s: String) -> Card {
        let r = Array(s)[0], su = Array(s)[1]
        let rank = ["2","3","4","5","6","7","8","9","T","J","Q","K","A"].firstIndex(of: String(r))!
        let suit = ["s","h","d","c"].firstIndex(of: String(su))!
        return Card(rank: Rank(rawValue: rank + 2)!, suit: Suit(rawValue: suit)!)
    }
    func cards(_ s: String) -> [Card] { s.split(separator: " ").map { c(String($0)) } }

    func testPreflopCanonical169() {
        XCTAssertEqual(Abstraction.preflopBucket(cards("Ah Kd")), Abstraction.preflopBucket(cards("Ks Ac")))
        XCTAssertEqual(Abstraction.preflopBucket(cards("7h 7d")), Abstraction.preflopBucket(cards("7c 7s")))
        XCTAssertNotEqual(Abstraction.preflopBucket(cards("Ah Kh")), Abstraction.preflopBucket(cards("Ah Kd")))  // 同花≠不同花
        // 全空间恰为 169 桶
        var seen = Set<Int>()
        for hi in 2...14 {
            for lo in 2...14 {
                let off = [Card(rank: Rank(rawValue: hi)!, suit: .spade), Card(rank: Rank(rawValue: lo)!, suit: .diamond)]
                seen.insert(Abstraction.preflopBucket(off))
                if hi != lo {
                    let suited = [Card(rank: Rank(rawValue: hi)!, suit: .spade), Card(rank: Rank(rawValue: lo)!, suit: .spade)]
                    seen.insert(Abstraction.preflopBucket(suited))
                }
            }
        }
        XCTAssertEqual(seen, Set(0..<169))
    }

    func testStrengthBucketMonotone() {
        let board = cards("2h 7d 9c")
        func b(_ h: String) -> Int { Abstraction.strengthBucket(HandEvaluator.evaluate(cards(h) + board), board: board) }
        XCTAssertLessThan(b("Ah 3d"), b("2c 2d"))   // 高牌 < 一对
        XCTAssertLessThan(b("9h 9s"), b("7h 7d"))   // 三条 9 < 葫芦 77（77 + 779 成葫芦）
        XCTAssertGreaterThanOrEqual(b("Ah Ad"), b("2c 2d"))  // 顶对不低于低对（细分不倒挂）
        XCTAssertLessThan(b("Ah Kh"), 12)           // 桶号有界
    }

    func testTextureBuckets() {
        XCTAssertEqual(Abstraction.textureBucket(cards("2h 7d 9c")), 0b000)  // 无配对/三花/连张
        XCTAssertEqual(Abstraction.textureBucket(cards("5h 6d 7c")), 0b100)  // 三连张
        XCTAssertEqual(Abstraction.textureBucket(cards("2h 7h 9h")), 0b010)  // 三同花
        XCTAssertEqual(Abstraction.textureBucket(cards("7h 7d 9c")), 0b001)  // 配对
        XCTAssertEqual(Abstraction.textureBucket(cards("5h 6h 7h")), 0b110)
        XCTAssertTrue((0..<8).contains(Abstraction.textureBucket(cards("Ah Kd 3c"))))
    }

    func testSequenceBucketDerivableAndBounded() {
        var s = GameState.start(config: GameConfig(playerCount: 2, startingStack: 2000, format: .cash(sb: 10, bb: 20)),
                                seed: 5, buttonSeat: 0)
        XCTAssertTrue((0..<48).contains(Abstraction.sequenceBucket(s, seat: 0)))
        s.apply(.raiseTo(60))   // 按钮加注；BB 视角下注规模档应 ≥1（seq % 4 为 bet 档）
        XCTAssertTrue((0..<48).contains(Abstraction.sequenceBucket(s, seat: 1)))
        XCTAssertEqual(Abstraction.sequenceBucket(s, seat: 1) % 4 >= 1, true)
    }

    func testInfoKeyRoundTrip() {
        var s = GameState.start(config: GameConfig(playerCount: 2, startingStack: 2000, format: .cash(sb: 10, bb: 20)),
                                seed: 5, buttonSeat: 0)
        let k = Abstraction.infoKey(s, seat: 0)
        let d = Abstraction.decodeKey(k)
        XCTAssertEqual(d.street, 0)
        XCTAssertEqual(d.bucket, Abstraction.preflopBucket(s.players[0].holeCards))
        XCTAssertEqual(d.seq, Abstraction.sequenceBucket(s, seat: 0))
        s.apply(.call); s.apply(.check)
        let k2 = Abstraction.infoKey(s, seat: 0)
        XCTAssertEqual(Abstraction.decodeKey(k2).street, 1)   // 翻牌 street=1
        XCTAssertNotEqual(k, k2)
    }

    func testSlotsMapping() {
        let s = GameState.start(config: GameConfig(playerCount: 2, startingStack: 2000, format: .cash(sb: 10, bb: 20)),
                                seed: 5, buttonSeat: 0)
        let slots = Abstraction.slots(for: ladderActions(legalActions(s), state: s), legal: legalActions(s))
        // 翻前按钮位 ladder = [call, fold, 最小, ½池, 满池, 全下] → 槽位同序
        XCTAssertEqual(slots.map(\.slot), [.call, .fold, .raiseMin, .raiseHalf, .raisePot, .allIn])
        // 短码单点区间：归并后仅剩一个加注档且为全下
        let short = GameState.start(config: GameConfig(playerCount: 2, startingStack: 2000, format: .cash(sb: 10, bb: 20)),
                                    seed: 5, buttonSeat: 0, stacks: [25, 2000])
        let s2 = Abstraction.slots(for: ladderActions(legalActions(short), state: short), legal: legalActions(short))
        XCTAssertEqual(s2.filter { $0.slot == .raiseMin || $0.slot == .allIn }.count, 1)
        XCTAssertEqual(s2.last?.slot, .allIn)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build --filter AbstractionTests 2>&1 | tail -3`
Expected: FAIL（`Abstraction` 未定义）

- [ ] **Step 3: 实现 Abstraction.swift**

```swift
/// 蓝图信息抽象（spec 阶段 2b §4）：牌桶 × 纹理 × 序列 → UInt64 键；7 槽位动作映射。
public enum AbstractSlot: Int, CaseIterable, Codable, Sendable {
    case fold = 0, check, call, raiseMin, raiseHalf, raisePot, allIn
}

public enum Abstraction {
    // MARK: 翻前 169 规范桶（对子 0..12 / 同花 13..90 / 不同花 91..168）
    public static func preflopBucket(_ hole: [Card]) -> Int {
        let a = hole[0].rank.rawValue, b = hole[1].rank.rawValue
        let hi = max(a, b), lo = min(a, b)
        if hi == lo { return hi - 2 }
        // 非对子组合索引（78 个）：sum_{h=3}^{hi-1}(h-2) + (lo-2)
        let combo = (3..<hi).reduce(0) { $0 + ($1 - 2) } + (lo - 2)
        let suited = hole[0].suit == hole[1].suit
        return 13 + (suited ? 0 : 78) + combo
    }

    // MARK: 翻后强度 12 桶（类别为主 + 顶对细分）
    public static func strengthBucket(_ rank: HandRank, board: [Card]) -> Int {
        let boardMax = board.map { $0.rank.rawValue }.max() ?? 0
        let top = rank.tiebreakers.first ?? 0
        switch rank.category {
        case .highCard: return top >= 11 ? 1 : 0                       // J+ 高 vs 低高
        case .onePair: return top >= boardMax ? 4 : (top * 2 >= boardMax ? 3 : 2)  // 顶对+/中对/低对
        case .twoPair: return 5
        case .threeOfAKind: return 6
        case .straight: return 7
        case .flush: return 8
        case .fullHouse: return 9
        case .fourOfAKind: return 10
        case .straightFlush: return 11
        }
    }

    // MARK: 纹理 8 桶（配对 × 三同花 × 三连张）
    public static func textureBucket(_ board: [Card]) -> Int {
        guard board.count >= 3 else { return 0 }
        let rankCounts = Dictionary(board.map { ($0.rank.rawValue, 1) }, uniquingKeysWith: +)
        let paired = rankCounts.values.contains { $0 >= 2 }
        let suitCounts = Dictionary(grouping: board, by: \.suit).mapValues(\.count)
        let flush3 = (suitCounts.values.max() ?? 0) >= 3
        let ranks = Array(Set(board.map { $0.rank.rawValue })).sorted()
        var connected = false
        if ranks.count >= 3 {
            for i in 2..<ranks.count where ranks[i] == ranks[i - 1] + 1 && ranks[i - 1] == ranks[i - 2] + 1 {
                connected = true; break
            }
            if ranks.last == 14, ranks.contains(2), ranks.contains(3) { connected = true }  // A-2-3 轮子连张
        }
        return (paired ? 1 : 0) | (flush3 ? 2 : 0) | (connected ? 4 : 0)
    }

    // MARK: 序列桶 48（预裁决三元组：注池比 4 × 我方投入 3 × 下注规模 4）
    public static func sequenceBucket(_ state: GameState, seat: Int) -> Int {
        let p = state.players[seat]
        let pot = max(1, state.potTotal)
        let ratio: Int
        if state.currentBet == 0 { ratio = 0 }
        else if state.currentBet * 2 <= pot { ratio = 1 }
        else if state.currentBet <= pot { ratio = 2 }
        else { ratio = 3 }
        let mine: Int
        if p.streetContribution == 0 { mine = 0 }
        else if p.streetContribution < state.currentBet { mine = 1 }
        else { mine = 2 }
        let bet: Int
        if state.currentBet == 0 { bet = 0 }
        else if state.currentBet <= 40 { bet = 1 }        // ≤2bb
        else if state.currentBet <= 120 { bet = 2 }       // ≤6bb
        else { bet = 3 }
        return ((ratio * 3) + mine) * 4 + bet
    }

    // MARK: 信息键 street(2) | bucket(8) | seq(6)
    public static func infoKey(_ state: GameState, seat: Int) -> UInt64 {
        let street: Int
        switch state.street { case .preflop: street = 0; case .flop: street = 1; case .turn: street = 2; default: street = 3 }
        let bucket: Int
        if state.street == .preflop {
            bucket = preflopBucket(state.players[seat].holeCards)
        } else {
            let rank = HandEvaluator.evaluate(state.players[seat].holeCards + state.board)
            bucket = 169 + strengthBucket(rank, board: state.board) * 8 + textureBucket(state.board)
        }
        let seq = sequenceBucket(state, seat: seat)
        return UInt64(street) << 14 | UInt64(bucket) << 6 | UInt64(seq)
    }

    public static func decodeKey(_ k: UInt64) -> (street: Int, bucket: Int, seq: Int) {
        (Int((k >> 14) & 0x3), Int((k >> 6) & 0xFF), Int(k & 0x3F))
    }

    // MARK: 档位 → 槽位（加注档按 ladder 内顺序：首→raiseMin、末→allIn、中间→half/pot）
    public static func slots(for ladder: [PlayerAction], legal: LegalActions) -> [(action: PlayerAction, slot: AbstractSlot)] {
        var out: [(PlayerAction, AbstractSlot)] = []
        let raiseTotal = ladder.filter { act in
            if case .bet = act { return true }
            if case .raiseTo = act { return true }
            return false
        }.count
        var raiseCount = 0
        for act in ladder {
            switch act {
            case .fold: out.append((act, .fold))
            case .check: out.append((act, .check))
            case .call: out.append((act, .call))
            case .bet, .raiseTo:
                let slot: AbstractSlot
                if raiseCount == 0 { slot = .raiseMin }
                else if raiseCount == raiseTotal - 1 { slot = .allIn }
                else if raiseTotal == 3 { slot = .raiseHalf }
                else { slot = .raisePot }   // raiseTotal == 4 的中间档
                out.append((act, slot))
                raiseCount += 1
            }
        }
        return out
    }
}
```

（`slots` 的 raiseTotal 分支保证任意档数都有确定映射。）

- [ ] **Step 4: 运行确认通过（全量回归）**

Run: `swift test --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build 2>&1 | grep Executed | tail -1`
Expected: 69+6=75 全绿（如个别构造断言与实现推导冲突，以手推为准修断言并在报告注明——不允许改弱语义）

- [ ] **Step 5: 提交**

```bash
git add Texas-Hold\'em-poker/PokerEngine
git commit -m "feat: CFR 信息抽象（翻前169/强度12×纹理8/序列48/键编码往返/7槽位映射）"
```

---

### Task 2: Blueprint 策略表（遗憾匹配 + 平均策略 + Codable + 版本拒载）

**Files:**
- Create: `PokerEngine/Sources/PokerEngine/CFR/Blueprint.swift`
- Test: `PokerEngine/Tests/PokerEngineTests/BlueprintTests.swift`

**Interfaces:**
- Consumes: `AbstractSlot`、`Abstraction`（键类型）
- Produces（T3/T4/T5/T6 消费）:
  - `public struct Blueprint: Codable, Sendable`：`ladderVersion: Int`（let）、`iterations: UInt64`（private(set)）、`entries: [UInt64: Entry]`（private(set)）；`init(ladderVersion: Int = 1, iterations: UInt64 = 0, entries: [UInt64: Entry] = [:])`
  - `public struct Entry: Codable, Sendable { public var regret: [Double]; public var strategySum: [Double] }`（各 7 槽；`init()` 零初始化）
  - `mutating func tickIteration()`、`mutating func addRegret(key:slots:deltas:)`、`mutating func addStrategy(key:slots:probs:weight:)`
  - `func currentStrategy(key:slots:) -> [Double]`（遗憾匹配：正遗憾归一，全非正 → 均匀）
  - `func averageStrategy(key:slots:) -> [Double]?`（strategySum 归一；无记录/零和 → nil）
  - `func save(to: URL) throws` / `static func load(from: URL) throws -> Blueprint`（JSON；`ladderVersion != 1` → `BlueprintError.versionMismatch(Int)`；文件/解码失败 → `.corrupted`）
  - `public enum BlueprintError: Error, Equatable { case versionMismatch(Int), corrupted }`
  - `slots` 参数类型统一为 `[(action: PlayerAction, slot: AbstractSlot)]`

- [ ] **Step 1: 写失败测试**

```swift
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
        XCTAssertEqual(loaded.entries[42]?.strategySum[1] ?? 0, 2 * 0.8, accuracy: 1e-12)
        let raw = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\"ladderVersion\":1", with: "\"ladderVersion\":2")
        let bad = URL(fileURLWithPath: "/tmp/bp-bad.json")
        try raw.write(to: bad, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Blueprint.load(from: bad)) { e in
            XCTAssertEqual(e as? BlueprintError, .versionMismatch(2))
        }
        XCTAssertThrowsError(try Blueprint.load(from: URL(fileURLWithPath: "/tmp/definitely-not-there.json"))) { e in
            XCTAssertEqual(e as? BlueprintError, .corrupted)
        }
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build --filter BlueprintTests 2>&1 | tail -3`
Expected: FAIL

- [ ] **Step 3: 实现 Blueprint.swift**

```swift
import Foundation

public enum BlueprintError: Error, Equatable {
    case versionMismatch(Int)
    case corrupted
}

/// MCCFR 蓝图策略表：信息键 → 7 槽位的遗憾与平均策略累计。
public struct Blueprint: Codable, Sendable {
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

public struct Entry: Codable, Sendable {
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
```

- [ ] **Step 4: 运行确认通过（全量回归）**

Run: `swift test --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build 2>&1 | grep Executed | tail -1`
Expected: 75+4=79 全绿

- [ ] **Step 5: 提交**

```bash
git add Texas-Hold\'em-poker/PokerEngine
git commit -m "feat: Blueprint 策略表（遗憾匹配/π加权平均策略/JSON 持久化/版本拒载）"
```

---

### Task 3: Trainer 外部采样 MCCFR（遍历/交替/确定性）

**Files:**
- Create: `PokerEngine/Sources/PokerEngine/CFR/Trainer.swift`
- Test: `PokerEngine/Tests/PokerEngineTests/TrainerTests.swift`

**Interfaces:**
- Consumes: `Blueprint`、`Abstraction.infoKey/slots`、`ladderActions`、`GameState.start/apply`、`SeededGenerator`
- Produces（T4/T5/T7 消费）:
  - `public enum Trainer { public static let huConfig: GameConfig; public static func train(_ bp: inout Blueprint, iterations: UInt64, seed: UInt64, from: UInt64 = 0, onProgress: ((UInt64, Int) -> Void)? = nil) }`
  - huConfig = 2 人 / startingStack 20000 / cash(10, 20)
  - 语义（成文）：每迭代独立 rng（Global Constraints 公式）；traverser = i%2 交替；`walk` 的 rng 全程穿线（训练方全分支按槽位顺序共用消费、对手采样顺序消费——无静态可变状态）；训练方节点 σ=regret matching → `addStrategy(π·σ)` → 全动作分支（子 π = π·σ[i]）→ `addRegret(u_i − nodeUtil)`；终局收益 = 本座 stack − 20000；`onProgress(完成迭代数, 表键数)` 每 10 万次 + 结束时各一次

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import PokerEngine

final class TrainerTests: XCTestCase {
    /// Review Focus #3：同种子两训逐字节相同。
    func testDeterminismSmall() {
        var a = Blueprint(); var b = Blueprint()
        Trainer.train(&a, iterations: 20_000, seed: 777)
        Trainer.train(&b, iterations: 20_000, seed: 777)
        XCTAssertEqual(a.iterations, 20_000)
        XCTAssertEqual(a, b)
    }

    /// Review Focus #3：续训 == 连训。
    func testResumeEqualsContinuous() {
        var cont = Blueprint()
        Trainer.train(&cont, iterations: 30_000, seed: 42)
        var split = Blueprint()
        Trainer.train(&split, iterations: 15_000, seed: 42, from: 0)
        Trainer.train(&split, iterations: 15_000, seed: 42, from: 15_000)
        XCTAssertEqual(split, cont)
    }

    /// 结构方向：训练后表非空且遗憾有正有非正。
    func testRegretStructureAfterSmallRun() {
        var bp = Blueprint()
        Trainer.train(&bp, iterations: 3_000, seed: 99)
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
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build --filter TrainerTests 2>&1 | tail -3`
Expected: FAIL

- [ ] **Step 3: 实现 Trainer.swift**

```swift
import Foundation

/// 外部采样 MCCFR（spec 阶段 2b §5）。单线程确定性：第 i 迭代 rng 独立播种。
public enum Trainer {
    public static let huConfig = GameConfig(playerCount: 2, startingStack: 20_000,
                                            format: .cash(sb: 10, bb: 20))

    public static func train(_ bp: inout Blueprint, iterations: UInt64, seed: UInt64,
                             from: UInt64 = 0,
                             onProgress: ((UInt64, Int) -> Void)? = nil) {
        for i in from..<(from + iterations) {
            var iterRng = SeededGenerator(seed: seed &* 0x9E37_79B9_7F4A_7C15 &+ i)
            let traverser = Int(i % 2)
            let handSeed = iterRng.next()
            let state = GameState.start(config: huConfig, seed: handSeed)
            _ = walk(state, bp: &bp, traverser: traverser, pi: 1.0, rng: &iterRng)
            bp.tickIteration()
            if let cb = onProgress, (i - from + 1) % 100_000 == 0 { cb(i + 1, bp.entries.count) }
        }
        if let cb = onProgress, iterations > 0, iterations % 100_000 != 0 {
            cb(from + iterations, bp.entries.count)
        }
    }

    /// 返回 traverser 的效用；π 为 traverser 自身到达概率。rng 全程穿线（无静态可变状态）：
    /// 训练方全分支按槽位顺序共用消费；对手采样顺序消费——同种子同迭代序列确定。
    private static func walk(_ state: GameState, bp: inout Blueprint,
                             traverser: Int, pi: Double,
                             rng: inout SeededGenerator) -> Double {
        if state.street == .handOver {
            return Double(state.players[traverser].stack - 20_000)
        }
        guard let actor = state.actorSeat else {
            return Double(state.players[traverser].stack - 20_000)
        }
        let legal = legalActions(state)
        let ladder = ladderActions(legal, state: state)
        let slots = Abstraction.slots(for: ladder, legal: legal)
        let key = Abstraction.infoKey(state, seat: actor)
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
```

- [ ] **Step 4: 运行确认通过（全量回归）**

Run: `swift test --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build 2>&1 | grep Executed | tail -1`
Expected: 79+4=83 全绿（TrainerTests 总时长应 < 60s；若超，迭代数减半并在报告注明）

- [ ] **Step 5: 提交**

```bash
git add Texas-Hold\'em-poker/PokerEngine
git commit -m "feat: 外部采样 MCCFR 训练器（交替 traverser/π加权/逐迭代独立 rng/续训=连训确定性）"
```

---

### Task 4: BlueprintAI（查表采样 + 回退 + 确定性）

**Files:**
- Create: `PokerEngine/Sources/PokerEngine/CFR/BlueprintAI.swift`
- Test: `PokerEngine/Tests/PokerEngineTests/BlueprintAITests.swift`

**Interfaces:**
- Consumes: `Blueprint.averageStrategy`、`Abstraction.infoKey/slots`、`ladderActions`、`PIMCAI.easy`、`Trainer.huConfig`
- Produces（T5/T6 消费）:
  - `public struct BlueprintAI: PokerAI { public init(blueprint: Blueprint, seedSalt: UInt64 = 0); public func decide(_ state: GameState, seat: Int) -> PlayerAction }`
  - 决策：键 → 平均策略（仅适用槽位）→ 概率采样（rng = `SeededGenerator(seed: state.seed &* 0x51ED_2701 &+ UInt64(state.handNumber) &* 31 &+ UInt64(truncatingIfNeeded: seat) &* 97 &+ UInt64(state.actions.count) &* 7 &+ seedSalt)`）；未命中/零和 → `PIMCAI.easy.decide`

- [ ] **Step 1: 写失败测试**

```swift
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
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build --filter BlueprintAITests 2>&1 | tail -3`
Expected: FAIL

- [ ] **Step 3: 实现 BlueprintAI.swift**

```swift
/// 蓝图查表 AI：平均策略采样；未命中键回退 PIMCAI.easy（spec 阶段 2b §6）。
public struct BlueprintAI: PokerAI {
    public let blueprint: Blueprint
    public var seedSalt: UInt64
    private let fallback = PIMCAI.easy

    public init(blueprint: Blueprint, seedSalt: UInt64 = 0) {
        self.blueprint = blueprint
        self.seedSalt = seedSalt
    }

    public func decide(_ state: GameState, seat: Int) -> PlayerAction {
        guard let actor = state.actorSeat, actor == seat else { return .fold }
        let legal = legalActions(state)
        let ladder = ladderActions(legal, state: state)
        let slots = Abstraction.slots(for: ladder, legal: legal)
        let key = Abstraction.infoKey(state, seat: seat)
        guard let probs = blueprint.averageStrategy(key: key, slots: slots), !probs.isEmpty else {
            return fallback.decide(state, seat: seat)
        }
        var rng = SeededGenerator(seed: state.seed &* 0x51ED_2701
                                    &+ UInt64(state.handNumber) &* 31
                                    &+ UInt64(truncatingIfNeeded: seat) &* 97
                                    &+ UInt64(state.actions.count) &* 7
                                    &+ seedSalt)
        let total = probs.reduce(0, +)
        let r = Double(rng.next() % 1_000_000) / 1_000_000 * total
        var acc = 0.0
        for (i, p) in probs.enumerated() {
            acc += p
            if r < acc { return slots[i].action }
        }
        return slots[slots.count - 1].action
    }
}
```

- [ ] **Step 4: 运行确认通过（全量回归）**

Run: `swift test --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build 2>&1 | grep Executed | tail -1`
Expected: 83+3=86 全绿

- [ ] **Step 5: 提交**

```bash
git add Texas-Hold\'em-poker/PokerEngine
git commit -m "feat: BlueprintAI 查表决策（平均策略采样/未命中回退/确定性种子）"
```

---

### Task 5: AIConsole train 子命令 + blueprint:hu 对战规格

**Files:**
- Modify: `PokerEngine/Sources/AIConsole/main.swift`
- Modify: `PokerApp/README.md`

**Interfaces:**
- Consumes: `Trainer.train`、`Blueprint.save/load`、`BlueprintAI`
- Produces（T7/T8 消费）:
  - `train --iterations N --seed S [--from N] [--checkpoint-every N(默认 100 万)] --out path [--resume path]`：训练（可续）、checkpoint 落盘、收敛日志行 `iter=N keys=K`、结束总结（迭代数/键数/文件大小）
  - `makeAI("blueprint:hu")` → 从 `--blueprint` 路径（默认 `blueprint-hu.json`）加载 → `BlueprintAI`；加载失败打印错误并 `exit(2)`；battle/bench 全兼容
  - README 追加 train/blueprint 用法

- [ ] **Step 1: 实现（CLI 无 TDD，验收 = 冒烟）**

`main.swift` 修改要点（执行者落地为完整代码，沿用现有 flag 解析模式）：
1. 顶部新增 `--blueprint` flag（默认 `blueprint-hu.json`）；`makeAI` 增加 `case ("blueprint", _)`：`Blueprint.load` 成功 → `BlueprintAI(blueprint: bp)`；失败 → `print` 错误 + `exit(2)`。
2. `switch sub` 增加 `case "train"`：解析 flags；`--resume` 有值时加载续训蓝图（缺失/损坏 → 报错退出），否则新表；`Trainer.train(&bp, iterations:n, seed:s, from:from)` 的回调里 `print("iter=\(iter) keys=\(keys)")`，到 `--checkpoint-every` 点且设了 `--out` 时 `try? bp.save(to:)`；结束后强制 save + 打印总结行。
3. usage 行更新（补 train 与 --blueprint）。

README 追加：

```markdown
## 蓝图训练（2b）

    swift run AIConsole train --iterations 10000000 --seed 20261022 --checkpoint-every 1000000 --out blueprint-hu.json
    swift run AIConsole battle --a blueprint:hu --b pimc:normal --table hu --hands 20000
```

- [ ] **Step 2: 冒烟**

```bash
cd Texas-Hold\'em-poker/PokerEngine
swift build --scratch-path /tmp/poker-build --product AIConsole 2>&1 | tail -1
swift run --scratch-path /tmp/poker-build AIConsole train --iterations 50000 --seed 7 --out /tmp/bp-smoke.json 2>&1 | tail -2
swift run --scratch-path /tmp/poker-build AIConsole battle --a blueprint:hu --b heuristic:0.5 --table hu --hands 100 --seed 3 --blueprint /tmp/bp-smoke.json 2>&1 | tail -3
```
Expected: train 输出迭代/键数与总结行；battle 加载蓝图完成 100 手（冒烟只验链路，不看胜负）

- [ ] **Step 3: 全量回归 + 提交**

Run: `swift test --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build 2>&1 | grep Executed | tail -1`
Expected: 86 全绿

```bash
git add Texas-Hold\'em-poker
git commit -m "feat: AIConsole train 子命令与 blueprint 对战规格（checkpoint 续训/收敛日志/README）"
```

---

### Task 6: App「大师（蓝图）」档 + 资源打包

**Files:**
- Create: `PokerApp/PokerApp/Resources/blueprint-hu.json`（最小合法占位：`{"ladderVersion":1,"iterations":0,"entries":{}}`——加载成功但全部回退，验证打包链路；T7 用正式产物覆盖）
- Modify: `PokerApp/PokerApp/GameViewModel.swift`（AIDifficulty.master + 加载与回退）
- Modify: `PokerApp/PokerApp/MenuView.swift`（无改动——Picker 走 CaseIterable 自动含新 case；如显示需排序按枚举序）

**Interfaces:**
- Consumes: `Blueprint.load`、`BlueprintAI`、`PIMCAI.normal`
- Produces: `AIDifficulty.master = "大师（蓝图）"`；bots 的 master 分支语义（Review Focus #5）：**多人局或加载失败一律回退普通档**（蓝图仅单挑训练，spec §1），`print` 告警不崩

- [ ] **Step 1: 实现**

`GameViewModel.swift` 的 `AIDifficulty` 增加 case 与分支：

```swift
        case master = "大师（蓝图）"
        // bots(...) switch 内：
        case .master:
            // 蓝图仅单挑训练（spec §1）：多人局或加载失败一律回退普通档，App 不崩
            let normal = Dictionary(uniqueKeysWithValues:
                (0..<playerCount).filter { $0 != humanSeat }.map { ($0, PIMCAI.normal as any PokerAI) })
            guard playerCount == 2,
                  let url = Bundle.main.url(forResource: "blueprint-hu", withExtension: "json"),
                  let bp = try? Blueprint.load(from: url) else {
                print("警告：大师档不可用（非单挑或蓝图加载失败），回退普通档")
                return normal
            }
            return Dictionary(uniqueKeysWithValues:
                (0..<playerCount).filter { $0 != humanSeat }.map { ($0, BlueprintAI(blueprint: bp) as any PokerAI) })
```

写入占位蓝图后执行 `xcodegen generate`（Resources 在 sources 路径内自动按资源处理；确认 pbxproj 含 blueprint-hu.json）。

- [ ] **Step 2: 构建与回归**

```bash
cd Texas-Hold\'em-poker/PokerApp && /tmp/xcodegen-dist/xcodegen/bin/xcodegen generate
xcodebuild -project PokerApp.xcodeproj -scheme PokerApp -destination 'platform=macOS' -derivedDataPath /tmp/poker-dd build 2>&1 | tail -2
xcodebuild test -project PokerApp.xcodeproj -scheme PokerApp -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/poker-dd 2>&1 | tail -2
```
Expected: BUILD SUCCEEDED；TEST SUCCEEDED 3/3

- [ ] **Step 3: 提交**

```bash
git add Texas-Hold\'em-poker/PokerApp
git commit -m "feat: App 大师（蓝图）难度档（Bundle 资源加载/非单挑与失败回退普通档）"
```

---

### Task 7: 蓝图训练运行（正式产物）

**Files:**
- Modify: `Texas-Hold'em-poker/PokerApp/PokerApp/Resources/blueprint-hu.json`（覆盖占位）
- Create: `Texas-Hold'em-poker/docs/superpowers/phase2b-training-log.md`

**Interfaces:**
- Consumes: AIConsole train（T5）
- Produces: 正式蓝图（T8 验收与 App 使用的同一份）+ 训练证据文档（迭代数/墙钟/收敛日志尾部/表键数/文件大小/种子）

- [ ] **Step 1: 训练（后台长跑，checkpoint 保护）**

```bash
cd Texas-Hold\'em-poker/PokerEngine && nohup swift run --scratch-path /tmp/poker-build AIConsole train \
  --iterations 10000000 --seed 20261022 --checkpoint-every 1000000 \
  --out /tmp/blueprint-hu.json > /tmp/poker-train-2b.log 2>&1 &
```
执行者用后台任务机制跟踪（预计 2–6 小时；每百万迭代 checkpoint，可随时停止取产物）。先以 10 万迭代实测吞吐再决定总量（目标：数小时内完成；若 200 万迭代后收敛指标趋平可提前停）。结束后 `cp /tmp/blueprint-hu.json ../PokerApp/PokerApp/Resources/blueprint-hu.json`，写训练日志文档。

- [ ] **Step 2: 产物冒烟（延迟门提前验证）**

```bash
swift run --scratch-path /tmp/poker-build AIConsole bench --ai blueprint:hu --blueprint ../PokerApp/PokerApp/Resources/blueprint-hu.json --hands 100 --seed 3 2>&1 | tail -1
```
Expected: p95 < 10ms（验收线之一）

- [ ] **Step 3: 提交**

```bash
git add Texas-Hold\'em-poker
git commit -m "chore: 2b 正式蓝图产物入库（N 迭代/种子 20261022）+ 训练证据"
```

---

### Task 8: 双基准验收 + 验收文档

**Files:**
- Create: `Texas-Hold'em-poker/docs/superpowers/phase2b-acceptance.md`

- [ ] **Step 1: 两场正式 battle（并发满核，各 20k 手）**

```bash
swift run AIConsole battle --a blueprint:hu --b pimc:normal --table hu --hands 20000 --seed 1 --concurrency 8 --blueprint ../PokerApp/PokerApp/Resources/blueprint-hu.json
swift run AIConsole battle --a blueprint:hu --b heuristic:0.5 --table hu --hands 20000 --seed 2 --concurrency 8 --blueprint ../PokerApp/PokerApp/Resources/blueprint-hu.json
```
判据（spec §1）：两场均 **≥ +10bb/100 且 CI 下界 > 0**。未达线 → 按 spec §1 升级路径执行并在文档记录（加迭代重训→加细桶→方案 C 降级翻前蓝图混合），每一步结果保留。

- [ ] **Step 2: 写验收文档**

含：训练配置与证据引用、两场 battle 命令与三行输出、判据算术、bench 延迟行（T7 已验，引用）、结论 PASS/FAIL（含升级路径记录）。

- [ ] **Step 3: 提交**

```bash
git add Texas-Hold\'em-poker/docs/superpowers/phase2b-acceptance.md
git commit -m "test: 阶段2b 双基准验收（blueprint vs pimc:normal / vs heuristic）"
```

---

## 任务依赖

T1→T2→T3→T4 严格线性；T5 依赖 T4；T6 依赖 T4；T7 依赖 T5；T8 依赖 T7。回归线 69→75→79→83→86（T5/T6 不增引擎测试）。

## 执行者注意事项（成文）

1. `Abstraction.infoKey` 每个树节点调用一次（含一次 evaluate）——FastEval 已就位；不要在同一节点重复算键。
2. Trainer 单线程确定性是硬约束（续训=连训测试钉死）；rng 必须穿线传递，禁止任何静态/全局可变状态。
3. 训练中每手 `GameState.start` 独立创建，不跨手复用状态。
4. 环境备忘：U+2019 路径（git add 用真实字符）；`--scratch-path`/`-derivedDataPath`；xcodegen 在 /tmp/xcodegen-dist/xcodegen/bin/；iPhone 17 模拟器；无 brew。
5. 提交信息中文，一任务一提交。
