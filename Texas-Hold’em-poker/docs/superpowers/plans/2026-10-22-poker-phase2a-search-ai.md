# 德州扑克 阶段 2a（搜索型 AI）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 PIMC 搜索型扑克 AI（视角重采样 + 根带 UCT + 档位动作阶梯）、FastEval 快评估、AIConsole 无头评测工作台，并完成 +5bb/100 验收。

**Architecture:** 全部进现有 `PokerEngine` 包：引擎新增 `resampled(from:using:)` 公开 API 与 FastEval 内部路由；AI 为 `PIMCAI: PokerAI`（挂第 1 期协议，App 零并发改动）；评测核心 `AI/Battle.swift`（async TaskGroup 并发、可单测），CLI 为薄壳 executable target `AIConsole`。对既有代码行为零变更（第 1 期 49 测试一个不改）。

**Tech Stack:** Swift 6（严格并发）/ XCTest / 手写零依赖 CLI。

**Spec:** `Texas-Hold'em-poker/docs/superpowers/specs/2026-10-22-poker-phase2a-search-ai-design.md`

## Global Constraints

- 第 1 期引擎 49 测试 + App 3 测试**一个不改、全绿**是每任务的硬回归线（测试数增长序列 49→52→55→60→65 即回归线）。
- 引擎与 AIConsole 零第三方依赖、不得 import SwiftUI/Combine/UIKit/AppKit。
- 对既有文件只允许修改：`HandEvaluator.swift`（内部路由 FastEval，行为全等）、`Deck.swift`（新增 internal init）、`Package.swift`（executable target 声明）、App 的 `MenuView.swift`/`GameViewModel.swift`/`PokerApp.swift`（难度接入；GameViewModel 新参数带默认值使旧测试不动）。
- 保留旧评估算法为 `HandEvaluator.evaluateLegacy`（internal）作全等 oracle。
- 测试命令一律：`swift test --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build`（iCloud 变通）。
- 每任务全量回归后才提交；提交信息中文 `feat/fix/test/chore: 描述`。
- battle 口径（spec §1）：heads-up 现金局、盲注 10/20、每手独立重置筹码 10000（1000bb）；bb/100 ± 95% 正态 CI。
- PIMCAI 预设（spec §4.5）：轻松 8×25 / 普通 16×64 / 困难 32×125；探索常数默认 1.4。
- Swift 6 严格并发：跨任务捕获必须是 Sendable（`any PokerAI` 已 Sendable）；禁用 GDD 捕获可变数组的模式，并发一律 TaskGroup。

## Review Focus

1. **FastEval 与旧实现不全等**（轮子顺/同花顺/踢脚序列最易错）→ Task 1：随机 5/6/7 张 × 5000 逐位全等 + 轮子顺/皇家专项。
2. **resample 泄漏真实隐藏信息或池算错**（公平性结构破坏）→ Task 2：世界全部未知牌 = 未见池重排、与可见牌不相交、逐字段保留可见状态、含已弃牌/终局淘汰者的池守恒。
3. **档位阶梯产出非法动作**（半池/满池未 clamp、单点区间多档）→ Task 3：ladder 单测（单点仅全下）+ 12 局×全手合法性性质测试。
4. **battle 并发后结果不确定**（种子冲突/结果乱序聚合）→ Task 4：concurrency=1 与 4 的 HandOutcome 数组逐元素相等。
5. **EV 基线错位**（fold EV ≠ 0、bb/100 符号翻转）→ Task 3：fold 恒不进 rollout（结构性 0）+ 决策确定性；Task 4：极端强弱构造 bb/100 符号为正、同 AI 镜像互反。

---

### Task 1: FastEval 快评估路径（全等替换 + 基准）

**Files:**
- Create: `PokerEngine/Sources/PokerEngine/HandEval/FastEval.swift`
- Modify: `PokerEngine/Sources/PokerEngine/HandEval/HandEvaluator.swift`（evaluate 路由；旧体改名 evaluateLegacy）
- Test: `PokerEngine/Tests/PokerEngineTests/FastEvalTests.swift`

**Interfaces:**
- Consumes: `Card`（`rank.rawValue` 2...14、`suit.rawValue` 0...3）、`HandRank(_:_:)`、`HandCategory`
- Produces:
  - `enum FastEval { static func evaluate(_ cards: [Card]) -> HandRank }`（5-7 张，与 legacy 逐位全等）
  - `HandEvaluator.evaluate`（公开，路由 FastEval——既有测试零影响）
  - `HandEvaluator.evaluateLegacy`（internal，oracle；原函数体原样保留改名）

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import PokerEngine

final class FastEvalTests: XCTestCase {
    /// 全等性质：随机 5/6/7 张 × 5000 组合，FastEval 与 legacy 逐位相等（Review Focus #1）。
    func testEquivalenceWithLegacyOnRandomCards() {
        var rng = SeededGenerator(seed: 20261022)
        for _ in 0..<5_000 {
            var deck = Deck(rng: &rng)
            for count in [5, 6, 7] {
                let cards = (0..<count).map { _ in deck.draw() }
                let fast = FastEval.evaluate(cards)
                let legacy = HandEvaluator.evaluateLegacy(cards)
                XCTAssertEqual(fast.value, legacy.value, "cards=\(cards.map(\.description))")
                XCTAssertEqual(fast.category, legacy.category)
                XCTAssertEqual(fast.tiebreakers, legacy.tiebreakers)
            }
        }
    }

    /// 专项：轮子顺家族与皇家（最易错类）。code = (rank-2)*4 + suit（spade=0）。
    func testWheelFamilyEquivalence() {
        let cases: [[Int]] = [
            [48, 0, 4, 8, 12],            // A♠2♠3♠4♠5♠ 同花轮子
            [48, 1, 5, 9, 13],            // 轮子（非同花）
            [48, 0, 4, 8, 40],            // 轮子 + K（6 张）
            [44, 45, 46, 47, 48],         // T♠J♠Q♠K♠A♠ 皇家
            [12, 16, 20, 24, 28, 29, 30]  // 5-9 顺 + 三条 9（7 张）
        ]
        for codes in cases {
            let cards = codes.map(Card.init(code:))
            XCTAssertEqual(FastEval.evaluate(cards).value,
                           HandEvaluator.evaluateLegacy(cards).value, "codes=\(codes)")
        }
    }

    /// 吞吐基准：数量级记录（measure 仅记录，不断言绝对值）。
    func testThroughputMagnitude() {
        var rng = SeededGenerator(seed: 7)
        let hands = (0..<2_000).map { _ in
            var d = Deck(rng: &rng)
            return (0..<7).map { _ in d.draw() }
        }
        measure { for h in hands { _ = FastEval.evaluate(h) } }
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build --filter FastEvalTests 2>&1 | tail -3`
Expected: FAIL（`FastEval`/`evaluateLegacy` 未定义）

- [ ] **Step 3: 实现**

`FastEval.swift`：

```swift
/// 零字典快评估：数组计数 + 位掩码顺子。与 HandEvaluator.evaluateLegacy 逐位全等（FastEvalTests 钉死）。
enum FastEval {
    static func evaluate(_ cards: [Card]) -> HandRank {
        precondition((5...7).contains(cards.count))
        var rankCount = [Int](repeating: 0, count: 15)
        var suitCount = [Int](repeating: 0, count: 4)
        var mask = 0
        for card in cards {
            let r = card.rank.rawValue
            rankCount[r] += 1
            suitCount[card.suit.rawValue] += 1
            mask |= 1 << r
        }

        // 同花 / 同花顺：任一花色 ≥5 张
        var flushStraightHigh: Int?
        var flushTop5: [Int] = []
        for s in 0..<4 where suitCount[s] >= 5 {
            var suitedMask = 0
            for card in cards where card.suit.rawValue == s {
                suitedMask |= 1 << card.rank.rawValue
            }
            if let high = straightHigh(mask: suitedMask) {
                flushStraightHigh = high
            } else {
                var top: [Int] = []
                for r in stride(from: 14, through: 2, by: -1) where suitedMask & (1 << r) != 0 {
                    top.append(r)
                    if top.count == 5 { break }
                }
                flushTop5 = top
            }
        }
        if let high = flushStraightHigh {
            return .init(.straightFlush, [high])
        }

        var quadRank = 0
        for r in stride(from: 14, through: 2, by: -1) where rankCount[r] == 4 { quadRank = r; break }
        if quadRank > 0 {
            var kicker = 0
            for r in stride(from: 14, through: 2, by: -1) where r != quadRank && rankCount[r] > 0 {
                kicker = r; break
            }
            return .init(.fourOfAKind, [quadRank, kicker])
        }
        var tripRanks: [Int] = []
        var pairRanks: [Int] = []
        for r in stride(from: 14, through: 2, by: -1) {
            if rankCount[r] == 3 { tripRanks.append(r) }
            else if rankCount[r] == 2 { pairRanks.append(r) }
        }
        if let t = tripRanks.first {
            let pairForBoat = pairRanks.first ?? (tripRanks.count > 1 ? tripRanks[1] : nil)
            if let p = pairForBoat { return .init(.fullHouse, [t, p]) }
        }
        if !flushTop5.isEmpty { return .init(.flush, flushTop5) }
        if let high = straightHigh(mask: mask) {
            return .init(.straight, [high])
        }
        if let t = tripRanks.first {
            var kickers: [Int] = []
            for r in stride(from: 14, through: 2, by: -1) where r != t && rankCount[r] > 0 {
                kickers.append(r)
                if kickers.count == 2 { break }
            }
            return .init(.threeOfAKind, [t] + kickers)
        }
        if pairRanks.count >= 2 {
            var kicker = 0
            for r in stride(from: 14, through: 2, by: -1)
            where r != pairRanks[0] && r != pairRanks[1] && rankCount[r] > 0 { kicker = r; break }
            return .init(.twoPair, [pairRanks[0], pairRanks[1], kicker])
        }
        if let p = pairRanks.first {
            var kickers: [Int] = []
            for r in stride(from: 14, through: 2, by: -1) where r != p && rankCount[r] > 0 {
                kickers.append(r)
                if kickers.count == 3 { break }
            }
            return .init(.onePair, [p] + kickers)
        }
        var top: [Int] = []
        for r in stride(from: 14, through: 2, by: -1) where rankCount[r] > 0 {
            top.append(r)
            if top.count == 5 { break }
        }
        return .init(.highCard, top)
    }

    /// 位掩码顺子：A 可当 1（置 bit 1）。返回最高顺子顶张。
    static func straightHigh(mask: Int) -> Int? {
        var m = mask
        if m & (1 << 14) != 0 { m |= 1 << 1 }
        for high in stride(from: 14, through: 5, by: -1) {
            let window = 0b11111 << (high - 4)
            if m & window == window { return high }
        }
        return nil
    }
}
```

`HandEvaluator.swift`：把现有 `public static func evaluate(...)` 改名为 `static func evaluateLegacy(...)`（去掉 public，函数体原样不动），并新增：

```swift
    /// 公开入口：路由到 FastEval（与 evaluateLegacy 全等，FastEvalTests 钉死）。
    public static func evaluate(_ cards: [Card]) -> HandRank {
        FastEval.evaluate(cards)
    }
```

- [ ] **Step 4: 运行确认通过（全量回归）**

Run: `swift test --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build 2>&1 | grep -E "Test Suite 'All tests'|Executed" | tail -2`
Expected: 全绿（49 旧 + 3 新 = 52；旧评估类测试对新路径自动成立）

- [ ] **Step 5: 提交**

```bash
git add Texas-Hold\'em-poker/PokerEngine
git commit -m "feat: FastEval 零字典快评估（全等性质测试 5000 例 + 轮子顺专项 + 吞吐基准）"
```

---

### Task 2: 视角重采样 resampled(from:using:)

**Files:**
- Create: `PokerEngine/Sources/PokerEngine/Game/Resample.swift`
- Modify: `PokerEngine/Sources/PokerEngine/Cards/Deck.swift`（新增 internal `init(cards:)`）
- Test: `PokerEngine/Tests/PokerEngineTests/ResampleTests.swift`

**Interfaces:**
- Consumes: `GameState`、`Deck`、`SeededGenerator`
- Produces（Task 3 消费）:
  - `extension GameState { public func resampled(from seat: Int, using rng: inout SeededGenerator) -> GameState }`
  - `Deck.init(cards: [Card])`（internal：直接持有，顶部 = 数组末尾）
  - 语义（spec §4.1，含本计划钉死的补充）：对手重发条件 = **有底牌且非 seat 本身**（已弃牌者、终局手淘汰未清牌者一律重发——他们的牌对 seat 不可见且是死牌，重发保持未见池无偏）；真正已无牌者（局间淘汰）自然跳过。

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import PokerEngine

final class ResampleTests: XCTestCase {
    let cash3 = GameConfig(playerCount: 3, startingStack: 1000, format: .cash(sb: 10, bb: 20))

    func testVisiblePreservedAndUnseenPoolCorrect() {
        var s = GameState.start(config: cash3, seed: 41, buttonSeat: 0)
        s.apply(.call); s.apply(.call); s.apply(.check)   // 进翻牌
        var rng = SeededGenerator(seed: 99)
        let world = s.resampled(from: 0, using: &rng)

        // 可见信息逐字段保留（Review Focus #2）
        XCTAssertEqual(world.players[0].holeCards, s.players[0].holeCards)
        XCTAssertEqual(world.board, s.board)
        XCTAssertEqual(world.players.map(\.stack), s.players.map(\.stack))
        XCTAssertEqual(world.players.map(\.handContribution), s.players.map(\.handContribution))
        XCTAssertEqual(world.actions, s.actions)
        XCTAssertEqual(world.street, s.street)
        XCTAssertEqual(world.actorSeat, s.actorSeat)

        // 未知牌守恒：对手 2×2 张 + deck 43 = 47 = 52 - 自己 2 - board 3；与可见牌不相交
        let visible = Set(s.players[0].holeCards).union(s.board)
        var worldCards = Set<Card>()
        for p in world.players where p.seat != 0 { worldCards.formUnion(p.holeCards) }
        worldCards.formUnion(world.deck.cards)
        XCTAssertEqual(worldCards.count, 47)
        XCTAssertTrue(worldCards.isDisjoint(with: visible))
        XCTAssertEqual(world.deck.count, 43)
    }

    func testFoldedOpponentResampled() {
        var s = GameState.start(config: cash3, seed: 42, buttonSeat: 0)
        s.apply(.fold)                                  // 座位 0 弃
        var rng = SeededGenerator(seed: 7)
        let world = s.resampled(from: 1, using: &rng)   // SB(座位1) 视角
        XCTAssertEqual(world.players[0].holeCards.count, 2)   // 已弃牌对手照样重发 2 张
        XCTAssertEqual(world.players[2].holeCards.count, 2)
    }

    func testSameSeedDeterministicAndWorldIsPlayable() {
        var s = GameState.start(config: cash3, seed: 44, buttonSeat: 0)
        s.apply(.call)
        var r1 = SeededGenerator(seed: 5), r2 = SeededGenerator(seed: 5)
        let w1 = s.resampled(from: 2, using: &r1)
        XCTAssertEqual(w1, s.resampled(from: 2, using: &r2))
        // 重采样世界可被引擎完整推进到终局（apply 兼容性；后续街道由重采样 deck 发出）
        var w = w1
        var counter = 0
        while w.street != .handOver, counter < 200 {
            let legal = legalActions(w)
            if legal.canCheck { w.apply(.check) }
            else if legal.canCall { w.apply(.call) }
            else if let r = legal.betRange { w.apply(.raiseTo(r.lowerBound)) }
            else { w.apply(.fold) }
            counter += 1
        }
        XCTAssertEqual(w.street, .handOver)
        XCTAssertEqual(w.board.count, 5)
        XCTAssertEqual(w.players.reduce(0) { $0 + $1.stack }, 1000 * 3)   // 守恒
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build --filter ResampleTests 2>&1 | tail -3`
Expected: FAIL（`resampled`/`Deck(cards:)` 未定义）

- [ ] **Step 3: 实现**

`Deck.swift` 追加（现有 init 不动）：

```swift
    /// 直接持有给定牌（顶部 = 末尾）。供视角重采样重建牌堆，不走洗牌路径。
    init(cards: [Card]) {
        self.cards = cards
    }
```

`Resample.swift`：

```swift
extension GameState {
    /// 从 seat 视角构造平行世界（spec 阶段 2a §4.1）：
    /// 保留 seat 底牌、board 与全部公开状态；对手（凡有底牌者——含已弃牌与终局手淘汰未清牌）
    /// 从未见池均匀重发 2 张；剩余未见牌构成新 deck。产出仅供搜索内部使用，不进 HandHistory。
    public func resampled(from seat: Int, using rng: inout SeededGenerator) -> GameState {
        var world = self
        let visible = Set(players[seat].holeCards).union(board)
        var unseen = (0..<52).map(Card.init(code:)).filter { !visible.contains($0) }
        for i in stride(from: unseen.count - 1, through: 1, by: -1) {
            unseen.swapAt(i, Int(rng.next() % UInt64(i + 1)))
        }
        var idx = 0
        for i in players.indices {
            guard i != seat, !players[i].holeCards.isEmpty else { continue }
            world.players[i].holeCards = [unseen[idx], unseen[idx + 1]]
            idx += 2
        }
        world.deck = Deck(cards: Array(unseen[idx...]))
        return world
    }
}
```

- [ ] **Step 4: 运行确认通过（全量回归）**

Run: `swift test --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build 2>&1 | grep -E "Test Suite 'All tests'|Executed" | tail -2`
Expected: 全绿（52+3 = 55）

- [ ] **Step 5: 提交**

```bash
git add Texas-Hold\'em-poker/PokerEngine
git commit -m "feat: 视角重采样 resampled(from:using:)（未见池均匀重发、含弃牌/终局淘汰者、世界可直接推进）"
```

---

### Task 3: PIMCAI 决策器（档位阶梯 + 根带 UCT + 平手裁决）

**Files:**
- Create: `PokerEngine/Sources/PokerEngine/AI/PIMCAI.swift`
- Test: `PokerEngine/Tests/PokerEngineTests/PIMCAITests.swift`

**Interfaces:**
- Consumes: `PokerAI`、`legalActions/LegalActions/isLegal`、`resampled(from:using:)`、`HeuristicAI`（rollout 默认策略——spec §4.4 的 RolloutPolicy 落点）
- Produces（Task 4/5/6 消费）:
  - `public struct PIMCAI: PokerAI`：
    - `init(worlds: Int, iterationsPerWorld: Int, exploreC: Double = 1.4, timeBudgetMs: Int? = nil, rollout: (any PokerAI)? = nil)`
    - `public static let easy / normal / hard`（8×25@300ms / 16×64@1000ms / 32×125@1500ms）
    - `public var rollout: any PokerAI`（默认 `HeuristicAI(aggression: 0.5)`）
  - `func ladderActions(_ legal: LegalActions, state: GameState) -> [PlayerAction]`（internal 可测；档位序 = [check, call, fold, 最小, ½池, 满池, 全下]，clamp 去重，此序即平手裁决保守优先序）

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import PokerEngine

final class PIMCAITests: XCTestCase {
    func c(_ s: String) -> Card {
        let r = Array(s)[0], su = Array(s)[1]
        let rank = ["2","3","4","5","6","7","8","9","T","J","Q","K","A"].firstIndex(of: String(r))!
        let suit = ["s","h","d","c"].firstIndex(of: String(su))!
        return Card(rank: Rank(rawValue: rank + 2)!, suit: Suit(rawValue: suit)!)
    }
    let cash3 = GameConfig(playerCount: 3, startingStack: 1000, format: .cash(sb: 10, bb: 20))

    func testLadderClampsDedupesAndSinglePoint() {
        let s = GameState.start(config: cash3, seed: 3, buttonSeat: 0)
        let ladder = ladderActions(legalActions(s), state: s)
        XCTAssertTrue(ladder.contains(.call))
        XCTAssertFalse(ladder.contains(.check))          // 面对大盲无 check
        XCTAssertEqual(ladder.first, .call)              // 保守序：call 最优先
        XCTAssertTrue(ladder.contains(.fold))
        for action in ladder {
            if case .raiseTo(let t) = action { XCTAssertTrue((40...1000).contains(t), "t=\(t)") }
            if case .bet(let t) = action { XCTAssertTrue((40...1000).contains(t), "t=\(t)") }
        }
        // 单点区间 → 激进档仅全下一档（Review Focus #3）
        let short = GameState.start(config: cash3, seed: 3, stacks: [25, 1000, 1000], buttonSeat: 0)
        let raises = ladderActions(legalActions(short), state: short).filter {
            if case .raiseTo = $0 { return true }; return false
        }
        XCTAssertEqual(raises, [.raiseTo(25)])
    }

    func testPreflopAANeverFoldsAndTrashFolds() {
        var s = GameState.start(config: cash3, seed: 41, buttonSeat: 0)
        s.players[s.actorSeat!].holeCards = [c("Ah"), c("Ad")]
        let a = PIMCAI.normal.decide(s, seat: s.actorSeat!)
        if case .fold = a { XCTFail("AA 翻前不应弃牌：\(a)") }

        var t = GameState.start(config: cash3, seed: 42, buttonSeat: 0)
        t.players[t.actorSeat!].holeCards = [c("7d"), c("2c")]
        XCTAssertEqual(PIMCAI.easy.decide(t, seat: t.actorSeat!), .fold)
    }

    /// Review Focus #3/#5：12 局随机采样，每手每个决策恒合法；同局面决策确定。
    func testAlwaysLegalAndDeterministic() {
        let cfg = GameConfig(playerCount: 4, startingStack: 1000, format: .cash(sb: 10, bb: 20))
        let ai = PIMCAI(worlds: 4, iterationsPerWorld: 8)
        for seed in UInt64(1)...12 {
            var s = GameState.start(config: cfg, seed: seed * 13)
            while s.street != .handOver {
                let legal = legalActions(s)
                let decision = ai.decide(s, seat: s.actorSeat!)
                XCTAssertTrue(isLegal(decision, in: legal), "seed \(seed): \(decision) vs \(legal)")
                s.apply(decision)
            }
        }
        let s0 = GameState.start(config: cfg, seed: 999)
        XCTAssertEqual(ai.decide(s0, seat: s0.actorSeat!), ai.decide(s0, seat: s0.actorSeat!))
    }

    func testPresetsMatchSpec() {
        XCTAssertEqual(PIMCAI.easy.worlds, 8); XCTAssertEqual(PIMCAI.easy.iterationsPerWorld, 25)
        XCTAssertEqual(PIMCAI.normal.worlds, 16); XCTAssertEqual(PIMCAI.normal.iterationsPerWorld, 64)
        XCTAssertEqual(PIMCAI.hard.worlds, 32); XCTAssertEqual(PIMCAI.hard.iterationsPerWorld, 125)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build --filter PIMCAITests 2>&1 | tail -3`
Expected: FAIL（PIMCAI/ladderActions 未定义）

- [ ] **Step 3: 实现 PIMCAI.swift**

```swift
/// PIMC 搜索型决策器（spec 阶段 2a §4.2/§4.3）：
/// 采样平行世界 × 每世界根带 UCB1 × rollout 至终局 × 跨世界平均 EV；
/// fold 的 EV 结构性为 0（筹码冻结）不发 rollout；时间预算到点完成当前世界即截断。
public struct PIMCAI: PokerAI {
    public var worlds: Int
    public var iterationsPerWorld: Int
    public var exploreC: Double
    public var timeBudgetMs: Int?
    public var rollout: any PokerAI

    public init(worlds: Int, iterationsPerWorld: Int,
                exploreC: Double = 1.4, timeBudgetMs: Int? = nil,
                rollout: (any PokerAI)? = nil) {
        self.worlds = max(1, worlds)
        self.iterationsPerWorld = max(1, iterationsPerWorld)
        self.exploreC = exploreC
        self.timeBudgetMs = timeBudgetMs
        self.rollout = rollout ?? HeuristicAI(aggression: 0.5)
    }

    public static let easy = PIMCAI(worlds: 8, iterationsPerWorld: 25, timeBudgetMs: 300)
    public static let normal = PIMCAI(worlds: 16, iterationsPerWorld: 64, timeBudgetMs: 1000)
    public static let hard = PIMCAI(worlds: 32, iterationsPerWorld: 125, timeBudgetMs: 1500)

    public func decide(_ state: GameState, seat: Int) -> PlayerAction {
        let legal = legalActions(state)
        let ladder = ladderActions(legal, state: state)
        guard ladder.count > 1 else { return ladder.first ?? .fold }

        var rng = SeededGenerator(seed: state.seed &* 0x9E37_79B9_7F4A_7C15
                                    &+ UInt64(state.handNumber)
                                    &+ UInt64(truncatingIfNeeded: seat) &* 97
                                    &+ UInt64(state.actions.count) &* 31)
        let start = Date()
        let myStack = state.players[seat].stack
        var sums = [Double](repeating: 0, count: ladder.count)
        var counts = [Int](repeating: 0, count: ladder.count)

        for _ in 0..<worlds {
            if let budgetMs = timeBudgetMs,
               Date().timeIntervalSince(start) * 1000 > Double(budgetMs) { break }
            let world = state.resampled(from: seat, using: &rng)
            if let fi = ladder.firstIndex(of: .fold) {
                counts[fi] += iterationsPerWorld   // fold EV 恒 0，仅记账不发 rollout
            }
            for _ in 0..<iterationsPerWorld {
                guard let idx = selectRootAction(ladder: ladder, sums: sums, counts: counts,
                                                 total: counts.reduce(0, +)) else { break }
                var w = world
                w.apply(ladder[idx])
                var counter = 0
                while w.street != .handOver, let actor = w.actorSeat, counter < 200 {
                    w.apply(rollout.decide(w, seat: actor))
                    counter += 1
                }
                sums[idx] += Double(w.players[seat].stack - myStack)
                counts[idx] += 1
            }
        }
        var best = ladder.firstIndex(of: .fold) ?? 0   // 全负 EV 时回退 fold（均值 0）
        var bestMean = 0.0                              // fold 基线
        for i in ladder.indices where counts[i] > 0 && ladder[i] != .fold {
            let mean = sums[i] / Double(counts[i])
            if mean > bestMean + 1e-9 { bestMean = mean; best = i }
        }
        return ladder[best]
    }

    /// 根带 UCB1：未试的非 fold 动作优先；随后 mean + c·√(ln N / n)。返回 nil = 无可行动作。
    private func selectRootAction(ladder: [PlayerAction], sums: [Double],
                                  counts: [Int], total: Int) -> Int? {
        for i in ladder.indices where counts[i] == 0 && ladder[i] != .fold { return i }
        var best: Int?; var bestUCB = -Double.infinity
        for i in ladder.indices where counts[i] > 0 && ladder[i] != .fold {
            let mean = sums[i] / Double(counts[i])
            let ucb = mean + exploreC * sqrt(log(Double(max(1, total))) / Double(counts[i]))
            if ucb > bestUCB { bestUCB = ucb; best = i }
        }
        return best
    }
}
```

档位阶梯（同文件 `PIMCAI.swift` 内，internal 供测试）：

```swift
/// 档位阶梯（spec §4.3）：[check, call, fold, 最小, ½池, 满池, 全下] ∩ 合法者，clamp 去重。
/// 数组顺序即平手裁决的保守优先序。
func ladderActions(_ legal: LegalActions, state: GameState) -> [PlayerAction] {
    var acts: [PlayerAction] = []
    if legal.canCheck { acts.append(.check) }
    if legal.canCall { acts.append(.call) }
    acts.append(.fold)
    if let range = legal.betRange {
        let toCall = legal.callAmount
        let half = state.currentBet + (state.potTotal + toCall) / 2
        let pot = state.currentBet + (state.potTotal + toCall)
        var seen = Set<Int>()
        for t in [range.lowerBound, half, pot, range.upperBound] {
            let clamped = min(max(t, range.lowerBound), range.upperBound)
            guard !seen.contains(clamped) else { continue }
            seen.insert(clamped)
            acts.append(legal.isRaiseContext ? .raiseTo(clamped) : .bet(clamped))
        }
    }
    return acts
}
```

- [ ] **Step 4: 运行确认通过（全量回归）**

Run: `swift test --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build 2>&1 | grep -E "Test Suite 'All tests'|Executed" | tail -2`
Expected: 全绿（55+5 = 60；合法性测试若超 5 分钟，种子数 12→6 并在报告注明）

- [ ] **Step 5: 提交**

```bash
git add Texas-Hold\'em-poker/PokerEngine
git commit -m "feat: PIMCAI 搜索决策器（视角采样×根带UCB1×档位阶梯×保守平手裁决×时间预算截断）"
```

---

### Task 4: Battle 评测核心（async 并发对战 + 统计）

**Files:**
- Create: `PokerEngine/Sources/PokerEngine/AI/Battle.swift`
- Test: `PokerEngine/Tests/PokerEngineTests/BattleTests.swift`

**Interfaces:**
- Consumes: `PokerAI`、`GameState.start/apply`、`PIMCAI`、`HeuristicAI`
- Produces（Task 5/7 消费）:
  - `public struct HandOutcome: Equatable, Sendable { let handIndex: Int; let seatDeltas: [Int] }`
  - `public struct BattleReport: Equatable, Sendable { let hands: Int; let perSeatBB100: [Double]; let perSeatCI: [Double] }`
  - `public enum BattleTable { case headsUp, sixMax }`（人数 2/6；筹码 10000；盲注 10/20；每手独立重置）
  - `public func runBattle(a: any PokerAI, b: any PokerAI, table: BattleTable, hands: Int, seedBase: UInt64, concurrency: Int) async -> [HandOutcome]`
    - 座位轮换：a 的起始席位 = handIndex % n（headsUp 即偶手 seat0）；手种子 = `seedBase &+ UInt64(truncatingIfNeeded: handIndex)`——与执行顺序无关（Review Focus #4）
    - 并发 = TaskGroup 分段（Swift 6 严格并发安全）
  - `public func summarizeBattle(_ outcomes: [HandOutcome]) -> BattleReport`（per-seat bb/100 与 ±95% CI）

- [ ] **Step 1: 写失败测试**

```swift
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
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build --filter BattleTests 2>&1 | tail -3`
Expected: FAIL（Battle API 未定义）

- [ ] **Step 3: 实现 Battle.swift**

```swift
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

public enum BattleTable {
    case headsUp, sixMax
    var playerCount: Int { self == .headsUp ? 2 : 6 }
}

/// 无头对战（spec §5）：每手独立重置（现金局 10000 筹码、盲注 10/20）。
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
            group.addTask {
                (lo..<hi).map { playOneHand(a: a, b: b, table: table, handIndex: $0, seedBase: seedBase) }
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
    var s = GameState.start(config: GameConfig(playerCount: n, startingStack: 10_000,
                                               format: .cash(sb: 10, bb: 20)),
                            seed: seedBase &+ UInt64(truncatingIfNeeded: handIndex),
                            stacks: Array(repeating: 10_000, count: n),
                            buttonSeat: (handIndex / n) % n)
    var counter = 0
    while s.street != .handOver, let actor = s.actorSeat, counter < 500 {
        let ai = ((actor - rotate + n) % n) % 2 == 0 ? a : b
        s.apply(ai.decide(s, seat: actor))
        counter += 1
    }
    return HandOutcome(handIndex: handIndex,
                       seatDeltas: (0..<n).map { s.players[$0].stack - 10_000 })
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
```

- [ ] **Step 4: 运行确认通过（全量回归）**

Run: `swift test --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build 2>&1 | grep -E "Test Suite 'All tests'|Executed" | tail -2`
Expected: 全绿（60+5 = 65；BattleTests 均为启发式/构造对局，秒级）

- [ ] **Step 5: 提交**

```bash
git add Texas-Hold\'em-poker/PokerEngine
git commit -m "feat: Battle 评测核心（每手独立现金局、座位轮换、TaskGroup 并发与种子解耦、bb/100±95%CI）"
```

---

### Task 5: AIConsole 命令行（battle / bench）

**Files:**
- Create: `PokerEngine/Sources/AIConsole/main.swift`
- Modify: `PokerEngine/Package.swift`（executable target）
- Modify: `PokerApp/README.md`（AIConsole 用法一节）

**Interfaces:**
- Consumes: `runBattle`（async）、`PIMCAI` 预设、`HeuristicAI`
- Produces（Task 7 验收消费）:
  - `swift run AIConsole battle --a <spec> --b <spec> --table hu|six --hands N [--seed S] [--concurrency C]`
    - AI spec：`heuristic:<aggression>`、`pimc:easy|normal|hard`
    - 输出末三行：`hands=...`、`bb/100[a-spec]=+X.XX ±Y.YY`、`bb/100[b-spec]=...`（按 a/b 聚合：a 的座位 = handIndex % n，与 runBattle 约定一致）
  - `swift run AIConsole bench --ai pimc:hard --hands 100 [--seed S]`：输出 `decisions=N mean=X.Xms p95=X.Xms totalSims=M sims/s=K`

- [ ] **Step 1: 实现（CLI 无 TDD；核心已由 Task 4 覆盖，验收 = 构建 + 冒烟）**

`Package.swift` targets 数组追加：

```swift
        .executableTarget(
            name: "AIConsole",
            dependencies: ["PokerEngine"],
            path: "Sources/AIConsole"
        ),
```

`main.swift`：

```swift
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
func flag(_ name: String, default def: String) -> String {
    if let i = args.firstIndex(of: name), i + 1 < args.count {
        let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
    }
    return def
}

let sub = args.first ?? "battle"; args.removeFirst()
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
    guard let a = makeAI(aSpec) else { print("unknown ai"); exit(2) }
    var s = GameState.start(config: GameConfig(playerCount: 2, startingStack: 10_000,
                                               format: .cash(sb: 10, bb: 20)), seed: seed)
    var times: [Double] = []
    var sims = 0
    loop: for _ in 0..<hands {
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
    print("usage: AIConsole battle|bench --a pimc:normal --b heuristic:0.5 --table hu|six --hands N --seed S --concurrency C")
}
```

`PokerApp/README.md` 追加：

```markdown
## AIConsole（AI 评测）

cd PokerEngine 后：

    swift run AIConsole battle --a pimc:normal --b heuristic:0.5 --table hu --hands 20000 --concurrency 8
    swift run AIConsole bench --ai pimc:hard --hands 100
```

- [ ] **Step 2: 构建 + 冒烟**

Run:
```bash
swift build --package-path Texas-Hold\'em-poker/PokerEngine --scratch-path /tmp/poker-build --product AIConsole 2>&1 | tail -2
swift run --package-path Texas-Hold\'em-poker/PokerEngine --scratch-path /tmp/poker-build AIConsole battle --a heuristic:0.5 --b heuristic:0.3 --table hu --hands 200 --seed 7 --concurrency 1 2>&1 | tail -3
swift run --package-path Texas-Hold\'em-poker/PokerEngine --scratch-path /tmp/poker-build AIConsole battle --a pimc:easy --b heuristic:0.5 --table hu --hands 50 --seed 11 2>&1 | tail -2
```
Expected: BUILD SUCCEEDED；两场输出 bb/100 三行格式正确（内战近 0±CI；pimc:easy 50 手仅验可运行）

- [ ] **Step 3: 全量回归 + 提交**

Run: `swift test --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build 2>&1 | grep -E "Executed" | tail -1`
Expected: 65 全绿

```bash
git add Texas-Hold\'em-poker
git commit -m "feat: AIConsole 评测 CLI（battle bb/100±CI / bench 吞吐，async 并发与种子解耦）"
```

---

### Task 6: App 集成（AI 难度档）

**Files:**
- Modify: `PokerApp/PokerApp/GameViewModel.swift`（AIDifficulty 枚举 + init 新参带默认值）
- Modify: `PokerApp/PokerApp/MenuView.swift`（难度 Picker，onStart 扩为三元组）
- Modify: `PokerApp/PokerApp/PokerApp.swift`（GameSession 带难度、调用点同步）

**Interfaces:**
- Consumes: `PIMCAI.easy/.normal/.hard`、`HeuristicAI`
- Produces:
  - `enum AIDifficulty: String, CaseIterable, Identifiable { case baseline, easy, normal, hard; func bots(humanSeat:playerCount:) -> [Int: any PokerAI]? }`（baseline 返回 nil → VM 默认 HeuristicAI 全员）
  - `GameViewModel.init(config:seed:bots:thinkMilliseconds:ai:)`（`ai: AIDifficulty = .baseline` 默认值保证旧调用与测试零改动）
  - `GameSession` 增 `var difficulty: AIDifficulty = .baseline`；`MenuView.onStart: (GameConfig, UInt64, AIDifficulty) -> Void`

- [ ] **Step 1: 修改三个 App 文件（UI 无 TDD；验收 = 构建 + 既有测试回归）**

`GameViewModel.swift` 追加枚举，init 追加参数（其余代码不动）：

```swift
enum AIDifficulty: String, CaseIterable, Identifiable {
    case baseline = "基线（启发式）"
    case easy = "轻松"
    case normal = "普通"
    case hard = "困难"
    var id: String { rawValue }

    /// nil → 沿用 VM 默认（全员 HeuristicAI）
    func bots(humanSeat: Int, playerCount: Int) -> [Int: any PokerAI]? {
        let pimc: PIMCAI?
        switch self {
        case .baseline: return nil
        case .easy: pimc = PIMCAI.easy
        case .normal: pimc = PIMCAI.normal
        case .hard: pimc = PIMCAI.hard
        }
        guard let ai = pimc else { return nil }
        return Dictionary(uniqueKeysWithValues:
            (0..<playerCount).filter { $0 != humanSeat }.map { ($0, ai as any PokerAI) })
    }
}
```

init 改为（仅首尾两行变化）：

```swift
    init(config: GameConfig, seed: UInt64,
         bots: [Int: any PokerAI]? = nil, thinkMilliseconds: Int = 700,
         ai: AIDifficulty = .baseline) {
        state = .start(config: config, seed: seed)
        let defaults: [Int: any PokerAI] = Dictionary(uniqueKeysWithValues:
            (0..<config.playerCount).filter { $0 != config.humanSeat }
                .map { ($0, HeuristicAI(aggression: 0.5) as any PokerAI) })
        self.bots = bots ?? ai.bots(humanSeat: config.humanSeat, playerCount: config.playerCount) ?? defaults
        thinkNanos = UInt64(max(1, thinkMilliseconds)) * 1_000_000
    }
```

`MenuView.swift`：`@State private var difficulty: AIDifficulty = .baseline`；Form 内（模式 Picker 之后）追加：

```swift
                Picker("AI 难度", selection: $difficulty) {
                    ForEach(AIDifficulty.allCases) { Text($0.rawValue).tag($0) }
                }
```

`onStart` 类型改为 `(GameConfig, UInt64, AIDifficulty) -> Void`，「开始游戏」按钮改 `onStart(config, UInt64(Date().timeIntervalSince1970 * 1000), difficulty)`。

`PokerApp.swift`：`GameSession` 增 `var difficulty: AIDifficulty = .baseline`；构造处 `GameSession(config: config, seed: seed, difficulty: difficulty)`（MenuView 闭包第三参）；GameView 构造处 `_vm = StateObject(wrappedValue: GameViewModel(config: session.config, seed: session.seed, ai: session.difficulty))`。注意闭包内如有对 session 的赋值需 `self.`（Swift 6.4 尾闭包崩溃规避，环境备忘）。

- [ ] **Step 2: 构建与回归**

Run:
```bash
cd Texas-Hold\'em-poker/PokerApp && /tmp/xcodegen-dist/xcodegen/bin/xcodegen generate
xcodebuild -project PokerApp.xcodeproj -scheme PokerApp -destination 'platform=macOS' -derivedDataPath /tmp/poker-dd build 2>&1 | tail -2
xcodebuild test -project PokerApp.xcodeproj -scheme PokerApp -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/poker-dd 2>&1 | tail -2
swift test --package-path ../PokerEngine --scratch-path /tmp/poker-build 2>&1 | grep Executed | tail -1
```
Expected: BUILD SUCCEEDED；TEST SUCCEEDED（3/3，默认参数零破坏）；引擎 65 全绿

- [ ] **Step 3: 提交**

```bash
git add Texas-Hold\'em-poker/PokerApp
git commit -m "feat: App 接入 AI 难度档（基线/轻松/普通/困难，GameViewModel 默认参数零破坏）"
```

---

### Task 7: 验收（bench 实测 → 500 手方向战 → 20k 手正式验收）

**Files:**
- Create: `Texas-Hold'em-poker/docs/superpowers/phase2a-acceptance.md`

**Interfaces:**
- Consumes: AIConsole（Task 5）、spec §1 验收线、spec §8 性能预算
- Produces: 验收证据文档（吞吐实测、500 手方向战、20k 手正式 battle 判读）

- [ ] **Step 1: bench 实测（性能预算门）**

Run: `swift run --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build AIConsole bench --ai pimc:hard --hands 100 --seed 3 2>&1 | tail -1`
Expected: 记录 mean/p95/sims-per-sec 入验收文档。门线：pimc:normal 折算单决策均值 ≤ 1000ms（spec §4.5）；超线 → 回 Task 3 按 spec §8 做画像驱动优化（rollout 档位缓存等），不得跳过。

- [ ] **Step 2: 500 手方向战（分钟级参考，不作判据）**

Run: `swift run --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build AIConsole battle --a pimc:normal --b heuristic:0.5 --table hu --hands 500 --seed 2026 2>&1 | tail -2`
Expected: 记录结果（样本小，CI 必含 0 亦正常）。

- [ ] **Step 3: 20k 手正式验收（后台长跑）**

Run（后台，输出重定向；预计墙钟与 bench 实测挂钩，正常应在 1-6 小时内）:
```bash
cd Texas-Hold\'em-poker && nohup swift run --package-path PokerEngine --scratch-path /tmp/poker-build AIConsole battle --a pimc:normal --b heuristic:0.5 --table hu --hands 20000 --seed 1 --concurrency $(sysctl -n hw.ncpu) > /tmp/poker-battle-20k.log 2>&1 &
```
判据（spec §1 验收线）：`bb/100[pimc:normal] ≥ +5` 且 `bb/100 - CI > 0`。CI 过宽不含结论 → 按 spec §10 扩到 50000 手重跑一次。墙钟 > 6h → 回 Task 3 优化吞吐后重跑（不降验收口径）。
执行者用后台任务机制跟踪该进程，完成后把日志尾部（末三行）与判读写入 `phase2a-acceptance.md`。

- [ ] **Step 4: 提交验收文档**

```bash
git add Texas-Hold\'em-poker/docs/superpowers/phase2a-acceptance.md
git commit -m "test: 阶段2a 验收证据（bench 吞吐/500 手方向战/20k 手 bb100 正式验收）"
```

---

## 任务依赖

- T1、T2 独立；T3 依赖 T1+T2；T4 依赖 T3（用 PIMCAI 与合法性基础设施）；T5 依赖 T4；T6 依赖 T3；T7 依赖 T5（+T6 完成后收尾）。
- 每任务全量回归（49→52→55→60→65），App 任务另跑双平台构建+模拟器测试。
- 环境备忘（执行者必读）：无 brew；xcodegen 在 `/tmp/xcodegen-dist/xcodegen/bin/xcodegen`（缺失从 yonaskolb/XcodeGen releases 重下）；iCloud 路径必须 `--scratch-path`/`-derivedDataPath`；模拟器 iPhone 17；闭包内对属性赋值写 `self.`（Swift 6.4 编译器崩溃规避）。
- 提交信息中文，一任务一提交，不混合多任务改动。
