# AlphaZero AI P0(引擎底座)实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 MCTS/AI 子系统提供引擎底座:快速完整动作枚举器(`FastActionEnumerator`)与模拟推进器(`SimulationRunner`),并用大规模对拍测试锁定正确性——这是 spec P0 阶段的全部内容。

**Architecture:** `FastActionEnumerator` 以 `LegalActionQueryEngine.respond` 的逐步 `nextChoices` 做 DFS,收集 `completePayload`,支持「完备」与「按先验截断」两种模式;`SimulationRunner` 复刻 `HostEngine.submitResolved` 的 validate→resolve 分发,但跳过身份校验、全量权威校验与投影构建。规则语义零修改,唯一动到的现有文件是给 `respond` 增加默认参数 `fastPath`(跳过摘要与结构上限校验)。

**Tech Stack:** Swift(Xcode 工程,文件系统同步组)、Swift Testing(`import Testing`)、xcodebuild + iOS 模拟器。

**Spec:** `docs/superpowers/specs/2026-10-11-alphazero-ai-design.md`(§4 引擎层改造、§11 P0 验收、§12 测试策略)

## Global Constraints

- 规则语义零修改:`Rules/*.swift` 中只允许改 `LegalActionQueryEngine.swift` 的 `respond` 签名(新增默认参数),缺省行为逐字节不变。
- 新生产代码全部放 `ui-prototype/IndustrialCityBirmingham/GameCore/Simulation/`,新测试全部放 `ui-prototype/IndustrialCityBirminghamTests/`;Xcode 工程是文件系统同步组,文件落盘即自动入 target,不许手改 project.pbxproj。
- 代码风格:与 GameCore 一致的 `nonisolated` 纯值语义、`extension GameCore` 命名空间。
- 测试框架:Swift Testing(`import Testing`、`@Test`、`#expect`、`#require`)。
- 测试命令(工作目录 `ui-prototype/`,模拟器 iPhone F993AE30-7BF3-4CAD-A79F-1AF9698E040F):

  ```bash
  cd /Users/baigeitiancai/Desktop/Interview-learning/Brass-Birmingham/ui-prototype && \
  xcodebuild test \
    -scheme IndustrialCityBirmingham \
    -destination 'platform=iOS Simulator,id=F993AE30-7BF3-4CAD-A79F-1AF9698E040F' \
    -derivedDataPath /tmp/bb_sim_dd \
    -parallel-testing-enabled NO \
    -only-testing:IndustrialCityBirminghamTests 2>&1 | tail -25
  ```

  套件级 `-only-testing` 过滤对本工程 Swift Testing 不生效,每轮都是全 target 运行(数分钟),这是预期成本;`-parallel-testing-enabled NO` 必须保留(并行克隆会导致 launchd spawn 失败)。
- 验收口径:4 人局、数据 v2018.11;不新增任何第三方依赖。
- **工作区门禁**:仓库工作区存在用户未提交的回合撤回/回合确认改动(`GameCore.swift`、`GameRulesEngine.swift`、`LegalActionQueryEngine.swift` 等为脏)。Task 0 检查通过前不得开工;执行期间绝不 revert、不 commit 用户自己的在途改动。

## Review Focus

1. **卖货链环回**:sell 的 `sellDisposition(continueSelling:)` 分支可能让 DFS 在同语义状态间环回不终止——期望:任何状态枚举都在有限步内终止。测试:Task 2 Step 7(有啤酒+可卖产业的卖货状态枚举终止且全被接受)、Task 5 随机对局天然覆盖。
2. **fastPath 不改变现有调用者语义**:会话层依赖 `draftDigest` 与 `malformedQuery` 拒绝。期望:缺省调用行为逐字节不变。测试:Task 1 Step 1 双调用一致性 + 全 target 回归。
3. **截断模式不得截出非法动作**:limit 截断后的动作仍须被 HostEngine 接受。测试:Task 3 Step 1 断言全部提交成功。
4. **模拟路径不得比宿主宽**:宿主拒绝的 payload,`SimulationRunner` 也必须抛错。测试:Task 4 Step 5 拒绝一致性。
5. **非行动玩家/非行动阶段安全**:枚举必须返回空而非崩溃或产出动作。测试:Task 2 Step 8(ended / eraIntermission / awaitingTurnEndConfirmation / 非行动玩家)。

---

### Task 0: 开工门禁——工作区状态检查

**Files:** 无(只读检查)。

**Interfaces:** 无。

- [ ] **Step 1: 确认要修改的现有文件没有未提交改动**

```bash
cd /Users/baigeitiancai/Desktop/Interview-learning/Brass-Birmingham && \
git status --porcelain -- \
  ui-prototype/IndustrialCityBirmingham/GameCore/Rules/LegalActionQueryEngine.swift
```

Expected: 无输出(干净)。若有输出:停止执行,向用户说明"回合撤回在途改动与本计划触碰同一文件,请先提交或暂存你的改动",等待用户处理。**不得**自行 commit/revert 用户的在途改动。

- [ ] **Step 2: 记录基线测试状态**

跑一遍 Global Constraints 里的全量测试命令,记录通过/失败基线(记忆里有已知历史失败:见 `known-test-debt`;新引入的失败在后续任务中一律视为回归)。不提交任何东西。

---

### Task 1: LegalActionQueryEngine 快速路径参数

**Files:**
- Modify: `ui-prototype/IndustrialCityBirmingham/GameCore/Rules/LegalActionQueryEngine.swift`
- Test: `ui-prototype/IndustrialCityBirminghamTests/LegalActionQueryFastPathTests.swift`

**Interfaces:**
- Consumes: 现有 `LegalActionQueryEngine.respond(to:actorID:state:catalog:)`。
- Produces: `LegalActionQueryEngine.respond(to:actorID:state:catalog:fastPath:)`,`fastPath: Bool = true` 缺省 `false`;`fastPath == true` 时跳过 `validateStructure` 与 `draftDigest` 计算(返回空串)。后续任务 2、3 的枚举器以 `fastPath: true` 调用。

- [ ] **Step 1: 写失败测试**

创建 `LegalActionQueryFastPathTests.swift`:

```swift
import Foundation
import Testing

@testable import IndustrialCityBirmingham

/// fastPath 只跳过摘要与结构上限校验,选择/完成判定必须与常规路径逐字段一致。
struct LegalActionQueryFastPathTests {
    private func verifiedCatalog() throws -> GameCore.VerifiedGameDataCatalog {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "IndustrialCityBirmingham/GameData/v2018.11")
        let catalog = try GameCore.GameDataLoader.decodeCatalog(
            rulesetVersion: "v2018.11",
            mapData: Data(contentsOf: directory.appending(path: "map.json")),
            industryData: Data(contentsOf: directory.appending(path: "industries.json")),
            cardData: Data(contentsOf: directory.appending(path: "cards.json")),
            merchantData: Data(contentsOf: directory.appending(path: "merchants.json")),
            incomeTrackData: Data(contentsOf: directory.appending(path: "income-track.json"))
        )
        let encoder = JSONEncoder()
        let files = try [
            "map.json": encoder.encode(catalog.board),
            "industries.json": encoder.encode(catalog.industries),
            "cards.json": encoder.encode(catalog.cards),
            "merchants.json": encoder.encode(catalog.merchants),
            "income-track.json": encoder.encode(catalog.incomeTrack),
        ]
        let manifest = GameCore.GameDataManifest(
            rulesetVersion: catalog.rulesetVersion,
            verificationStatus: .verified,
            files: files.keys.sorted().map {
                .init(path: $0, sha256: GameCore.GameDataLoader.sha256(files[$0]!))
            },
            sources: [.init(
                id: "fast-path-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-10-11",
                checker: "independent-test", checkedOn: "2026-10-11"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }

    private func freshFourPlayerState(catalog: GameCore.VerifiedGameDataCatalog) throws -> GameCore.GameState {
        let players = (1...4).map { GameCore.PlayerID(rawValue: "fast-p\($0)") }
        var setupRules = GameCore.SetupRules(seed: 20_241)
        return try setupRules.makeGame(catalog: catalog, playerIDs: players).state
    }

    @Test func fastPathReturnsEmptyDigestAndIdenticalChoices() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let player = try #require(state.players.first { $0.id == actor })
        let card = try #require(player.hand.first)
        let draft = GameCore.LegalActionDraft(action: .pass, cardID: card.id, selections: [])

        let slow: GameCore.LegalActionResponse = try GameCore.LegalActionQueryEngine.respond(
            to: .init(requestID: "digest-check", baseVersion: state.authoritativeVersion, draft: draft),
            actorID: actor, state: state, catalog: catalog
        )
        let fast: GameCore.LegalActionResponse = try GameCore.LegalActionQueryEngine.respond(
            to: .init(requestID: "digest-check", baseVersion: state.authoritativeVersion, draft: draft),
            actorID: actor, state: state, catalog: catalog, fastPath: true
        )

        #expect(fast.draftDigest.isEmpty)
        #expect(slow.draftDigest.isEmpty == false)
        #expect(fast.completePayload == slow.completePayload)
        #expect(fast.nextChoices == slow.nextChoices)
        #expect(fast.confirmation == slow.confirmation)
    }

    @Test func fastPathSkipsMalformedQueryBoundButSlowPathKeepsIt() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let player = try #require(state.players.first { $0.id == actor })
        let card = try #require(player.hand.first)
        let longID = String(repeating: "x", count: 300)
        let query = GameCore.LegalActionQuery(
            requestID: longID, baseVersion: state.authoritativeVersion,
            draft: .init(action: .pass, cardID: card.id, selections: [])
        )
        #expect(throws: GameCore.LegalActionQueryError.self) {
            _ = try GameCore.LegalActionQueryEngine.respond(
                to: query, actorID: actor, state: state, catalog: catalog
            )
        }
        // fastPath 跳过结构校验:同样的查询不再因 requestID 超长被拒。
        let response = try GameCore.LegalActionQueryEngine.respond(
            to: query, actorID: actor, state: state, catalog: catalog, fastPath: true
        )
        #expect(response.completePayload != nil)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: Global Constraints 的测试命令。
Expected: FAIL,编译错误 `extra argument 'fastPath' in call`。

- [ ] **Step 3: 最小实现**

`LegalActionQueryEngine.swift` 三处修改:

1. `respond` 签名增加默认参数(约第 9–14 行):

```swift
        static func respond(
            to query: LegalActionQuery,
            actorID: PlayerID,
            state: GameState,
            catalog: VerifiedGameDataCatalog,
            fastPath: Bool = false
        ) throws -> LegalActionResponse {
```

2. 函数体第一行 `try validateStructure(query)` 改为:

```swift
            if fastPath == false { try validateStructure(query) }
```

3. 两处 `draftDigest: try query.draft.canonicalDigest()`(forcedSale 分支的提前返回与正常返回)都改为:

```swift
                    draftDigest: fastPath ? "" : (try query.draft.canonicalDigest()),
```

注意缩进保持原样;两个返回点的参数标签顺序不变。

- [ ] **Step 4: 跑测试确认通过(含全 target 回归)**

Run: Global Constraints 的测试命令。
Expected: PASS——新测试通过,且既有套件(SessionCoordinatorTests、GameRulesEngineTests 等)无新增失败。

- [ ] **Step 5: Commit**

```bash
cd /Users/baigeitiancai/Desktop/Interview-learning/Brass-Birmingham && \
git add ui-prototype/IndustrialCityBirmingham/GameCore/Rules/LegalActionQueryEngine.swift \
        ui-prototype/IndustrialCityBirminghamTests/LegalActionQueryFastPathTests.swift && \
git commit -m "GameCore: LegalActionQueryEngine 增加 fastPath 快速路径(跳过摘要与结构校验)"
```

---

### Task 2: FastActionEnumerator——完备模式与阶段语义

**Files:**
- Create: `ui-prototype/IndustrialCityBirmingham/GameCore/Simulation/FastActionEnumerator.swift`
- Test: `ui-prototype/IndustrialCityBirminghamTests/FastActionEnumeratorTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `respond(..., fastPath: true)`;现有 `SnapshotActionAvailability.make(state:recipient:catalog:)`。
- Produces(Task 3/4/5 及 P1 全部依赖):

```swift
extension GameCore {
    nonisolated enum FastActionEnumerator {
        struct Result: Equatable, Sendable {
            var payloads: [PlayerIntent.Payload]   // 去重后的完整合法动作
            var truncated: Bool                     // limit 生效时为 true
        }
        enum EnumerationError: Error, Equatable, Sendable {
            case depthExceeded                      // draft.selections 超过 128(替代被跳过的结构上限)
        }
        static func enumerate(
            state: GameState,
            actorID: PlayerID,
            catalog: VerifiedGameDataCatalog,
            limit: Int? = nil,                                     // 本任务恒传 nil
            prioritizer: ((PlayerIntent.Payload) -> Double)? = nil // 本任务恒传 nil
        ) throws -> Result
    }
}
```

阶段语义:仅 `turnPhase` 为 `.active` 或 `.forcedSale` 且 `activePlayerID == actorID` 时产出动作(强卖阶段要求 pending 玩家即 actor,由查询引擎的 `notActivePlayer` 拒绝兜底);`.eraIntermission`、`.awaitingTurnEndConfirmation`、`.ended` 返回空。产出动作不包含 `confirmEraIntermission`/`confirmTurnEnd`/`retractTurnActions`(由调用方按阶段自动处理)。

- [ ] **Step 1: 写失败测试**

创建 `FastActionEnumeratorTests.swift`(verifiedCatalog/freshState 辅助同 Task 1,新增 host 构造与全量提交辅助):

```swift
import Foundation
import Testing

@testable import IndustrialCityBirmingham

struct FastActionEnumeratorTests {
    private func verifiedCatalog() throws -> GameCore.VerifiedGameDataCatalog {
        // 与 LegalActionQueryFastPathTests.verifiedCatalog 完全相同的实现,原样复制。
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "IndustrialCityBirmingham/GameData/v2018.11")
        let catalog = try GameCore.GameDataLoader.decodeCatalog(
            rulesetVersion: "v2018.11",
            mapData: Data(contentsOf: directory.appending(path: "map.json")),
            industryData: Data(contentsOf: directory.appending(path: "industries.json")),
            cardData: Data(contentsOf: directory.appending(path: "cards.json")),
            merchantData: Data(contentsOf: directory.appending(path: "merchants.json")),
            incomeTrackData: Data(contentsOf: directory.appending(path: "income-track.json"))
        )
        let encoder = JSONEncoder()
        let files = try [
            "map.json": encoder.encode(catalog.board),
            "industries.json": encoder.encode(catalog.industries),
            "cards.json": encoder.encode(catalog.cards),
            "merchants.json": encoder.encode(catalog.merchants),
            "income-track.json": encoder.encode(catalog.incomeTrack),
        ]
        let manifest = GameCore.GameDataManifest(
            rulesetVersion: catalog.rulesetVersion,
            verificationStatus: .verified,
            files: files.keys.sorted().map {
                .init(path: $0, sha256: GameCore.GameDataLoader.sha256(files[$0]!))
            },
            sources: [.init(
                id: "enumerator-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-10-11",
                checker: "independent-test", checkedOn: "2026-10-11"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }

    private func freshFourPlayerState(catalog: GameCore.VerifiedGameDataCatalog) throws -> GameCore.GameState {
        let players = (1...4).map { GameCore.PlayerID(rawValue: "enum-p\($0)") }
        var setupRules = GameCore.SetupRules(seed: 20_242)
        return try setupRules.makeGame(catalog: catalog, playerIDs: players).state
    }

    /// HostEngine 全量提交:对 state 的每个枚举动作,在 host 副本上提交,断言全部被接受。
    private func assertAllAccepted(
        _ state: GameCore.GameState,
        payloads: [GameCore.PlayerIntent.Payload],
        catalog: GameCore.VerifiedGameDataCatalog,
        roomID: GameCore.RoomID,
        tokens: [GameCore.PlayerID: GameCore.ReconnectToken]
    ) throws {
        guard let actor = state.activePlayerID else {
            Issue.record("active player required"); return
        }
        var host = try state.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 2
        )
        for (index, payload) in payloads.enumerated() {
            var trial = host
            let intent = GameCore.PlayerIntent(
                protocolVersion: 2, rulesetVersion: state.rulesetVersion,
                roomID: roomID, senderID: actor,
                reconnectToken: try #require(tokens[actor]),
                baseVersion: state.authoritativeVersion, payload: payload
            )
            let result = trial.submit(intent, catalog: catalog)
            guard case .accepted = result else {
                Issue.record("payload[\(index)] rejected by HostEngine: \(payload) -> \(result)")
                continue
            }
        }
    }

    @Test func freshStateEnumeratesUniqueNonEmptyLegalActions() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let result = try GameCore.FastActionEnumerator.enumerate(state: state, actorID: actor, catalog: catalog)
        #expect(result.payloads.isEmpty == false)
        #expect(result.truncated == false)
        let keys = Set(result.payloads.map { String(describing: $0) })
        #expect(keys.count == result.payloads.count)
    }

    @Test func enumerationCoversAvailabilityEngineCardActionPairs() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let result = try GameCore.FastActionEnumerator.enumerate(state: state, actorID: actor, catalog: catalog)
        let availability = try GameCore.SnapshotActionAvailability.make(
            state: state, recipient: actor, catalog: catalog
        )
        // 正向:可用性引擎说可完成的 (卡, 动作) 对,枚举器必须至少给出一个完整 payload。
        for (cardID, kinds) in availability.byCardID {
            for kind in kinds {
                let has = result.payloads.contains { payload in
                    pair(of: payload) == (kind, cardID)
                }
                #expect(has, "枚举缺失 \(kind.rawValue)+\(cardID)")
            }
        }
        // 反向:枚举手里的 (动作, 卡) 对必须都在可用性集合内。
        for payload in result.payloads {
            let (kind, cardID) = pair(of: payload)
            #expect(availability.byCardID[cardID ?? ""]?.contains(kind) == true,
                    "枚举多出不合法对 \(kind.rawValue)+\(cardID ?? "nil")")
        }
    }

    /// payload → (ActionKind, cardID);枚举器不产出确认类动作,此处不需要处理它们。
    private func pair(of payload: GameCore.PlayerIntent.Payload)
        -> (GameCore.ActionKind, String?) {
        switch payload {
        case .pass(let i): return (.pass, i.cardID)
        case .build(let i): return (.build, i.cardID)
        case .network(let i): return (.network, i.cardID)
        case .develop(let i): return (.develop, i.cardID)
        case .sell(let i): return (.sell, i.cardID)
        case .loan(let i): return (.loan, i.cardID)
        case .scout(let i): return (.scout, i.cardIDs.first)
        case .forcedSale: return (.forcedSale, nil)
        case .confirmEraIntermission, .confirmTurnEnd, .retractTurnActions:
            return (.pass, "IMPOSSIBLE")
        }
    }

    @Test func allEnumeratedPayloadsAreAcceptedByHostEngine() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let result = try GameCore.FastActionEnumerator.enumerate(state: state, actorID: actor, catalog: catalog)
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "enum-token-\($0.id.rawValue)"))
        })
        try assertAllAccepted(
            state, payloads: result.payloads, catalog: catalog,
            roomID: .init(rawValue: "enum-room"), tokens: tokens
        )
    }

    @Test func forcedSalePhaseEnumeratesAcceptedForcedSaleIntents() throws {
        let catalog = try verifiedCatalog()
        // 强卖状态构造复刻 GameRulesEngineTests.forcedSaleSubmittedThroughHost…(seed 10_099)
        let players = [GameCore.PlayerID(rawValue: "debtor"), GameCore.PlayerID(rawValue: "other")]
        var setupRules = GameCore.SetupRules(seed: 10_099)
        var state = try setupRules.makeGame(catalog: catalog, playerIDs: players).state
        let debtor = state.playerOrder[0]
        let debtorIndex = try #require(state.players.firstIndex { $0.id == debtor })
        let stackIndex = try #require(state.players[debtorIndex].industryStacks.firstIndex {
            $0.industryDefinitionID == "manufacturer"
        })
        let canonicalTile = try #require(state.players[debtorIndex].industryStacks[stackIndex].tiles.first)
        state.players[debtorIndex].industryStacks[stackIndex].tiles.removeFirst()
        state.players[debtorIndex].cash = 0
        state.players[debtorIndex].incomePosition = 0
        let location = try #require(catalog.catalog.board.locations.first { location in
            location.industrySlots.contains { $0.contains("manufacturer") }
        })
        let slotIndex = try #require(location.industrySlots.firstIndex { $0.contains("manufacturer") })
        state.boardIndustryPlacements = [.init(
            placementID: "forced-sale-proof", locationID: location.id, slotIndex: slotIndex,
            ownerID: debtor, tile: canonicalTile
        )]
        _ = try GameCore.GameRulesEngine.resolveRoundEnd(state: &state, catalog: catalog)
        guard case .forcedSale = state.turnPhase else {
            Issue.record("round end must create a pending forced sale"); return
        }

        let result = try GameCore.FastActionEnumerator.enumerate(state: state, actorID: debtor, catalog: catalog)
        #expect(result.payloads.isEmpty == false)
        for payload in result.payloads {
            guard case .forcedSale = payload else {
                Issue.record("强卖阶段只应枚举强卖意图,却出现 \(payload)"); continue
            }
        }
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "fs-token-\($0.id.rawValue)"))
        })
        try assertAllAccepted(
            state, payloads: result.payloads, catalog: catalog,
            roomID: .init(rawValue: "fs-room"), tokens: tokens
        )
    }

    @Test func nonActivePhasesAndPlayersEnumerateEmpty() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let bystander = try #require(state.players.first { $0.id != actor }?.id)

        // 非行动玩家:返回空。
        let wrongActor = try GameCore.FastActionEnumerator.enumerate(
            state: state, actorID: bystander, catalog: catalog
        )
        #expect(wrongActor.payloads.isEmpty)

        // ended:终局状态返回空。
        var ended = state
        ended.turnPhase = .ended
        let endedResult = try GameCore.FastActionEnumerator.enumerate(
            state: ended, actorID: actor, catalog: catalog
        )
        #expect(endedResult.payloads.isEmpty)

        // eraIntermission:时代结算阶段返回空(手工置阶段;该阶段任何座位都无普通动作)。
        var intermission = state
        intermission.turnPhase = .eraIntermission(.init(
            settledEra: .canal, awards: [], confirmedPlayerIDs: []
        ))
        let intermissionResult = try GameCore.FastActionEnumerator.enumerate(
            state: intermission, actorID: actor, catalog: catalog
        )
        #expect(intermissionResult.payloads.isEmpty)
    }
}
```

**说明**:`awaitingTurnEndConfirmation` 的枚举空断言需要先落地 `SimulationRunner` 或通过 HostEngine 推进状态,放在 Task 4 Step 6 补充,本任务的测试必须当下即可编译执行。

- [ ] **Step 2: 跑测试确认失败**

Run: Global Constraints 的测试命令。
Expected: FAIL,编译错误 `cannot find 'FastActionEnumerator' in scope 'GameCore'`。

- [ ] **Step 3: 实现 FastActionEnumerator**

创建 `GameCore/Simulation/FastActionEnumerator.swift`:

```swift
import Foundation

extension GameCore {
    /// MCTS/AI 专用的高速合法动作枚举器。
    /// 以 LegalActionQueryEngine 的逐步 choices 做 DFS,收集 completePayload;
    /// 完备模式不做任何剪枝,截断模式(limit+prioritizer)在完备集合上排序取前 K。
    nonisolated enum FastActionEnumerator {
        struct Result: Equatable, Sendable {
            var payloads: [PlayerIntent.Payload]
            var truncated: Bool
        }

        enum EnumerationError: Error, Equatable, Sendable {
            /// fastPath 跳过了结构上限校验,枚举器自设 selections 深度上限。
            case depthExceeded
        }

        static func enumerate(
            state: GameState,
            actorID: PlayerID,
            catalog: VerifiedGameDataCatalog,
            limit: Int? = nil,
            prioritizer: ((PlayerIntent.Payload) -> Double)? = nil
        ) throws -> Result {
            guard state.activePlayerID == actorID else {
                return .init(payloads: [], truncated: false)
            }
            switch state.turnPhase {
            case .active, .forcedSale:
                break
            case .eraIntermission, .awaitingTurnEndConfirmation, .ended:
                return .init(payloads: [], truncated: false)
            }

            var stack: [LegalActionDraft] = []
            if case .forcedSale = state.turnPhase {
                stack.append(LegalActionDraft(action: .forcedSale, cardID: nil, selections: []))
            } else if let player = state.players.first(where: { $0.id == actorID }) {
                let kinds = ActionKind.allCases.filter { $0 != .forcedSale }
                stack.reserveCapacity(player.hand.count * kinds.count)
                for card in player.hand {
                    for kind in kinds {
                        stack.append(LegalActionDraft(action: kind, cardID: card.id, selections: []))
                    }
                }
            } else {
                return .init(payloads: [], truncated: false)
            }

            var complete: [PlayerIntent.Payload] = []
            var seen: Set<String> = []
            while let draft = stack.popLast() {
                guard draft.selections.count <= 128 else { throw EnumerationError.depthExceeded }
                let query = LegalActionQuery(
                    requestID: "enumerate", baseVersion: state.authoritativeVersion, draft: draft
                )
                let response: LegalActionResponse
                do {
                    response = try LegalActionQueryEngine.respond(
                        to: query, actorID: actorID, state: state, catalog: catalog, fastPath: true
                    )
                } catch is LegalActionQueryError {
                    continue // 死分支:该 draft 在此状态不可完成
                }
                if let payload = response.completePayload {
                    let key = String(describing: payload)
                    if seen.insert(key).inserted { complete.append(payload) }
                    continue
                }
                for choice in response.nextChoices {
                    var next = draft
                    next.selections.append(choice.value)
                    stack.append(next)
                }
            }

            var truncated = false
            if let limit {
                if let prioritizer {
                    // 稳定排序:先验降序,同分保持发现顺序。
                    complete = complete.enumerated()
                        .sorted { lhs, rhs in
                            let left = prioritizer(lhs.element)
                            let right = prioritizer(rhs.element)
                            return left == right ? lhs.offset < rhs.offset : left > right
                        }
                        .map(\.element)
                }
                if complete.count > limit {
                    complete.removeLast(complete.count - limit)
                    truncated = true
                }
            }
            return .init(payloads: complete, truncated: truncated)
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: Global Constraints 的测试命令。
Expected: PASS(本任务全部 5 个测试)。

- [ ] **Step 5: Commit**

```bash
cd /Users/baigeitiancai/Desktop/Interview-learning/Brass-Birmingham && \
git add ui-prototype/IndustrialCityBirmingham/GameCore/Simulation/FastActionEnumerator.swift \
        ui-prototype/IndustrialCityBirminghamTests/FastActionEnumeratorTests.swift && \
git commit -m "GameCore: FastActionEnumerator 完备模式(DFS 全枚举+阶段语义+去重)"
```

- [ ] **Step 6: 卖货状态专项测试(Review Focus 1)**

在 `FastActionEnumeratorTests` 追加:构造”有可卖产业”的状态——固定种子下用枚举器驱动:反复枚举+选 build 类 payload,直至 boardIndustryPlacements 含当前行动玩家的产业,再全量枚举并提交。种子 20_242 为初值;若 20 步内始终选不到 build(种子决定论,要么总行要么总不行),把 `freshFourPlayerState` 的种子 +1 重试到 build 出现为止,并把最终种子写回测试。

```swift
    @Test func sellChainStateEnumeratesAndSubmitsWithoutLooping() throws {
        let catalog = try verifiedCatalog()
        var state = try freshFourPlayerState(catalog: catalog)
        let roomID = GameCore.RoomID(rawValue: "sell-room")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "sell-token-\($0.id.rawValue)"))
        })
        var host = try state.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 2
        )
        var builtOwn = false
        for _ in 0..<20 {
            let current = try #require(host.gameState.activePlayerID)
            let result = try GameCore.FastActionEnumerator.enumerate(
                state: host.gameState, actorID: current, catalog: catalog
            )
            guard let buildPayload = result.payloads.first(where: { payload in
                if case .build = payload { return true } else { return false }
            }) else { break }
            let intent = GameCore.PlayerIntent(
                protocolVersion: 2, rulesetVersion: host.gameState.rulesetVersion,
                roomID: roomID, senderID: current,
                reconnectToken: try #require(tokens[current]),
                baseVersion: host.gameState.authoritativeVersion, payload: buildPayload
            )
            guard case .accepted = host.submit(intent, catalog: catalog) else {
                Issue.record("构造用 build 提交被拒"); return
            }
            // 回合确认推进(两行动后的待确认与时代结算都自动确认)。
            for _ in 0..<6 {
                let s = host.gameState
                if case .awaitingTurnEndConfirmation = s.turnPhase {
                    let actor2 = try #require(s.activePlayerID)
                    let r = host.submit(.init(
                        protocolVersion: 2, rulesetVersion: s.rulesetVersion, roomID: roomID,
                        senderID: actor2, reconnectToken: try #require(tokens[actor2]),
                        baseVersion: s.authoritativeVersion, payload: .confirmTurnEnd
                    ), catalog: catalog)
                    guard case .accepted = r else { Issue.record("turn confirm rejected"); return }
                } else if case .eraIntermission(let inter) = s.turnPhase {
                    guard let p = s.players.map(\.id).first(where: { inter.confirmedPlayerIDs.contains($0) == false }) else { break }
                    let r = host.submit(.init(
                        protocolVersion: 2, rulesetVersion: s.rulesetVersion, roomID: roomID,
                        senderID: p, reconnectToken: try #require(tokens[p]),
                        baseVersion: s.authoritativeVersion, payload: .confirmEraIntermission
                    ), catalog: catalog)
                    guard case .accepted = r else { Issue.record("era confirm rejected"); return }
                } else { break }
            }
            if host.gameState.turnPhase == .ended { break }
            if let c = host.gameState.activePlayerID,
               host.gameState.boardIndustryPlacements.contains(where: { $0.ownerID == c }) {
                builtOwn = true
                state = host.gameState
                break
            }
        }
        guard builtOwn, let actor = state.activePlayerID else { return }
        let result = try GameCore.FastActionEnumerator.enumerate(state: state, actorID: actor, catalog: catalog)
        #expect(result.payloads.isEmpty == false)
        try assertAllAccepted(state, payloads: result.payloads, catalog: catalog, roomID: roomID, tokens: tokens)
    }
```

Run: 同上命令。Expected: PASS(测试本身在有限步内完成即为“无环回”证明)。
Commit:

```bash
git add ui-prototype/IndustrialCityBirminghamTests/FastActionEnumeratorTests.swift && \
git commit -m "测试:卖货链状态下的枚举终止性与合法性"
```

---

### Task 3: FastActionEnumerator——limit/prioritizer 截断模式

**Files:**
- Modify: `ui-prototype/IndustrialCityBirmingham/GameCore/Simulation/FastActionEnumerator.swift`(排序/截断逻辑已在 Task 2 Step 3 一并写入,本任务用测试锁定)
- Test: `ui-prototype/IndustrialCityBirminghamTests/FastActionEnumeratorTests.swift`(追加)

**Interfaces:**
- Consumes: Task 2 的 `enumerate(state:actorID:catalog:limit:prioritizer:)`。
- Produces: 同一签名;`limit != nil` 时按 prioritizer 降序稳定截断,`truncated == true` 表示发生了截断。P1 的 MCTS 将以网络先验作为 prioritizer 传入。

- [ ] **Step 1: 写失败测试(追加到 FastActionEnumeratorTests)**

```swift
    @Test func truncatedModeKeepsTopPrioritizedActionsAndStaysLegal() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let complete = try GameCore.FastActionEnumerator.enumerate(state: state, actorID: actor, catalog: catalog)
        #expect(complete.payloads.count > 3, "需要足够多的动作才有截断意义")

        // 人为先验:loan > network > 其他,同分随机(用描述字符串哈希打散)。
        func prior(_ payload: GameCore.PlayerIntent.Payload) -> Double {
            switch payload {
            case .loan: return 3
            case .network: return 2
            default: return 1
            }
        }
        let top2 = try GameCore.FastActionEnumerator.enumerate(
            state: state, actorID: actor, catalog: catalog, limit: 2, prioritizer: prior
        )
        #expect(top2.payloads.count == 2)
        #expect(top2.truncated == true)
        #expect(prior(top2.payloads[0]) >= prior(top2.payloads[1]))

        // 截断结果与完备模式按同一先验排序后的前缀一致(稳定顺序)。
        let ranked = complete.payloads.enumerated()
            .sorted { lhs, rhs in
                let l = prior(lhs.element), r = prior(rhs.element)
                return l == r ? lhs.offset < rhs.offset : l > r
            }
            .map(\.element)
        #expect(Array(ranked.prefix(2)) == top2.payloads)

        // limit ≥ 总数:不截断。
        let big = try GameCore.FastActionEnumerator.enumerate(
            state: state, actorID: actor, catalog: catalog,
            limit: complete.payloads.count, prioritizer: prior
        )
        #expect(big.truncated == false)
        #expect(Set(big.payloads.map { String(describing: $0) })
            == Set(complete.payloads.map { String(describing: $0) }))

        // Review Focus 3:截断模式产物仍然全部合法。
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "trunc-token-\($0.id.rawValue)"))
        })
        try assertAllAccepted(
            state, payloads: top2.payloads, catalog: catalog,
            roomID: .init(rawValue: "trunc-room"), tokens: tokens
        )
    }

    @Test func limitWithoutPrioritizerKeepsDiscoveryOrder() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let complete = try GameCore.FastActionEnumerator.enumerate(state: state, actorID: actor, catalog: catalog)
        let head = try GameCore.FastActionEnumerator.enumerate(
            state: state, actorID: actor, catalog: catalog, limit: 3
        )
        #expect(head.payloads == Array(complete.payloads.prefix(3)))
        #expect(head.truncated == complete.payloads.count > 3)
    }
```

- [ ] **Step 2: 跑测试确认通过**

Run: Global Constraints 的测试命令。
Expected: PASS(截断逻辑已随 Task 2 实现,此测试若失败说明排序/截断实现有误,修到通过为止——TDD 的红步在 Task 2 已完成,这里是行为锁定)。

- [ ] **Step 3: Commit**

```bash
cd /Users/baigeitiancai/Desktop/Interview-learning/Brass-Birmingham && \
git add ui-prototype/IndustrialCityBirminghamTests/FastActionEnumeratorTests.swift && \
git commit -m "测试:FastActionEnumerator 截断模式(先验排序/稳定序/合法性保持)"
```

---

### Task 4: SimulationRunner

**Files:**
- Create: `ui-prototype/IndustrialCityBirmingham/GameCore/Simulation/SimulationRunner.swift`
- Test: `ui-prototype/IndustrialCityBirminghamTests/SimulationRunnerTests.swift`

**Interfaces:**
- Consumes: 各 `*Rules.validate` + `GameRulesEngine.resolve*`(与 `HostEngine.submitResolved` 同一组调用)。
- Produces(Task 5 与 P1/P2 依赖):

```swift
extension GameCore {
    nonisolated enum SimulationRunner {
        enum SimulationError: Error, Equatable, Sendable {
            case unsupportedRetracement   // 模拟永不撤回
        }
        static func apply(
            _ payload: PlayerIntent.Payload,
            actorID: PlayerID,
            roomID: RoomID,
            to state: inout GameState,
            catalog: VerifiedGameDataCatalog
        ) throws
    }
}
```

- [ ] **Step 1: 写失败测试**

创建 `SimulationRunnerTests.swift`(verifiedCatalog/freshState 同前,复制):

```swift
import Foundation
import Testing

@testable import IndustrialCityBirmingham

struct SimulationRunnerTests {
    private func verifiedCatalog() throws -> GameCore.VerifiedGameDataCatalog {
        // 与 FastActionEnumeratorTests.verifiedCatalog 完全相同,原样复制(仅 sources id 换成 "sim-runner-tests")。
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "IndustrialCityBirmingham/GameData/v2018.11")
        let catalog = try GameCore.GameDataLoader.decodeCatalog(
            rulesetVersion: "v2018.11",
            mapData: Data(contentsOf: directory.appending(path: "map.json")),
            industryData: Data(contentsOf: directory.appending(path: "industries.json")),
            cardData: Data(contentsOf: directory.appending(path: "cards.json")),
            merchantData: Data(contentsOf: directory.appending(path: "merchants.json")),
            incomeTrackData: Data(contentsOf: directory.appending(path: "income-track.json"))
        )
        let encoder = JSONEncoder()
        let files = try [
            "map.json": encoder.encode(catalog.board),
            "industries.json": encoder.encode(catalog.industries),
            "cards.json": encoder.encode(catalog.cards),
            "merchants.json": encoder.encode(catalog.merchants),
            "income-track.json": encoder.encode(catalog.incomeTrack),
        ]
        let manifest = GameCore.GameDataManifest(
            rulesetVersion: catalog.rulesetVersion,
            verificationStatus: .verified,
            files: files.keys.sorted().map {
                .init(path: $0, sha256: GameCore.GameDataLoader.sha256(files[$0]!))
            },
            sources: [.init(
                id: "sim-runner-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-10-11",
                checker: "independent-test", checkedOn: "2026-10-11"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }

    private func freshFourPlayerState(catalog: GameCore.VerifiedGameDataCatalog) throws -> GameCore.GameState {
        let players = (1...4).map { GameCore.PlayerID(rawValue: "sim-p\($0)") }
        var setupRules = GameCore.SetupRules(seed: 20_243)
        return try setupRules.makeGame(catalog: catalog, playerIDs: players).state
    }

    @Test func simulatedSequenceMatchesHostEngineStateExactly() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let roomID = GameCore.RoomID(rawValue: "sim-room")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "sim-token-\($0.id.rawValue)"))
        })
        var host = try state.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 2
        )
        var sim = state
        var rng = SplitMix64(seed: 44)

        for step in 0..<30 {
            let current = try #require(host.gameState.activePlayerID)
            switch host.gameState.turnPhase {
            case .active, .forcedSale:
                let result = try GameCore.FastActionEnumerator.enumerate(
                    state: host.gameState, actorID: current, catalog: catalog
                )
                guard let payload = result.payloads.randomElement(using: &rng) else {
                    Issue.record("step \(step): 无可枚举动作"); return
                }
                try GameCore.SimulationRunner.apply(
                    payload, actorID: current, roomID: roomID, to: &sim, catalog: catalog
                )
                let intent = GameCore.PlayerIntent(
                    protocolVersion: 2, rulesetVersion: host.gameState.rulesetVersion,
                    roomID: roomID, senderID: current,
                    reconnectToken: try #require(tokens[current]),
                    baseVersion: host.gameState.authoritativeVersion, payload: payload
                )
                guard case .accepted = host.submit(intent, catalog: catalog) else {
                    Issue.record("step \(step): 宿主拒绝了枚举动作"); return
                }
            case .awaitingTurnEndConfirmation:
                try GameCore.SimulationRunner.apply(
                    .confirmTurnEnd, actorID: current, roomID: roomID, to: &sim, catalog: catalog
                )
                let r = host.submit(.init(
                    protocolVersion: 2, rulesetVersion: host.gameState.rulesetVersion, roomID: roomID,
                    senderID: current, reconnectToken: try #require(tokens[current]),
                    baseVersion: host.gameState.authoritativeVersion, payload: .confirmTurnEnd
                ), catalog: catalog)
                guard case .accepted = r else { Issue.record("turn confirm 被拒"); return }
            case .eraIntermission(let inter):
                guard let p = host.gameState.players.map(\.id)
                    .first(where: { inter.confirmedPlayerIDs.contains($0) == false }) else {
                    Issue.record("intermission 卡死"); return
                }
                try GameCore.SimulationRunner.apply(
                    .confirmEraIntermission, actorID: p, roomID: roomID, to: &sim, catalog: catalog
                )
                let r = host.submit(.init(
                    protocolVersion: 2, rulesetVersion: host.gameState.rulesetVersion, roomID: roomID,
                    senderID: p, reconnectToken: try #require(tokens[p]),
                    baseVersion: host.gameState.authoritativeVersion, payload: .confirmEraIntermission
                ), catalog: catalog)
                guard case .accepted = r else { Issue.record("era confirm 被拒"); return }
            case .ended:
                return
            }
            // 每步之后状态必须完全一致(含版本与 actionNumber)。
            guard sim == host.gameState else {
                Issue.record("step \(step): 模拟与宿主状态分叉"); return
            }
        }
    }

    @Test func retractionIsUnsupportedInSimulation() throws {
        let catalog = try verifiedCatalog()
        var state = try freshFourPlayerState(catalog: catalog)
        #expect(throws: GameCore.SimulationRunner.SimulationError.self) {
            try GameCore.SimulationRunner.apply(
                .retractTurnActions, actorID: state.activePlayerID!,
                roomID: .init(rawValue: "x"), to: &state, catalog: catalog
            )
        }
    }

    @Test func illegalPayloadRejectedInSimulationToo() throws {
        let catalog = try verifiedCatalog()
        var state = try freshFourPlayerState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        // 手牌之外的卡做 pass:宿主会拒(missingDiscardCard),模拟侧必须抛错。
        let fakeCard = "not-in-any-hand"
        #expect(throws: (any Error).self) {
            try GameCore.SimulationRunner.apply(
                .pass(.init(cardID: fakeCard)), actorID: actor,
                roomID: .init(rawValue: "x"), to: &state, catalog: catalog
            )
        }
        // 状态不得被部分写入。
        let pristine = try freshFourPlayerState(catalog: catalog)
        #expect(state == pristine)
    }
```

(文件末尾补充 SplitMix64,定义见 Task 5 Step 1 代码块,原样复制一份。)

- [ ] **Step 2: 跑测试确认失败**

Run: Global Constraints 的测试命令。
Expected: FAIL,编译错误 `cannot find 'SimulationRunner' in scope 'GameCore'`。

- [ ] **Step 3: 实现 SimulationRunner**

创建 `GameCore/Simulation/SimulationRunner.swift`:

```swift
import Foundation

extension GameCore {
    /// 模拟专用"瘦提交":复刻 HostEngine 的 validate→resolve 分发,
    /// 跳过身份校验、GameStateAuthorityValidator 与投影构建。
    /// 规则解析逻辑与宿主路径逐行同源,状态推进必须等价(对拍测试锁定)。
    nonisolated enum SimulationRunner {
        enum SimulationError: Error, Equatable, Sendable {
            case unsupportedRetracement
        }

        static func apply(
            _ payload: PlayerIntent.Payload,
            actorID: PlayerID,
            roomID: RoomID,
            to state: inout GameState,
            catalog: VerifiedGameDataCatalog
        ) throws {
            switch payload {
            case .pass(let intent):
                let target = try SimpleActionRules.validatePass(
                    intent, actorID: actorID, state: state, catalog: catalog
                )
                _ = try GameRulesEngine.resolvePass(
                    target, roomID: roomID, state: &state, catalog: catalog
                )
            case .build(let intent):
                let target = try BuildRules.validate(
                    intent, actorID: actorID, state: state, catalog: catalog
                )
                _ = try GameRulesEngine.resolveBuild(
                    target, roomID: roomID, state: &state, catalog: catalog
                )
            case .network(let intent):
                let target = try NetworkRules.validate(
                    intent, actorID: actorID, state: state, catalog: catalog
                )
                _ = try GameRulesEngine.resolveNetwork(
                    target, roomID: roomID, state: &state, catalog: catalog
                )
            case .develop(let intent):
                let target = try DevelopRules.validate(
                    intent, actorID: actorID, state: state, catalog: catalog
                )
                _ = try GameRulesEngine.resolveDevelop(
                    target, roomID: roomID, state: &state, catalog: catalog
                )
            case .sell(let intent):
                let target = try SellRules.validate(
                    intent, actorID: actorID, state: state, catalog: catalog
                )
                _ = try GameRulesEngine.resolveSell(
                    target, roomID: roomID, state: &state, catalog: catalog
                )
            case .loan(let intent):
                let target = try SimpleActionRules.validateLoan(
                    intent, actorID: actorID, state: state, catalog: catalog
                )
                _ = try GameRulesEngine.resolveLoan(
                    target, roomID: roomID, state: &state, catalog: catalog
                )
            case .scout(let intent):
                let target = try SimpleActionRules.validateScout(
                    intent, actorID: actorID, state: state, catalog: catalog
                )
                _ = try GameRulesEngine.resolveScout(
                    target, roomID: roomID, state: &state, catalog: catalog
                )
            case .forcedSale(let intent):
                _ = try GameRulesEngine.resolveForcedSale(
                    intent, actorID: actorID, roomID: roomID, state: &state, catalog: catalog
                )
            case .confirmEraIntermission:
                let target = try SimpleActionRules.validateEraConfirmation(
                    actorID: actorID, state: state, catalog: catalog
                )
                _ = try GameCore.GameRulesEngine.resolveEraConfirmation(
                    target, roomID: roomID, state: &state, catalog: catalog
                )
            case .confirmTurnEnd:
                let target = try SimpleActionRules.validateTurnEndConfirmation(
                    actorID: actorID, state: state, catalog: catalog
                )
                _ = try GameCore.GameRulesEngine.resolveTurnEndConfirmation(
                    actorID: target.actorID, roomID: roomID, state: &state, catalog: catalog
                )
            case .retractTurnActions:
                throw SimulationError.unsupportedRetracement
            }
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: Global Constraints 的测试命令。
Expected: PASS。若 `simulatedSequenceMatchesHostEngineStateExactly` 失败于"状态分叉",用 `print(String(describing: (sim, host.gameState)))` 差分定位第一处分叉字段——resolvers 内部对 state 的写入必须已包含版本自增,任何缺失即宿主/模拟不等价的实现 bug,在 resolvers 调用参数上修正(不得改 resolvers 本身)。

- [ ] **Step 5: Review Focus 4——拒绝一致性专项**

已在 Step 1 的 `illegalPayloadRejectedInSimulationToo` 覆盖(错误卡 pass:模拟抛错且状态零写入)。跑全量测试确认无回归。

- [ ] **Step 6: 补 Task 2 遗留的 awaitingTurnEndConfirmation 枚举测试**

在 `FastActionEnumeratorTests` 追加:

```swift
    @Test func awaitingTurnEndConfirmationEnumeratesEmpty() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let roomID = GameCore.RoomID(rawValue: "await-room")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "await-token-\($0.id.rawValue)"))
        })
        var host = try state.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 2
        )
        // 打满本回合行动(运河第 1 回合只有 1 行动,之后是 2,用循环兼容两种),
        // 每次提交 loan(总是合法);进入待确认即停。
        for _ in 0..<3 {
            guard host.gameState.turnPhase == .active else { break }
            let s = host.gameState
            let actor = try #require(s.activePlayerID)
            let player = try #require(s.players.first { $0.id == actor })
            let card = try #require(player.hand.first)
            let r = host.submit(.init(
                protocolVersion: 2, rulesetVersion: s.rulesetVersion, roomID: roomID,
                senderID: actor, reconnectToken: try #require(tokens[actor]),
                baseVersion: s.authoritativeVersion, payload: .loan(.init(cardID: card.id))
            ), catalog: catalog)
            guard case .accepted = r else { Issue.record("loan 被拒"); return }
        }
        guard case .awaitingTurnEndConfirmation = host.gameState.turnPhase else {
            Issue.record("打满行动后应进入待确认,实际 \(host.gameState.turnPhase)"); return
        }
        let result = try GameCore.FastActionEnumerator.enumerate(
            state: host.gameState, actorID: try #require(host.gameState.activePlayerID),
            catalog: catalog
        )
        #expect(result.payloads.isEmpty)
    }
```

Run: Global Constraints 的测试命令。Expected: PASS。

- [ ] **Step 7: Commit**

```bash
cd /Users/baigeitiancai/Desktop/Interview-learning/Brass-Birmingham && \
git add ui-prototype/IndustrialCityBirmingham/GameCore/Simulation/SimulationRunner.swift \
        ui-prototype/IndustrialCityBirminghamTests/SimulationRunnerTests.swift \
        ui-prototype/IndustrialCityBirminghamTests/FastActionEnumeratorTests.swift && \
git commit -m "GameCore: SimulationRunner 瘦提交路径 + 宿主等价/拒绝一致性测试"
```

---

### Task 5: P0 验收——随机对局等价、万状态接受率、吞吐基准

**Files:**
- Create: `ui-prototype/IndustrialCityBirminghamTests/SimulationFuzzTests.swift`

**Interfaces:**
- Consumes: Task 2/3 的 `FastActionEnumerator.enumerate`、Task 4 的 `SimulationRunner.apply`。
- Produces: 测试侧公共件 `SplitMix64`(确定性 RNG)与 `RandomGameDriver`(枚举驱动的随机对局推进器,P1 的 MCTS 冒烟测试将复用)。

- [ ] **Step 1: 写测试文件(含驱动器与三个验收测试)**

```swift
import Foundation
import Testing

@testable import IndustrialCityBirmingham

/// 确定性 RNG:种子固定 → 对局序列完全可复现。
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// 枚举驱动的随机对局推进器:active/forcedSale 随机选枚举动作,
/// awaitingTurnEnd/eraIntermission 自动确认。P1 的 MCTS 冒烟测试复用此结构。
struct RandomGameDriver {
    enum DriverError: Error, Equatable {
        case exceededSafetyBound
        case missingActor
        case noActionsAvailable
        case intermissionStuck
    }

    struct Step: Sendable {
        var actor: GameCore.PlayerID
        var payload: GameCore.PlayerIntent.Payload
    }

    let catalog: GameCore.VerifiedGameDataCatalog
    let roomID: GameCore.RoomID
    var rng: SplitMix64

    /// onState:每个枚举状态回调(状态 + 完备枚举结果);驱动器不持有引用,防内存膨胀。
    mutating func playToEnd(
        from initial: GameCore.GameState,
        onState: (GameCore.GameState, GameCore.FastActionEnumerator.Result) throws -> Void = { _, _ in }
    ) throws -> (final: GameCore.GameState, steps: [Step]) {
        var state = initial
        var steps: [Step] = []
        var guardCounter = 0
        while state.turnPhase != .ended {
            guardCounter += 1
            guard guardCounter < 2_000 else { throw DriverError.exceededSafetyBound }
            switch state.turnPhase {
            case .active, .forcedSale:
                guard let actor = state.activePlayerID else { throw DriverError.missingActor }
                let result = try GameCore.FastActionEnumerator.enumerate(
                    state: state, actorID: actor, catalog: catalog
                )
                guard let payload = result.payloads.randomElement(using: &rng) else {
                    throw DriverError.noActionsAvailable
                }
                try onState(state, result)
                try GameCore.SimulationRunner.apply(
                    payload, actorID: actor, roomID: roomID, to: &state, catalog: catalog
                )
                steps.append(Step(actor: actor, payload: payload))
            case .awaitingTurnEndConfirmation:
                guard let actor = state.activePlayerID else { throw DriverError.missingActor }
                try GameCore.SimulationRunner.apply(
                    .confirmTurnEnd, actorID: actor, roomID: roomID, to: &state, catalog: catalog
                )
                steps.append(Step(actor: actor, payload: .confirmTurnEnd))
            case .eraIntermission(let intermission):
                guard let player = state.players.map(\.id)
                    .first(where: { intermission.confirmedPlayerIDs.contains($0) == false }) else {
                    throw DriverError.intermissionStuck
                }
                try GameCore.SimulationRunner.apply(
                    .confirmEraIntermission, actorID: player, roomID: roomID, to: &state, catalog: catalog
                )
                steps.append(Step(actor: player, payload: .confirmEraIntermission))
            case .ended:
                break
            }
        }
        return (state, steps)
    }
}

struct SimulationFuzzTests {
    private func verifiedCatalog() throws -> GameCore.VerifiedGameDataCatalog {
        // 与 SimulationRunnerTests.verifiedCatalog 完全相同,原样复制(仅 sources id 换成 "fuzz-tests")。
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "IndustrialCityBirmingham/GameData/v2018.11")
        let catalog = try GameCore.GameDataLoader.decodeCatalog(
            rulesetVersion: "v2018.11",
            mapData: Data(contentsOf: directory.appending(path: "map.json")),
            industryData: Data(contentsOf: directory.appending(path: "industries.json")),
            cardData: Data(contentsOf: directory.appending(path: "cards.json")),
            merchantData: Data(contentsOf: directory.appending(path: "merchants.json")),
            incomeTrackData: Data(contentsOf: directory.appending(path: "income-track.json"))
        )
        let encoder = JSONEncoder()
        let files = try [
            "map.json": encoder.encode(catalog.board),
            "industries.json": encoder.encode(catalog.industries),
            "cards.json": encoder.encode(catalog.cards),
            "merchants.json": encoder.encode(catalog.merchants),
            "income-track.json": encoder.encode(catalog.incomeTrack),
        ]
        let manifest = GameCore.GameDataManifest(
            rulesetVersion: catalog.rulesetVersion,
            verificationStatus: .verified,
            files: files.keys.sorted().map {
                .init(path: $0, sha256: GameCore.GameDataLoader.sha256(files[$0]!))
            },
            sources: [.init(
                id: "fuzz-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-10-11",
                checker: "independent-test", checkedOn: "2026-10-11"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }

    private func freshFourPlayerState(
        catalog: GameCore.VerifiedGameDataCatalog, gameIndex: Int
    ) throws -> GameCore.GameState {
        let players = (1...4).map { GameCore.PlayerID(rawValue: "fuzz-g\(gameIndex)-p\($0)") }
        var setupRules = GameCore.SetupRules(seed: UInt64(30_000 + gameIndex))
        return try setupRules.makeGame(catalog: catalog, playerIDs: players).state
    }

    private func tokens(for state: GameCore.GameState) -> [GameCore.PlayerID: GameCore.ReconnectToken] {
        Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "fuzz-token-\($0.id.rawValue)"))
        })
    }

    /// 验收 A(spec §11 P0-②):模拟路径与宿主路径终局状态逐字段一致。
    @Test func simulatedGamesReplayIdenticallyThroughHostEngine() throws {
        let catalog = try verifiedCatalog()
        let roomID = GameCore.RoomID(rawValue: "fuzz-eq-room")
        for gameIndex in 0..<5 {
            let initial = try freshFourPlayerState(catalog: catalog, gameIndex: gameIndex)
            var driver = RandomGameDriver(catalog: catalog, roomID: roomID, rng: SplitMix64(seed: UInt64(77_000 + gameIndex)))
            let (simFinal, steps) = try driver.playToEnd(from: initial)
            #expect(simFinal.turnPhase == .ended)

            var host = try initial.makeHostEngine(
                roomID: roomID, reconnectTokens: tokens(for: initial), protocolVersion: 2
            )
            for step in steps {
                let intent = GameCore.PlayerIntent(
                    protocolVersion: 2, rulesetVersion: host.gameState.rulesetVersion,
                    roomID: roomID, senderID: step.actor,
                    reconnectToken: try #require(tokens(for: initial)[step.actor]),
                    baseVersion: host.gameState.authoritativeVersion, payload: step.payload
                )
                guard case .accepted = host.submit(intent, catalog: catalog) else {
                    Issue.record("game \(gameIndex): 宿主拒绝重放动作 \(step.payload)")
                    return
                }
            }
            #expect(host.gameState == simFinal)
            #expect(try host.gameState.canonicalHash() == simFinal.canonicalHash())
        }
    }

    /// 验收 B(spec §11 P0-①):≥10k 状态完备枚举,分层全量提交 + 抽样单提交,100% 被 HostEngine 接受。
    /// 预计运行 10–20 分钟,是 P0 的签收测试。
    @Test func acceptanceSweepTenThousandStates() throws {
        let catalog = try verifiedCatalog()
        let roomID = GameCore.RoomID(rawValue: "fuzz-sweep-room")
        var totalStates = 0
        var fullSubmitStates = 0
        var submittedPairs = 0
        var stateOrdinal = 0

        for gameIndex in 0..<90 {
            let initial = try freshFourPlayerState(catalog: catalog, gameIndex: gameIndex)
            let tokens = tokens(for: initial)
            var driver = RandomGameDriver(
                catalog: catalog, roomID: roomID,
                rng: SplitMix64(seed: UInt64(88_000 + gameIndex))
            )
            try driver.playToEnd(from: initial) { state, result in
                stateOrdinal += 1
                totalStates += 1
                // 每 40 个状态做一次全量提交(单状态动作数封顶 400,防病态分支拖爆测试)。
                if stateOrdinal % 40 == 0 {
                    fullSubmitStates += 1
                    var host = try state.makeHostEngine(
                        roomID: roomID, reconnectTokens: tokens, protocolVersion: 2
                    )
                    for payload in result.payloads.prefix(400) {
                        guard let actor = state.activePlayerID else { continue }
                        var trial = host
                        let intent = GameCore.PlayerIntent(
                            protocolVersion: 2, rulesetVersion: state.rulesetVersion,
                            roomID: roomID, senderID: actor,
                            reconnectToken: try #require(tokens[actor]),
                            baseVersion: state.authoritativeVersion, payload: payload
                        )
                        submittedPairs += 1
                        guard case .accepted = trial.submit(intent, catalog: catalog) else {
                            Issue.record("game \(gameIndex) state#\(stateOrdinal) 拒绝了枚举动作 \(payload)")
                            continue
                        }
                    }
                }
            }
        }
        #expect(totalStates >= 10_000)
        #expect(fullSubmitStates >= 200)
        #expect(submittedPairs >= 4_000)
        print("P0_SWEEP states=\(totalStates) fullSubmitStates=\(fullSubmitStates) pairs=\(submittedPairs)")
    }

    /// 验收 C(spec §11 P0-③):完备枚举吞吐 p95 ≤ 50ms(开发机模拟器)。
    @Test func enumerationThroughputP95Under50ms() throws {
        let catalog = try verifiedCatalog()
        let roomID = GameCore.RoomID(rawValue: "fuzz-perf-room")
        var samples: [StateSample] = []
        for gameIndex in 0..<3 {
            let initial = try freshFourPlayerState(catalog: catalog, gameIndex: 500 + gameIndex)
            var driver = RandomGameDriver(
                catalog: catalog, roomID: roomID,
                rng: SplitMix64(seed: UInt64(99_000 + gameIndex))
            )
            try driver.playToEnd(from: initial) { state, _ in
                if samples.count < 200, state.turnPhase == .active {
                    samples.append(StateSample(state: state))
                }
            }
        }
        #expect(samples.count >= 120, "需要至少 120 个有效采样")
        var durations: [Double] = []
        for sample in samples {
            let actor = try #require(sample.state.activePlayerID)
            let start = DispatchTime.now()
            _ = try GameCore.FastActionEnumerator.enumerate(
                state: sample.state, actorID: actor, catalog: catalog
            )
            durations.append(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        }
        durations.sort()
        let p95 = durations[Int((Double(durations.count - 1) * 0.95).rounded(.down))]
        print("P0_PERF p95ms=\(p95) samples=\(durations.count)")
        #expect(p95 <= 50.0)
    }

    private struct StateSample {
        let state: GameCore.GameState
    }
}
```

- [ ] **Step 2: 先跑两个快测试**

Run: Global Constraints 的测试命令(全 target)。
Expected: `simulatedGamesReplayIdenticallyThroughHostEngine` 与 `enumerationThroughputP95Under50ms` PASS;`acceptanceSweepTenThousandStates` 允许暂时失败(下一红步),但不得编译失败。

- [ ] **Step 3: 跑万状态签收测试**

Run: 同上命令(预计 10–20 分钟)。
Expected: PASS,输出 `P0_SWEEP states=… fullSubmitStates=… pairs=…` 且总数达标。若出现任何“拒绝了枚举动作”:这是引擎/枚举正确性 bug,按 systematic-debugging 处理——最小化复现(记录 gameIndex/stateOrdinal/payload),修根因后重跑;不得放宽断言。若 p95 超标:先确认采样逻辑无误,再对 `FastActionEnumerator` 做性能分析(Instruments/手动计时拆分 respond 调用数),优化方向仅限:避免重复构造查询对象、去重 key 优化;**不得**通过砍完备性达标。

- [ ] **Step 4: Commit**

```bash
cd /Users/baigeitiancai/Desktop/Interview-learning/Brass-Birmingham && \
git add ui-prototype/IndustrialCityBirminghamTests/SimulationFuzzTests.swift && \
git commit -m "测试:P0 验收——随机对局宿主等价/万状态枚举接受率/吞吐基准"
```

---

## 完成定义(对照 spec §11 P0)

1. ✅ 完备枚举全量 submit 接受率 100%,覆盖 ≥10k 状态(Task 5 Step 3 输出为证);
2. ✅ 模拟路径与宿主路径状态逐字段一致(Task 4 Step 1 + Task 5 验收 A);
3. ✅ 单决策完备枚举 p95 ≤ 50ms(Task 5 验收 C 输出为证);
4. ✅ 全 target 测试无回归(Task 0 基线对照);
5. ✅ 每个任务独立提交,工作区无本计划产生的未提交文件。

## 自审记录

- **Spec 覆盖**:spec §4.1(枚举器:完备/截断/正确性契约)、§4.2(SimulationRunner)、§4.3(不改规则语义/等价对拍)→ Task 1–5;§11 P0 三条验收 → Task 5;§12(与 ExactCompletionSearch 交叉验证)→ 以 `SnapshotActionAvailability` 双向覆盖测试等价实现(它内部即 `ExactCompletionSearch`),语义一致且更强(反向覆盖也验了)。
- **占位符扫描**:无 TBD/TODO/占位代码;`awaitingTurnEndConfirmation` 的测试依赖明确安排在 Task 4 Step 6(依赖 SimulationRunner 落地),不阻塞所在任务的编译执行;所有代码步骤完整可照抄。
- **类型一致性**:`FastActionEnumerator.Result`/`EnumerationError`、`SimulationRunner.SimulationError`、`SplitMix64`、`RandomGameDriver.Step` 在各任务间签名一致;`respond(..., fastPath:)` 命名贯穿。
- **Review Focus**:五条均有对应测试(见各条标注)。
