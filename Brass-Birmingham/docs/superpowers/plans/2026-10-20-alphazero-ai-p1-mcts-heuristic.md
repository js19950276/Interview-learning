# AlphaZero AI P1(纯 MCTS AI + 单机对 AI)实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付不依赖任何训练的可用 AI:PUCT 树搜索(MaxN 多人备份)+ 启发式评估 + 宿主侧 AI 驱动器 + 单机对 AI 模式,并用 arena CLI 验证棋力(随机席胜率 ≤15%)。

**Architecture:** 两阶段。Stage A(纯 Swift,CLI 可验):`GameCore/AI/` 下启发式评估器与 MCTS 搜索核心,复用 P0 的 `FastActionEnumerator`(完备枚举,作者已定)与 `SimulationRunner`,节点惰性展开(每节点只枚举一次);Stage B(App 集成):`SessionCoordinator` 增加 AI 座位本地开局与代提交路径(只走宿主 `resolve` 权威门,不碰多人协议),`AIPlayerDriver` 监听状态流驱动 AI 座位,Home 增加单人挑战入口;`tools/p1-arena` CLI 承担棋力验收(macOS 权威测量环境)。

**Tech Stack:** Swift(GameCore `nonisolated` 纯值语义)、Swift Testing、xcodebuild(iOS 模拟器,只做正确性;性能测量在 macOS CLI)、swiftc 直编 CLI(P0 已验证零 UI 依赖)。

**Spec:** `docs/superpowers/specs/2026-10-11-alphazero-ai-design.md`(§7 MCTS 设计、§7.1 启发式评估、§10.1 单机模式、§10.3 AIPlayerDriver、§11 P1 验收)

**P0 基线:** 已合并 main(`1ce76be`)。枚举 macOS -O 实测 avg 123ms/状态;MCTS 节点惰性展开使每步搜索的枚举次数 ≈ 新访问节点数。

## Global Constraints

- 规则引擎语义零修改:`Rules/*.swift`、`GameCore.swift`、`GameState.swift` 不得改动(本计划不需要);AI 新代码全部进 `GameCore/AI/`、`Session/`、`Features/`。
- 枚举一律完备模式(`FastActionEnumerator.enumerate`,无 limit)——作者 2026-10-19 拍板,P1 MCTS 每节点树内子女=全部枚举动作,PUCT 天然聚焦。
- 性能测量/棋力验收环境 = macOS CLI(`swiftc -O -D DEBUG` 直编,P0 模式);iOS 模拟器只跑正确性断言;模拟器上不做任何时延门禁。
- 测试命令(与 P0 相同,iOS 侧):

  ```bash
  cd <repo>/Brass-Birmingham/ui-prototype && \
  xcodebuild test -scheme IndustrialCityBirmingham \
    -destination 'platform=iOS Simulator,id=6EA1BDBE-769D-441F-90B4-CA6CBE573389' \
    -derivedDataPath /tmp/bb_p0_iso_dd \
    -parallel-testing-enabled NO \
    -only-testing:IndustrialCityBirminghamTests 2>&1 | tail -25
  ```

  专用模拟器 `P0-Test-iPhone`(6EA1BDBE)已存在;若被用户会话占用,等待或提示用户,不得与其并发共用同一模拟器。Swift Testing 套件级过滤不可用,每轮全 target(约 5-8 分钟)。
- 工作区纪律:P0 的台账与 worktree 流程沿用;若主树有用户在途改动,先 `git status` 核对触碰文件零重叠再开工(Stage A 新文件全在 GameCore/AI/ 与 tests,天然无重叠;Stage B 触碰 SessionCoordinator.swift/HomeView.swift/RootView——开工前必须核对这两个文件干净,脏则停下请用户先落地)。
- 全部新类型遵守 GameCore `nonisolated` + Sendable 值语义风格;不新增第三方依赖。
- 用户在途改动(含 LegalActionQueryEngine.swift 的 saleBeerLabel)绝不 commit/revert。

## Review Focus

1. **MaxN 备份的"轮到谁最大化谁"**——多人局回传错玩家视角会让 AI 帮对手下棋。测试:Task 2 Step 1 合成树数学验证 + 终局排名效用方向(自己第一=1.0)。
2. **AI 座位绝不动人类座位**——驱动器只在 `activePlayerID ∈ aiSeatIDs` 时行动。测试:Task 5 Step 1。
3. **取消正确性**——人类撤回/对局结束时搜索必须立即停,不得在旧状态上提交。测试:Task 5 Step 3。
4. **单机模式不污染多人协议**——AI 座位不进大厅名册广播、不发快照、不进持久化;`submitAs` 只对 aiSeatIDs 开放。测试:Task 4 Step 1/3。
5. **预算超时截断**——`timeLimitMs` 到点必须停并返回当前最优,不得无限搜。测试:Task 2 Step 4。

---

## Stage A:AI 核心(纯 Swift,CLI 可验)

### Task 1: HeuristicEvaluator——启发式评估函数

**Files:**
- Create: `ui-prototype/IndustrialCityBirmingham/GameCore/AI/HeuristicEvaluator.swift`
- Test: `ui-prototype/IndustrialCityBirminghamTests/HeuristicEvaluatorTests.swift`

**Interfaces:**
- Consumes: `GameState`(players/boardIndustryPlacements/placedLinks/finalStandings)、`SetupRules(seed:).makeGame(catalog:playerIDs:)`、verifiedCatalog 测试辅助(P0 各测试文件同名函数,原样复制,sources id 换 `heuristic-tests`)。
- Produces(Task 2/3、arena、P3 降级路径依赖):

```swift
extension GameCore {
    nonisolated enum HeuristicEvaluator {
        /// 原始启发式分(spec §7.1,权重初值人工设定、不训练)。
        /// score = 0.01·cash + income/10 + 1.0·VP + Σ产业(未翻转 1+level,已翻转 0.5·(1+level))
        ///        + 0.3·链接数 + 0.2·手牌数
        static func scores(state: GameState) -> [PlayerID: Double]
        /// 排名效用:同分并列同组,r 从 1 起,v=(n−r)/(n−1);终局用 finalStandings,
        /// 非终局用 scores 排名。返回 0…1,恰好覆盖所有玩家。
        static func utilities(state: GameState) -> [PlayerID: Double]
    }
}
```

- [ ] **Step 1: 写失败测试**

```swift
import Foundation
import Testing

@testable import IndustrialCityBirmingham

struct HeuristicEvaluatorTests {
    // verifiedCatalog() 与 freshFourPlayerState(catalog:) 从 FastActionEnumeratorTests.swift
    // 原样复制(种子改 20_501,sources id "heuristic-tests")。

    @Test func freshStateScoresMatchHandTunedFormula() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let scores = GameCore.HeuristicEvaluator.scores(state: state)
        #expect(scores.count == 4)
        // 开局各家同分(对称)。
        #expect(Set(scores.values.map { String(format: "%.6f", $0) }).count == 1)
        let p = state.players[0]
        let income = try #require(
            catalog.catalog.incomeTrack.entries.first { $0.position == p.incomePosition }?.income
        )
        let handBonus = 0.2 * Double(p.hand.count)
        let expected = 0.01 * Double(p.cash) + Double(income) / 10
            + Double(p.victoryPoints) + handBonus
        #expect(abs((scores[p.id] ?? 0) - expected) < 1e-9)
    }

    @Test func richerPlayerOutranksPoorer() throws {
        let catalog = try verifiedCatalog()
        var state = try freshFourPlayerState(catalog: catalog)
        state.players[0].cash += 100
        state.players[0].victoryPoints += 10
        let utilities = GameCore.HeuristicEvaluator.utilities(state: state)
        #expect(utilities[state.players[0].id] == 1.0)
        #expect(utilities[state.players[1].id]! < 1.0)
    }

    @Test func terminalUtilitiesFollowFinalStandings() throws {
        let catalog = try verifiedCatalog()
        var state = try freshFourPlayerState(catalog: catalog)
        let winner = state.players[0].id
        state.turnPhase = .ended
        state.finalStandings = [[winner], [state.players[1].id, state.players[2].id], [state.players[3].id]]
        let utilities = GameCore.HeuristicEvaluator.utilities(state: state)
        #expect(utilities[winner] == 1.0)
        // 并列第二:同组同效用 (4−2)/(4−1) = 2/3。
        #expect(abs(utilities[state.players[1].id]! - 2.0 / 3.0) < 1e-9)
        #expect(abs(utilities[state.players[2].id]! - 2.0 / 3.0) < 1e-9)
        #expect(utilities[state.players[3].id] == 0.0)
    }

    @Test func scoresCoverIndustryAndLinkTerms() throws {
        let catalog = try verifiedCatalog()
        var state = try freshFourPlayerState(catalog: catalog)
        let p0 = state.players[0]
        let tile = p0.industryStacks[0].tiles[0]
        state.boardIndustryPlacements = [
            .init(locationID: "birmingham", slotIndex: 0, ownerID: p0.id, tile: tile),
            .init(locationID: "birmingham", slotIndex: 1, ownerID: p0.id, tile: tile, isFlipped: true),
        ]
        state.placedLinks = [
            .init(routeID: "r1", ownerID: p0.id, era: .canal),
            .init(routeID: "r2", ownerID: p0.id, era: .canal),
        ]
        let scores = GameCore.HeuristicEvaluator.scores(state: state)
        let base = GameCore.HeuristicEvaluator.scores(state: try freshFourPlayerState(catalog: catalog))
        let delta = scores[p0.id]! - base[p0.id]!
        let industryTerm = Double(1 + tile.level) + 0.5 * Double(1 + tile.level)
        let linkTerm = 0.3 * 2
        #expect(abs(delta - (industryTerm + linkTerm)) < 1e-9)
    }
}
```

注意 `birmingham` 的 slotIndex 0/1 是否为该 tile 的合法产业槽不影响评估器(它只数格子,不验规则);`tile` 取 0 号玩家第一个产业堆顶。

- [ ] **Step 2: 跑测试确认失败**——Run: 全 target 命令;Expected: FAIL,`type 'GameCore' has no member 'HeuristicEvaluator'`。
- [ ] **Step 3: 实现**

```swift
import Foundation

extension GameCore {
    /// P1 纯启发式评估(spec §7.1):权重初值人工设定、不训练;
    /// P3 网络模型加载失败时也退回到这里。
    nonisolated enum HeuristicEvaluator {
        static func scores(state: GameState) -> [PlayerID: Double] {
            var placementsByOwner: [PlayerID: (flipped: Double, unflipped: Double)] = [:]
            for placement in state.boardIndustryPlacements {
                let value = Double(1 + placement.tile.level)
                var slot = placementsByOwner[placement.ownerID] ?? (0, 0)
                if placement.isFlipped { slot.flipped += value } else { slot.unflipped += value }
                placementsByOwner[placement.ownerID] = slot
            }
            var linksByOwner: [PlayerID: Int] = [:]
            for link in state.placedLinks {
                linksByOwner[link.ownerID, default: 0] += 1
            }
            var incomeByPosition: [Int: Int] = [:]
            for entry in state.incomeTrackEntriesOrEmpty { incomeByPosition[entry.position] = entry.income }
            var result: [PlayerID: Double] = [:]
            for player in state.players {
                let income = incomeByPosition[player.incomePosition] ?? 0
                let placement = placementsByOwner[player.id] ?? (0, 0)
                result[player.id] =
                    0.01 * Double(player.cash)
                    + Double(income) / 10
                    + Double(player.victoryPoints)
                    + placement.unflipped + 0.5 * placement.flipped
                    + 0.3 * Double(linksByOwner[player.id] ?? 0)
                    + 0.2 * Double(player.hand.count)
            }
            return result
        }

        static func utilities(state: GameState) -> [PlayerID: Double] {
            if state.turnPhase == .ended, let standings = state.finalStandings {
                let n = Double(state.players.count)
                guard n > 1 else { return Dictionary(uniqueKeysWithValues: state.players.map { ($0.id, 1.0) }) }
                var result: [PlayerID: Double] = [:]
                for (groupIndex, group) in standings.enumerated() {
                    let utility = (n - Double(groupIndex + 1)) / (n - 1)
                    for player in group { result[player] = utility }
                }
                for player in state.players where result[player.id] == nil { result[player.id] = 0 }
                return result
            }
            let scores = scores(state: state)
            return rankUtilities(scores: scores, playerCount: state.players.count)
        }

        /// 同分并列同组,按组排名给效用;分数从高到低。
        static func rankUtilities(scores: [PlayerID: Double], playerCount: Int) -> [PlayerID: Double] {
            let n = Double(playerCount)
            guard n > 1 else { return scores.mapValues { _ in 1.0 } }
            let ordered = scores.sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
            var result: [PlayerID: Double] = [:]
            var index = 0
            while index < ordered.count {
                var end = index
                while end + 1 < ordered.count, ordered[end + 1].value == ordered[index].value { end += 1 }
                let utility = (n - Double(index + 1)) / (n - 1)
                for entry in ordered[index...end] { result[entry.key] = utility }
                index = end + 1
            }
            return result
        }
    }
}

extension GameCore.GameState {
    /// 收入轨条目的轻量访问(catalog 不在手上时由调用方传入,评估器自用缓存)。
    var incomeTrackEntriesOrEmpty: [GameCore.IncomeTrack.Entry] { [] }
}
```

**实现注意(执行时修正)**:`incomeTrackEntriesOrEmpty` 返回空会导致 income 项=0——把 `scores(state:)` 改为 `scores(state:incomeTrack:)`,签名 `static func scores(state: GameState, incomeTrack: [IncomeTrack.Entry]) -> [PlayerID: Double]`,utilities 内部用 `utilities(state:incomeTrack:)`,MCTS/arena 调用方从 `catalog.catalog.incomeTrack.entries` 传入;测试同步补该参数。禁止留空实现。

- [ ] **Step 4: 跑测试确认通过**——Run: 全 target;Expected: PASS(基线遗留除外,下同)。
- [ ] **Step 5: Commit**——`git add …HeuristicEvaluator.swift …HeuristicEvaluatorTests.swift && git commit -m "AI: HeuristicEvaluator 启发式评估(spec §7.1)与排名效用"`

### Task 2: MonteCarloTreeSearch——PUCT 树 + MaxN 备份

**Files:**
- Create: `ui-prototype/IndustrialCityBirmingham/GameCore/AI/MonteCarloTreeSearch.swift`
- Test: `ui-prototype/IndustrialCityBirminghamTests/MonteCarloTreeSearchTests.swift`

**Interfaces:**
- Consumes: Task 1 `HeuristicEvaluator.utilities(state:incomeTrack:)`、P0 `FastActionEnumerator.enumerate`、P0 `SimulationRunner.apply`。
- Produces(Task 3/5、arena 依赖):

```swift
extension GameCore {
    /// 难度档(spec §10.3):模拟数初值按实测展开成本(~123ms)定,深档可后续调。
    nonisolated enum AIDifficulty: String, CaseIterable, Codable, Sendable {
        case light, standard, deep
        var simulations: Int { switch self { case .light: 8; case .standard: 24; case .deep: 48 } }
        var displayName: String { switch self { case .light: "轻量"; case .standard: "标准"; case .deep: "深思" } }
    }

    nonisolated struct MCTSConfiguration: Sendable {
        var simulations: Int = 24
        var explorationConstant: Double = 1.25
        var timeLimitMs: Int? = 4_000
        var seed: UInt64 = 0
        static func preset(_ difficulty: AIDifficulty) -> MCTSConfiguration {
            .init(simulations: difficulty.simulations, explorationConstant: 1.25, timeLimitMs: 4_000, seed: 0)
        }
    }

    nonisolated enum MCTSError: Error, Equatable, Sendable {
        case noActionsAvailable
    }

    nonisolated enum MonteCarloTreeSearch {
        struct Decision: Equatable, Sendable {
            var payload: PlayerIntent.Payload
            var totalVisits: Int
            var elapsedMs: Double
            var expandedNodes: Int
            /// 调试面板用:根子女按访问数降序的前 5 个(actionKind 描述 + 访问数 + 行动方平均效用)。
            var topCandidates: [String]
        }

        /// 单步决策:完备枚举 → PUCT+MaxN 搜索 → 访问数最多的动作。
        /// 适用于 turnPhase == .active 或 .forcedSale(强卖枚举强卖意图,同一树)。
        static func chooseAction(
            state: GameState,
            actorID: PlayerID,
            catalog: VerifiedGameDataCatalog,
            configuration: MCTSConfiguration
        ) throws -> Decision
    }
}
```

设计要点(实现必须遵守):节点 = `final class Node`(引用类型,树内原地变异;`payload: PlayerIntent.Payload?` 根为 nil;`children: [Node]`;`pendingPayloads: [PlayerIntent.Payload]`(本节点首次访问时完备枚举一次填充,之后逐个展开);`visits: Int`;`valueSum: [PlayerID: Double]`)。每次模拟:从根沿 PUCT 下降(选择公式对"当前工作状态的 activePlayerID"视角取 max),工作状态经 `SimulationRunner.apply` 逐步重放;遇未展开节点则取 `pendingPayloads` 下一个展开为叶;叶 = 工作状态终局(`utilities` 走 finalStandings)或启发式 `utilities(state:incomeTrack:)`;沿路径 MaxN 备份(每节点 `visits+=1`、`valueSum[p]+=utility[p]`,均值 = valueSum/visits)。均匀先验 `P=1/N`;根 Dirichlet 以"先验乘 (0.75 + 0.5·均匀随机(seed))"近似(spec 噪声 α=0.3/权重 0.25,V1 无网络先验,仅自博弈多样性用,P1 对局默认关)。时间预算每模拟检查一次,超时立即返回当前最多访问;同访问数平手取稳定序(枚举发现序)。全程确定性(seed 固定 → 结果可复现)。

- [ ] **Step 1: 写失败测试**(全 target 命令验证 RED:编译错 `no member 'MonteCarloTreeSearch'`)

```swift
import Foundation
import Testing

@testable import IndustrialCityBirmingham

struct MonteCarloTreeSearchTests {
    // verifiedCatalog()/freshFourPlayerState(种子 20_502,sources id "mcts-tests")同 Task 1 复制。
    private let incomeTrack: GameCore.IncomeTrack = { /* 从 verifiedCatalog 取;在测试内 try 后赋值不可行,改为每个测试内先取再断言 */ }()

    @Test func chooseActionReturnsLegalPayloadOnFreshState() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let decision = try GameCore.MonteCarloTreeSearch.chooseAction(
            state: state, actorID: actor, catalog: catalog,
            configuration: .init(simulations: 8, explorationConstant: 1.25, timeLimitMs: nil, seed: 7)
        )
        // 决策必须是该状态合法动作,且能被宿主接受。
        var host = try state.makeHostEngine(
            roomID: .init(rawValue: "mcts-room"),
            reconnectTokens: Dictionary(uniqueKeysWithValues: state.players.map {
                ($0.id, GameCore.ReconnectToken(rawValue: "mcts-token-\($0.rawValue)"))
            }), protocolVersion: 2
        )
        let result = host.submit(.init(
            protocolVersion: 2, rulesetVersion: state.rulesetVersion, roomID: .init(rawValue: "mcts-room"),
            senderID: actor, reconnectToken: .init(rawValue: "mcts-token-\($0.rawValue)"),
            baseVersion: state.authoritativeVersion, payload: decision.payload
        ), catalog: catalog)
        guard case .accepted = result else {
            Issue.record("MCTS 决策被宿主拒绝: \(decision.payload)"); return
        }
        #expect(decision.totalVisits >= 1)
        #expect(decision.elapsedMs >= 0)
        #expect(decision.topCandidates.isEmpty == false)
    }

    @Test func deterministicWithSameSeed() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let a = try GameCore.MonteCarloTreeSearch.chooseAction(
            state: state, actorID: actor, catalog: catalog,
            configuration: .init(simulations: 8, explorationConstant: 1.25, timeLimitMs: nil, seed: 42))
        let b = try GameCore.MonteCarloTreeSearch.chooseAction(
            state: state, actorID: actor, catalog: catalog,
            configuration: .init(simulations: 8, explorationConstant: 1.25, timeLimitMs: nil, seed: 42))
        #expect(a.payload == b.payload)
        #expect(a.totalVisits == b.totalVisits)
    }

    @Test func timeLimitStopsSearchEarly() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let decision = try GameCore.MonteCarloTreeSearch.chooseAction(
            state: state, actorID: actor, catalog: catalog,
            configuration: .init(simulations: 100_000, explorationConstant: 1.25, timeLimitMs: 900, seed: 1)
        )
        // 预算生效:远小于满额模拟也必须返回合法动作。
        #expect(decision.totalVisits >= 1)
        #expect(decision.elapsedMs < 5_000)
    }

    @Test func forcedSalePhaseChoosesLegalForcedSale() throws {
        // 强卖状态构造:与 FastActionEnumeratorTests.forcedSalePhaseEnumeratesAcceptedForcedSaleIntents
        // 完全相同(seed 10_099 技法),断言 decision.payload 为 .forcedSale 且宿主接受。
    }
}
```

(`forcedSalePhaseChoosesLegalForcedSale` 测试体从 FastActionEnumeratorTests 的同名构造技法原样复制后补 chooseAction 调用与断言;`chooseActionReturnsLegalPayloadOnFreshState` 的 token 简化为按 ID 推导。)

- [ ] **Step 2: 跑测试确认失败**——Expected: `no member 'MonteCarloTreeSearch'` 编译错。
- [ ] **Step 3: 实现**(约 220 行;按上面"设计要点"实现,类 Node/选择/展开/备份/预算/平手/确定性;`topCandidates` 格式 `"#\(i) [kind] visits=… util=…"`。)
- [ ] **Step 4: 跑测试确认通过**——Run: 全 target;Expected: PASS。
- [ ] **Step 5: Commit**——`git commit -m "AI: PUCT 树搜索 + MaxN 多人备份 + 时间预算(spec §7)"`

### Task 3: MCTS 整局冒烟 + macOS 性能剖面

**Files:**
- Create: `ui-prototype/IndustrialCityBirminghamTests/MCTSFullGameTests.swift`
- Create: `tools/p1-profile/main.swift`(复用 tools/p0-acceptance 的 shim.swift/uistub.swift:复制到本目录;build 脚本同款)

**Interfaces:**
- Consumes: Task 2 chooseAction、P0 SimulationRunner、`RandomGameDriver` 不适用(MCTS 驱动自己写)。
- Produces: iOS 冒烟测试(2 局小预算)+ macOS 剖析 CLI(输出每步耗时与整局统计,供 Stage B 预算标定)。

- [ ] **Step 1: iOS 冒烟测试**(RED:引用 MCTS;GREEN 后)——驱动 2 局完整 4 人局(种子 40_001/40_002,所有座位 `simulations: 4, timeLimitMs: nil`——iOS Debug 下必须小预算,单局断言 `turnPhase == .ended` 且全程零拒绝;phase 循环与 P0 RandomGameDriver 相同,MCTS 座位用 chooseAction、确认阶段自动提交)。跑全 target,Expected: PASS(注意单局 Debug 耗时 ~2-4 分钟,属预期)。
- [ ] **Step 2: macOS 剖析 CLI**——tools/p1-profile/main.swift:复用 p0-acceptance 的构建模式(swiftc -O -D DEBUG 直编 GameCore+AI),驱动 1 局 4 人局全部座位 `AIDifficulty.standard` 预算,逐步打印 `MOVE seat ms payloads visits`,终局打印 `P1_PROFILE moves=N avgMs= p95Ms= totalS= winner=`。运行并记录数字到台账(这是 Stage B 难度档与 5s 预算的标定依据)。
- [ ] **Step 3: Commit**——两处一起:`git commit -m "AI: MCTS 整局冒烟(iOS 小预算)+ macOS 性能剖析 CLI"`

## Stage B:App 集成

### Task 4: SessionCoordinator——AI 座位本地开局与代提交

**Files:**
- Modify: `ui-prototype/IndustrialCityBirmingham/Session/SessionCoordinator.swift`
- Test: `ui-prototype/IndustrialCityBirminghamTests/AISeatSessionTests.swift`

**Interfaces:**
- Consumes: 现有 `startGame()` 的发牌主体(`beginGame` 重构)、`resolve(_:)` 权威门、`tokens/ready/playerColors/playerNames`。
- Produces(Task 5/6 依赖):

```swift
// SessionCoordinator 内新增:
/// AI 接管的座位(host 侧生成,无传输对端)。
private(set) var aiSeatIDs: Set<GameCore.PlayerID> = []
/// 单机模式:房主 + N 个 AI 座位直接开局;不进大厅名册、不给 AI 发快照、不写 tokenStore。
func startSinglePlayerGame(aiDifficulties: [GameCore.AIDifficulty]) async throws
/// 仅限 aiSeatIDs 内座位:以该座位身份过宿主权威门(日志/串行化/广播全复用)。
func submitAs(seat: GameCore.PlayerID, _ payload: GameCore.PlayerIntent.Payload) async throws
```

实现要点:`startGame()` 主体抽成 `private func beginGame(ordered:[PlayerID], colors:..., names:...)`(现有行为不变);`startSinglePlayerGame` 生成 seat ID `ai-1…`(ReconnectToken 用 `UUID().uuidString`),填 `tokens/ready/playerColors/playerNames`(名字 "AI·\(difficulty.displayName)")、`aiSeatIDs`,然后 `beginGame(ordered: [host] + aiSeats…)`;`distributeInitialSnapshots` 与后续事件扇出、存盘扇出里凡是遍历座位发消息的循环,开头加 `guard aiSeatIDs.contains(player) == false else { continue }`(执行时 grep 所有 `for player in` 定位,逐一核对;AI 无对端,漏加会在 send 处 recordDeliveryFailure 触发恢复机制——测试会暴露);`submitAs` guard `isHost && aiSeatIDs.contains(seat)`,用 `tokens[seat]` + `engine.gameState.authoritativeVersion` 组 intent 走 `resolve(intent)`。

- [ ] **Step 1: 写失败测试**——`startSinglePlayerGameCreatesRosterAndDeals`(名册=1 人+3 AI、`aiSeatIDs` 正确、开局后 snapshot 玩家数 4、AI 座位无对端不报错);`submitAsResolvesThroughHostAndBroadcasts`(AI 座位 submitAs 一个 loan 落地、版本 +1);`submitAsRejectsHumanSeat`(本地座位被拒)。构造:LoopbackTransportHub 单端 + `SessionCoordinator(configuration: Loopback 传输…)`(参照 GameSetupTests.swift:669 的构造方式,configuration.hostPlayerID = 自己)。RED:方法不存在编译错。
- [ ] **Step 2: 跑测试确认失败** → **Step 3: 实现** → **Step 4: 全 target 通过**(若事件扇出对 AI 座位 send 抛错,按实现要点补 guard)→ **Step 5: Commit** `git commit -m "会话:AI 座位本地开局与代提交(单机模式,零多人协议改动)"`

### Task 5: AIPlayerDriver——宿主侧 AI 驱动器

**Files:**
- Create: `ui-prototype/IndustrialCityBirmingham/Session/AIPlayerDriver.swift`
- Test: `ui-prototype/IndustrialCityBirminghamTests/AIPlayerDriverTests.swift`

**Interfaces:**
- Consumes: Task 4 `submitAs`/`aiSeatIDs`、`stateUpdates()`、Task 2 chooseAction、verifiedCatalog(宿主侧经 coordinator 现有路径拿不到 catalog 的话,给 SessionCoordinator 加 `var verifiedCatalogForAI: GameCore.VerifiedGameDataCatalog? { verifiedCatalog }` 只读透出)。
- Produces(Task 6 依赖):

```swift
@MainActor
final class AIPlayerDriver {
    struct SeatAssignment: Sendable { let seat: GameCore.PlayerID; let difficulty: GameCore.AIDifficulty }
    init(coordinator: SessionCoordinator, seats: [SeatAssignment])
    func start()   // 订阅 stateUpdates,进入驱动循环
    func stop()    // 取消搜索 Task,幂等
    var lastDiagnostics: [GameCore.PlayerID: GameCore.MonteCarloTreeSearch.Decision]  // 调试面板
}
```

驱动循环(每状态事件):①`.ended` → stop;②`active/forcedSale` 且 `activePlayerID` ∈ seats → 起搜索 Task(`chooseAction`,预算=难度档,seed=actionNumber 派生保证复现),完成后 `Task.sleep(minimumThinkMs=800)` 再 `submitAs`;提交被拒(staleVersion)→ 取最新状态重搜,上限 3 次;③`awaitingTurnEndConfirmation` 且座位 ∈ seats → 直接 submitAs(confirmTurnEnd);④`eraIntermission` → 为每个未确认的 AI 座位 submitAs(confirmEraIntermission)。人类撤回/retract 后状态回卷:驱动循环按状态事件重评估,旧搜索 Task 在每次新事件到来时取消(保存当前搜索 Task 引用,事件到达先 cancel)。

- [ ] **Step 1: 写失败测试**——①`aiSeatActsOnlyWhenActive`(AI 座位激活→收到提交;人类座位激活→驱动器静默,等待超时断言无提交);②`confirmPhasesAutoAdvance`(awaitingTurnEnd → confirmTurnEnd 落地;eraIntermission → 全 AI 确认);③`stopCancelsPendingSearch`(start 后立即 stop,搜索 Task 取消,无提交)。测试用小预算(`simulations: 2, timeLimitMs: nil`)与 `minimumThinkMs` 可注入(构造参数 `minimumThinkMs: UInt64 = 800`,测试传 10)。RED:`cannot find 'AIPlayerDriver'`。
- [ ] **Step 2: RED 确认** → **Step 3: 实现** → **Step 4: 全 target 通过** → **Step 5: Commit** `git commit -m "会话:AIPlayerDriver 宿主侧驱动(仅 AI 座位行动/自动确认/可取消/最小思考延迟)"`

### Task 6: 单人挑战入口与对局视图接入

**Files:**
- Modify: `ui-prototype/IndustrialCityBirmingham/Features/Home/HomeView.swift`
- Create: `ui-prototype/IndustrialCityBirmingham/Features/Home/SinglePlayerSetupView.swift`
- Modify: App 路由文件(`App/RootView.swift` 的 AppRoute 枚举;执行时先读该文件确认枚举与导航挂载方式,按现有 case 的样式加 `case singlePlayer`)
- Test: `ui-prototype/IndustrialCityBirminghamTests/SinglePlayerFlowTests.swift`

实现要点:`SinglePlayerSetupView`:难度 Picker(AIDifficulty 三档,默认 standard,应用于全部 3 个 AI 座位)+ 开始按钮 → 构造 LoopbackTransportHub 单端 SessionCoordinator(host=本地,`startSinglePlayerGame(aiDifficulties: [.init(repeating: difficulty, count: 3)])`)→ 启动 AIPlayerDriver → 进入现有对局视图(执行时读 RootView 确认对局视图的构造入参——沿用在线/附近房间开始对局后的同一导航路径)。HomeView 主按钮区加「单人挑战」(`accessibilityIdentifier("home.single")`)。

- [ ] **Step 1: 写失败测试**——`singlePlayerEntryExposesRouteAndStartsGame`(NavigationTests 模式:route 存在、setup 视图渲染三档难度、开始后协调器名册 1+3、AIPlayerDriver 已启动——用可注入的协调器工厂闭包测)。RED:route/view 不存在编译错。
- [ ] **Step 2: RED 确认** → **Step 3: 实现** → **Step 4: 全 target 通过 + 真机/模拟器手动冒烟一次(完整运河+铁路至终局,AI 无非法提交,单步观感 ≤5s)** → **Step 5: Commit** `git commit -m "App:单人挑战入口(难度选择)+ 对局视图接入"`

### Task 7: P1 棋力验收——arena CLI

**Files:**
- Create: `tools/p1-arena/main.swift`(+ 同款 shim/uistub/build 脚本)

**Interfaces:** Consumes: Task 2 chooseAction、P0 SimulationRunner/FastActionEnumerator、SplitMix64(SimulationRunnerTests.swift)。
验收(spec §11 P1-③):20 局 4 人局,座位 = 3 × AI(arena 预算 `simulations: 12, timeLimitMs: nil` 标定值,以单局时长 ≤4 分钟为准) + 1 × 随机策略席(种子派生);断言随机席胜局 ≤ 3(≤15%,随机基线 25%);输出 `P1_ARENA games=20 aiWins=… randomWins=… avgGameSec=…`。

- [ ] **Step 1: 实现 arena CLI**(MCTS 座位 chooseAction、随机座位 `enumerate().payloads.randomElement(using:)`,确认阶段自动;逐局打印胜负与时长)。
- [ ] **Step 2: 后台跑 20 局**(预计 40-80 分钟;先跑 2 局标定单局时长,必要时降 arena 预算至 simulations: 8)。
- [ ] **Step 3: 断言通过 → 台账记录数字 → Commit** `git commit -m "AI: P1 arena 验收工具与结果(随机席胜率 ≤15%)"`

## 完成定义(对照 spec §11 P1)

1. ✅ 真机/模拟器单机(1 人 + 3 AI)完整跑通运河+铁路至终局,无非法提交(Task 6 Step 4);
2. ✅ AI 单步 ≤5s(standard 档;Task 3 剖析标定 + Task 6 冒烟观感;实测数字记录台账);
3. ✅ 4 人局 3 AI + 1 随机,20 局随机席胜率 ≤15%(Task 7);
4. ✅ 全 target 无回归(基线遗留除外)。

## 自审记录

- **Spec 覆盖**:§7(PUCT/MaxN/温度/预算/可取消)→ Task 2;§7.1 → Task 1;§10.1(单机入口/Loopback/不进持久化)→ Task 4/6;§10.3(驱动器节奏/取消/自动确认/调试面板数据)→ Task 5(lastDiagnostics 即调试面板数据源,面板 UI 本体属 P4 打磨,Decision.topCandidates 已备好);§11 P1 三验收 → Task 6/3/7。
- **占位符扫描**:Task 1 Step 3 的 incomeTrack 空实现已在正文明确"实现注意"强制改为显式参数,不留空;Task 6 对 RootView 的读取步骤给出明确的挂载预期与验证方式,非泛泛"适当修改"。
- **类型一致性**:HeuristicEvaluator.utilities(state:incomeTrack:)、MCTSConfiguration/MCTSError/Decision/chooseAction、AIDifficulty、SeatAssignment/submitAs/startSinglePlayerGame 在各任务间签名一致。
- **Review Focus**:五条分别钉在 Task 2 Step 1(数学)、Task 5 Step 1(座位纪律)、Task 5 Step 1③(取消)、Task 4 Step 1(协议隔离)、Task 2 Step 1(预算)。
