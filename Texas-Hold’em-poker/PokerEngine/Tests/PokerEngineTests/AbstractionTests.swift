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
        XCTAssertLessThan(b("Ah 3d"), b("2c 2d"))   // 高牌 < 三条（"2c 2d" 撞面上 2h 成暗三条；原注释"一对"系笔误）
        XCTAssertLessThan(b("2c 9d"), b("7h 7s"))   // 两对(99-22) < 三条(777)：原构造"葫芦77"在无配对翻牌 2h7d9c 上不可达成（手推修正）
        XCTAssertGreaterThanOrEqual(b("Ah Ad"), b("4c 4d"))  // 顶对不低于低对（细分不倒挂；"2c 2d"实为三条，改真·空袋低对，手推修正）
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
        // 翻前按钮位 ladder = [call, fold, 最小40, ½池60, 全下2000]（½池=40 与最小加注 clamp 去重，3 个加注档）；
        // 抽象层去最小加注档（3 档 ≥2 → 丢 40），保留档按位 [½池, 全下]：60→raiseHalf、2000→allIn
        XCTAssertEqual(slots.map(\.slot), [.call, .fold, .raiseHalf, .allIn])
        XCTAssertFalse(slots.contains { $0.slot == .raiseMin })   // 最小加注档无槽位映射（设计性死位）
        // 短码单点区间：归并后仅剩一个加注档且为全下
        let short = GameState.start(config: GameConfig(playerCount: 2, startingStack: 2000, format: .cash(sb: 10, bb: 20)),
                                    seed: 5, stacks: [25, 2000], buttonSeat: 0)   // 编译强制：stacks 先于 buttonSeat
        let s2 = Abstraction.slots(for: ladderActions(legalActions(short), state: short), legal: legalActions(short))
        let raiseSlots = s2.filter { $0.slot == .raiseMin || $0.slot == .allIn }
        XCTAssertEqual(raiseSlots.count, 1)
        XCTAssertEqual(s2.last?.slot, AbstractSlot.allIn)   // 编译强制：可选上下文需显式类型
    }
}
