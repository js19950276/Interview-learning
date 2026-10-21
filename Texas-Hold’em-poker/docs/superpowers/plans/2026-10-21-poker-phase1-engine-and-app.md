# 德州扑克第 1 期实施计划（引擎 + 单机可玩版）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现纯逻辑扑克引擎（现金局 + SNG，Reducer 状态机）并交付 SwiftUI 单机 App（iOS 主目标 + macOS）。

**Architecture:** 引擎是独立 Swift Package `PokerEngine`（纯值类型、可播种 RNG、确定性重放）；App 通过 `GameViewModel` 持有引擎状态快照并分发 action，AI 在后台队列决策。对局间逻辑（升盲/淘汰/奖金）由 `GameFormat` 配置驱动。

**Tech Stack:** Swift 6 / SwiftUI / XCTest；引擎与 App 均**零第三方依赖**；App 工程用 xcodegen 生成（`project.yml` 入库）。

**Spec:** `Texas-Hold'em-poker/docs/superpowers/specs/2026-10-21-poker-phase1-engine-and-app-design.md`

## Global Constraints

- Swift tools version 6.0；`swift test --package-path PokerEngine` 每任务全绿后才可提交。
- 引擎零第三方依赖，且**不得 import SwiftUI / Combine / UIKit / AppKit**（仅 Foundation）。
- 部署目标：iOS 18.0 / macOS 15.0。
- 所有金额为 `Int` 筹码；SNG 奖金 `Int(rate * pool)` 向下取整，**余数全部给第 1 名**。
- 人数 2–9；单挑局按钮=小盲、翻前按钮先行动、翻后按钮后行动。
- 不足额 all-in 加注**不重开**已闭合的加注轮（spec §4.3 家规）。
- 平分池奇数筹码给按钮顺时针下一位方向的最近赢家。
- 同 seed + 同动作序列 ⇒ 逐字段相同的牌局（自定义 `==` 忽略 RNG 内部状态）。
- 每任务结束必须**全量** `swift test --package-path PokerEngine` 回归（不只跑当任务 filter）。
- 每任务一次提交，提交信息中文、格式 `feat/fix/test: 描述`。
- 目录结构按 spec §3（Cards/ HandEval/ Game/ Formats/ AI/ Replay/）。

## Review Focus

1. **轮子顺 A-2-3-4-5（及同花版本）评错成高牌/普通顺** → Task 2 专项测试钉住（A 当 5 用、A-5 同花顺按 5 高同花顺、低于 6 高同花顺）。
2. **不足额 all-in 误重开加注轮**（违反家规）→ Task 6 专项测试：下注后对方短码全下加注，原下注者 `betRange` 必须为 nil。
3. **边池分层遇弃牌者死钱/未被跟注超额时算错** → Task 7 专项：未跟注的 500 形成仅自己 eligible 的顶层并退回。
4. **同手多人淘汰的名次排序与奖金取整余数** → Task 8 专项：手初筹码高者名次靠前；333×3 买入奖金池取整余数 2 归冠军（501/299/199）。
5. **AI 在不能加注时（betRange 为 nil，筹码仅够跟注）仍返回加注** → Task 10 合法性性质测试采样 50 局，显式断言覆盖过该局面。

---

### Task 1: Package 脚手架 + 卡牌 + 可播种 RNG + 牌堆

**Files:**
- Create: `PokerEngine/Package.swift`
- Create: `PokerEngine/Sources/PokerEngine/Cards/Card.swift`
- Create: `PokerEngine/Sources/PokerEngine/Cards/SeededGenerator.swift`
- Create: `PokerEngine/Sources/PokerEngine/Cards/Deck.swift`
- Test: `PokerEngine/Tests/PokerEngineTests/CardDeckTests.swift`

**Interfaces:**
- Consumes: 无（首个任务）
- Produces（后续所有任务依赖）:
  - `enum Suit: Int, CaseIterable, Sendable, Hashable, Comparable { case spade=0, heart=1, diamond=2, club=3 }`
  - `enum Rank: Int, CaseIterable, Sendable, Hashable, Comparable { case two=2 … case ace=14 }`
  - `struct Card: Hashable, Sendable, Codable, CustomStringConvertible { let rank: Rank; let suit: Suit; var code: Int; init(code: Int); init(rank:suit:) }`（`code = rank.rawValue * 4 + suit.rawValue`；`description` 如 "A♠"）
  - `struct SeededGenerator: RandomNumberGenerator, Sendable { init(seed: UInt64); mutating func next() -> UInt64 }`（SplitMix64）
  - `struct Deck: Equatable, Sendable { init(rng: inout any RandomNumberGenerator); mutating func draw() -> Card; var count: Int; func peekTop() -> Card? }`（52 张 Fisher-Yates，从顶部摸牌）

- [ ] **Step 1: 写 Package.swift 与失败测试**

`PokerEngine/Package.swift`：

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PokerEngine",
    targets: [
        .target(name: "PokerEngine"),
        .testTarget(name: "PokerEngineTests", dependencies: ["PokerEngine"]),
    ]
)
```

`CardDeckTests.swift`：

```swift
import XCTest
@testable import PokerEngine

final class CardDeckTests: XCTestCase {
    func testCardEncodingRoundTrip() {
        for code in 0..<52 {
            let card = Card(code: code)
            XCTAssertEqual(card.code, code)
            XCTAssertEqual(Card(rank: card.rank, suit: card.suit), card)
        }
    }

    func testRankSuitBasics() {
        let aceSpades = Card(rank: .ace, suit: .spade)
        XCTAssertEqual(aceSpades.rank.rawValue, 14)
        XCTAssertEqual(aceSpades.suit, .spade)
        XCTAssertTrue(Rank.two < Rank.ace)
        XCTAssertEqual(Suit.allCases.count, 4)
        XCTAssertEqual(Rank.allCases.count, 13)
    }

    func testSeededGeneratorDeterministic() {
        var a = SeededGenerator(seed: 42)
        var b = SeededGenerator(seed: 42)
        var c = SeededGenerator(seed: 43)
        let sa = (0..<8).map { _ in a.next() }
        let sb = (0..<8).map { _ in b.next() }
        let sc = (0..<8).map { _ in c.next() }
        XCTAssertEqual(sa, sb)
        XCTAssertNotEqual(sa, sc)
    }

    func testDeckHas52UniqueCardsInStableOrderPerSeed() {
        var rng1 = SeededGenerator(seed: 7)
        var rng2 = SeededGenerator(seed: 7)
        let deck1 = Deck(rng: &rng1)
        var d1 = deck1
        var d2 = Deck(rng: &rng2)
        XCTAssertEqual(d1.count, 52)
        var seen = Set<Card>()
        while d1.count > 0 { seen.insert(d1.draw()) }
        XCTAssertEqual(seen.count, 52)
        XCTAssertEqual(d2.draw(), deck1.peekTop())
    }

    func testDeckEqualityComparesRemainingOrder() {
        var rngA = SeededGenerator(seed: 9)
        var rngB = SeededGenerator(seed: 9)
        var a = Deck(rng: &rngA)
        var b = Deck(rng: &rngB)
        XCTAssertEqual(a, b)
        _ = a.draw()
        XCTAssertNotEqual(a, b)
        _ = b.draw()
        XCTAssertEqual(a, b)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --package-path PokerEngine --filter CardDeckTests 2>&1 | tail -5`
Expected: FAIL（编译错误：找不到 `Card`/`Deck`/`SeededGenerator`。Swift TDD 的 RED 常以编译失败呈现，视为失败）

- [ ] **Step 3: 实现**

`Card.swift`：

```swift
/// 花色。原始值即 Card 整数编码的低 2 位。
public enum Suit: Int, CaseIterable, Sendable, Hashable, Comparable {
    case spade = 0, heart = 1, diamond = 2, club = 3
    public static func < (lhs: Suit, rhs: Suit) -> Bool { lhs.rawValue < rhs.rawValue }
    var symbol: String { ["♠", "♥", "♦", "♣"][rawValue] }
}

/// 点数。2…14，A=14（轮子顺中另按 1 处理，见 HandEvaluator）。
public enum Rank: Int, CaseIterable, Sendable, Hashable, Comparable {
    case two = 2, three, four, five, six, seven, eight, nine, ten, jack, queen, king, ace
    public static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.rawValue < rhs.rawValue }
    var symbol: String {
        switch self {
        case .ace: return "A"; case .king: return "K"; case .queen: return "Q"
        case .jack: return "J"; case .ten: return "T"
        default: return String(rawValue)
        }
    }
}

/// 一张牌，0-51 整数编码（rank*4+suit）。
public struct Card: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rank: Rank
    public let suit: Suit
    public var code: Int { rank.rawValue * 4 + suit.rawValue }
    public init(code: Int) {
        precondition((0..<52).contains(code), "card code out of range")
        rank = Rank(rawValue: code / 4)!
        suit = Suit(rawValue: code % 4)!
    }
    public init(rank: Rank, suit: Suit) { self.rank = rank; self.suit = suit }
    public var description: String { rank.symbol + suit.symbol }
}
```

`SeededGenerator.swift`：

```swift
/// SplitMix64：确定性、质量足够、实现极小。引擎所有随机性的唯一来源。
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
```

`Deck.swift`：

```swift
/// 洗好的 52 张牌堆，从顶部摸牌。
public struct Deck: Equatable, Sendable {
    public private(set) var cards: [Card]
    public var count: Int { cards.count }

    public init(rng: inout any RandomNumberGenerator) {
        cards = (0..<52).map(Card.init(code:))
        // Fisher-Yates，从尾部往前换
        for i in stride(from: 51, through: 1, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            cards.swapAt(i, j)
        }
    }

    public mutating func draw() -> Card { cards.removeLast() }

    /// 仅供测试偷看顶牌。
    public func peekTop() -> Card? { cards.last }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --package-path PokerEngine --filter CardDeckTests 2>&1 | tail -5`
Expected: PASS（5 个测试全绿）

- [ ] **Step 5: 提交**

```bash
git add PokerEngine
git commit -m "feat: 引擎脚手架与卡牌系统（Card/Rank/Suit、SplitMix64 可播种 RNG、Fisher-Yates 牌堆）"
```

---

### Task 2: HandRank 与 7 张牌型判定器

**Files:**
- Create: `PokerEngine/Sources/PokerEngine/HandEval/HandRank.swift`
- Create: `PokerEngine/Sources/PokerEngine/HandEval/HandEvaluator.swift`
- Test: `PokerEngine/Tests/PokerEngineTests/HandEvaluatorTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `Card` / `Rank` / `Suit`
- Produces:
  - `enum HandCategory: Int, CaseIterable, Sendable, Comparable, Codable { case highCard=0, onePair=1, twoPair=2, threeOfAKind=3, straight=4, flush=5, fullHouse=6, fourOfAKind=7, straightFlush=8 }`
  - `struct HandRank: Comparable, Equatable, Sendable, Codable, CustomStringConvertible { let category: HandCategory; let tiebreakers: [Int]; var value: Int }`（tiebreakers 恒 5 个降序点数，不足补 0）
  - `enum HandEvaluator { static func evaluate(_ cards: [Card]) -> HandRank }`（接受 5–7 张；直接法：点数直方图 + 花色桶 + 顺子检测）

- [ ] **Step 1: 写失败测试（含性质测试）**

```swift
import XCTest
@testable import PokerEngine

final class HandEvaluatorTests: XCTestCase {
    // 便捷构造："As" = A♠
    func c(_ s: String) -> Card {
        let r = Array(s)[0], su = Array(s)[1]
        let rank = ["2","3","4","5","6","7","8","9","T","J","Q","K","A"].firstIndex(of: String(r))!
        let suit = ["s","h","d","c"].firstIndex(of: String(su))!
        return Card(rank: Rank(rawValue: rank + 2)!, suit: Suit(rawValue: suit)!)
    }
    func cards(_ s: String) -> [Card] { s.split(separator: " ").map { c(String($0)) } }

    func testCategoryOrdering() {
        let royal = cards("As Ks Qs Js Ts")
        let quads = cards("9c 9d 9h 9s 2c")
        let boat  = cards("8c 8d 8h Kc Kd")
        let flush = cards("Ah Th 7h 5h 2h")
        let straight = cards("9c 8d 7h 6s 5c")
        let trips = cards("7c 7d 7h Kc 2d")
        let twoPair = cards("Kc Kd 7h 7s 3c")
        let pair = cards("Ac Ad Kc 9h 5d")
        let high = cards("Ac Jd 8h 5c 3d")
        XCTAssertGreaterThan(HandEvaluator.evaluate(royal).value, HandEvaluator.evaluate(quads).value)
        XCTAssertGreaterThan(HandEvaluator.evaluate(quads).value, HandEvaluator.evaluate(boat).value)
        XCTAssertGreaterThan(HandEvaluator.evaluate(boat).value, HandEvaluator.evaluate(flush).value)
        XCTAssertGreaterThan(HandEvaluator.evaluate(flush).value, HandEvaluator.evaluate(straight).value)
        XCTAssertGreaterThan(HandEvaluator.evaluate(straight).value, HandEvaluator.evaluate(trips).value)
        XCTAssertGreaterThan(HandEvaluator.evaluate(trips).value, HandEvaluator.evaluate(twoPair).value)
        XCTAssertGreaterThan(HandEvaluator.evaluate(twoPair).value, HandEvaluator.evaluate(pair).value)
        XCTAssertGreaterThan(HandEvaluator.evaluate(pair).value, HandEvaluator.evaluate(high).value)
        XCTAssertEqual(HandEvaluator.evaluate(royal).category, .straightFlush)
    }

    func testWheelStraightAndSteelWheel() {
        // A-2-3-4-5 是 5 高顺子，不是高牌
        let wheel = HandEvaluator.evaluate(cards("Ah 2c 3d 4s 5h"))
        XCTAssertEqual(wheel.category, .straight)
        XCTAssertEqual(wheel.tiebreakers[0], 5)
        // A-5 同花顺按 5 高同花顺，且低于 6 高同花顺
        let steel = HandEvaluator.evaluate(cards("Ah 2h 3h 4h 5h"))
        let sixHigh = HandEvaluator.evaluate(cards("6h 2h 3h 4h 5h"))
        XCTAssertEqual(steel.category, .straightFlush)
        XCTAssertEqual(steel.tiebreakers[0], 5)
        XCTAssertLessThan(steel.value, sixHigh.value)
        // A 高顺（TJQKA）高于轮子
        let broadway = HandEvaluator.evaluate(cards("Ah Kc Qd Js Tc"))
        XCTAssertEqual(broadway.tiebreakers[0], 14)
    }

    func testKickerComparisons() {
        let a = HandEvaluator.evaluate(cards("Ac Ad Kc 9h 5d"))   // 一对 A，踢 K-9-5
        let b = HandEvaluator.evaluate(cards("Ah As Qc 9h 5d"))   // 一对 A，踢 Q-9-5
        XCTAssertGreaterThan(a.value, b.value)
        let twoPairLowKicker = HandEvaluator.evaluate(cards("Kc Kd 7h 7s 2c"))
        let twoPairHighKicker = HandEvaluator.evaluate(cards("Kc Kd 7h 7s Ac"))
        XCTAssertGreaterThan(twoPairHighKicker.value, twoPairLowKicker.value)
    }

    func testSevenCardsPickBestFive() {
        // 两对在场但成顺更大
        XCTAssertEqual(HandEvaluator.evaluate(cards("Ah 2c 3d 4s 5h 9c 9d")).category, .straight)
        // 公共牌四条：任何底牌都是四条
        XCTAssertEqual(HandEvaluator.evaluate(cards("9c 9d 9h 9s 2c Ah Kd")).category, .fourOfAKind)
    }

    // 性质测试：直接法必须与参考暴力实现（21 种 5 张组合取最大）一致
    func testEvaluateMatchesBruteForceOnRandomDeals() {
        var rng = SeededGenerator(seed: 20261021)
        func bruteForce7(_ seven: [Card]) -> HandRank {
            var best: HandRank?
            for i in 0..<7 {
                for j in (i + 1)..<7 {
                    let five = seven.enumerated().filter { $0.offset != i && $0.offset != j }.map(\.element)
                    let r = HandEvaluator.evaluate(five)
                    if best == nil || r.value > best!.value { best = r }
                }
            }
            return best!
        }
        for _ in 0..<2_000 {
            var deck = Deck(rng: &rng)
            let seven = (0..<7).map { _ in deck.draw() }
            XCTAssertEqual(HandEvaluator.evaluate(seven).value, bruteForce7(seven).value,
                           "mismatch on \(seven.map(\.description).joined(separator: " "))")
        }
    }

    func testTiebreakersPaddedToFive() {
        XCTAssertEqual(HandEvaluator.evaluate(cards("Ah Kc Qd Js Tc")).tiebreakers.count, 5)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --package-path PokerEngine --filter HandEvaluatorTests 2>&1 | tail -5`
Expected: FAIL（找不到 `HandRank` / `HandEvaluator`）

- [ ] **Step 3: 实现**

`HandRank.swift`：

```swift
public enum HandCategory: Int, CaseIterable, Sendable, Comparable, Codable {
    case highCard = 0, onePair, twoPair, threeOfAKind, straight, flush, fullHouse, fourOfAKind, straightFlush
    public static func < (lhs: HandCategory, rhs: HandCategory) -> Bool { lhs.rawValue < rhs.rawValue }
    var name: String {
        ["高牌", "一对", "两对", "三条", "顺子", "同花", "葫芦", "四条", "同花顺"][rawValue]
    }
}

/// 可整体比较的牌力：类别 + 恒定 5 个降序踢脚，编码成单个 Int。
public struct HandRank: Comparable, Equatable, Sendable, Codable, CustomStringConvertible {
    public let category: HandCategory
    public let tiebreakers: [Int]   // 恒 5 个，降序，缺位补 0
    public var value: Int {
        var v = category.rawValue
        for t in tiebreakers { v = (v << 4) | min(t, 14) }
        return v
    }
    public init(_ category: HandCategory, _ tiebreakers: [Int]) {
        self.category = category
        var t = Array(tiebreakers.prefix(5))
        while t.count < 5 { t.append(0) }
        self.tiebreakers = t
    }
    public static func < (lhs: HandRank, rhs: HandRank) -> Bool { lhs.value < rhs.value }
    public var description: String {
        let cards = tiebreakers.filter { $0 > 0 }.map { Rank(rawValue: $0)!.symbol }
        return category.name + " " + cards.joined(separator: "-")
    }
}
```

`HandEvaluator.swift`：

```swift
public enum HandEvaluator {
    /// 评估 5–7 张牌的最优 5 张牌型。
    public static func evaluate(_ cards: [Card]) -> HandRank {
        precondition((5...7).contains(cards.count))
        let ranks = cards.map { $0.rank.rawValue }          // 2...14
        let rankCounts = Dictionary(ranks.map { ($0, 1) }, uniquingKeysWith: +)
        let byCount = Dictionary(grouping: rankCounts.filter { $0.value > 1 }) { $0.value }
        let quads = (byCount[4] ?? []).map(\.key).sorted(by: >)
        let trips = (byCount[3] ?? []).map(\.key).sorted(by: >)
        let pairs = (byCount[2] ?? []).map(\.key).sorted(by: >)

        // 同花 / 同花顺：任一花色 ≥5 张（同花顺是全局最大，直接返回）
        var flushRank: HandRank?
        for suit in Suit.allCases {
            let suited = cards.filter { $0.suit == suit }.map { $0.rank.rawValue }
            if suited.count >= 5 {
                let desc = suited.sorted(by: >)
                if let high = straightHigh(in: desc) {
                    return .init(.straightFlush, [high])
                }
                flushRank = .init(.flush, Array(desc.prefix(5)))
            }
        }

        if let q = quads.first {
            let kicker = ranks.filter { $0 != q }.max() ?? 0
            return .init(.fourOfAKind, [q, kicker])
        }
        // 葫芦：三条 + 对子（两个三条时较小者当对子）
        if let t = trips.first {
            let pairForBoat = pairs.first ?? trips.dropFirst().first?.key
            if let p = pairForBoat { return .init(.fullHouse, [t, p]) }
        }
        if let f = flushRank { return f }
        if let high = straightHigh(in: ranks) {
            return .init(.straight, [high])
        }
        if let t = trips.first {
            let kickers = ranks.filter { $0 != t }.sorted(by: >)
            return .init(.threeOfAKind, [t] + kickers.prefix(2))
        }
        if pairs.count >= 2 {
            let kick = ranks.filter { $0 != pairs[0] && $0 != pairs[1] }.max() ?? 0
            return .init(.twoPair, [pairs[0], pairs[1], kick])
        }
        if let p = pairs.first {
            let kickers = ranks.filter { $0 != p }.sorted(by: >)
            return .init(.onePair, [p] + kickers.prefix(3))
        }
        return .init(.highCard, ranks.sorted(by: >))
    }

    /// 给一组点数（可含重复），返回最高顺子的最高张；A 可当 1（轮子顺）。无顺子返回 nil。
    static func straightHigh(in ranks: [Int]) -> Int? {
        var present = Set(ranks)
        if present.contains(14) { present.insert(1) }
        for high in stride(from: 14, through: 5, by: -1) {
            let low = high - 4
            if (low...high).allSatisfy({ present.contains($0) }) { return high }
        }
        return nil
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --package-path PokerEngine --filter HandEvaluatorTests 2>&1 | tail -5`
Expected: PASS（6 个测试全绿，含 2000 次随机对比）

- [ ] **Step 5: 提交**

```bash
git add PokerEngine
git commit -m "feat: 牌型判定器（整数编码 HandRank、轮子顺/同花顺、5-7 张直接法 + 暴力参考性质测试）"
```

---

### Task 3: 对局形式与配置类型（现金局/SNG、盲注调度）

**Files:**
- Create: `PokerEngine/Sources/PokerEngine/Formats/GameFormat.swift`
- Test: `PokerEngine/Tests/PokerEngineTests/FormatsTests.swift`

**Interfaces:**
- Consumes: 无新依赖
- Produces（Task 4/5/8/10 依赖）:
  - `struct BlindLevel: Equatable, Sendable, Codable { let sb: Int; let bb: Int; let hands: Int; init(sb:bb:hands:) }`
  - `struct SNGConfig: Equatable, Sendable, Codable { var buyIn: Int; var startingStack: Int; var levels: [BlindLevel]; var payouts: [Double] }`（`payouts` 名次比例降序、总和须为 1）
  - `enum GameFormat: Equatable, Sendable, Codable { case cash(sb: Int, bb: Int); case sng(SNGConfig) }`
  - `struct GameConfig: Equatable, Sendable, Codable { var playerCount: Int; var startingStack: Int; var format: GameFormat; var humanSeat: Int; var effectiveStack: Int }`
  - `func currentBlinds(for format: GameFormat, handNumber: Int) -> (sb: Int, bb: Int)`：cash 恒定；SNG 按 `levels` 的 `hands` 累加推进，超出表尾用最后一档

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import PokerEngine

final class FormatsTests: XCTestCase {
    func testCashBlindsConstant() {
        let f = GameFormat.cash(sb: 5, bb: 10)
        XCTAssertEqual(currentBlinds(for: f, handNumber: 0).bb, 10)
        XCTAssertEqual(currentBlinds(for: f, handNumber: 999).sb, 5)
    }

    func testSNGBlindEscalationByHandCount() {
        let sng = SNGConfig(buyIn: 1000, startingStack: 1500,
                            levels: [BlindLevel(sb: 10, bb: 20, hands: 10),
                                     BlindLevel(sb: 25, bb: 50, hands: 10)],
                            payouts: [0.5, 0.3, 0.2])
        let f = GameFormat.sng(sng)
        // 手 0-9 → 10/20；手 10-19 → 25/50；手 20+ 沿用最后一档
        XCTAssertEqual(currentBlinds(for: f, handNumber: 0).sb, 10)
        XCTAssertEqual(currentBlinds(for: f, handNumber: 9).bb, 20)
        XCTAssertEqual(currentBlinds(for: f, handNumber: 10).sb, 25)
        XCTAssertEqual(currentBlinds(for: f, handNumber: 19).bb, 50)
        XCTAssertEqual(currentBlinds(for: f, handNumber: 25).bb, 50)
    }

    func testEffectiveStackPerFormat() {
        let cash = GameConfig(playerCount: 2, startingStack: 2000, format: .cash(sb: 5, bb: 10))
        XCTAssertEqual(cash.effectiveStack, 2000)
        let sng = GameConfig(playerCount: 2, startingStack: 999,
                             format: .sng(SNGConfig(buyIn: 100, startingStack: 1500,
                                                    levels: [BlindLevel(sb: 10, bb: 20, hands: 8)],
                                                    payouts: [0.6, 0.4])))
        XCTAssertEqual(sng.effectiveStack, 1500)   // SNG 以 sng.startingStack 为准
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --package-path PokerEngine --filter FormatsTests 2>&1 | tail -5`
Expected: FAIL（类型未定义）

- [ ] **Step 3: 实现**

```swift
/// 一档盲注等级：小盲/大盲/持续手数。
public struct BlindLevel: Equatable, Sendable, Codable {
    public let sb: Int, bb: Int, hands: Int
    public init(sb: Int, bb: Int, hands: Int) { self.sb = sb; self.bb = bb; self.hands = hands }
}

/// 单桌锦标赛配置。payouts 为名次比例（降序，总和 1）。
public struct SNGConfig: Equatable, Sendable, Codable {
    public var buyIn: Int
    public var startingStack: Int
    public var levels: [BlindLevel]
    public var payouts: [Double]

    public init(buyIn: Int, startingStack: Int, levels: [BlindLevel], payouts: [Double]) {
        self.buyIn = buyIn; self.startingStack = startingStack
        self.levels = levels; self.payouts = payouts
    }

    /// 结构校验：等级非空且合法；比例非空、总和为 1（容差 1e-9）、降序。
    public static func validated(_ c: SNGConfig) -> SNGConfig {
        precondition(!c.levels.isEmpty)
        precondition(c.levels.allSatisfy { $0.sb > 0 && $0.bb >= $0.sb && $0.hands > 0 })
        precondition(!c.payouts.isEmpty && abs(c.payouts.reduce(0, +) - 1) < 1e-9)
        precondition(zip(c.payouts, c.payouts.dropFirst()).allSatisfy { $0.0 >= $0.1 })
        return c
    }
}

/// 对局形式：现金局（固定盲注）或 SNG。
public enum GameFormat: Equatable, Sendable, Codable {
    case cash(sb: Int, bb: Int)
    case sng(SNGConfig)
}

public struct GameConfig: Equatable, Sendable, Codable {
    public var playerCount: Int      // 2...9
    public var startingStack: Int    // 现金局初始筹码
    public var format: GameFormat
    public var humanSeat: Int        // 单机人类座位，其余为 AI

    public init(playerCount: Int, startingStack: Int, format: GameFormat, humanSeat: Int = 0) {
        self.playerCount = playerCount; self.startingStack = startingStack
        self.format = format; self.humanSeat = humanSeat
    }

    /// 开局每人筹码：现金局用 startingStack，SNG 用 sng.startingStack。
    public var effectiveStack: Int {
        switch format {
        case .cash: return startingStack
        case .sng(let s): return s.startingStack
        }
    }
}

/// 按手号查当前盲注。SNG 按等级表累加推进，超出表尾沿用最后一档。
public func currentBlinds(for format: GameFormat, handNumber: Int) -> (sb: Int, bb: Int) {
    switch format {
    case .cash(let sb, let bb): return (sb, bb)
    case .sng(let cfg):
        var remaining = handNumber
        for level in cfg.levels {
            if remaining < level.hands { return (level.sb, level.bb) }
            remaining -= level.hands
        }
        let last = cfg.levels.last!
        return (last.sb, last.bb)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --package-path PokerEngine --filter FormatsTests 2>&1 | tail -5`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add PokerEngine
git commit -m "feat: 对局形式配置（现金局/SNG、盲注等级调度 currentBlinds）"
```

---

### Task 4: GameState 核心——开局、发牌、盲注

**Files:**
- Create: `PokerEngine/Sources/PokerEngine/Game/PlayerAction.swift`
- Create: `PokerEngine/Sources/PokerEngine/Game/GameState.swift`
- Test: `PokerEngine/Tests/PokerEngineTests/GameStateTests.swift`

**Interfaces:**
- Consumes: Task 1–3 全部
- Produces（Task 5–10 依赖，字段名为准）:
  - `enum PlayerAction: Equatable, Sendable, Codable { case fold, check, call, bet(Int), raiseTo(Int) }`
  - `struct SeatAction: Equatable, Sendable, Codable { let seat: Int; let action: PlayerAction }`
  - `enum Street: Equatable, Sendable, Codable, CaseIterable { case preflop, flop, turn, river, showdown, handOver }`
  - `enum PlayerStatus: Equatable, Sendable, Codable { case active, folded, allIn, eliminated }`
  - `struct PlayerState: Equatable, Sendable { var seat: Int; var name: String; var isBot: Bool; var stack: Int; var holeCards: [Card]; var streetContribution: Int; var handContribution: Int; var status: PlayerStatus; var hasActed: Bool; var stackAtHandStart: Int; var finishPlace: Int? }`
  - `struct PotLayer: Equatable, Sendable { var amount: Int; var eligibleSeats: [Int] }`
  - `struct PotAward: Equatable, Sendable { var potIndex: Int; var amount: Int; var winners: [Int]; var perWinner: Int; var oddChipSeat: Int?; var ranks: [Int: HandRank] }`
  - `struct HandResult: Equatable, Sendable { var awards: [PotAward] }`
  - `struct TournamentPayout: Equatable, Sendable { let seat: Int; let place: Int; let amount: Int }`
  - `struct GameState: Equatable, Sendable`，存储属性顺序：`config, seed, rng(private(set)), deck, handNumber, buttonSeat, street, board, players, pots, currentBet, minRaiseIncrement, actorSeat, actions, handResult, tournamentOver, tournamentPayouts, lastAggressionFullRaise`
  - `static func start(config: GameConfig, seed: UInt64, stacks: [Int]? = nil, buttonSeat: Int? = nil, handNumber: Int = 0) -> GameState`
  - `var potTotal: Int`（所有玩家 handContribution 之和）
  - 自定义 `==`：逐字段比较但**忽略 rng**

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import PokerEngine

final class GameStateTests: XCTestCase {
    let cash6 = GameConfig(playerCount: 6, startingStack: 2000, format: .cash(sb: 10, bb: 20))

    func testStartDealsTwoCardsEachAndPostsBlinds() {
        let s = GameState.start(config: cash6, seed: 1)
        XCTAssertEqual(s.street, .preflop)
        XCTAssertEqual(s.players.filter { $0.holeCards.count == 2 }.count, 6)
        XCTAssertEqual(s.players.map(\.handContribution).reduce(0, +), 30)   // 10+20
        XCTAssertEqual(s.currentBet, 20)
        XCTAssertEqual(s.minRaiseIncrement, 20)
        // 6 人桌：按钮+1 是 SB，+2 是 BB，UTG = BB+1 先行动
        XCTAssertEqual(s.players[(s.buttonSeat + 1) % 6].streetContribution, 10)
        XCTAssertEqual(s.players[(s.buttonSeat + 2) % 6].streetContribution, 20)
        XCTAssertEqual(s.actorSeat, (s.buttonSeat + 3) % 6)
        XCTAssertEqual(s.potTotal, 30)
    }

    func testHeadsUpButtonIsSmallBlindAndActsFirst() {
        let s = GameState.start(config: GameConfig(playerCount: 2, startingStack: 1500, format: .cash(sb: 5, bb: 10)), seed: 2, buttonSeat: 0)
        XCTAssertEqual(s.players[s.buttonSeat].streetContribution, 5)          // 按钮=SB
        XCTAssertEqual(s.players[(s.buttonSeat + 1) % 2].streetContribution, 10)
        XCTAssertEqual(s.actorSeat, s.buttonSeat)                              // 翻前按钮先行动
    }

    func testDeterminismSameSeedSameState() {
        let a = GameState.start(config: cash6, seed: 777)
        let b = GameState.start(config: cash6, seed: 777)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, GameState.start(config: cash6, seed: 778))
    }

    func testStacksOverrideForReplay() {
        let s = GameState.start(config: cash6, seed: 5, stacks: [100, 500, 900, 1300, 1700, 2000], buttonSeat: 2, handNumber: 3)
        XCTAssertEqual(s.players[0].stack, 100)
        XCTAssertEqual(s.buttonSeat, 2)
        XCTAssertEqual(s.handNumber, 3)
        XCTAssertEqual(s.currentBet, 20)   // cash 恒定盲注
    }

    func testShortBigBlindPostsAllIn() {
        // BB 只有 8，不足大盲 20 → 全下投入 8，currentBet 仍是名义 20
        let cfg = GameConfig(playerCount: 3, startingStack: 2000, format: .cash(sb: 10, bb: 20))
        let s = GameState.start(config: cfg, seed: 9, stacks: [2000, 2000, 8], buttonSeat: 0)
        XCTAssertEqual(s.players[2].stack, 0)          // 按钮 0 → SB 1 → BB 2
        XCTAssertEqual(s.players[2].handContribution, 8)
        XCTAssertEqual(s.players[2].status, .allIn)
        XCTAssertEqual(s.currentBet, 20)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --package-path PokerEngine --filter GameStateTests 2>&1 | tail -5`
Expected: FAIL（GameState 未定义）

- [ ] **Step 3: 实现**

`PlayerAction.swift`：

```swift
/// 玩家行动。bet 与 raiseTo 在引擎内部统一按“本轮投入总额”解释（见 Reducer）。
public enum PlayerAction: Equatable, Sendable, Codable {
    case fold
    case check
    case call
    case bet(Int)
    case raiseTo(Int)
}

public struct SeatAction: Equatable, Sendable, Codable {
    public let seat: Int
    public let action: PlayerAction
    public init(seat: Int, action: PlayerAction) { self.seat = seat; self.action = action }
}
```

`GameState.swift`：

```swift
public enum Street: Equatable, Sendable, Codable, CaseIterable {
    case preflop, flop, turn, river, showdown, handOver
}

public enum PlayerStatus: Equatable, Sendable, Codable {
    case active, folded, allIn, eliminated
}

public struct PlayerState: Equatable, Sendable {
    public var seat: Int
    public var name: String
    public var isBot: Bool
    public var stack: Int
    public var holeCards: [Card]
    public var streetContribution: Int
    public var handContribution: Int
    public var status: PlayerStatus
    public var hasActed: Bool
    public var stackAtHandStart: Int
    public var finishPlace: Int?

    public init(seat: Int, name: String, isBot: Bool, stack: Int,
                status: PlayerStatus = .active, finishPlace: Int? = nil) {
        self.seat = seat; self.name = name; self.isBot = isBot; self.stack = stack
        self.status = status; self.finishPlace = finishPlace
        holeCards = []; streetContribution = 0; handContribution = 0
        hasActed = false; stackAtHandStart = stack
    }
}

public struct PotLayer: Equatable, Sendable {
    public var amount: Int
    public var eligibleSeats: [Int]
    public init(amount: Int, eligibleSeats: [Int]) { self.amount = amount; self.eligibleSeats = eligibleSeats }
}

public struct PotAward: Equatable, Sendable {
    public var potIndex: Int
    public var amount: Int
    public var winners: [Int]
    public var perWinner: Int
    public var oddChipSeat: Int?
    public var ranks: [Int: HandRank]
    public init(potIndex: Int, amount: Int, winners: [Int], perWinner: Int,
                oddChipSeat: Int?, ranks: [Int: HandRank]) {
        self.potIndex = potIndex; self.amount = amount; self.winners = winners
        self.perWinner = perWinner; self.oddChipSeat = oddChipSeat; self.ranks = ranks
    }
}

public struct HandResult: Equatable, Sendable {
    public var awards: [PotAward]
    public init(awards: [PotAward]) { self.awards = awards }
}

public struct TournamentPayout: Equatable, Sendable {
    public let seat: Int, place: Int, amount: Int
    public init(seat: Int, place: Int, amount: Int) { self.seat = seat; self.place = place; self.amount = amount }
}

/// 游戏的全部状态：值类型，唯一推进方式是 apply / nextHand。
public struct GameState: Equatable, Sendable {
    public var config: GameConfig
    public let seed: UInt64
    public private(set) var rng: SeededGenerator
    public private(set) var deck: Deck
    public private(set) var handNumber: Int
    public private(set) var buttonSeat: Int
    public private(set) var street: Street
    public private(set) var board: [Card]
    public private(set) var players: [PlayerState]    // 下标即 seat
    public private(set) var pots: [PotLayer]
    public private(set) var currentBet: Int
    public private(set) var minRaiseIncrement: Int
    public private(set) var actorSeat: Int?
    public private(set) var actions: [SeatAction]
    public private(set) var handResult: HandResult?
    public private(set) var tournamentOver: Bool
    public private(set) var tournamentPayouts: [TournamentPayout]
    /// 最近一次激进动作（bet/raise）是否足额（决定是否重开加注轮）。
    public private(set) var lastAggressionFullRaise: Bool

    public var potTotal: Int { players.reduce(0) { $0 + $1.handContribution } }

    /// 开一局。stacks/buttonSeat/handNumber 供重放（HandHistory）使用。
    public static func start(config: GameConfig, seed: UInt64,
                             stacks: [Int]? = nil, buttonSeat: Int? = nil,
                             handNumber: Int = 0) -> GameState {
        precondition((2...9).contains(config.playerCount))
        precondition(config.effectiveStack > 0)
        var rng = SeededGenerator(seed: seed)
        var s = GameState(
            config: config, seed: seed, rng: rng, deck: Deck(rng: &rng),
            handNumber: handNumber,
            buttonSeat: 0,          // 占位，下方按需覆写
            street: .preflop, board: [], players: [],
            pots: [], currentBet: 0, minRaiseIncrement: 0, actorSeat: nil,
            actions: [], handResult: nil, tournamentOver: false,
            tournamentPayouts: [], lastAggressionFullRaise: true)
        let stack0 = stacks ?? Array(repeating: config.effectiveStack, count: config.playerCount)
        precondition(stack0.count == config.playerCount)
        for seat in 0..<config.playerCount {
            s.players.append(PlayerState(seat: seat, name: "座位 \(seat + 1)",
                                          isBot: seat != config.humanSeat, stack: stack0[seat]))
        }
        s.buttonSeat = buttonSeat ?? Int(rng.next() % UInt64(config.playerCount))
        // 重置 rng：按钮选择不再影响发牌序列（重放传显式按钮时同样成立）
        rng = SeededGenerator(seed: seed)
        s.rng = rng
        s.dealNewHand()
        return s
    }

    /// 发一手新牌（含盲注）。start 与 nextHand 共用。
    mutating func dealNewHand() {
        let (sb, bb) = currentBlinds(for: config.format, handNumber: handNumber)
        var rng = self.rng
        deck = Deck(rng: &rng)
        self.rng = rng
        board = []; pots = []; actions = []; handResult = nil
        currentBet = bb; minRaiseIncrement = bb; lastAggressionFullRaise = true
        for i in players.indices {
            players[i].holeCards = []
            players[i].streetContribution = 0
            players[i].handContribution = 0
            players[i].hasActed = false
            players[i].stackAtHandStart = players[i].stack
            if players[i].status == .folded || players[i].status == .allIn {
                players[i].status = .active
            }
        }
        // 从按钮下一位开始每人两张（两轮各一张）
        let dealOrder = liveSeatsClockwise(from: buttonSeat)
        for _ in 0..<2 {
            for seat in dealOrder {
                players[seat].holeCards.append(deck.draw())
            }
        }
        // 盲注：单挑按钮=SB；否则按钮+1=SB
        let n = players.count
        let sbSeat = n == 2 ? buttonSeat : nextSeat(after: buttonSeat)
        let bbSeat = nextSeat(after: sbSeat)
        postBlind(amount: sb, seat: sbSeat)
        postBlind(amount: bb, seat: bbSeat)
        street = .preflop
        actorSeat = n == 2 ? buttonSeat : nextSeat(after: bbSeat)
    }

    private mutating func postBlind(amount: Int, seat: Int) {
        let pay = min(amount, players[seat].stack)
        players[seat].stack -= pay
        players[seat].streetContribution += pay
        players[seat].handContribution += pay
        if players[seat].stack == 0 { players[seat].status = .allIn }
    }

    /// 从 from 下一位起顺时针第一个未淘汰座位。
    func nextSeat(after from: Int) -> Int {
        var s = (from + 1) % players.count
        while players[s].status == .eliminated { s = (s + 1) % players.count }
        return s
    }

    /// 从 from 下一位起顺时针所有未淘汰座位（发牌顺序）。
    func liveSeatsClockwise(from: Int) -> [Int] {
        let total = players.filter { $0.status != .eliminated }.count
        var seats: [Int] = []
        var s = nextSeat(after: from)
        seats.append(s)
        while seats.count < total {
            s = nextSeat(after: s)
            seats.append(s)
        }
        return seats
    }

    /// 忽略 rng 内部状态的状态等价（重放测试的基础）。
    public static func == (lhs: GameState, rhs: GameState) -> Bool {
        lhs.config == rhs.config && lhs.seed == rhs.seed && lhs.deck == rhs.deck
            && lhs.handNumber == rhs.handNumber && lhs.buttonSeat == rhs.buttonSeat
            && lhs.street == rhs.street && lhs.board == rhs.board
            && lhs.players == rhs.players && lhs.pots == rhs.pots
            && lhs.currentBet == rhs.currentBet
            && lhs.minRaiseIncrement == rhs.minRaiseIncrement
            && lhs.actorSeat == rhs.actorSeat && lhs.actions == rhs.actions
            && lhs.handResult == rhs.handResult
            && lhs.tournamentOver == rhs.tournamentOver
            && lhs.tournamentPayouts == rhs.tournamentPayouts
            && lhs.lastAggressionFullRaise == rhs.lastAggressionFullRaise
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --package-path PokerEngine --filter GameStateTests 2>&1 | tail -5`
Expected: PASS（注意成员构造参数顺序与存储属性声明顺序一致；如编译器报顺序问题按声明顺序核对）

- [ ] **Step 5: 提交**

```bash
git add PokerEngine
git commit -m "feat: GameState 核心（开局发牌、盲注、单挑特例、确定性、重放参数）"
```

---

### Task 5: 合法动作查询 legalActions / isLegal

**Files:**
- Create: `PokerEngine/Sources/PokerEngine/Game/LegalActions.swift`
- Test: `PokerEngine/Tests/PokerEngineTests/LegalActionsTests.swift`

**Interfaces:**
- Consumes: Task 4 的 `GameState` / `PlayerAction`
- Produces（Task 6/10/12 依赖）:
  - `struct LegalActions: Equatable, Sendable { let seat: Int; let canCheck: Bool; let canCall: Bool; let callAmount: Int; let betRange: ClosedRange<Int>?; let isRaiseContext: Bool }`
  - `func legalActions(_ state: GameState) -> LegalActions`（作用于 `state.actorSeat`；非下注街返回空集）
  - `func isLegal(_ action: PlayerAction, in legal: LegalActions) -> Bool`（fold 恒真；check↔canCheck；call↔canCall（canCall 仅在 toCall>0 时为真，**大盲 option 时 call 不可用、用 check**）；bet(x)/raiseTo(x) 同义，均要求 betRange.contains(x)）

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import PokerEngine

final class LegalActionsTests: XCTestCase {
    let cash3 = GameConfig(playerCount: 3, startingStack: 1000, format: .cash(sb: 10, bb: 20))

    func testPreflopFirstToAct() {
        let s = GameState.start(config: cash3, seed: 3, buttonSeat: 0)
        // 按钮 0 → SB 1 → BB 2，UTG = 座位 0
        let legal = legalActions(s)
        XCTAssertTrue(isLegal(.fold, in: legal))
        XCTAssertFalse(isLegal(.check, in: legal))       // 面对大盲
        XCTAssertTrue(isLegal(.call, in: legal))
        XCTAssertEqual(legal.callAmount, 20)
        XCTAssertEqual(legal.betRange?.lowerBound, 40)   // 最小加注到 2BB
        XCTAssertEqual(legal.betRange?.upperBound, 1000) // 全下 = 0 已投 + 1000
        XCTAssertTrue(legal.isRaiseContext)
    }

    // TASK6-DEFERRED（依赖 apply，Task 6 Step 4 恢复）:
    // testBigBlindOptionIsCheckOrRaise
    // testPostflopBetRangeAndCheck

    func testShortStackCanOnlyShove() {
        // 按钮位（也是 UTG）只剩 25：翻前加注只有 all-in 一个档
        let cfg = GameConfig(playerCount: 3, startingStack: 1000, format: .cash(sb: 10, bb: 20))
        let s = GameState.start(config: cfg, seed: 3, stacks: [25, 1000, 1000], buttonSeat: 0)
        let legal = legalActions(s)
        XCTAssertEqual(legal.callAmount, 20)
        XCTAssertEqual(legal.betRange, 25...25)          // 全下加注到 25
    }

    func testCannotRaiseWhenOnlyEnoughToCall() {
        // 剩 20 正好够跟注 → 无加注区间
        let cfg = GameConfig(playerCount: 3, startingStack: 1000, format: .cash(sb: 10, bb: 20))
        let s = GameState.start(config: cfg, seed: 3, stacks: [20, 1000, 1000], buttonSeat: 0)
        let legal = legalActions(s)
        XCTAssertNil(legal.betRange)
        XCTAssertTrue(isLegal(.call, in: legal))
        XCTAssertFalse(isLegal(.check, in: legal))
    }
}
```

Task 6 恢复时追加到本文件（先以注释占位防误跑）：

```swift
    func testBigBlindOptionIsCheckOrRaise() {
        var s = GameState.start(config: cash3, seed: 3, buttonSeat: 0)
        s.apply(.call)   // 座位 0 跟 20
        s.apply(.call)   // 座位 1（SB）补 10 跟平
        let legal = legalActions(s)   // BB（座位 2）的 option：toCall == 0
        XCTAssertTrue(isLegal(.check, in: legal))
        XCTAssertFalse(isLegal(.call, in: legal))        // toCall=0 → call 不可用
        XCTAssertEqual(legal.callAmount, 0)
        XCTAssertEqual(legal.betRange?.lowerBound, 40)   // BB 可加注
        XCTAssertFalse(legal.isRaiseContext)
    }

    func testPostflopBetRangeAndCheck() {
        var s = GameState.start(config: cash3, seed: 3, buttonSeat: 0)
        s.apply(.call)    // 0
        s.apply(.call)    // 1
        s.apply(.check)   // 2（BB option，用 check 而不是 call！）
        XCTAssertEqual(s.street, .flop)
        let legal = legalActions(s)
        XCTAssertTrue(isLegal(.check, in: legal))
        XCTAssertFalse(isLegal(.call, in: legal))
        XCTAssertEqual(legal.betRange?.lowerBound, 20)   // 最小下注 = BB
        XCTAssertEqual(legal.betRange?.upperBound, 980)
        XCTAssertFalse(legal.isRaiseContext)
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --package-path PokerEngine --filter LegalActionsTests 2>&1 | tail -5`
Expected: FAIL（`legalActions` 未定义）

- [ ] **Step 3: 实现**

```swift
public struct LegalActions: Equatable, Sendable {
    public let seat: Int
    public let canCheck: Bool
    public let canCall: Bool
    public let callAmount: Int
    /// 可用的激进动作总额区间（bet=x 与 raiseTo=x 同为“本轮投入总额”）。nil = 不能下注/加注。
    public let betRange: ClosedRange<Int>?
    public let isRaiseContext: Bool   // 面对下注（true）还是无人下注（false），供 UI 标签
}

/// 当前行动者的合法动作。
public func legalActions(_ state: GameState) -> LegalActions {
    guard let seat = state.actorSeat,
          [.preflop, .flop, .turn, .river].contains(state.street)
    else {
        return LegalActions(seat: state.actorSeat ?? -1, canCheck: false, canCall: false,
                            callAmount: 0, betRange: nil, isRaiseContext: false)
    }
    let p = state.players[seat]
    let toCall = max(0, state.currentBet - p.streetContribution)
    let allInTotal = p.streetContribution + p.stack
    // 家规：已行动过且此后只发生不足额加注 → 不得再加注（spec §4.3）
    let mayAggress = !p.hasActed || state.lastAggressionFullRaise

    var range: ClosedRange<Int>? = nil
    if mayAggress && allInTotal > state.currentBet {
        if toCall > 0 {
            let fullRaiseTo = state.currentBet + state.minRaiseIncrement
            range = min(fullRaiseTo, allInTotal)...allInTotal
        } else {
            let (_, bb) = currentBlinds(for: state.config.format, handNumber: state.handNumber)
            range = allInTotal <= bb ? allInTotal...allInTotal : bb...allInTotal
        }
    }
    return LegalActions(seat: seat,
                        canCheck: toCall == 0,
                        canCall: toCall > 0,
                        callAmount: min(toCall, p.stack),
                        betRange: range,
                        isRaiseContext: toCall > 0)
}

public func isLegal(_ action: PlayerAction, in legal: LegalActions) -> Bool {
    switch action {
    case .fold: return true
    case .check: return legal.canCheck
    case .call: return legal.canCall
    case .bet(let x), .raiseTo(let x): return legal.betRange?.contains(x) ?? false
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --package-path PokerEngine --filter LegalActionsTests 2>&1 | tail -5`
Expected: PASS（TASK6-DEFERRED 两个测试仍注释状态）

- [ ] **Step 5: 提交**

```bash
git add PokerEngine
git commit -m "feat: 合法动作查询（最小加注区间、不足额不加注限制、全下档位）"
```

---

### Task 6: Reducer——apply、下注轮、街道推进、runout

**Files:**
- Create: `PokerEngine/Sources/PokerEngine/Game/Reducer.swift`
- Modify: `PokerEngine/Tests/PokerEngineTests/LegalActionsTests.swift`（恢复 TASK6-DEFERRED 测试）
- Test: `PokerEngine/Tests/PokerEngineTests/ReducerTests.swift`

**Interfaces:**
- Consumes: Task 4/5 全部
- Produces（Task 7/8/9/10/12 依赖）:
  - `extension GameState { public mutating func apply(_ action: PlayerAction) }`：作用于 `actorSeat`；非法动作按 fold 处理（Debug `assert` 兜底）；摊牌结算调用本文件中的 `showdown()` **空壳**（Task 7 原地填充实现）
  - 行为契约：
    - 下注轮结束 = 存活（active）玩家全部 `hasActed && streetContribution == currentBet`，或未弃牌玩家 ≤1（uncontested）
    - 足额 bet/raise 重置其他 active 玩家 `hasActed=false` 并更新 `minRaiseIncrement`；不足额 all-in 加注不重开（只更新 `currentBet` 与 `lastAggressionFullRaise=false`）
    - 街道推进：flop 发 3 张、turn/river 各 1 张（不烧牌，成文）；**能行动玩家 ≤1 时 runout 发完**；翻后首行动者 = 按钮顺时针下一位 **active** 玩家（跳过弃牌/all-in/淘汰）
    - uncontested：只剩一人未弃牌 → 收走全部 `handContribution`（未跟注部分自然返还），`.handOver`

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import PokerEngine

final class ReducerTests: XCTestCase {
    let cash3 = GameConfig(playerCount: 3, startingStack: 1000, format: .cash(sb: 10, bb: 20))

    func testFoldFoldUncontestedWin() {
        var s = GameState.start(config: cash3, seed: 11, buttonSeat: 0)
        s.apply(.fold)   // 座位 0
        s.apply(.fold)   // 座位 1 (SB) —— 只剩 BB
        XCTAssertEqual(s.street, .handOver)
        XCTAssertEqual(s.handResult?.awards.first?.winners, [2])
        XCTAssertEqual(s.handResult?.awards.first?.amount, 30)
        XCTAssertEqual(s.players[2].stack, 1000)   // 投 20 收 30，净 +10
        XCTAssertNil(s.actorSeat)
    }

    func testCallCallCheckBetRaiseFlow() {
        var s = GameState.start(config: cash3, seed: 11, buttonSeat: 0)
        s.apply(.call)    // 0 → 20
        s.apply(.call)    // 1 (SB) → 20
        s.apply(.check)   // 2 (BB) option
        XCTAssertEqual(s.street, .flop)
        XCTAssertEqual(s.board.count, 3)
        XCTAssertEqual(s.potTotal, 60)
        XCTAssertEqual(s.actorSeat, 1)             // 翻牌从 SB（座位 1）开始
        s.apply(.bet(30))                          // SB 下注 30
        XCTAssertEqual(s.currentBet, 30)
        XCTAssertEqual(s.minRaiseIncrement, 30)
        XCTAssertTrue(s.lastAggressionFullRaise)
        s.apply(.fold)                             // BB 弃
        s.apply(.raiseTo(60))                      // 座位 0 加注到 60
        let legal = legalActions(s)                // 座位 1 面对 60
        XCTAssertFalse(legal.canCheck)
        XCTAssertEqual(legal.betRange?.lowerBound, 120)   // 60 + 最小加注量 60
        s.apply(.fold)
        XCTAssertEqual(s.street, .handOver)
        // 底池 = 翻前 60 + SB 30 + 0 的 60 = 150；座位 0 总投入 80，收回 150
        XCTAssertEqual(s.players[0].stack, 1000 - 80 + 150)
    }

    func testHeadsUpPostflopButtonActsSecond() {
        var s = GameState.start(config: GameConfig(playerCount: 2, startingStack: 1000, format: .cash(sb: 5, bb: 10)), seed: 12, buttonSeat: 0)
        s.apply(.call)    // 按钮/SB 跟
        s.apply(.check)   // BB check
        XCTAssertEqual(s.street, .flop)
        XCTAssertEqual(s.actorSeat, 1)   // 翻后按钮后行动
    }

    func testUnderRaiseAllInDoesNotReopen() {
        // Review Focus #2：座位 0 下注 100（足额），座位 2 (BB) 短码全下加注到 125（增量 25 < 80）
        var s = GameState.start(config: cash3, seed: 13, buttonSeat: 0, stacks: [500, 500, 125])
        s.apply(.bet(100))          // 座位 0 下注 100（足额，minRaiseIncrement → 80）
        s.apply(.fold)              // 座位 1 (SB) 弃
        s.apply(.raiseTo(125))      // 座位 2 全下总额 125（盲注 20 + 剩余 105），不足额加注
        XCTAssertEqual(s.players[2].status, .allIn)
        XCTAssertEqual(s.currentBet, 125)
        XCTAssertFalse(s.lastAggressionFullRaise)
        let legal = legalActions(s)  // 轮到 0：只能跟 25 或弃
        XCTAssertFalse(legal.canCheck)
        XCTAssertEqual(legal.callAmount, 25)
        XCTAssertNil(legal.betRange) // 不得再加注
        s.apply(.call)
        // 0 跟后：0 active、2 allIn → runout → handOver（Task 7 showdown 填充前 street 已到 handOver? 空壳不分配 → 该断言 Task 7 后成立，此处只断言不再轮到任何人下注街）
        XCTAssertTrue(s.street == .handOver || s.street == .river)
    }

    func testAllInRunoutDealsAllStreets() throws {
        var s = GameState.start(config: GameConfig(playerCount: 2, startingStack: 1000, format: .cash(sb: 5, bb: 10)), seed: 14, buttonSeat: 0)
        s.apply(.raiseTo(1000))     // 按钮/SB 全下
        s.apply(.call)              // BB 跟全下
        // 双方 all-in → 直接发完（showdown 为 Task 7 空壳，Task 7 完成后此测试恢复）
        try XCTSkipUnless(ProcessInfo.processInfo.environment["POKER_TASK7_DONE"] != nil, "Task 7 填充 showdown 后启用")
        XCTAssertEqual(s.board.count, 5)
        XCTAssertEqual(s.street, .handOver)
        XCTAssertFalse(s.handResult!.awards.isEmpty)
    }

    func testStreetChangeResetsBettingState() {
        var s = GameState.start(config: cash3, seed: 11, buttonSeat: 0)
        s.apply(.call); s.apply(.call); s.apply(.check)   // 进翻牌
        s.apply(.check); s.apply(.check); s.apply(.check) // 翻牌全过
        XCTAssertEqual(s.street, .turn)
        XCTAssertEqual(s.board.count, 4)
        XCTAssertEqual(s.currentBet, 0)
        XCTAssertEqual(s.minRaiseIncrement, 20)
    }

    func testFoldedSmallBlindNotFirstActorPostflop() {
        // 回归钉：SB 弃牌后，翻牌首行动者必须跳过 SB
        var s = GameState.start(config: cash3, seed: 15, buttonSeat: 0)
        s.apply(.call)    // 0
        s.apply(.fold)    // 1 (SB) 弃
        s.apply(.check)   // 2 (BB) → flop
        XCTAssertEqual(s.street, .flop)
        XCTAssertEqual(s.actorSeat, 2)   // 从按钮顺时针：1 已弃 → 轮到 2
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --package-path PokerEngine --filter ReducerTests 2>&1 | tail -5`
Expected: FAIL（`apply` 未实现）

- [ ] **Step 3: 实现 Reducer.swift（showdown 为 Task 7 空壳）**

```swift
extension GameState {
    /// 唯一的行动入口：作用于当前 actorSeat。
    public mutating func apply(_ action: PlayerAction) {
        guard let seat = actorSeat,
              [.preflop, .flop, .turn, .river].contains(street) else { return }
        let legal = legalActions(self)
        var act = action
        if !isLegal(act, in: legal) {
            assert(false, "illegal action \(action) for seat \(seat); treated as fold")
            act = .fold
        }
        actions.append(SeatAction(seat: seat, action: act))
        var p = players[seat]

        switch act {
        case .fold:
            p.status = .folded
        case .check:
            p.hasActed = true
        case .call:
            let pay = min(max(0, currentBet - p.streetContribution), p.stack)
            p.stack -= pay
            p.streetContribution += pay
            p.handContribution += pay
            p.hasActed = true
            if p.stack == 0 { p.status = .allIn }
        case .bet(let target), .raiseTo(let target):
            let t = min(target, p.streetContribution + p.stack)   // 全下封顶
            let add = t - p.streetContribution
            precondition(add > 0, "aggressive action must exceed current contribution")
            let raiseSize = t - currentBet
            let isFull = currentBet == 0 ? t >= minRaiseIncrement : raiseSize >= minRaiseIncrement
            p.stack -= add
            p.streetContribution = t
            p.handContribution += add
            p.hasActed = true
            if p.stack == 0 { p.status = .allIn }
            if isFull {
                if raiseSize > 0 { minRaiseIncrement = raiseSize }
                lastAggressionFullRaise = true
                for i in players.indices where players[i].status == .active && i != seat {
                    players[i].hasActed = false
                }
            } else {
                lastAggressionFullRaise = false             // 不足额 all-in：不重开
            }
            currentBet = t
        }
        players[seat] = p

        let unfolded = players.filter { $0.status != .folded && $0.status != .eliminated }
        if unfolded.count <= 1 {
            settleUncontested(winner: unfolded.first?.seat ?? seat)
            return
        }
        if bettingRoundComplete() { closeBettingRound() }
        else { actorSeat = nextToAct(after: seat) }
    }

    func bettingRoundComplete() -> Bool {
        let contenders = players.filter { $0.status == .active }
        if contenders.isEmpty { return true }
        return contenders.allSatisfy { $0.hasActed && $0.streetContribution == currentBet }
    }

    func nextToAct(after from: Int) -> Int? {
        var s = (from + 1) % players.count
        for _ in 0..<players.count {
            let p = players[s]
            if p.status == .active && (!p.hasActed || p.streetContribution < currentBet) { return s }
            s = (s + 1) % players.count
        }
        return nil
    }

    mutating func closeBettingRound() {
        guard street != .river else { showdown(); return }
        dealNextStreet()
        let contenders = players.filter { $0.status == .active }
        if contenders.count <= 1 {
            // runout：直接发完剩余公共牌
            while street != .river { dealNextStreet() }
            showdown()
            return
        }
        // 新街道重置下注状态
        for i in players.indices { players[i].streetContribution = 0; players[i].hasActed = false }
        currentBet = 0
        let (_, bb) = currentBlinds(for: config.format, handNumber: handNumber)
        minRaiseIncrement = bb
        lastAggressionFullRaise = true
        // 翻后首行动者 = 按钮顺时针下一位 active 玩家（nextToAct 从 from+1 起扫，单挑即非按钮方）
        actorSeat = nextToAct(after: buttonSeat)
    }

    mutating func dealNextStreet() {
        switch street {
        case .preflop:
            board += [deck.draw(), deck.draw(), deck.draw()]; street = .flop
        case .flop:
            board.append(deck.draw()); street = .turn
        case .turn:
            board.append(deck.draw()); street = .river
        default: break
        }
    }

    /// 只剩一人未弃牌：直接收池（未跟注部分自然返还）。
    mutating func settleUncontested(winner: Int) {
        let amount = potTotal
        pots = [PotLayer(amount: amount, eligibleSeats: [winner])]
        players[winner].stack += amount
        handResult = HandResult(awards: [PotAward(potIndex: 0, amount: amount, winners: [winner],
                                                  perWinner: amount, oddChipSeat: nil, ranks: [:])])
        street = .handOver
        actorSeat = nil
    }

    // Task 7 原地填充：摊牌与边池
    mutating func showdown() {}
}
```

注意 `dealNextStreet` 直接调用 `deck.draw()`（struct 内部，deck 是存储属性可直接变更，无需手动搬运 rng——rng 只在洗牌时消耗）。同时恢复 `LegalActionsTests.swift` 中两个 TASK6-DEFERRED 测试（去掉注释）。

- [ ] **Step 4: 运行确认通过**

Run: `swift test --package-path PokerEngine --filter ReducerTests 2>&1 | tail -5 && swift test --package-path PokerEngine --filter LegalActionsTests 2>&1 | tail -5`
Expected: ReducerTests 中 `testAllInRunoutDealsAllStreets` 以 XCTSkip 跳过，其余 PASS；LegalActionsTests 6 个全绿

- [ ] **Step 5: 提交**

```bash
git add PokerEngine
git commit -m "feat: Reducer（apply/下注轮结束判定/街道推进/不足额加注不重开/单挑次序/弃牌者跳过/uncontested 收池）"
```

---

### Task 7: 摊牌、边池分层、奖金分配与奇数筹码

**Files:**
- Modify: `PokerEngine/Sources/PokerEngine/Game/Reducer.swift`（填充 `showdown()`，新增 `splitOddChip`）
- Modify: `PokerEngine/Tests/PokerEngineTests/ReducerTests.swift`（删除 `testAllInRunoutDealsAllStreets` 的 XCTSkip 行，直接断言）
- Test: `PokerEngine/Tests/PokerEngineTests/ShowdownTests.swift`

**Interfaces:**
- Consumes: Task 6 全链路
- Produces（Task 8/9/12 依赖）:
  - `showdown()` 契约：以未弃牌玩家的 `handContribution` 为分层上限（升序），每层金额 = 全部玩家落入该区间的贡献之和（弃牌者死钱按其到达区间计入）；每层由 eligible 玩家 `HandEvaluator.evaluate(hole + board)` 最大者赢，平分，奇数筹码给按钮顺时针下一位方向最近的赢家；`pots` 与 `handResult.awards` 填充、stack 入账、street = .handOver
  - `func splitOddChip(amount: Int, winners: [Int], buttonSeat: Int, playerCount: Int) -> [(seat: Int, amount: Int)]`（internal，`@testable` 可测）

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import PokerEngine

final class ShowdownTests: XCTestCase {
    func c(_ s: String) -> Card {
        let r = Array(s)[0], su = Array(s)[1]
        let rank = ["2","3","4","5","6","7","8","9","T","J","Q","K","A"].firstIndex(of: String(r))!
        let suit = ["s","h","d","c"].firstIndex(of: String(su))!
        return Card(rank: Rank(rawValue: rank + 2)!, suit: Suit(rawValue: suit)!)
    }

    /// 三人翻前全下 900/500/300：pots 与 eligible 是确定结构，与牌面无关。
    func testThreeWayAllInSidePots() {
        let cfg = GameConfig(playerCount: 3, startingStack: 2000, format: .cash(sb: 10, bb: 20))
        var s = GameState.start(config: cfg, seed: 21, buttonSeat: 0, stacks: [900, 500, 300])
        s.apply(.raiseTo(900))   // 座位 0（UTG）全下
        s.apply(.call)           // 座位 1 (SB) 跟到全下 500
        s.apply(.call)           // 座位 2 (BB) 跟到全下 300
        XCTAssertEqual(s.street, .handOver)
        XCTAssertEqual(s.pots.map(\.amount), [900, 400, 400])
        XCTAssertEqual(s.pots[0].eligibleSeats, [0, 1, 2])   // 300×3
        XCTAssertEqual(s.pots[1].eligibleSeats, [0, 1])      // 200×2
        XCTAssertEqual(s.pots[2].eligibleSeats, [0])         // 400 未被跟注
        XCTAssertEqual(s.handResult?.awards.reduce(0) { $0 + $1.amount }, 1700)
        XCTAssertEqual(s.players.reduce(0) { $0 + $1.stack }, 1700)   // 筹码守恒
    }

    /// 未被跟注的超额（Review Focus #3）：座位 2 翻牌全下 300，座位 0 加注到 800。
    /// 分层必为 [650 eligible 0/2] + [500 仅 0]（退回）；SB 弃牌死钱 10 进主池。
    func testUncalledExcessFormsSoloTopLayer() {
        let cfg = GameConfig(playerCount: 3, startingStack: 1000, format: .cash(sb: 10, bb: 20))
        var s = GameState.start(config: cfg, seed: 22, buttonSeat: 0, stacks: [1000, 1000, 300])
        s.apply(.call)     // 座位 0 跟 20
        s.apply(.fold)     // 座位 1 (SB) 弃，死钱 10
        s.apply(.check)    // 座位 2 (BB) option → flop
        // flop 首行动 = 按钮顺时针下一位 active = 座位 2（1 已弃）
        s.apply(.bet(300))      // 座位 2 全下 300
        s.apply(.raiseTo(800))  // 座位 0 加注到 800（合法区间 600...1000）
        XCTAssertEqual(s.street, .handOver)   // 2 allIn、0 唯一 active → runout + showdown
        XCTAssertEqual(s.pots.count, 2)
        XCTAssertEqual(s.pots[0].amount, 650)            // 320+10+320
        XCTAssertEqual(s.pots[0].eligibleSeats, [0, 2])
        XCTAssertEqual(s.pots[1].amount, 500)            // 未被跟注的 500
        XCTAssertEqual(s.pots[1].eligibleSeats, [0])
        // 0 无论比牌输赢，未跟注的 500 必回自己（0 本手共投入 820，剩余 180）
        XCTAssertEqual(s.players[0].stack, 180 + 500 + (s.handResult!.awards[0].winners.contains(0) ? 650 : 0))
        XCTAssertEqual(s.players.reduce(0) { $0 + $1.stack }, 2300)   // 守恒
    }

    /// 平分池奇数筹码给按钮顺时针下一位最近的赢家（Review Focus 之外的基础规则钉）。
    func testSplitOddChipGoesClockwiseAfterButton() {
        let a = splitOddChip(amount: 101, winners: [1, 2], buttonSeat: 0, playerCount: 3)
        XCTAssertEqual(a[0].seat, 1); XCTAssertEqual(a[0].amount, 51)
        XCTAssertEqual(a[1].seat, 2); XCTAssertEqual(a[1].amount, 50)
        let b = splitOddChip(amount: 101, winners: [1, 2], buttonSeat: 1, playerCount: 3)
        XCTAssertEqual(b[0].seat, 2); XCTAssertEqual(b[0].amount, 51)   // 按钮在 1 → 2 先拿大头
        XCTAssertEqual(b[1].seat, 1); XCTAssertEqual(b[1].amount, 50)
    }

    /// 端到端：两人全下摊牌必有 awards 与 ranks。
    func testShowdownProducesRanksAndAwards() {
        let cfg = GameConfig(playerCount: 3, startingStack: 1000, format: .cash(sb: 10, bb: 20))
        var s = GameState.start(config: cfg, seed: 23, buttonSeat: 0, stacks: [300, 1000, 300])
        s.apply(.raiseTo(300))   // 0 全下
        s.apply(.fold)           // 1
        s.apply(.call)           // 2 全下
        XCTAssertEqual(s.street, .handOver)
        let award = s.handResult!.awards[0]
        XCTAssertTrue((1...2).contains(award.winners.count))   // 可能平分
        XCTAssertFalse(award.ranks.isEmpty)
        XCTAssertEqual(s.players.reduce(0) { $0 + $1.stack }, 1600)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --package-path PokerEngine --filter ShowdownTests 2>&1 | tail -5`
Expected: FAIL（`splitOddChip` 未定义、`pots` 为空、`showdown` 空壳不推进）

- [ ] **Step 3: 实现（替换 Reducer.swift 空壳）**

```swift
extension GameState {
    /// 平分层的奇数筹码分配：按钮顺时针下一位方向的最近赢家拿大份。
    func splitOddChip(amount: Int, winners: [Int], buttonSeat: Int, playerCount: Int) -> [(seat: Int, amount: Int)] {
        let n = winners.count
        let per = amount / n
        let odd = amount % n
        let ordered = winners.sorted {
            (($0 - buttonSeat + playerCount) % playerCount) < (($1 - buttonSeat + playerCount) % playerCount)
        }
        return ordered.enumerated().map { i, seat in (seat, per + (i == 0 && odd > 0 ? odd : 0)) }
    }

    mutating func showdown() {
        let contenders = players.filter { $0.status != .folded && $0.status != .eliminated }
        precondition(contenders.count >= 2)
        let ranks: [Int: HandRank] = Dictionary(uniqueKeysWithValues:
            contenders.map { ($0.seat, HandEvaluator.evaluate($0.holeCards + board)) })

        // 分层：未弃牌玩家的投入上限升序
        let caps = Array(Set(contenders.map(\.handContribution))).sorted()
        var layers: [PotLayer] = []
        var prev = 0
        for cap in caps {
            let amount = players.reduce(0) { sum, p in
                sum + max(0, min(p.handContribution, cap) - prev)
            }
            let eligible = contenders.filter { $0.handContribution >= cap }.map(\.seat)
            if amount > 0 { layers.append(PotLayer(amount: amount, eligibleSeats: eligible)) }
            prev = cap
        }
        pots = layers

        var awards: [PotAward] = []
        for (i, layer) in layers.enumerated() {
            let best = layer.eligibleSeats.map { ranks[$0]! }.max()!
            let winners = layer.eligibleSeats.filter { ranks[$0]! == best }
            let split = splitOddChip(amount: layer.amount, winners: winners,
                                     buttonSeat: buttonSeat, playerCount: players.count)
            for (seat, amount) in split { players[seat].stack += amount }
            awards.append(PotAward(potIndex: i, amount: layer.amount, winners: winners,
                                   perWinner: layer.amount / winners.count,
                                   oddChipSeat: layer.amount % winners.count > 0 ? split[0].seat : nil,
                                   ranks: ranks))
        }
        handResult = HandResult(awards: awards)
        street = .handOver
        actorSeat = nil
    }
}
```

- [ ] **Step 4: 运行确认通过（含恢复 ReducerTests 的 runout 测试）**

Run: `swift test --package-path PokerEngine --filter ShowdownTests 2>&1 | tail -3 && swift test --package-path PokerEngine --filter ReducerTests 2>&1 | tail -3`
Expected: 全部 PASS

- [ ] **Step 5: 提交**

```bash
git add PokerEngine
git commit -m "feat: 摊牌与边池（投入分层、弃牌死钱归池、未跟注退回、奇数筹码顺时针归属）"
```

---

### Task 8: 局间逻辑——nextHand、SNG 淘汰/升盲/奖金/终局

**Files:**
- Modify: `PokerEngine/Sources/PokerEngine/Game/Reducer.swift`（新增 `nextHand()`）
- Test: `PokerEngine/Tests/PokerEngineTests/NextHandTests.swift`

**Interfaces:**
- Consumes: Task 7 全链路
- Produces（Task 9/12 依赖）:
  - `extension GameState { public mutating func nextHand() }`：仅 `.handOver` 且 `!tournamentOver` 时可用；先结算淘汰（本手筹码归零者从最差名次起分配 `finishPlace`，**手初筹码低者名次差**，同筹码时座位小者优先），仅剩 1 人 → `tournamentOver=true` 并按 `payouts` 结算（金额 floor、**余数全部给第 1 名**）；否则 `handNumber += 1`、按钮跳到下一位未淘汰、`dealNewHand()`
  - 现金局：0 筹码玩家同样 eliminated（单机会话语义），无奖金

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import PokerEngine

final class NextHandTests: XCTestCase {
    func testCashButtonRotationAcrossHands() {
        let cfg = GameConfig(playerCount: 4, startingStack: 1000, format: .cash(sb: 5, bb: 10))
        var s = GameState.start(config: cfg, seed: 31, buttonSeat: 0)
        s.apply(.fold); s.apply(.fold); s.apply(.fold)   // 只剩 BB 收池
        XCTAssertEqual(s.street, .handOver)
        s.nextHand()
        XCTAssertEqual(s.handNumber, 1)
        XCTAssertEqual(s.buttonSeat, 1)
        XCTAssertEqual(s.street, .preflop)
    }

    func testSNGBlindLevelAdvancesAtHandTen() {
        let sng = SNGConfig(buyIn: 1000, startingStack: 1500,
                            levels: [BlindLevel(sb: 10, bb: 20, hands: 10),
                                     BlindLevel(sb: 25, bb: 50, hands: 10)],
                            payouts: [0.5, 0.3, 0.2])
        let s = GameState.start(config: GameConfig(playerCount: 3, startingStack: 1500, format: .sng(sng)),
                                seed: 32, buttonSeat: 0, handNumber: 10)
        XCTAssertEqual(s.currentBet, 50)    // 0-based 10 → 第二档
        XCTAssertEqual(s.minRaiseIncrement, 50)
    }

    /// 3 人 SNG：座位 2 (BB) 只有 15（< 盲注 20）→ 发牌即全下；
    /// 座位 0 弃、座位 1 (SB) 加注后手牌自动 runout（2 已 allIn 无需再行动）。
    func testSNGEliminationRecordsPlaceAndGameContinues() {
        let sng = SNGConfig(buyIn: 100, startingStack: 300,
                            levels: [BlindLevel(sb: 10, bb: 20, hands: 50)], payouts: [0.6, 0.4])
        var s = GameState.start(config: GameConfig(playerCount: 3, startingStack: 300, format: .sng(sng)),
                                seed: 33, buttonSeat: 0, stacks: [1000, 300, 15])
        s.apply(.fold)          // 座位 0
        s.apply(.raiseTo(60))   // 座位 1 (SB)；座位 2 已盲注全下 → 自动 runout
        XCTAssertEqual(s.street, .handOver)
        s.nextHand()
        if s.players[2].stack == 0 {
            XCTAssertEqual(s.players[2].finishPlace, 3)
            XCTAssertEqual(s.players[2].status, .eliminated)
            XCTAssertEqual(s.players.filter { $0.status != .eliminated }.count, 2)
        } else {
            XCTAssertEqual(s.players.filter { $0.status == .eliminated }.count, 0)  // 2 赢下主池存活
        }
    }

    /// Review Focus #4（名次 + 奖金取整合并验证）：
    /// 三人翻前全下（0 深筹横扫时 1、2 同手淘汰）。发牌随机，用种子循环找到必然触发
    /// 「0 横扫三池」的种子，然后钉死：手初 500 的拿 place 2、100 的拿 place 3；
    /// 333×3 买入 → 池 999，[0.5,0.3,0.2] → 499/299/199，余 2 归第 1 名 → 501/299/199。
    func testSameHandMultiBustPlacesAndPayoutRounding() {
        let sng = SNGConfig(buyIn: 333, startingStack: 500,
                            levels: [BlindLevel(sb: 10, bb: 20, hands: 50)], payouts: [0.5, 0.3, 0.2])
        let cfg = GameConfig(playerCount: 3, startingStack: 500, format: .sng(sng))
        for seed in UInt64(1)...30 {
            var s = GameState.start(config: cfg, seed: seed, buttonSeat: 0, stacks: [2000, 500, 100])
            s.apply(.raiseTo(2000))   // 0 全下
            s.apply(.call)            // 1 全下 500
            s.apply(.call)            // 2 全下 100
            XCTAssertEqual(s.street, .handOver)
            s.nextHand()
            guard s.tournamentOver else { continue }   // 本种子未横扫三池，换下一个
            XCTAssertEqual(s.players[0].finishPlace, 1)
            XCTAssertEqual(s.players[1].finishPlace, 2)   // 手初 500 > 100 → 名次靠前
            XCTAssertEqual(s.players[2].finishPlace, 3)
            XCTAssertEqual(s.tournamentPayouts.map(\.place), [1, 2, 3])
            XCTAssertEqual(s.tournamentPayouts.first?.amount, 501)
            XCTAssertEqual(s.tournamentPayouts.dropFirst().map(\.amount).sorted(), [199, 299])
            XCTAssertEqual(s.tournamentPayouts.reduce(0) { $0 + $1.amount }, 999)
            return
        }
        XCTFail("30 个种子均未出现 0 横扫三池（未触发同手双淘汰），扩大种子范围后重试")
    }

    /// 现金局破产者同样淘汰、无奖金；仅剩 1 人 → 会话结束。
    func testCashBustMarksEliminated() {
        var s = GameState.start(config: GameConfig(playerCount: 2, startingStack: 1000, format: .cash(sb: 5, bb: 10)),
                                seed: 36, buttonSeat: 0, stacks: [1000, 10])
        // 座位 1 (BB) 只有 10 → 盲注即全下；座位 0 (SB/按钮) 全下后自动 runout
        s.apply(.raiseTo(1000))
        XCTAssertEqual(s.street, .handOver)
        s.nextHand()
        if s.players[1].stack == 0 {
            XCTAssertEqual(s.players[1].status, .eliminated)
            XCTAssertTrue(s.tournamentOver)
            XCTAssertTrue(s.tournamentPayouts.isEmpty)
        }
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --package-path PokerEngine --filter NextHandTests 2>&1 | tail -5`
Expected: FAIL（`nextHand` 未实现）

- [ ] **Step 3: 实现（加到 Reducer.swift）**

```swift
extension GameState {
    /// 结束当前手之后开下一手；或结束锦标赛。
    public mutating func nextHand() {
        guard street == .handOver, !tournamentOver else { return }

        // 1) 淘汰结算：从最差名次起分配；手初筹码低者名次差，同筹码时座位大者名次差
        var remaining = players.filter { $0.status != .eliminated }.count
        let busted = players
            .filter { $0.status != .eliminated && $0.stack == 0 }
            .sorted {
                if $0.stackAtHandStart != $1.stackAtHandStart { return $0.stackAtHandStart < $1.stackAtHandStart }
                return $0.seat > $1.seat
            }
        for p in busted {
            players[p.seat].status = .eliminated
            players[p.seat].finishPlace = remaining
            remaining -= 1
        }

        // 2) 只剩一人 → 终局 + 奖金（SNG）；现金局会话结束无奖金
        if remaining <= 1 {
            let champ = players.first { $0.status != .eliminated }!
            players[champ.seat].finishPlace = 1
            tournamentOver = true
            if case .sng(let cfg) = config.format {
                let pool = cfg.buyIn * config.playerCount
                let floorTotal = cfg.payouts.reduce(0) { $0 + Int(Double(pool) * $1) }
                var entries: [TournamentPayout] = []
                for (i, rate) in cfg.payouts.enumerated() {
                    let place = i + 1
                    let seat = players.first { $0.finishPlace == place }?.seat ?? -1
                    var amount = Int(Double(pool) * rate)
                    if i == 0 { amount += pool - floorTotal }   // 余数归第 1 名
                    entries.append(TournamentPayout(seat: seat, place: place, amount: amount))
                }
                tournamentPayouts = entries
            }
            return
        }

        // 3) 下一手
        handNumber += 1
        buttonSeat = nextSeat(after: buttonSeat)
        dealNewHand()
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --package-path PokerEngine --filter NextHandTests 2>&1 | tail -5`
Expected: PASS。`testSameHandMultiBust` / `testSNGElimination` 有按牌面分叉的断言（已在两分支内），**两个分支都失败才说明实现错误，修实现不改测试**。

- [ ] **Step 5: 提交**

```bash
git add PokerEngine
git commit -m "feat: 局间逻辑（按钮轮转、SNG 升盲/淘汰名次/奖金取整余数归冠军/终局判定、现金会话结束）"
```

---

### Task 9: HandHistory 记录与确定性重放

**Files:**
- Create: `PokerEngine/Sources/PokerEngine/Replay/HandHistory.swift`
- Test: `PokerEngine/Tests/PokerEngineTests/ReplayTests.swift`

**Interfaces:**
- Consumes: Task 8 全链路（含 `nextHand`）
- Produces（Task 12 复盘与第 2 期自博弈依赖）:
  - `struct HandHistory: Equatable, Sendable, Codable { let seed: UInt64; let config: GameConfig; let initialStacks: [Int]; let buttonSeat: Int; let handNumber: Int; let actions: [SeatAction]; static func record(from: GameState) -> HandHistory; static func replay(_: HandHistory) -> GameState }`
  - 契约：`record(from:)` 是**快照**——记录调用时刻已发生的动作，`replay` 重建到同一时刻（手结束后调用即重建到 handOver）

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import PokerEngine

final class ReplayTests: XCTestCase {
    /// 随机打完整整手牌（全合法随机动作），结束后记录 → 重放 → 逐字段相等。
    func testReplayWholeHandEquality() {
        let cfg = GameConfig(playerCount: 6, startingStack: 2000, format: .cash(sb: 10, bb: 20))
        for seed in UInt64(1)...20 {
            var s = GameState.start(config: cfg, seed: seed * 100)
            var rng = SeededGenerator(seed: seed)
            while s.street != .handOver {
                let legal = legalActions(s)
                var pick: PlayerAction
                let roll = Int(rng.next() % 100)
                if let range = legal.betRange, roll < 20 {
                    let span = range.upperBound - range.lowerBound
                    pick = .raiseTo(range.lowerBound + Int(rng.next() % UInt64(max(1, span))))
                } else if legal.canCall, roll < 60 { pick = .call }
                else if legal.canCheck { pick = .check }
                else if legal.canCall { pick = .call }
                else { pick = .fold }
                s.apply(pick)
            }
            let replayed = HandHistory.replay(HandHistory.record(from: s))
            XCTAssertEqual(replayed, s, "seed \(seed)")
        }
    }

    func testReplaySNGHandWithElevatedBlinds() {
        let sng = SNGConfig(buyIn: 1000, startingStack: 1500,
                            levels: [BlindLevel(sb: 10, bb: 20, hands: 2), BlindLevel(sb: 50, bb: 100, hands: 5)],
                            payouts: [0.5, 0.3, 0.2])
        let cfg = GameConfig(playerCount: 3, startingStack: 1500, format: .sng(sng))
        var s = GameState.start(config: cfg, seed: 77, buttonSeat: 0, handNumber: 5, stacks: [900, 2100, 1500])
        XCTAssertEqual(s.currentBet, 100)   // 第 6 手 → 第二档 50/100
        var rng = SeededGenerator(seed: 99)
        while s.street != .handOver {
            let legal = legalActions(s)
            if let range = legal.betRange, rng.next() % 4 == 0 {
                s.apply(.raiseTo(range.upperBound))
            } else if legal.canCall { s.apply(.call) }
            else if legal.canCheck { s.apply(.check) }
            else { s.apply(.fold) }
        }
        XCTAssertEqual(HandHistory.replay(HandHistory.record(from: s)), s)
    }

    func testRecordMidHandReplaysToSameMoment() {
        var s = GameState.start(config: GameConfig(playerCount: 3, startingStack: 1000, format: .cash(sb: 10, bb: 20)),
                                seed: 88, buttonSeat: 0)
        s.apply(.call)
        let snapshot = HandHistory.record(from: s)   // 记录此刻
        s.apply(.call); s.apply(.check)              // 继续打
        XCTAssertEqual(HandHistory.replay(snapshot).actions, snapshot.actions)   // 重放到记录时刻
        XCTAssertNotEqual(HandHistory.replay(snapshot), s)                        // 而不是打完之后
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --package-path PokerEngine --filter ReplayTests 2>&1 | tail -5`
Expected: FAIL（HandHistory 未定义）

- [ ] **Step 3: 实现**

```swift
/// 一手牌的完整重建材料：起点 + 种子 + 动作序列。record 是调用时刻的快照。
public struct HandHistory: Equatable, Sendable, Codable {
    public let seed: UInt64
    public let config: GameConfig
    public let initialStacks: [Int]
    public let buttonSeat: Int
    public let handNumber: Int
    public let actions: [SeatAction]

    public init(seed: UInt64, config: GameConfig, initialStacks: [Int],
                buttonSeat: Int, handNumber: Int, actions: [SeatAction]) {
        self.seed = seed; self.config = config; self.initialStacks = initialStacks
        self.buttonSeat = buttonSeat; self.handNumber = handNumber; self.actions = actions
    }

    public static func record(from state: GameState) -> HandHistory {
        HandHistory(seed: state.seed, config: state.config,
                    initialStacks: state.players.map(\.stackAtHandStart),
                    buttonSeat: state.buttonSeat, handNumber: state.handNumber,
                    actions: state.actions)
    }

    /// 重建：同起点同种子，逐个 apply 已记录动作（到记录时刻）。
    public static func replay(_ h: HandHistory) -> GameState {
        var s = GameState.start(config: h.config, seed: h.seed,
                                stacks: h.initialStacks, buttonSeat: h.buttonSeat,
                                handNumber: h.handNumber)
        for sa in h.actions { s.apply(sa.action) }
        return s
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --package-path PokerEngine --filter ReplayTests 2>&1 | tail -5`
Expected: PASS（20 个种子全等 + SNG 升盲手 + 中途快照）

- [ ] **Step 5: 提交**

```bash
git add PokerEngine
git commit -m "feat: HandHistory 记录与确定性重放（record/replay 快照语义，20 种子逐字段相等）"
```

---

### Task 10: PokerAI 协议与 HeuristicAI 基线

**Files:**
- Create: `PokerEngine/Sources/PokerEngine/AI/PokerAI.swift`
- Create: `PokerEngine/Sources/PokerEngine/AI/HeuristicAI.swift`
- Test: `PokerEngine/Tests/PokerEngineTests/HeuristicAITests.swift`

**Interfaces:**
- Consumes: Task 5/2（legalActions、evaluate）
- Produces（Task 12 VM 与第 2 期依赖）:
  - `protocol PokerAI: Sendable { func decide(_ state: GameState, seat: Int) -> PlayerAction }`
  - `struct HeuristicAI: PokerAI { var aggression: Double; init(aggression: Double = 0.5) }`
  - 契约：返回值必在 `legalActions(state)` 合法集内；只读自己座位的底牌

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import PokerEngine

final class HeuristicAITests: XCTestCase {
    func c(_ s: String) -> Card {
        let r = Array(s)[0], su = Array(s)[1]
        let rank = ["2","3","4","5","6","7","8","9","T","J","Q","K","A"].firstIndex(of: String(r))!
        let suit = ["s","h","d","c"].firstIndex(of: String(su))!
        return Card(rank: Rank(rawValue: rank + 2)!, suit: Suit(rawValue: suit)!)
    }

    func testAAtoOpenRaises() {
        var s = GameState.start(config: GameConfig(playerCount: 6, startingStack: 2000, format: .cash(sb: 10, bb: 20)),
                                seed: 41, buttonSeat: 0)
        s.players[s.actorSeat!].holeCards = [c("Ah"), c("Ad")]
        let ai = HeuristicAI(aggression: 0.5)
        let a = ai.decide(s, seat: s.actorSeat!)
        if case .bet = a { } else if case .raiseTo = a { } else { XCTFail("AA 翻前应加注，得到 \(a)") }
    }

    func testTrashFoldsToFacingRaise() {
        var s = GameState.start(config: GameConfig(playerCount: 6, startingStack: 2000, format: .cash(sb: 10, bb: 20)),
                                seed: 42, buttonSeat: 0)
        s.players[s.actorSeat!].holeCards = [c("7d"), c("2c")]
        let ai = HeuristicAI(aggression: 0.5)
        XCTAssertEqual(ai.decide(s, seat: s.actorSeat!), .fold)
    }

    func testFreeCheckWhenNoBet() {
        var s = GameState.start(config: GameConfig(playerCount: 3, startingStack: 1000, format: .cash(sb: 10, bb: 20)),
                                seed: 43, buttonSeat: 0)
        s.apply(.call); s.apply(.call)                    // 到 BB option，toCall = 0
        s.players[s.actorSeat!].holeCards = [c("7d"), c("2c")]
        let ai = HeuristicAI(aggression: 0.5)
        XCTAssertEqual(ai.decide(s, seat: s.actorSeat!), .check)
    }

    /// Review Focus #5：随机局面采样，AI 输出恒在合法集合（重点覆盖 betRange 为 nil）。
    func testAlwaysLegalOnRandomStates() {
        let cfg = GameConfig(playerCount: 4, startingStack: 1000, format: .cash(sb: 10, bb: 20))
        var sawNoRaiseContext = false
        for seed in UInt64(1)...50 {
            var s = GameState.start(config: cfg, seed: seed * 7)
            let ai = HeuristicAI(aggression: Double(seed % 5) / 4)
            while s.street != .handOver {
                let legal = legalActions(s)
                if legal.betRange == nil { sawNoRaiseContext = true }
                let decision = ai.decide(s, seat: s.actorSeat!)
                XCTAssertTrue(isLegal(decision, in: legal), "seed \(seed) \(decision) vs \(legal)")
                s.apply(decision)
            }
        }
        XCTAssertTrue(sawNoRaiseContext, "采样未覆盖不能加注的局面，扩大采样")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --package-path PokerEngine --filter HeuristicAITests 2>&1 | tail -5`
Expected: FAIL（PokerAI 未定义）

- [ ] **Step 3: 实现**

`PokerAI.swift`：

```swift
import Foundation

/// AI 对手接口。实现必须只依据自己座位的可见信息决策（不偷看他人底牌）。
public protocol PokerAI: Sendable {
    func decide(_ state: GameState, seat: Int) -> PlayerAction
}
```

`HeuristicAI.swift`：

```swift
/// 启发式基线：翻前 Chen 公式，翻后成牌等级 + 听牌加成，底池赔率决策。
public struct HeuristicAI: PokerAI {
    public var aggression: Double   // 0...1
    public init(aggression: Double = 0.5) { self.aggression = aggression }

    public func decide(_ state: GameState, seat: Int) -> PlayerAction {
        let legal = legalActions(state)
        var rng = SeededGenerator(seed: state.seed &* 6_364_136_223_846_793_005
                                    &+ UInt64(state.handNumber)
                                    &+ UInt64(truncatingIfNeeded: seat) &* 97)
        let r = Double(rng.next() % 1000) / 1000.0
        let me = state.players[seat]
        let pot = state.potTotal

        let equity: Double
        if state.street == .preflop {
            equity = 0.25 + chenScore(me.holeCards) * 0.035
        } else {
            equity = postflopStrength(me.holeCards + state.board, street: state.street)
        }

        let raiseThreshold = 0.78 - aggression * 0.08
        if let range = legal.betRange, equity > raiseThreshold {
            if range.upperBound - range.lowerBound < 5 { return .raiseTo(range.upperBound) }
            let raw = Int(Double(pot + 2 * legal.callAmount) * (0.6 + r * 0.5))
            let target = min(max(raw, range.lowerBound), range.upperBound)
            return legal.isRaiseContext ? .raiseTo(target) : .bet(target)
        }
        if legal.canCall, legal.callAmount > 0 {
            let odds = Double(legal.callAmount) / Double(max(1, pot + legal.callAmount))
            let margin = 0.04 - aggression * 0.06
            return equity >= odds + margin ? .call : .fold
        }
        return legal.canCheck ? .check : .fold
    }

    /// Chen 公式（成文实现）：AA=20、KK=16、…、72o≈-1.5。
    func chenScore(_ cards: [Card]) -> Double {
        guard cards.count == 2 else { return 5 }
        let a = cards[0].rank.rawValue, b = cards[1].rank.rawValue
        let hi = Double(max(a, b)), lo = Double(min(a, b))
        var s: Double
        switch hi {
        case 14: s = 10; case 13: s = 8; case 12: s = 7; case 11: s = 6
        default: s = hi / 2
        }
        if a == b { s = max(5, s * 2) }
        if cards[0].suit == cards[1].suit { s += 2 }
        if a != b {
            let gap = Int(hi - lo) - 1
            if gap == 1 { s -= 1 } else if gap == 2 { s -= 2 }
            else if gap == 3 { s -= 4 } else if gap >= 4 { s -= 5 }
            if gap <= 1 && hi < 12 { s += 1 }   // 连张且都 < Q 的顺子潜力
        }
        return s
    }

    /// 翻后强度：成牌类别 + 顶张 + 听牌加成，压到 0.02...0.98。
    func postflopStrength(_ cards: [Card], street: Street) -> Double {
        let rank = HandEvaluator.evaluate(cards)
        var s = 0.30 + Double(rank.category.rawValue) * 0.075
        s += Double(rank.tiebreakers.first ?? 0) / 14.0 * 0.08
        if street == .flop || street == .turn {
            let suitCounts = Dictionary(grouping: cards, by: \.suit).mapValues(\.count)
            if (suitCounts.values.max() ?? 0) == 4 { s += 0.12 }   // 同花听牌
            let uniq = Set(cards.map { $0.rank.rawValue }).sorted()
            var run = 1, best = 1
            for i in 1..<uniq.count {
                run = uniq[i] == uniq[i - 1] + 1 ? run + 1 : 1
                best = max(best, run)
            }
            if best >= 4 { s += 0.08 }                              // 两头顺听牌
        }
        return min(max(s, 0.02), 0.98)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --package-path PokerEngine --filter HeuristicAITests 2>&1 | tail -5`
Expected: PASS（含 50 局全动作合法性采样）

- [ ] **Step 5: 提交**

```bash
git add PokerEngine
git commit -m "feat: PokerAI 协议与 HeuristicAI（Chen 翻前/成牌+听牌翻后/底池赔率，合法性性质测试）"
```

---

### Task 11: App 工程脚手架（xcodegen）与骨架界面

**Files:**
- Create: `PokerApp/project.yml`
- Create: `PokerApp/PokerApp/PokerApp.swift`（@main + 路由 + 占位 GameView）
- Create: `PokerApp/PokerApp/MenuView.swift`
- Create: `PokerApp/PokerAppTests/PlaceholderTests.swift`
- Create: `PokerApp/README.md`
- Generate: `PokerApp/PokerApp.xcodeproj`（xcodegen 产物，**入库**）

**Interfaces:**
- Consumes: `PokerEngine` 本地包（路径 `../PokerEngine`）
- Produces（Task 12/13 依赖）: 可构建的多平台 App 工程（scheme `PokerApp`，iOS + macOS）；`MenuView(onStart:)` 回调 `(GameConfig, UInt64) -> Void`；`GameSession` 类型（config + seed）
- Task 13 会把占位 `GameView` 替换为真实牌桌

- [ ] **Step 1: 安装 xcodegen（如无）**

Run: `which xcodegen || brew install xcodegen`
Expected: `xcodegen` 可用

- [ ] **Step 2: 写 project.yml 与骨架代码**

`PokerApp/project.yml`：

```yaml
name: PokerApp
options:
  bundleIdPrefix: com.interviewlearning.poker
  deploymentTarget:
    iOS: "18.0"
    macOS: "15.0"
packages:
  PokerEngine:
    path: ../PokerEngine
targets:
  PokerApp:
    type: application
    platform: [iOS, macOS]
    sources: [PokerApp]
    dependencies:
      - package: PokerEngine
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
        PRODUCT_BUNDLE_IDENTIFIER: com.interviewlearning.poker.app
        SWIFT_STRICT_CONCURRENCY: complete
  PokerAppTests:
    type: bundle.unit-test
    platform: iOS
    sources: [PokerAppTests]
    dependencies:
      - target: PokerApp
schemes:
  PokerApp:
    build:
      targets:
        PokerApp: all
    test:
      targets: [PokerAppTests]
```

`PokerApp/PokerApp/PokerApp.swift`：

```swift
import SwiftUI
import PokerEngine

@main
struct PokerApp: App {
    @State private var session: GameSession?

    var body: some Scene {
        WindowGroup {
            if let session {
                GameView(session: session) { session = nil }
            } else {
                MenuView { config, seed in
                    session = GameSession(config: config, seed: seed)
                }
            }
        }
    }
}

/// 一场会话（配置 + 种子）。
struct GameSession: Identifiable {
    let id = UUID()
    let config: GameConfig
    let seed: UInt64
}

/// Task 13 替换为完整牌桌。
struct GameView: View {
    let session: GameSession
    let onExit: () -> Void

    var body: some View {
        Text("牌桌（Task 13）")
    }
}
```

`PokerApp/PokerApp/MenuView.swift`：

```swift
import SwiftUI
import PokerEngine

struct MenuView: View {
    let onStart: (GameConfig, UInt64) -> Void
    @State private var isSNG = false
    @State private var playerCount = 6
    @State private var cashSB = 10
    @State private var cashStack = 2000
    @State private var buyIn = 1000

    private var config: GameConfig {
        let format: GameFormat = isSNG
            ? .sng(SNGConfig(buyIn: buyIn, startingStack: 1500,
                             levels: [BlindLevel(sb: 10, bb: 20, hands: 12),
                                      BlindLevel(sb: 25, bb: 50, hands: 12),
                                      BlindLevel(sb: 50, bb: 100, hands: 12),
                                      BlindLevel(sb: 100, bb: 200, hands: 12)],
                             payouts: [0.5, 0.3, 0.2]))
            : .cash(sb: cashSB, bb: cashSB * 2)
        return GameConfig(playerCount: playerCount,
                          startingStack: isSNG ? 1500 : cashStack,
                          format: format)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("模式", selection: $isSNG) {
                    Text("现金局").tag(false)
                    Text("单桌锦标赛 SNG").tag(true)
                }
                Stepper("玩家人数：\(playerCount)", value: $playerCount, in: 2...9)
                if isSNG {
                    Stepper("买入：\(buyIn)", value: $buyIn, in: 100...10000, step: 100)
                } else {
                    Stepper("小盲：\(cashSB)", value: $cashSB, in: 1...1000, step: 5)
                    Stepper("初始筹码：\(cashStack)", value: $cashStack, in: 500...100000, step: 500)
                }
                Button("开始游戏") {
                    onStart(config, UInt64(Date().timeIntervalSince1970 * 1000))
                }
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("德州扑克")
        }
    }
}
```

`PokerApp/PokerAppTests/PlaceholderTests.swift`：

```swift
import XCTest

final class PlaceholderTests: XCTestCase {
    func testPlaceholder() { XCTAssertTrue(true) }
}
```

`PokerApp/README.md`（内容如下，注意其中 bash 块）：

````markdown
# PokerApp

单机德州扑克（现金局 + SNG）。引擎见 `../PokerEngine`（纯 Swift Package，`swift test` 可独立运行）。

## 构建

```bash
cd PokerApp && xcodegen generate
xcodebuild -project PokerApp.xcodeproj -scheme PokerApp -destination 'platform=macOS' build
xcodebuild -project PokerApp.xcodeproj -scheme PokerApp -destination 'generic/platform=iOS Simulator' build
```

或直接用 Xcode 打开 `PokerApp.xcodeproj`。
````

- [ ] **Step 3: 生成工程并双平台构建**

```bash
cd PokerApp && xcodegen generate && \
xcodebuild -project PokerApp.xcodeproj -scheme PokerApp -destination 'platform=macOS' build 2>&1 | tail -3 && \
xcodebuild -project PokerApp.xcodeproj -scheme PokerApp -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3
```
Expected: 两个 build 均 `BUILD SUCCEEDED`

- [ ] **Step 4: 提交**

```bash
git add PokerApp
git commit -m "feat: App 工程脚手架（xcodegen 多平台、引擎包接入、主菜单）"
```

---

### Task 12: GameViewModel（含后台 AI 驱动）

**Files:**
- Create: `PokerApp/PokerApp/GameViewModel.swift`
- Test: `PokerApp/PokerAppTests/GameViewModelTests.swift`

**Interfaces:**
- Consumes: 引擎全部公开 API（`GameState.start/apply/nextHand`、`legalActions`、`HandResult`、`HeuristicAI`）
- Produces（Task 13 UI 依赖）:
  - `@MainActor final class GameViewModel: ObservableObject`：
    - `@Published private(set) var state: GameState`
    - `private(set) var lastResult: HandResult?`（非 published 的上一手结算，供复盘展示）
    - `init(config: GameConfig, seed: UInt64, bots: [Int: any PokerAI]? = nil, thinkMilliseconds: Int = 700)`
    - `var humanLegal: LegalActions?`（仅轮到人类且在下注街时非 nil）
    - `func act(_ action: PlayerAction) async`
    - `func nextHand() async`
    - `func driveBots() async`（UI 需在 `.task {}` 中调用一次以启动机器人先手的局面）
    - `var isHandOver: Bool`、`var isSessionOver: Bool`

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import PokerApp
import PokerEngine

final class GameViewModelTests: XCTestCase {
    func testFullHandRunsAndProducesResult() async {
        let vm = GameViewModel(config: GameConfig(playerCount: 3, startingStack: 1000,
                                                  format: .cash(sb: 10, bb: 20)),
                               seed: 51, thinkMilliseconds: 1)
        for _ in 0..<300 {
            if vm.isHandOver || vm.isSessionOver { break }
            if vm.humanLegal != nil {
                await vm.act(.fold)      // 人类永远弃牌，最快推进
            } else {
                await vm.driveBots()
            }
        }
        XCTAssertTrue(vm.isHandOver || vm.isSessionOver)
        XCTAssertNotNil(vm.state.handResult)
    }

    func testNextHandCapturesLastResultAndAdvances() async {
        let vm = GameViewModel(config: GameConfig(playerCount: 3, startingStack: 1000,
                                                  format: .cash(sb: 10, bb: 20)),
                               seed: 52, thinkMilliseconds: 1)
        while !(vm.isHandOver || vm.isSessionOver) {
            if vm.humanLegal != nil { await vm.act(.fold) }
            else { await vm.driveBots() }
        }
        let first = vm.state.handResult
        let before = vm.state.handNumber
        if !vm.isSessionOver {
            await vm.nextHand()
            XCTAssertEqual(vm.state.handNumber, before + 1)
            XCTAssertEqual(vm.state.street, .preflop)
            XCTAssertEqual(vm.lastResult, first)   // 上一手结果被留存
        }
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `xcodebuild -project PokerApp/PokerApp.xcodeproj -scheme PokerApp -showdestinations 2>&1 | grep "iPhone"`（选一个模拟器名，下称 `$SIM`）
Run: `xcodebuild test -project PokerApp/PokerApp.xcodeproj -scheme PokerApp -destination "platform=iOS Simulator,name=$SIM" 2>&1 | tail -5`
Expected: FAIL（GameViewModel 未定义）

- [ ] **Step 3: 实现**

`PokerApp/PokerApp/GameViewModel.swift`：

```swift
import Foundation
import Combine
import PokerEngine

@MainActor
final class GameViewModel: ObservableObject {
    @Published private(set) var state: GameState
    private(set) var lastResult: HandResult?
    private let bots: [Int: any PokerAI]
    private let thinkNanos: UInt64

    init(config: GameConfig, seed: UInt64,
         bots: [Int: any PokerAI]? = nil, thinkMilliseconds: Int = 700) {
        state = .start(config: config, seed: seed)
        let defaults: [Int: any PokerAI] = Dictionary(uniqueKeysWithValues:
            (0..<config.playerCount).filter { $0 != config.humanSeat }
                .map { ($0, HeuristicAI(aggression: 0.5) as any PokerAI) })
        self.bots = bots ?? defaults
        thinkNanos = UInt64(max(1, thinkMilliseconds)) * 1_000_000
    }

    var humanLegal: LegalActions? {
        guard state.actorSeat == state.config.humanSeat,
              [.preflop, .flop, .turn, .river].contains(state.street) else { return nil }
        return legalActions(state)
    }

    var isHandOver: Bool { state.street == .handOver }
    var isSessionOver: Bool { state.tournamentOver }

    /// 人类行动，然后驱动机器人直到再次轮到人类或本手结束。
    func act(_ action: PlayerAction) async {
        guard state.actorSeat == state.config.humanSeat else { return }
        state.apply(action)
        await driveBots()
    }

    func nextHand() async {
        guard state.street == .handOver, !state.tournamentOver else { return }
        lastResult = state.handResult
        state.nextHand()
        await driveBots()
    }

    /// 驱动机器人直到回到人类或本手结束。UI 需在 .task {} 调用一次（机器人先手的开局）。
    func driveBots() async {
        while let seat = state.actorSeat,
              seat != state.config.humanSeat,
              let bot = bots[seat] {
            let snapshot = state
            let decision = await Task.detached(priority: .userInitiated) {
                bot.decide(snapshot, seat: seat)
            }.value
            try? await Task.sleep(nanoseconds: thinkNanos)
            guard state.actorSeat == seat else { return }   // 防竞态：状态未变才应用
            state.apply(decision)
        }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `xcodebuild test -project PokerApp/PokerApp.xcodeproj -scheme PokerApp -destination "platform=iOS Simulator,name=$SIM" 2>&1 | tail -5`
Expected: PASS（2 个测试）

- [ ] **Step 5: 提交**

```bash
git add PokerApp
git commit -m "feat: GameViewModel（引擎状态快照、后台 AI 驱动、拟人延迟、防竞态应用、上一手结果留存）"
```

---

### Task 13: 牌桌 UI 全量（座位/公共牌/行动条/结算/SNG 结算页）+ 终验

**Files:**
- Create: `PokerApp/PokerApp/CardView.swift`
- Create: `PokerApp/PokerApp/TableView.swift`（GameView 真身 + SeatView/BoardView/ActionBar/浮层）
- Modify: `PokerApp/PokerApp/PokerApp.swift`（删除占位 GameView，路由不变）

**Interfaces:**
- Consumes: Task 12 的 `GameViewModel` 全部 API
- Produces: 最终 UI；验收 = 双平台 build + 全测试套件绿

- [ ] **Step 1: 实现视图（UI 无 TDD，验收以构建 + 既有测试回归为准）**

`CardView.swift`：

```swift
import SwiftUI
import PokerEngine

struct CardView: View {
    let card: Card?
    var hidden = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.background)
                .shadow(radius: 2)
            if let card, !hidden {
                VStack(spacing: 2) {
                    Text(card.rank.symbol).font(.system(size: 16, weight: .bold))
                    Text(card.suit.symbol).font(.system(size: 14))
                }
                .foregroundColor([Suit.heart, .diamond].contains(card.suit) ? .red : .primary)
            } else if hidden {
                Image(systemName: "questionmark").foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 50)
    }
}
```

`TableView.swift`：

```swift
import SwiftUI
import PokerEngine

struct GameView: View {
    @StateObject private var vm: GameViewModel
    let onExit: () -> Void

    init(session: GameSession, onExit: @escaping () -> Void) {
        _vm = StateObject(wrappedValue: GameViewModel(config: session.config, seed: session.seed))
        self.onExit = onExit
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TableView(vm: vm)
            if vm.isSessionOver {
                sessionOverlay
            } else if vm.isHandOver {
                resultOverlay
            } else if let legal = vm.humanLegal {
                ActionBar(vm: vm, legal: legal)
            } else {
                Text("等待对手…").padding()
            }
        }
        .task { await vm.driveBots() }   // 机器人先手的开局在这里启动
    }

    private var header: some View {
        HStack {
            Button("退出") { onExit() }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if case .sng = vm.state.config.format {
                    let (sb, bb) = currentBlinds(for: vm.state.config.format, handNumber: vm.state.handNumber)
                    Text("第 \(vm.state.handNumber + 1) 手 · 盲注 \(sb)/\(bb)")
                        .font(.footnote)
                } else {
                    Text("第 \(vm.state.handNumber + 1) 手").font(.footnote)
                }
                if let last = vm.lastResult, let w = last.awards.last?.winners.first {
                    Text("上一手：\(vm.state.players[w].name) 赢 \(last.awards.reduce(0) { $0 + $1.amount })")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    private var resultOverlay: some View {
        VStack(spacing: 12) {
            ForEach(vm.state.handResult?.awards ?? [], id: \.potIndex) { award in
                let names = award.winners.map { vm.state.players[$0].name }.joined(separator: "、")
                Text("\(names) 赢 \(award.amount)")
            }
            Button("下一手") { Task { await vm.nextHand() } }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    private var sessionOverlay: some View {
        VStack(spacing: 8) {
            Text(vm.state.tournamentPayouts.isEmpty ? "会话结束" : "锦标赛结束")
                .font(.title2.bold())
            ForEach(vm.state.tournamentPayouts, id: \.place) { p in
                Text("第 \(p.place) 名 · \(vm.state.players[p.seat].name) · \(p.amount)")
            }
            Button("回到菜单") { onExit() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}

private struct TableView: View {
    @ObservedObject var vm: GameViewModel

    var body: some View {
        GeometryReader { geo in
            let n = vm.state.players.count
            ZStack {
                ForEach(vm.state.players) { p in
                    let angle = Double(p.seat) / Double(n) * 2 * .pi + .pi / 2   // 座位 0 在正下方
                    SeatView(player: p,
                             isActor: vm.state.actorSeat == p.seat,
                             isButton: vm.state.buttonSeat == p.seat,
                             isHuman: p.seat == vm.state.config.humanSeat,
                             street: vm.state.street)
                        .position(x: geo.size.width / 2 + cos(angle) * geo.size.width * 0.38,
                                  y: geo.size.height / 2 + sin(angle) * geo.size.height * 0.36)
                }
                VStack(spacing: 8) {
                    Text("底池 \(vm.state.potTotal)").font(.headline)
                    HStack(spacing: 6) {
                        ForEach(0..<5, id: \.self) { i in
                            CardView(card: i < vm.state.board.count ? vm.state.board[i] : nil)
                        }
                    }
                }
            }
        }
    }
}

private struct SeatView: View {
    let player: PlayerState
    let isActor: Bool
    let isButton: Bool
    let isHuman: Bool
    let street: Street

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text(player.name).font(.caption.bold())
                if isButton { Image(systemName: "circle.fill").font(.caption2) }
            }
            HStack(spacing: 3) {
                if player.holeCards.count == 2 {
                    CardView(card: player.holeCards[0], hidden: !isHuman && street != .handOver)
                    CardView(card: player.holeCards[1], hidden: !isHuman && street != .handOver)
                } else {
                    CardView(card: nil).opacity(0.3)
                    CardView(card: nil).opacity(0.3)
                }
            }
            Text("筹码 \(player.stack)").font(.caption.monospacedDigit())
            if player.streetContribution > 0 {
                Text("投入 \(player.streetContribution)").font(.caption2).foregroundStyle(.secondary)
            }
            if player.status == .folded { Text("弃牌").font(.caption2).foregroundStyle(.red) }
            if player.status == .allIn { Text("全下").font(.caption2).foregroundStyle(.orange) }
        }
        .padding(8)
        .background(isActor ? Color.yellow.opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isActor ? .yellow : .clear))
    }
}

private struct ActionBar: View {
    @ObservedObject var vm: GameViewModel
    let legal: LegalActions
    @State private var raiseTarget: Double = 0

    var body: some View {
        VStack(spacing: 8) {
            if let range = legal.betRange, range.lowerBound < range.upperBound {
                HStack {
                    Text("\(legal.isRaiseContext ? "加注到" : "下注") \(Int(raiseTarget))")
                        .font(.footnote.monospacedDigit())
                    Slider(value: $raiseTarget,
                           in: Double(range.lowerBound)...Double(range.upperBound))
                }
                HStack {
                    quick("最小", Double(range.lowerBound))
                    quick("1/2 池", potTarget(vm.state.potTotal / 2))
                    quick("满池", potTarget(vm.state.potTotal))
                    quick("全下", Double(range.upperBound))
                }
            }
            HStack(spacing: 12) {
                Button("弃牌") { Task { await vm.act(.fold) } }
                    .buttonStyle(.bordered)
                if legal.canCheck {
                    Button("过牌") { Task { await vm.act(.check) } }.buttonStyle(.bordered)
                }
                if legal.canCall, legal.callAmount > 0 {
                    Button("跟注 \(legal.callAmount)") { Task { await vm.act(.call) } }
                        .buttonStyle(.bordered)
                }
                if let range = legal.betRange {
                    if range.lowerBound == range.upperBound {
                        Button("全下 \(range.upperBound)") { Task { await vm.act(.raiseTo(range.upperBound)) } }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(legal.isRaiseContext ? "加注" : "下注") {
                            Task { await vm.act(.raiseTo(Int(raiseTarget))) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding()
        .background(.bar)
        .onAppear {
            if let r = legal.betRange { raiseTarget = Double(min(r.lowerBound + (r.upperBound - r.lowerBound) / 2, r.upperBound)) }
        }
    }

    private func potTarget(_ base: Int) -> Double {
        guard let r = legal.betRange else { return 0 }
        let t = Double(base + vm.state.currentBet)
        return min(max(t, Double(r.lowerBound)), Double(r.upperBound))
    }

    private func quick(_ label: String, _ target: Double) -> some View {
        Button(label) { raiseTarget = target }
            .buttonStyle(.bordered)
            .font(.caption)
    }
}

extension PlayerState: Identifiable { public var id: Int { seat } }
```

- [ ] **Step 2: 双平台构建 + 全量测试回归**

```bash
cd PokerEngine && swift test 2>&1 | tail -3
cd ../PokerApp && xcodegen generate && \
xcodebuild -project PokerApp.xcodeproj -scheme PokerApp -destination 'platform=macOS' build 2>&1 | tail -2 && \
xcodebuild -project PokerApp.xcodeproj -scheme PokerApp -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -2 && \
xcodebuild test -project PokerApp.xcodeproj -scheme PokerApp -destination "platform=iOS Simulator,name=$SIM" 2>&1 | tail -3
```
Expected: 引擎全绿；三个 xcodebuild 均 SUCCEEDED / TEST SUCCEEDED

- [ ] **Step 3: 手工冒烟（有 GUI 环境时；无则跳过并注明）**

Run: `open PokerApp/PokerApp.xcodeproj`，Xcode 运行 iOS 模拟器
Expected: 菜单 → 现金局 3 人 → 打完一手 → 「下一手」连续多手；SNG 打到终局出名次结算页

- [ ] **Step 4: 提交**

```bash
git add PokerApp
git commit -m "feat: 牌桌 UI 全量（椭圆座位、公共牌、行动条/快捷加注、结算浮层、上一手回顾、SNG 终局页）"
```

---

## 任务依赖与里程碑映射

- M1（引擎核心，2 人现金局可跑通）= Task 1–7
- M2（全形式 + AI + 重放）= Task 8–10
- M3（App）= Task 11–13
- 线性依赖：每个 Task 依赖前序 Task 的 Produces 接口；Task 5→6 有显式 TASK6-DEFERRED 交接；Task 6→7 有 showdown 空壳交接与 XCTSkip 启用点。

## 执行者注意事项（成文）

1. **不要「修复」测试来让实现通过**——测试是契约；实现与测试冲突时先怀疑实现（重算底池守恒、重查规则），确认测试构造本身错误才可改测试并说明。
2. 引擎热路径（apply/dealNewHand/evaluate）避免不必要的类分配与拷贝；第 2 期要跑自博弈吞吐。
3. `xcodebuild` 模拟器名以 `-showdestinations` 实际输出为准（记为 `$SIM`）。
4. 每任务结束必须全量 `swift test --package-path PokerEngine` 回归，防止前序行为回归。
5. 提交信息用中文，一个任务一个提交，不混合多任务改动。
6. SNG `SNGConfig.validated` 未在引擎内强制调用（构造宽松、校验显式）；App 菜单的内置配置已满足校验。
