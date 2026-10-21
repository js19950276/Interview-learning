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
        var s = GameState.start(config: cfg, seed: 21, stacks: [900, 500, 300], buttonSeat: 0)
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
        // T7 裁决：brief 原文 stacks [1000,1000,300] 与其自身断言矛盾——座位 2 需投入 320
        //（BB 20 + 翻牌 300）但只有 300；改为 320 使"翻牌全下 300"成立，守恒 2320。
        var s = GameState.start(config: cfg, seed: 22, stacks: [1000, 1000, 320], buttonSeat: 0)
        s.apply(.call)     // 座位 0 跟 20
        s.apply(.fold)     // 座位 1 (SB) 弃，死钱 10
        s.apply(.check)    // 座位 2 (BB) option → flop
        // flop 首行动 = 按钮顺时针下一位 active = 座位 2（1 已弃）
        s.apply(.bet(300))      // 座位 2 全下 300
        s.apply(.raiseTo(800))  // 座位 0 加注到 800（合法区间 600...980）
        XCTAssertEqual(s.street, .handOver)   // 2 allIn、0 唯一 active → runout + showdown
        XCTAssertEqual(s.pots.count, 2)
        XCTAssertEqual(s.pots[0].amount, 650)            // 320+10+320
        XCTAssertEqual(s.pots[0].eligibleSeats, [0, 2])
        XCTAssertEqual(s.pots[1].amount, 500)            // 未被跟注的 500
        XCTAssertEqual(s.pots[1].eligibleSeats, [0])
        // 0 无论比牌输赢，未跟注的 500 必回自己（0 本手共投入 820，剩余 180）
        XCTAssertEqual(s.players[0].stack, 180 + 500 + (s.handResult!.awards[0].winners.contains(0) ? 650 : 0))
        XCTAssertEqual(s.players.reduce(0) { $0 + $1.stack }, 2320)   // 守恒（1000+1000+320）
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
        var s = GameState.start(config: cfg, seed: 23, stacks: [300, 1000, 300], buttonSeat: 0)
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
