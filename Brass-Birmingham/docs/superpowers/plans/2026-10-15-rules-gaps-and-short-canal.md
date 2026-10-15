# 规则缺口(A–D)与运河新手短局 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把规格里的四条收成规则写成权威文档/注释/回归测试（A/B/C 不改玩法，D 抽出 `returnScoredLinks` 并让铁路终局撤线），再实现 `MatchMode.shortCanal` 新手短局（引擎、存档盖章、大厅入口），标准局字节级不变。

**Architecture:** 三份顺序合并的 PR。PR 1 只动文档、错误注释、`ScoringRules`/`TurnRules` 的撤线抽取与补充测试锁；PR 2 在 GameCore 增加 `MatchMode`、`isGameFinalRound`、`applyShortCanalBonus`、`shortCanalScored` 事件，并让 `SnapshotStore` 把短局存档盖成 schema 5（协议 3）；PR 3 让真实大厅可选模式并完成协议 2/3 的 `versionIncompatible` 编舞。标准局 canonical bytes、事件序列、金哈希全程钉死不变。

**Tech Stack:** Swift 6 / SwiftUI，Swift Testing（`@Test`/`#expect`/`#require`），xcodebuild 单元测试目标 `IndustrialCityBirminghamTests`。

**Spec:** `docs/superpowers/specs/2026-10-15-rules-gaps-and-short-canal.md`（本计划从该规格论证；执行者须同时读规格与计划）

---

## Global Constraints

- **测试命令**（所有 "Run" 步骤通用；Swift Testing 不支持单测名过滤，每步都跑整个单元测试目标，从输出里的用例名确认结果）：
  ```bash
  cd ui-prototype && xcodebuild test -scheme IndustrialCityBirmingham \
    -destination 'platform=iOS Simulator,id=F993AE30-7BF3-4CAD-A79F-1AF9698E040F' \
    -derivedDataPath /tmp/bb_sim_dd -parallel-testing-enabled NO \
    -only-testing:IndustrialCityBirminghamTests 2>&1 | tail -40
  ```
- **三份金哈希一个字符都不许改**（`GameRulesEngineTests.swift:26-30`）：2 人 `ae1e20cb…`、3 人 `479b30f6…`、4 人 `f0f69d8f…`。哈希若变，是编码器改坏了旧字段的写法——修代码，禁止重录。
- **标准局**：会话协议 2、快照 schema 4、`GameState` canonical JSON 不含 `matchMode` 键、事件序列不变。`SnapshotEnvelope.currentSchemaVersion` 保持 4。
- **⚠ 规格勘误（已实证）**：规格说 "`JSONEncoder` 对 `nil` 可选值写出 `null`，不要改成 `encodeIfPresent`"——**与现状相反**。GameCore 全目录没有任何手写 `encode(to:)`（已 grep 确认），`GameState`/`MatchProjection` 用合成编码，而 Swift 合成 `Encodable` 对 `nil` 可选**省略键**（已用独立 Swift 脚本实测 `{"a":1}`）。因此 PR 2 手写 `encode(to:)` 时，既有可选字段必须用 `encodeIfPresent` 才能保持字节不变；写出 `null` 反而会改字节、炸金哈希。**以"往返字节相等测试 + 金哈希"为最终裁判**，规格那句按本条修正执行。
- **测试名不得改名**：`RulesCoverageTests`（`RulesCoverageTests.swift:121-228`）按字符串引用了大量测试函数名，包括 `canalPreparationPreservesMarketsRefillsMerchantsRedealsAndPreservesLongLivedState`、`finalRailScoringRepeatsPreservedLevelTwoAwardsNoIncomeAndResolvesAllWinnerTies`、`eraScoringCountsEveryHyperedgeAdjacentFlippedIndustryAndKeepsAllLinks` 等。本计划新增断言只加不改名；两处错误测试**注释**要改、断言不动。
- **两份 RULES.md 按节编辑**：仓库根 `RULES.md` 与 `ui-prototype/RULES.md`（`RulesCoverageTests.rulesURL()` 读的是后者，`RulesCoverageTests.swift:196-199`）。禁止用一份覆盖另一份，禁止整文件重排（§12/§13 切片边界必须保持）。
- **非目标（不许碰）**：`resolveNetwork` 双铁路煤顺序、`productionCount`、贷款、资源优先级、覆盖建造、出售奖励、`RULES.md` 6.1 的确认/撤回、`DemoModels.LobbyState`、`#if DEBUG` 演示 `LobbyView`（`LobbyView.swift:175-481`）、`RecoveryCoordinator.recover` 的 schema `switch`（`RecoveryCoordinator.swift:267-291`）、`versionIncompatible` 不加关联值、不引入运行时 flag。
- **Xcode 工程**使用 `PBXFileSystemSynchronizedRootGroup`，新增 .swift 文件放进对应目录即自动入 target，无需改 pbxproj。
- 提交信息沿用仓库风格（中文、`规则文档:`/`引擎:`/`测试:`/`会话:` 前缀）。

## Review Focus

规格未逐一列出、但最可能咬人的五类输入；每条已钉进所属任务的测试：

1. **孤儿线**（`placedLinks` 的 `ownerID` 不在 `players` 里）：`returnScoredLinks` 必须抛 `missingDefinition` 且一条余量都不改、过渡整体失败，而不是像旧 `prepareRailEra` 那样静默跳过再清空 → Task 1 测试 `eraConfirmationFailsClosedWhenALinkHasNoOwner`。
2. **标准局 canonical bytes**：手写 `encode(to:)` 若把 `nil` 可选写成 `null`（照规格字面执行）就会改字节、炸三份金哈希 → Task 5 测试 `standardStateOmitsMatchModeKeyAndRoundTripsCanonicalBytes` + 金哈希全跑。
3. **短局扣分顺序与地板**：VP 0、现金 £4、收入等级 -3 时最终 VP 必须是 0（先加现金再扣收入），事件仍记录名义 `incomePoints == -3` → Task 9 测试 `shortCanalBonusFloorsVictoryPointsAfterCashThenIncomeInOrder`。
4. **schema 5 盖章与模式门**：协议 3 + 短局才由 `save` 盖 5；schema 5 但内层不是短局 → `schemaMismatch`；schema 4 夹带 `"matchMode":"shortCanal"` → 拒绝且不恢复 → Task 12 三个测试。
5. **客机协议跟随不震荡**：翻转后的 hello 若再被拒即停（不在 2/3 之间来回）；主机名册只保留按新协议重新 hello 的人 → Task 15 测试 `guestFollowsHostProtocolFlipAndStaysSeated` / `hostSwitchingProtocolPrunesSeatsThatNeverRehello`（"二次拒绝即停"分支靠代码评审覆盖，时序赛跑做不成确定性测试，见 Task 15 Step 1 的说明）。

---

# PR 1：对齐 A/B/C/D 规则文档，铁路终局撤线且不重复计分

依赖：无。行为除铁路终局撤线外不变；无连线的对局（金哈希局）连终态都不变。

### Task 1: 抽出 `returnScoredLinks`，铁路终局计分后撤线退回

**Files:**
- Modify: `ui-prototype/IndustrialCityBirmingham/GameCore/Rules/ScoringRules.swift:75-100`（prepareRailEra 内联撤线循环 → 调用新函数）
- Modify: `ui-prototype/IndustrialCityBirmingham/GameCore/Rules/TurnRules.swift:189-197`（completeRound 铁路分支）
- Test: `ui-prototype/IndustrialCityBirminghamTests/TurnScoringRulesTests.swift`（文件末尾、private 辅助之前加两个测试）

**Interfaces:**
- Produces: `GameCore.ScoringRules.returnScoredLinks(state: inout GameState) throws`（`ScoringRules.swift` 新静态函数；PR 2 的短局终局将复用它）
- Consumes: 既有 `placement(ownerID:industryID:level:placementID:locationID:catalog:)`、`mutatePlayer(_:in:_:)`、`setup(playerCount:catalog:)`、`verifiedCatalog()`（`TurnScoringRulesTests.swift:1053-1129`）

- [ ] **Step 1: 写失败的铁路终局撤线测试**

在 `TurnScoringRulesTests.swift` 的 `finalSeatActionAtomicallyCarriesReplayableEraTransitionsAndRailSkipsIncome` 之后加：

```swift
@Test func railFinalRoundReturnsScoredLinksToOwnersWithoutDoubleScoring() throws {
    let catalog = try verifiedCatalog()
    var state = try setup(playerCount: 2, catalog: catalog)
    state.era = .rail
    state.roundNumber = state.railRoundCapacity
    let owner = state.playerOrder[0]
    var cotton = try placement(
        ownerID: owner, industryID: "cotton-mill", level: 2,
        placementID: "rail-cotton", locationID: "birmingham", catalog: catalog.catalog
    )
    cotton.isFlipped = true
    state.boardIndustryPlacements.append(cotton)
    let cottonLevel = try #require(
        catalog.catalog.industries.first { $0.id == "cotton-mill" }?
            .levels.first { $0.level == 2 }
    )
    let route = try #require(catalog.catalog.board.routes.first { $0.id == "birmingham-coventry" })
    // 直接 append,不走 resolveNetwork:那条路径会把余量减到 12,退回后回不到 14。
    state.placedLinks.append(.init(routeID: route.id, ownerID: owner, era: .rail))
    mutatePlayer(owner, in: &state) { $0.linksRemaining = 13; $0.victoryPoints = 0 }

    let events = try GameCore.GameRulesEngine.resolveRoundEnd(state: &state, catalog: catalog)

    let player = try #require(state.players.first { $0.id == owner })
    // 线分 2 + 产业分 5,各计一次,不是两倍。
    #expect(player.victoryPoints == cottonLevel.linkPoints + cottonLevel.victoryPoints)
    #expect(state.placedLinks.isEmpty)
    #expect(player.linksRemaining == 14)
    #expect(state.turnPhase == .ended)
    // 撤线不产生第四个转换:仍是 roundEnded、eraScored、gameEnded。
    #expect(events.count == 3)
    guard case .roundEnded = events[0],
          case .eraScored(let scored) = events[1],
          case .gameEnded = events[2] else {
        Issue.record("rail endgame events must stay roundEnded, eraScored, gameEnded")
        return
    }
    #expect(scored.removedRouteIDs.isEmpty)
}
```

数字依据（当前 `industries.json`/`map.json` 已核实）：cotton-mill L2 `victoryPoints 5`、`linkPoints 2`；`birmingham-coventry` 的 `adjacentLocationIDs` 只有 `birmingham`、`coventry`，两者都是 city、无贸易商格，故无线分以外的连接图标。Birmingham 槽 0 允许 cotton-mill。

- [ ] **Step 2: 写失败的孤儿线测试**

同文件再加：

```swift
@Test func eraConfirmationFailsClosedWhenALinkHasNoOwner() throws {
    let catalog = try verifiedCatalog()
    var state = try setup(playerCount: 2, catalog: catalog)
    state.roundNumber = state.canalRoundCapacity
    state.placedLinks.append(.init(
        routeID: "birmingham-coventry",
        ownerID: .init(rawValue: "ghost"), era: .canal
    ))

    _ = try GameCore.GameRulesEngine.resolveRoundEnd(state: &state, catalog: catalog)
    guard case .eraIntermission = state.turnPhase else {
        Issue.record("canal capacity round should pause at era intermission")
        return
    }
    for player in state.playerOrder {
        let target = try GameCore.SimpleActionRules.validateEraConfirmation(
            actorID: player, state: state, catalog: catalog
        )
        // 合法对局的线都有主人;孤儿线让最后一次确认整体失败,不写回候选状态。
        if player == state.playerOrder.last {
            #expect(throws: GameCore.ScoringRuleError.missingDefinition) {
                _ = try GameCore.GameRulesEngine.resolveEraConfirmation(
                    target, roomID: .init(rawValue: "orphan-link"), state: &state, catalog: catalog
                )
            }
        } else {
            _ = try GameCore.GameRulesEngine.resolveEraConfirmation(
                target, roomID: .init(rawValue: "orphan-link"), state: &state, catalog: catalog
            )
        }
    }
    #expect(state.era == .canal)
    #expect(state.placedLinks.count == 1)
}
```

- [ ] **Step 3: 跑测试，确认两个新测试失败**

Run 全量命令。预期：`railFinalRoundReturnsScoredLinksToOwnersWithoutDoubleScoring` FAIL（`placedLinks` 非空、`linksRemaining` 仍 13）；`eraConfirmationFailsClosedWhenALinkHasNoOwner` FAIL（孤儿线被静默跳过，`resolveEraConfirmation` 不抛）。若编译失败，先修测试代码。

- [ ] **Step 4: 实现 `returnScoredLinks` 并接两个调用点**

`ScoringRules.swift` 在 `scoreEra` 之后加（两遍扫描：先解析全部主人，再统一加余量、清空；缺主人在改动任何余量之前抛出）：

```swift
/// 已计分的连接片全部撤下,退回各自主人(余量+1);不加 VP、不发事件。
/// 缺主人的孤儿线抛 missingDefinition 且一条余量都不改。
static func returnScoredLinks(state: inout GameState) throws {
    var ownerIndexes: [Int] = []
    ownerIndexes.reserveCapacity(state.placedLinks.count)
    for link in state.placedLinks {
        guard let index = state.players.firstIndex(where: { $0.id == link.ownerID }) else {
            throw ScoringRuleError.missingDefinition
        }
        ownerIndexes.append(index)
    }
    for index in ownerIndexes {
        state.players[index].linksRemaining += 1
    }
    state.placedLinks.removeAll()
}
```

`prepareRailEra`（`ScoringRules.swift:95-100`）的内联循环替换为（位置仍在移除一级产业之后、补贸易商啤酒之前）：

```swift
try returnScoredLinks(state: &state)
```

`TurnRules.swift` `completeRound` 的铁路分支（现 `ScoringRules.swift` 无关，在 `TurnRules.swift:194-196`）：

```swift
} else {
    try ScoringRules.returnScoredLinks(state: &state)
    events.append(ScoringRules.resolveWinner(state: &state))
}
```

- [ ] **Step 5: 跑测试，全部通过**

Run 全量命令。预期：两个新测试 PASS；`canalPreparationPreservesMarketsRefillsMerchantsRedealsAndPreservesLongLivedState`、`eraTransitionBatchReplaysAtomicallyAndRejectsEveryTamperedPosition`（事件数 3）、三份金哈希（全 pass 对局不铺线，撤线是空操作）全部 PASS。

- [ ] **Step 6: 提交**

```bash
git add ui-prototype/IndustrialCityBirmingham/GameCore/Rules/ScoringRules.swift \
        ui-prototype/IndustrialCityBirmingham/GameCore/Rules/TurnRules.swift \
        ui-prototype/IndustrialCityBirminghamTests/TurnScoringRulesTests.swift
git commit -m "引擎:抽出 returnScoredLinks,铁路终局计分后撤线退回且孤儿线失败收口"
```

### Task 2: 修正 `scoreEra` 与两处测试的错误注释；补两份 RULES.md 的 D 条款

**Files:**
- Modify: `ui-prototype/IndustrialCityBirmingham/GameCore/Rules/ScoringRules.swift:36-37,69`（错误注释）
- Modify: `ui-prototype/IndustrialCityBirminghamTests/TurnScoringRulesTests.swift:233-237,273`（错误注释；断言与测试名不动）
- Modify: `RULES.md:327-359`（10.1/10.3/10.4）
- Modify: `ui-prototype/RULES.md:328-360`

**Interfaces:** 无代码接口；文档措辞被 `RulesCoverageTests` 的 §12/§13 切片约束（不得改动节标题行）。

- [ ] **Step 1: 改 `scoreEra` 注释**

`ScoringRules.swift:36-37` 的

```swift
// 官方规则:每个时代结束时,自己的"所有"连线都计分
// (运河连线保留到铁路时代,铁路末再次计分)。
```

改为：

```swift
// 官方规则:每个时代结束时,自己的"所有"连线各计一次分。
// 本函数只加 VP、不撤线:运河线留在地图上,待全员确认后的
// prepareRailEra 退回主人;铁路线由终局调用方退回。两种线都不计第二次分。
```

`ScoringRules.swift:69` 的 `// 官方规则:连线永久保留,时代结算不移除任何线路。` 改为 `// 撤线不在本函数:见上方注释;removedRouteIDs 恒为空。`。函数体一行不改。

- [ ] **Step 2: 改两处测试注释**

`TurnScoringRulesTests.swift`：
- `eraScoringCountsEveryHyperedgeAdjacentFlippedIndustryAndKeepsAllLinks` 内 233-234 行注释保留（描述逐条计分，正确）；236 行 `// 官方规则:连线永久保留,时代结算不移除。` 改为 `// 计分函数本身不撤线:运河线待 eraIntermission 确认后的 prepareRailEra 退回。`
- `eraScoringCountsAdjacentMerchantTileLinkIcons` 内 273 行 `// 连线永久保留:时代结算不再移除线路。` 改为 `// 计分函数不撤线;removedRouteIDs 恒空,撤线在确认后的 prepareRailEra。`

断言、测试名一字不动。

- [ ] **Step 3: 补两份 RULES.md 的 10.1/10.3**

根 `RULES.md`（行号为当前值；`ui-prototype/RULES.md` 同内容在 +1 行处）：

- 根 332 行 `- 每个连接片计分后立即从地图移除。` 替换为（ui 副本 333 行已有前半句，追加第二行即可，两份最终一致）：

```markdown
- 每个连接片只计一次分。运河时代结束后连接片留在地图上，待全员确认时代结算（见 6.1）后统一撤下，双面连线片退回其主人，铁路时代可再次使用。
- 铁路时代结束（游戏终局）计分后，连接片同样撤下退回主人；撤下不再产生任何得分。
```

- 两份 10.3（运河时代结束维护步骤，根 340-350 / ui 341-351）：在"移除地图上所有一级产业"步骤之后、"补贸易商啤酒"步骤之前插入一步（编号按现有列表顺延）：

```markdown
- 撤下地图上所有连接片并退回各自主人（双面连线片铁路时代可再用）；已在 10.1 计过分，退回不再得分。未翻面产业不提供连接图标。
```

根 342 行的一级产业步骤同步补齐 ui 副本 343 行已有的"板块退回游戏盒（移出游戏，铁路时代不可重建）"语义，使两份一致。

- [ ] **Step 4: 跑测试确认文档没破坏覆盖测试**

Run 全量命令。预期全 PASS（`RulesCoverageTests` 读 `ui-prototype/RULES.md` 切 §12/§13 数风险条目，本步只改 §9/§10 内文，不触节标题）。

- [ ] **Step 5: 提交**

```bash
git add RULES.md ui-prototype/RULES.md \
        ui-prototype/IndustrialCityBirmingham/GameCore/Rules/ScoringRules.swift \
        ui-prototype/IndustrialCityBirminghamTests/TurnScoringRulesTests.swift
git commit -m "规则文档:连接片只计一次分,确认后撤下退回主人;修正 scoreEra 误导注释"
```

### Task 3: 9.1 伯明翰例外写成权威规则 + Build 测试锁

**Files:**
- Modify: `RULES.md:310-315`（9.1）
- Modify: `ui-prototype/RULES.md:310-316`（9.1；已有简短例外句，扩成完整权威表述）
- Test: `ui-prototype/IndustrialCityBirminghamTests/BuildAndNetworkRulesTests.swift`（`wildBuildReturnsToPoolAndCanalOwnOneAndWrongEraFailClosed` 之后，1207 行附近加四个测试）

**Interfaces:**
- Consumes: `setupState(catalog:)`（`BuildAndNetworkRulesTests.swift:2118-2155`）、`GameCore.BuildRules.validate(_:actorID:state:catalog:)`、`GameCore.BuildRuleError`

- [ ] **Step 1: 写四个测试（行为已正确，预期直接 PASS——这是回归锁；若有 FAIL 先停下查根因，不许改产品代码迁就测试）**

数据事实（已核实 `map.json`/`industries.json`）：`nuneaton` 槽 0 = `[manufacturer, brewery]`、槽 1 = `[cotton-mill, coal-mine]`；运河零煤零铁板块只有 coal-mine L1（cost 5）与 cotton-mill L1；coal-mine L2 rail 合法、cost 7、零煤零铁；manufacturer L2 cost 10、1 铁；开局现金 £17。

```swift
@Test func canalNonBirminghamLocationAllowsOnlyOneOwnIndustry() throws {
    let catalog = try verifiedCatalog()
    var state = try setupState(catalog: catalog)
    let actor = try #require(state.activePlayerID)
    let index = try #require(state.players.firstIndex { $0.id == actor })
    state.players[index].hand = [.init(id: "wild-build", definitionID: "wild-industry")]
    // 先占槽 0(注入一块已在板上的自己的产业),再对槽 1 校验零消耗的煤矿 1 级。
    state.boardIndustryPlacements.append(.init(
        locationID: "nuneaton", slotIndex: 0, ownerID: actor,
        tile: .init(id: "own-first", industryDefinitionID: "manufacturer", level: 1)
    ))
    #expect(throws: GameCore.BuildRuleError.canalLocationLimit) {
        try GameCore.BuildRules.validate(
            .init(cardID: "wild-build", locationID: "nuneaton",
                  industryDefinitionID: "coal-mine", slotIndex: 1, resourceSources: []),
            actorID: actor, state: state, catalog: catalog
        )
    }
}

@Test func canalLocationLimitIgnoresOpponentPlacements() throws {
    let catalog = try verifiedCatalog()
    var state = try setupState(catalog: catalog)
    let actor = try #require(state.activePlayerID)
    let index = try #require(state.players.firstIndex { $0.id == actor })
    state.players[index].hand = [.init(id: "wild-build", definitionID: "wild-industry")]
    let opponent = state.players.first { $0.id != actor }!.id
    state.boardIndustryPlacements.append(.init(
        locationID: "nuneaton", slotIndex: 0, ownerID: opponent,
        tile: .init(id: "opp-first", industryDefinitionID: "manufacturer", level: 1)
    ))
    // 对手的板块不占自己的名额:自己的第一格(槽 1)仍然合法。
    let target = try GameCore.BuildRules.validate(
        .init(cardID: "wild-build", locationID: "nuneaton",
              industryDefinitionID: "coal-mine", slotIndex: 1, resourceSources: []),
        actorID: actor, state: state, catalog: catalog
    )
    #expect(target.intent.locationID == "nuneaton")
}

@Test func canalOverbuildSameSlotDoesNotCountTowardLocationLimit() throws {
    let catalog = try verifiedCatalog()
    var state = try setupState(catalog: catalog)
    let actor = try #require(state.activePlayerID)
    let index = try #require(state.players.firstIndex { $0.id == actor })
    state.players[index].hand = [.init(id: "wild-build", definitionID: "wild-industry")]
    // 伯明翰已有自己的两块(槽 0、槽 1);覆盖槽 1 不算"第三个产业",
    // 拒绝理由必须是槽位规则而非 canalLocationLimit。
    state.boardIndustryPlacements.append(.init(
        locationID: "birmingham", slotIndex: 0, ownerID: actor,
        tile: .init(id: "own-a", industryDefinitionID: "manufacturer", level: 1)
    ))
    state.boardIndustryPlacements.append(.init(
        locationID: "birmingham", slotIndex: 1, ownerID: actor,
        tile: .init(id: "own-b", industryDefinitionID: "manufacturer", level: 1)
    ))
    // 栈顶升到制造厂 2 级,构造合法的同产业覆盖意图(槽 3 仍空,应报 emptySlotAvailable)。
    let stackIndex = try #require(
        state.players[index].industryStacks.firstIndex { $0.industryDefinitionID == "manufacturer" }
    )
    state.players[index].industryStacks[stackIndex].tiles.removeFirst()
    do {
        _ = try GameCore.BuildRules.validate(
            .init(cardID: "wild-build", locationID: "birmingham",
                  industryDefinitionID: "manufacturer", slotIndex: 1, resourceSources: []),
            actorID: actor, state: state, catalog: catalog
        )
        Issue.record("expected a non-limit rejection for same-slot overbuild")
    } catch let error as GameCore.BuildRuleError {
        #expect(error == .emptySlotAvailable)
    }
}

@Test func railEraHasNoPerLocationIndustryLimit() throws {
    let catalog = try verifiedCatalog()
    var state = try setupState(catalog: catalog)
    state.era = .rail
    let actor = try #require(state.activePlayerID)
    let index = try #require(state.players.firstIndex { $0.id == actor })
    state.players[index].hand = [.init(id: "rail-wild", definitionID: "wild-industry")]
    state.players[index].cash = 25
    // (a) 非伯明翰:nuneaton 已有自己两块(运河上限是 1),铁路时代覆盖第三块仍合法。
    state.boardIndustryPlacements.append(.init(
        locationID: "nuneaton", slotIndex: 0, ownerID: actor,
        tile: .init(id: "rail-a", industryDefinitionID: "manufacturer", level: 1)
    ))
    state.boardIndustryPlacements.append(.init(
        locationID: "nuneaton", slotIndex: 1, ownerID: actor,
        tile: .init(id: "rail-b", industryDefinitionID: "coal-mine", level: 1)
    ))
    let coalStack = try #require(
        state.players[index].industryStacks.firstIndex { $0.industryDefinitionID == "coal-mine" }
    )
    state.players[index].industryStacks[coalStack].tiles.removeFirst()
    _ = try GameCore.BuildRules.validate(
        .init(cardID: "rail-wild", locationID: "nuneaton",
              industryDefinitionID: "coal-mine", slotIndex: 1, resourceSources: []),
        actorID: actor, state: state, catalog: catalog
    )
    // (b) 伯明翰:已有两块(运河上限 2),铁路第三格(槽 3)仍合法;制造厂 2 级补 1 铁。
    state.boardIndustryPlacements.append(.init(
        locationID: "birmingham", slotIndex: 0, ownerID: actor,
        tile: .init(id: "rail-c", industryDefinitionID: "manufacturer", level: 1)
    ))
    state.boardIndustryPlacements.append(.init(
        locationID: "birmingham", slotIndex: 1, ownerID: actor,
        tile: .init(id: "rail-d", industryDefinitionID: "manufacturer", level: 1)
    ))
    _ = try GameCore.BuildRules.validate(
        .init(cardID: "rail-wild", locationID: "birmingham",
              industryDefinitionID: "manufacturer", slotIndex: 3,
              resourceSources: [.marketSlot(resource: .iron, index: 2)]),
        actorID: actor, state: state, catalog: catalog
    )
}
```

夹具合法性依据（已核实）：(a) 槽 1 已被自己的煤矿 L1 占据 → `existing != nil`、compatibleEmptySlots 为空 → 走覆盖分支（同产业、2 级 > 1 级合法）；coal-mine L2 零煤零铁、cost £7 ≤ £17；自己已有产业使 nuneaton 在自己网络内（`TopologyRules.isInPlayerNetwork` 对"自己有产业的地点"返回 true，`TopologyRules.swift:216-221`）。(b) 槽 3 是 `[manufacturer]` 单产业槽且为空 → slotPriority 通过；制造厂 L2 cost £10 + 铁市场格 £2 ≤ £25。

- [ ] **Step 2: 跑测试，预期四个全 PASS**

Run 全量命令。任何 FAIL 都说明规格"代码已正确"的判断有误——停下，用失败输出定位，向规格作者报告，不许改 `BuildRules.validate`。

- [ ] **Step 3: 补两份 9.1 文档**

根 `RULES.md` 9.1（312-314 的 bullet 之后）与 `ui-prototype/RULES.md` 9.1（把 313 行的单句例外替换为下述完整表述，使两份一致）：

```markdown
- 例外：运河时代同一玩家在伯明翰（Birmingham）最多可拥有 2 个产业，其他地点仍为 1 个；不同玩家互不影响。上限只统计行动玩家自己的板块，正在覆盖建造的那一格（见 9.2）不计入。
- 铁路时代没有每人每地点的产业数上限，只受空位、时代图标与覆盖建造规则限制。
```

- [ ] **Step 4: 跑全量测试 + 提交**

```bash
git add RULES.md ui-prototype/RULES.md \
        ui-prototype/IndustrialCityBirminghamTests/BuildAndNetworkRulesTests.swift
git commit -m "测试:锁运河每地点上限(伯明翰例外/覆盖不计/对手不占/铁路无上限);补两份9.1"
```

### Task 4: 7.6 空万能堆侦察 + 5.1 产业牌按人数移除（文档为主，一条断言收紧）

**Files:**
- Modify: `RULES.md:258-263`（7.6）、`RULES.md:92-114`（5.1）
- Modify: `ui-prototype/RULES.md:258-263`（7.6）、`ui-prototype/RULES.md:92-114`（5.1）
- Modify: `ui-prototype/IndustrialCityBirminghamTests/DevelopSellSimpleActionTests.swift:666-683`（收紧两堆全空分支断言，删错误注释）

- [ ] **Step 1: 收紧 `scoutWithExhaustedWildPoolsStillExecutesAndGainsNothingFromEmptyPiles` 的两堆全空分支**

把 679 行的错误注释 `// 两堆全空:一张万能牌也拿不到,手牌只有补牌。` 删除，并把 680-682 的 `allSatisfy` 断言替换为（该夹具手牌恰好只有这 3 张、运河第 1 回合只有 1 动、`finishAction` 停在待确认——所以手牌为空只是夹具事实，不是规则）：

```swift
        // 两堆全空:侦察仍成功,3 张普通牌照弃,手牌不增加任何万能牌。
        // (hand.isEmpty 只因本夹具手牌恰为这 3 张且停在补牌前的待确认相位。)
        #expect(afterBoth.hand.isEmpty)
        #expect(engineBoth.publicDiscard.count == 3)
        #expect(engineBoth.wildLocationPool.isEmpty)
        #expect(engineBoth.wildIndustryPool.isEmpty)
```

测试名不动。

- [ ] **Step 2: 跑测试，预期 PASS（行为断言本就成立，只是没写全）**

Run 全量命令。

- [ ] **Step 3: 补两份 7.6**

两份相同（258-263），在"手持任意万能牌不能侦察"条目前后补：

```markdown
- 某一叠或两叠万能牌堆为空时侦察仍然成功：3 张普通牌照常弃掉，只拿到仍有牌的那一叠的顶牌；两叠都空则一张万能牌也拿不到（空堆本身不是拒绝理由）。
```

- [ ] **Step 4: 补两份 5.1**

两份 95 行"移除人数标记高于当前人数的卡牌和贸易商板块"之后、107-113 行地点牌清单标题之前，插入一段（放在"地点牌随人数变化"小标题之前作为总则）：

```markdown
产业牌与地点牌同一条规则：`playerCounts` 不含当前人数的产业牌实例同样移出本局摸牌堆（2 人局剔除 10 张、3 人局剔除 4 张产业牌实例），最终摸牌堆张数固定为 2 人 40、3 人 54、4 人 64。万能牌各 4 张始终留在两个公共牌堆，不进摸牌堆。被移除的地点牌不删除地图地点（见下）。
```

不新增牌数测试（`GameSetupTests.verifySetup` 的 `playerCounts` 断言已覆盖产业牌，`GameSetupTests.swift:801-817`）；不把颜色名映射进产业牌。

- [ ] **Step 5: 跑全量测试 + 提交**

```bash
git add RULES.md ui-prototype/RULES.md \
        ui-prototype/IndustrialCityBirminghamTests/DevelopSellSimpleActionTests.swift
git commit -m "规则文档:空万能堆侦察仍成功+产业牌按人数移除;收紧两堆全空侦察断言"
```

---

# PR 2：短局规则引擎与测试

依赖：PR 1（`returnScoredLinks` 与文档里的计分顺序）。`makeGame` 新参数默认 `.standard`，旧调用点不改仍是标准局；标准局信封保持协议 2、schema 4；金哈希不动。

### Task 5: `MatchMode` 枚举 + `GameState.matchMode` 手写编解码

**Files:**
- Modify: `ui-prototype/IndustrialCityBirmingham/GameCore/Model/GameState.swift:5-8`（枚举）、`215-247`（字段）、`380-431`（CodingKeys/解码/新增 encode）
- Test: Create `ui-prototype/IndustrialCityBirminghamTests/ShortCanalRulesTests.swift`（新文件，自动入 target）

**Interfaces:**
- Produces: `GameCore.MatchMode`（`standard` / `shortCanal`，`String` rawValue，Codable）；`GameState.matchMode: MatchMode = .standard`；新测试文件里的 `verifiedCatalog()` / `shortCanalState()` 辅助（后续任务复用）

- [ ] **Step 1: 建新测试文件并写字节往返失败测试**

```swift
import Foundation
import Testing

@testable import IndustrialCityBirmingham

/// 运河新手短局(RULES.md §11)引擎规则测试。
struct ShortCanalRulesTests {

    @Test func standardStateOmitsMatchModeKeyAndRoundTripsCanonicalBytes() throws {
        let catalog = try verifiedCatalog()
        var rules = GameCore.SetupRules(seed: 5)
        let state = try rules.makeGame(
            catalog: catalog,
            playerIDs: (1...2).map { .init(rawValue: "p\($0)") }
        ).state

        let original = try state.canonicalBytes()
        let json = try #require(String(data: original, encoding: .utf8))
        // 标准局 canonical JSON 不得出现 matchMode 键(缺键解码为 .standard)。
        #expect(json.contains("\"matchMode\"") == false)

        let decoded = try JSONDecoder().decode(GameCore.GameState.self, from: original)
        #expect(decoded.matchMode == .standard)
        #expect(decoded == state)
        #expect(try decoded.canonicalBytes() == original)
    }

    @Test func shortCanalStateEncodesMatchModeKeyAndDecodesBack() throws {
        let catalog = try verifiedCatalog()
        var rules = GameCore.SetupRules(seed: 5)
        var state = try rules.makeGame(
            catalog: catalog,
            playerIDs: (1...2).map { .init(rawValue: "p\($0)") }
        ).state
        state.matchMode = .shortCanal

        let original = try state.canonicalBytes()
        let json = try #require(String(data: original, encoding: .utf8))
        #expect(json.contains("\"matchMode\":\"shortCanal\""))

        let decoded = try JSONDecoder().decode(GameCore.GameState.self, from: original)
        #expect(decoded.matchMode == .shortCanal)
        #expect(decoded == state)
        #expect(try decoded.canonicalBytes() == original)
    }

    // MARK: - 辅助(与 TurnScoringRulesTests.verifiedCatalog 同款)

    private func verifiedCatalog() throws -> GameCore.VerifiedGameDataCatalog {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "IndustrialCityBirmingham/GameData/v2018.11")
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
            rulesetVersion: catalog.rulesetVersion, verificationStatus: .verified,
            files: try files.keys.sorted().map { path in
                .init(path: path, sha256: GameCore.GameDataLoader.sha256(try #require(files[path])))
            },
            sources: [.init(
                id: "short-canal-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-10-15",
                checker: "independent-test", checkedOn: "2026-10-15"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }
}
```

- [ ] **Step 2: 跑测试确认编译失败（`matchMode` 不存在）**

Run 全量命令。预期：编译错误 `value of type 'GameCore.GameState' has no member 'matchMode'`。

- [ ] **Step 3: 实现 `MatchMode` 与编解码**

`GameState.swift`，`Era` 之后（第 8 行后）：

```swift
nonisolated enum MatchMode: String, Codable, Equatable, Sendable {
    case standard
    case shortCanal
}
```

`GameState` 存储属性（`finalStandings` 之后，247 行附近）：

```swift
var matchMode: MatchMode = .standard
```

`extension GameCore.GameState` 的 `CodingKeys` 枚举末尾加 `case matchMode`；`init(from:)` 末尾加：

```swift
matchMode = try values.decodeIfPresent(GameCore.MatchMode.self, forKey: .matchMode) ?? .standard
```

同一 extension 加手写 `encode(to:)`。**注意全局约束里的规格勘误**：既有可选字段用 `encodeIfPresent`（合成实现的实际行为，nil 省略键），非可选字段用 `encode`；`matchMode` 仅非 standard 时写出：

```swift
nonisolated func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(rulesetVersion, forKey: .rulesetVersion)
    try values.encode(seed, forKey: .seed)
    try values.encode(playerCount, forKey: .playerCount)
    try values.encode(era, forKey: .era)
    try values.encode(roundNumber, forKey: .roundNumber)
    try values.encode(actionsRemaining, forKey: .actionsRemaining)
    try values.encode(turnsCompletedInRound, forKey: .turnsCompletedInRound)
    try values.encode(actionNumber, forKey: .actionNumber)
    try values.encode(canalRoundCapacity, forKey: .canalRoundCapacity)
    try values.encode(railRoundCapacity, forKey: .railRoundCapacity)
    try values.encode(players, forKey: .players)
    try values.encode(playerOrder, forKey: .playerOrder)
    try values.encodeIfPresent(activePlayerID, forKey: .activePlayerID)
    try values.encode(standardDrawDeck, forKey: .standardDrawDeck)
    try values.encode(wildLocationPool, forKey: .wildLocationPool)
    try values.encode(wildIndustryPool, forKey: .wildIndustryPool)
    try values.encode(publicDiscard, forKey: .publicDiscard)
    try values.encode(boardIndustryPlacements, forKey: .boardIndustryPlacements)
    try values.encode(placedLinks, forKey: .placedLinks)
    try values.encode(coalMarket, forKey: .coalMarket)
    try values.encode(ironMarket, forKey: .ironMarket)
    try values.encode(publicSupply, forKey: .publicSupply)
    try values.encode(merchants, forKey: .merchants)
    try values.encode(authoritativeVersion, forKey: .authoritativeVersion)
    try values.encode(turnPhase, forKey: .turnPhase)
    try values.encodeIfPresent(roundIncomeCursor, forKey: .roundIncomeCursor)
    try values.encodeIfPresent(authorityCompleteness, forKey: .authorityCompleteness)
    try values.encodeIfPresent(appliedResourceActionIDs, forKey: .appliedResourceActionIDs)
    try values.encodeIfPresent(finalStandings, forKey: .finalStandings)
    if matchMode != .standard {
        try values.encode(matchMode, forKey: .matchMode)
    }
}
```

- [ ] **Step 4: 跑测试，全部通过（含三份金哈希）**

Run 全量命令。预期：两个新测试 PASS；`GameRulesEngineTests.seededCompleteGamesProduceReplayableDeterministicProofs` 三人全 PASS（金哈希证明标准局字节未变）。**金哈希若 FAIL，唯一可能是 encode 写法偏离合成行为（如把可选写成 null 或漏键）——修 encode，禁止改 expectedHashes。**

- [ ] **Step 5: 提交**

```bash
git add ui-prototype/IndustrialCityBirmingham/GameCore/Model/GameState.swift \
        ui-prototype/IndustrialCityBirminghamTests/ShortCanalRulesTests.swift
git commit -m "引擎:MatchMode 枚举与 GameState 条件编码,标准局 canonical 字节不变"
```

### Task 6: 验证器短局条款

**Files:**
- Modify: `ui-prototype/IndustrialCityBirmingham/GameCore/Rules/GameStateAuthorityValidator.swift`（`isValid` 内，era 检查附近 47-48 行后）
- Test: `ui-prototype/IndustrialCityBirminghamTests/ShortCanalRulesTests.swift`

**Interfaces:**
- Consumes: Task 5 的 `MatchMode` 与 `verifiedCatalog()`

- [ ] **Step 1: 写失败测试**

`ShortCanalRulesTests` 加：

```swift
@Test func shortCanalStateMustStayInCanalEraWithoutIntermission() throws {
    let catalog = try verifiedCatalog()
    func shortState() throws -> GameCore.GameState {
        var rules = GameCore.SetupRules(seed: 9)
        var state = try rules.makeGame(
            catalog: catalog, playerIDs: (1...2).map { .init(rawValue: "p\($0)") }
        ).state
        state.matchMode = .shortCanal
        return state
    }
    // 干净的短局开局状态合法。
    #expect(GameCore.GameStateAuthorityValidator.isValid(try shortState(), catalog: catalog))
    // 短局不得进入铁路时代。
    var railed = try shortState()
    railed.era = .rail
    #expect(GameCore.GameStateAuthorityValidator.isValid(railed, catalog: catalog) == false)
    // 短局不得进入时代间暂停。
    var paused = try shortState()
    paused.turnPhase = .eraIntermission(.init(
        settledEra: .canal, awards: [], confirmedPlayerIDs: []
    ))
    #expect(GameCore.GameStateAuthorityValidator.isValid(paused, catalog: catalog) == false)
    // 标准局不受新条款影响(多解出来的 .standard 与今天等价)。
    var standard = try shortState()
    standard.matchMode = .standard
    #expect(GameCore.GameStateAuthorityValidator.isValid(standard, catalog: catalog))
}
```

- [ ] **Step 2: 跑测试，确认两条 FAIL（条款未实现时 railed/paused 意外通过）**

- [ ] **Step 3: 实现条款**

`GameStateAuthorityValidator.isValid` 在 era/回合检查（47-48 行）之后加：

```swift
if state.matchMode == .shortCanal {
    // 短局只打运河时代:不进铁路,也不进 eraIntermission(终局直接 .ended)。
    guard state.era == .canal else { return false }
    if case .eraIntermission = state.turnPhase { return false }
}
```

- [ ] **Step 4: 跑测试全 PASS + 提交**

```bash
git add ui-prototype/IndustrialCityBirmingham/GameCore/Rules/GameStateAuthorityValidator.swift \
        ui-prototype/IndustrialCityBirminghamTests/ShortCanalRulesTests.swift
git commit -m "引擎:验证器拒绝短局进入铁路时代或时代间暂停"
```

### Task 7: `makeGame(mode:)` 与 `matchModeSelected` 设置事件

**Files:**
- Modify: `ui-prototype/IndustrialCityBirmingham/GameCore/Rules/SetupRules.swift:46-53`（签名）、`114-135`（事件插入）、`214-330`（replay）
- Modify: `ui-prototype/IndustrialCityBirmingham/GameCore/Model/GameState.swift:335-368`（`SetupEvent.Payload` 加 case）
- Test: `ui-prototype/IndustrialCityBirminghamTests/ShortCanalRulesTests.swift`

**Interfaces:**
- Produces: `makeGame(catalog:playerIDs:colors:mode:) throws -> SetupResult`（`mode: MatchMode = .standard`，加在参数表最后）；`SetupEvent.Payload.matchModeSelected(MatchMode)`（追加在 `setupCompleted` 之后）；Task 5 的 `verifiedCatalog()`
- 注意：`.gameCreated` 的关联值一字不动；重放里该事件只允许出现在 `gameCreated` 之后、`turnStateInitialized` 之前，且值只能是 `.shortCanal`；显式 `.standard` 抛 `SetupReplayError.unexpectedPhase`（经 `SetupError.invalidReplay(.unexpectedPhase)` 包装，与现有用法一致——按 `SetupRules.swift:262-264` 的现有模式）。

- [ ] **Step 1: 写失败测试**

```swift
@Test func shortCanalSetupInsertsMatchModeSelectedAndKeepsTheDealIdentical() throws {
    let catalog = try verifiedCatalog()
    let playerIDs = [GameCore.PlayerID(rawValue: "p1"), GameCore.PlayerID(rawValue: "p2")]

    var standardRules = GameCore.SetupRules(seed: 77)
    let standard = try standardRules.makeGame(catalog: catalog, playerIDs: playerIDs)
    var shortRules = GameCore.SetupRules(seed: 77)
    let short = try shortRules.makeGame(catalog: catalog, playerIDs: playerIDs, mode: .shortCanal)

    #expect(short.state.matchMode == .shortCanal)
    #expect(standard.state.matchMode == .standard)
    // 不带 mode 的调用与显式 .standard 的事件序列完全相同(没有新事件)。
    var explicitRules = GameCore.SetupRules(seed: 77)
    let explicit = try explicitRules.makeGame(
        catalog: catalog, playerIDs: playerIDs, mode: .standard
    )
    #expect(explicit.events == standard.events)
    // 短局只多一条事件:紧跟 gameCreated 的 matchModeSelected(.shortCanal)。
    #expect(short.events.count == standard.events.count + 1)
    guard case .matchModeSelected(let mode) = short.events[1].payload else {
        Issue.record("second setup event must be matchModeSelected")
        return
    }
    #expect(mode == .shortCanal)
    // 同种子下,开局/发牌/顺位与标准局完全一致。
    #expect(short.state.players.map { $0.hand } == standard.state.players.map { $0.hand })
    #expect(short.state.playerOrder == standard.state.playerOrder)
    #expect(short.state.standardDrawDeck == standard.state.standardDrawDeck)
    // 短局事件重放回同一状态。
    #expect(try GameCore.SetupRules.replay(short.events, catalog: catalog) == short.state)
}

@Test func setupReplayRejectsMisplacedOrExplicitStandardMatchModeEvents() throws {
    let catalog = try verifiedCatalog()
    let playerIDs = [GameCore.PlayerID(rawValue: "p1"), GameCore.PlayerID(rawValue: "p2")]
    var rules = GameCore.SetupRules(seed: 77)
    let standard = try rules.makeGame(catalog: catalog, playerIDs: playerIDs)

    // 显式 .standard 视为非法(缺事件才是 standard)。
    var explicit = standard.events
    explicit.insert(
        .init(sequence: 1, payload: .matchModeSelected(.standard)), at: 1
    )
    for (index, event) in explicit.enumerated() where index > 1 {
        explicit[index] = .init(sequence: index, payload: event.payload)
    }
    #expect(throws: GameCore.SetupError.self) {
        _ = try GameCore.SetupRules.replay(explicit, catalog: catalog)
    }
    // 位置错(出现在 turnStateInitialized 之后)同样拒绝。
    var misplaced = standard.events
    misplaced.insert(
        .init(sequence: 2, payload: .matchModeSelected(.shortCanal)), at: 3
    )
    for (index, event) in misplaced.enumerated() where index > 3 {
        misplaced[index] = .init(sequence: index, payload: event.payload)
    }
    #expect(throws: GameCore.SetupError.self) {
        _ = try GameCore.SetupRules.replay(misplaced, catalog: catalog)
    }
}
```

- [ ] **Step 2: 跑测试确认编译失败（无 `mode:` 参数、无 `.matchModeSelected`）**

- [ ] **Step 3: 实现**

`GameState.swift` `SetupEvent.Payload` 的 `setupCompleted` 之后追加：

```swift
case matchModeSelected(MatchMode)
```

`SetupRules.makeGame` 签名加尾参 `mode: MatchMode = .standard`；`gameCreated` 事件 append 之后（122 行后）：

```swift
if mode == .shortCanal {
    append(.matchModeSelected(.shortCanal), to: &events)
}
```

`replay` 的 `switch event.payload`（252 行起）：`gameCreated` case 之后加（`gameCreated` 已把 phase 置 `.turnState`，所以本事件允许的窗口恰好是 `phase == .turnState` 且 `turnStateInitialized` 还没出现）：

```swift
case let .matchModeSelected(mode):
    // 只允许紧跟 gameCreated、在 turnStateInitialized 之前,且只允许 .shortCanal
    // (显式选 standard 是编码错误;缺事件即 standard)。
    guard phase == .turnState, mode == .shortCanal, var value = state else {
        throw SetupError.invalidReplay(.unexpectedPhase)
    }
    value.matchMode = mode
    state = value
```

phase 不前进（仍停在 `.turnState`，`turnStateInitialized` 的 guard 原样通过）。

- [ ] **Step 4: 跑测试全 PASS（含既有 `GameSetupTests` 全部开局断言）+ 提交**

```bash
git add ui-prototype/IndustrialCityBirmingham/GameCore/Model/GameState.swift \
        ui-prototype/IndustrialCityBirmingham/GameCore/Rules/SetupRules.swift \
        ui-prototype/IndustrialCityBirminghamTests/ShortCanalRulesTests.swift
git commit -m "引擎:makeGame 增加 mode 参数,短局插入 matchModeSelected 设置事件"
```

### Task 8: `isGameFinalRound` 谓词 + 标准运河末回合现金锁

**Files:**
- Modify: `ui-prototype/IndustrialCityBirmingham/GameCore/Rules/TurnRules.swift:44-47`（resolveRoundEnd 终局判定）
- Test: `ui-prototype/IndustrialCityBirminghamTests/TurnScoringRulesTests.swift:1016-1022`（canal 分支加断言）

**Interfaces:**
- Produces: `TurnRules.isGameFinalRound(_ state: GameState) -> Bool`（static；PR 2 后续与 PR 3 依赖其语义）
- 语义：`.standard` → `era == .rail && roundNumber >= railRoundCapacity`；`.shortCanal` → `era == .canal && roundNumber >= canalRoundCapacity`。

- [ ] **Step 1: 在 `finalSeatActionAtomicallyCarriesReplayableEraTransitionsAndRailSkipsIncome` 的 canal 分支加断言**

`TurnScoringRulesTests.swift:1016` 的 `if era == .canal {` 块内（`intermission.awards` 断言之后）加：

```swift
            // 标准局运河末回合不是游戏最后一回合:照常发收入(15 位收入 £3,20→23),
            // 且不得出现短局事件。
            #expect(engine.gameState.turnPhase == .eraIntermission)
            #expect(Dictionary(uniqueKeysWithValues: engine.gameState.players.map { ($0.id, $0.cash) })
                == Dictionary(uniqueKeysWithValues: state.players.map { ($0.id, $0.cash - 20 + 23) }))
            #expect(event.transitions.contains { if case .shortCanalScored = $0 { true } else { false } } == false)
```

（夹具已把每人 cash 设 20、incomePosition 设 15；income 3 已核实。）同时此断言此刻必 FAIL——`.shortCanalScored` 还不存在，编译不过；先只写现金两条，模式匹配那条等 Task 9 加了事件 case 后再补。**为保持每步可编译，本步只加前两条断言，第三条挪到 Task 9 Step 5。**

- [ ] **Step 2: 写谓词失败测试（`ShortCanalRulesTests`）**

```swift
@Test func isGameFinalRoundDependsOnMatchMode() throws {
    let catalog = try verifiedCatalog()
    func state(mode: GameCore.MatchMode, era: GameCore.Era) throws -> GameCore.GameState {
        var rules = GameCore.SetupRules(seed: 11)
        var value = try rules.makeGame(
            catalog: catalog, playerIDs: (1...2).map { .init(rawValue: "p\($0)") }
        ).state
        value.matchMode = mode
        value.era = era
        return value
    }
    var standardCanalEnd = try state(mode: .standard, era: .canal)
    standardCanalEnd.roundNumber = standardCanalEnd.canalRoundCapacity
    #expect(GameCore.TurnRules.isGameFinalRound(standardCanalEnd) == false)
    var standardRailEnd = try state(mode: .standard, era: .rail)
    standardRailEnd.roundNumber = standardRailEnd.railRoundCapacity
    #expect(GameCore.TurnRules.isGameFinalRound(standardRailEnd))
    var shortCanalEnd = try state(mode: .shortCanal, era: .canal)
    shortCanalEnd.roundNumber = shortCanalEnd.canalRoundCapacity
    #expect(GameCore.TurnRules.isGameFinalRound(shortCanalEnd))
    var shortMidway = shortCanalEnd
    shortMidway.roundNumber = shortMidway.canalRoundCapacity - 1
    #expect(GameCore.TurnRules.isGameFinalRound(shortMidway) == false)
}
```

- [ ] **Step 3: 跑测试（谓词测试编译失败：无 `isGameFinalRound`）**

- [ ] **Step 4: 实现谓词并替换 `resolveRoundEnd` 的判定**

`TurnRules` 内（`actionsPerTurn` 之后）：

```swift
/// 游戏最后一回合(RULES.md §6.3 不结收入的"最后一回合"):
/// 标准局=铁路末回合;短局=运河末回合。标准局运河末回合为假。
static func isGameFinalRound(_ state: GameState) -> Bool {
    switch state.matchMode {
    case .standard:
        return state.era == .rail && state.roundNumber >= state.railRoundCapacity
    case .shortCanal:
        return state.era == .canal && state.roundNumber >= state.canalRoundCapacity
    }
}
```

`resolveRoundEnd`（`TurnRules.swift:44-47`）替换为：

```swift
            if isGameFinalRound(state) {
                return try completeRound(state: &state, catalog: catalog)
            }
            return try resolveIncomeFromCursor(state: &state, catalog: catalog)
```

- [ ] **Step 5: 跑测试全 PASS + 提交**

预期：`isGameFinalRoundDependsOnMatchMode` PASS；`finalSeatAction…` canal 分支现金 23 断言 PASS；铁路分支（跳收入）与金哈希不受影响。

```bash
git add ui-prototype/IndustrialCityBirmingham/GameCore/Rules/TurnRules.swift \
        ui-prototype/IndustrialCityBirminghamTests/TurnScoringRulesTests.swift \
        ui-prototype/IndustrialCityBirminghamTests/ShortCanalRulesTests.swift
git commit -m "引擎:isGameFinalRound 按模式判定最后一回合,短局运河末跳过收入"
```

### Task 9: `applyShortCanalBonus` + `shortCanalScored` 事件类型

**Files:**
- Modify: `ui-prototype/IndustrialCityBirmingham/GameCore/GameCore.swift:238-267`（事件类型与 case）
- Modify: `ui-prototype/IndustrialCityBirmingham/GameCore/Rules/ScoringRules.swift`（新静态函数）
- Modify: `ui-prototype/IndustrialCityBirmingham/Session/MatchActionLog.swift:132-152`（显式日志分支）
- Test: `ui-prototype/IndustrialCityBirminghamTests/ShortCanalRulesTests.swift`

**Interfaces:**
- Produces:
  - `GameTransitionEvent.ShortCanalPlayerScore`（`playerID`/`linkPoints`/`industryPoints`/`secondIndustryPoints`/`cashPoints`/`incomePoints`/`victoryPoints`，全 `let Int` 除 playerID）
  - `GameTransitionEvent.ShortCanalScoredDetails`（`let awards: [ShortCanalPlayerScore]`）
  - `case shortCanalScored(ShortCanalScoredDetails)`（追加在 `gameEnded` 之后）
  - `ScoringRules.applyShortCanalBonus(priorAwards: [GameTransitionEvent.PlayerVPAward], state: inout GameState, catalog: VerifiedGameDataCatalog) throws -> GameTransitionEvent`（Task 10 调用；`priorAwards` 是刚才 `eraScored` 的 awards，用于回显线分/第一次产业分，不重加）
- 字段语义：`secondIndustryPoints`/`cashPoints`/`incomePoints` 在本事件之前已按序加入 VP；`incomePoints` 是名义值（可为负，不夹断）；`victoryPoints` 是夹断后的最终值；`awards` 按 `state.playerOrder`。

- [ ] **Step 1: 写失败测试（数字例子全部按当前目录现算，不写死魔法数的位置无关副本）**

`ShortCanalRulesTests` 加辅助与测试：

```swift
private func shortCanalState(playerCount: Int = 2, seed: UInt64 = 21) throws -> GameCore.GameState {
    let catalog = try verifiedCatalog()
    var rules = GameCore.SetupRules(seed: seed)
    return try rules.makeGame(
        catalog: catalog,
        playerIDs: (1...playerCount).map { .init(rawValue: "p\($0)") },
        mode: .shortCanal
    ).state
}

@Test func shortCanalBonusAddsSecondIndustryThenCashThenIncomeWithFloor() throws {
    let catalog = try verifiedCatalog()
    var state = try shortCanalState()
    let owner = state.playerOrder[0]
    // 翻面煤矿 1 级(线外):只在 scoreEra 出现;翻面棉纺厂 2 级(birmingham):
    // scoreEra + 追加分各一次;未翻面制造厂 2 级:两次都是 0。
    var coal = try placement(
        ownerID: owner, industryID: "coal-mine", level: 1,
        placementID: "off-link-coal", locationID: "dudley", catalog: catalog.catalog
    )
    coal.isFlipped = true
    var cotton = try placement(
        ownerID: owner, industryID: "cotton-mill", level: 2,
        placementID: "on-link-cotton", locationID: "birmingham", catalog: catalog.catalog
    )
    cotton.isFlipped = true
    let darkManufacturer = try placement(
        ownerID: owner, industryID: "manufacturer", level: 2,
        placementID: "unflipped", locationID: "nuneaton", catalog: catalog.catalog
    )
    state.boardIndustryPlacements += [coal, cotton, darkManufacturer]
    let route = try #require(catalog.catalog.board.routes.first { $0.id == "birmingham-coventry" })
    state.placedLinks.append(.init(routeID: route.id, ownerID: owner, era: .canal))
    mutate(owner, in: &state) { $0.cash = 3; $0.incomePosition = 10; $0.victoryPoints = 0 }
    let coalLevel = try #require(catalog.catalog.industries.first { $0.id == "coal-mine" }?
        .levels.first { $0.level == 1 })
    let cottonLevel = try #require(catalog.catalog.industries.first { $0.id == "cotton-mill" }?
        .levels.first { $0.level == 2 })

    let eraEvent = try GameCore.GameRulesEngine.scoreEra(.canal, state: &state, catalog: catalog)
    guard case .eraScored(let eraDetails) = eraEvent else {
        Issue.record("expected eraScored")
        return
    }
    // 第 3 步:线分 2 + 产业分 1+5。
    let afterEra = try #require(state.players.first { $0.id == owner }).victoryPoints
    #expect(afterEra == cottonLevel.linkPoints + coalLevel.victoryPoints + cottonLevel.victoryPoints)

    let bonusEvent = try GameCore.ScoringRules.applyShortCanalBonus(
        priorAwards: eraDetails.awards, state: &state, catalog: catalog
    )
    guard case .shortCanalScored(let details) = bonusEvent else {
        Issue.record("expected shortCanalScored")
        return
    }
    let award = try #require(details.awards.first { $0.playerID == owner })
    // 第 4 步:二次产业分 5(只有翻面二级棉纺厂),现金分 0(£3),收入分 0(pos 10)。
    // 总 VP = 1 + 5 + 2 + 5 = 13,不是 15 也不是 18。
    #expect(award.secondIndustryPoints == cottonLevel.victoryPoints)
    #expect(award.cashPoints == 0)
    #expect(award.incomePoints == 0)
    #expect(award.linkPoints == cottonLevel.linkPoints)
    #expect(award.industryPoints == coalLevel.victoryPoints + cottonLevel.victoryPoints)
    #expect(award.victoryPoints ==
        cottonLevel.linkPoints + coalLevel.victoryPoints + cottonLevel.victoryPoints * 2)
    #expect(try #require(state.players.first { $0.id == owner }).victoryPoints == award.victoryPoints)
    // 追加分不碰现金与收入轨。
    #expect(try #require(state.players.first { $0.id == owner }).cash == 3)
    #expect(try #require(state.players.first { $0.id == owner }).incomePosition == 10)
}

@Test func shortCanalCashPointsUseIntegerDivisionWithCap() throws {
    let catalog = try verifiedCatalog()
    for (cash, expected) in [(0, 0), (3, 0), (4, 1), (59, 14), (60, 15), (61, 15)] {
        var state = try shortCanalState()
        let owner = state.playerOrder[0]
        mutate(owner, in: &state) { $0.cash = cash; $0.incomePosition = 10 }
        let event = try GameCore.ScoringRules.applyShortCanalBonus(
            priorAwards: [], state: &state, catalog: catalog
        )
        guard case .shortCanalScored(let details) = event,
              let award = details.awards.first(where: { $0.playerID == owner }) else {
            Issue.record("expected shortCanalScored for cash \(cash)")
            return
        }
        #expect(award.cashPoints == expected)
        #expect(award.victoryPoints == expected)
    }
}

@Test func shortCanalBonusFloorsVictoryPointsAfterCashThenIncomeInOrder() throws {
    let catalog = try verifiedCatalog()
    var state = try shortCanalState()
    let owner = state.playerOrder[0]
    // 顺序锁:VP 0、现金 £4(→+1)、收入等级 -3(pos 7)。先加现金再扣收入,最终 0;
    // 若先扣再加现金会得到 1。名义扣分 -3 仍写进事件。
    mutate(owner, in: &state) { $0.victoryPoints = 0; $0.cash = 4; $0.incomePosition = 7 }
    let event = try GameCore.ScoringRules.applyShortCanalBonus(
        priorAwards: [], state: &state, catalog: catalog
    )
    guard case .shortCanalScored(let details) = event,
          let award = details.awards.first(where: { $0.playerID == owner }) else {
        Issue.record("expected shortCanalScored")
        return
    }
    #expect(award.cashPoints == 1)
    #expect(award.incomePoints == -3)
    #expect(award.victoryPoints == 0)
    #expect(try #require(state.players.first { $0.id == owner }).victoryPoints == 0)
    // 收入 6(pos 21)在 VP 10 上加 6;收入 -3 在 VP 10 上扣成 7。
    var richState = try shortCanalState()
    mutate(richState.playerOrder[0], in: &richState) { $0.victoryPoints = 10; $0.cash = 0; $0.incomePosition = 21 }
    guard case .shortCanalScored(let rich) = try GameCore.ScoringRules.applyShortCanalBonus(
        priorAwards: [], state: &richState, catalog: catalog
    ), let richAward = rich.first(where: { $0.playerID == richState.playerOrder[0] }) else {
        Issue.record("expected shortCanalScored for positive income")
        return
    }
    #expect(richAward.victoryPoints == 16)
}

@Test func shortCanalWinnerTieBreaksOnIncomePositionNotIncomeLevel() throws {
    let catalog = try verifiedCatalog()
    var state = try shortCanalState()
    let first = state.playerOrder[0]
    let second = state.playerOrder[1]
    // 两人 VP、现金全同;收入轨 11 与 12 的收入等级都是 £1(收入分相同,
    // 不会自己打破平手),排名必须按 incomePosition(12 在前),不得并列。
    mutate(first, in: &state) { $0.victoryPoints = 7; $0.cash = 4; $0.incomePosition = 11 }
    mutate(second, in: &state) { $0.victoryPoints = 7; $0.cash = 4; $0.incomePosition = 12 }

    let event = try GameCore.ScoringRules.applyShortCanalBonus(
        priorAwards: [], state: &state, catalog: catalog
    )
    _ = try GameCore.GameRulesEngine.resolveWinner(state: &state)

    guard case .shortCanalScored(let details) = event else {
        Issue.record("expected shortCanalScored")
        return
    }
    // 名义收入分:两人都是 1(等级),最终 VP 都是 8。
    #expect(details.awards.allSatisfy { $0.incomePoints == 1 && $0.victoryPoints == 8 })
    #expect(state.finalStandings == [[second], [first]])
}

    private func mutate(
    _ playerID: GameCore.PlayerID,
    in state: inout GameCore.GameState,
    _ mutation: (inout GameCore.SetupPlayer) -> Void
) {
    guard let index = state.players.firstIndex(where: { $0.id == playerID }) else { return }
    mutation(&state.players[index])
}

private func placement(
    ownerID: GameCore.PlayerID, industryID: String, level: Int,
    placementID: String, locationID: String,
    catalog: GameCore.GameDataCatalog
) throws -> GameCore.BoardIndustryPlacement {
    let location = try #require(catalog.board.locations.first { $0.id == locationID })
    let slotIndex = try #require(location.industrySlots.firstIndex { $0.contains(industryID) })
    return .init(
        placementID: placementID, locationID: locationID, slotIndex: slotIndex,
        ownerID: ownerID,
        tile: .init(id: "tile-\(placementID)", industryDefinitionID: industryID, level: level)
    )
}
```

数字依据（已核实）：coal-mine L1 vp 1 / link 2、cotton-mill L2 vp 5 / link 2；`dudley` 有 coal-mine 槽且不邻接 `birmingham-coventry`；收入轨 pos 7 → -3、pos 10 → 0、pos 21 → 6。

- [ ] **Step 2: 跑测试确认编译失败（`applyShortCanalBonus`/`.shortCanalScored` 不存在）**

- [ ] **Step 3: 实现事件类型与函数**

`GameCore.swift` `GameTransitionEvent` 内、`GameEndedDetails` 之后加两个 struct，`gameEnded` case 之后加 case：

```swift
struct ShortCanalPlayerScore: Codable, Equatable, Sendable {
    let playerID: PlayerID
    let linkPoints: Int
    let industryPoints: Int
    let secondIndustryPoints: Int
    let cashPoints: Int
    let incomePoints: Int
    let victoryPoints: Int
}

struct ShortCanalScoredDetails: Codable, Equatable, Sendable {
    let awards: [ShortCanalPlayerScore]
}
```

```swift
case shortCanalScored(ShortCanalScoredDetails)
```

`ScoringRules.swift` 加（复用文件内私有 `checkedAdd`；结算顺序写死：二次产业分 → 现金分 → 收入等级分 → VP 夹到 ≥ 0）：

```swift
/// 短局追加分(RULES.md §11):二次产业分 → 现金分 → 收入等级分 → VP 夹到 ≥ 0。
/// 不重做线分与第一次产业分(它们由 scoreEra 完成);priorAwards 只用于回显。
static func applyShortCanalBonus(
    priorAwards: [GameTransitionEvent.PlayerVPAward],
    state: inout GameState,
    catalog: VerifiedGameDataCatalog
) throws -> GameTransitionEvent {
    let definitions = Dictionary(uniqueKeysWithValues: catalog.catalog.industries.map { ($0.id, $0) })
    var secondIndustry = Dictionary(uniqueKeysWithValues: state.players.map { ($0.id, 0) })
    for placement in state.boardIndustryPlacements
    where placement.isFlipped && placement.tile.level >= 2 {
        guard let level = definitions[placement.tile.industryDefinitionID]?
            .levels.first(where: { $0.level == placement.tile.level })
        else { throw ScoringRuleError.missingDefinition }
        secondIndustry[placement.ownerID] = try checkedAdd(
            secondIndustry[placement.ownerID, default: 0], level.victoryPoints
        )
    }
    let incomeByPosition = Dictionary(
        uniqueKeysWithValues: catalog.catalog.incomeTrack.entries.map { ($0.position, $0.income) }
    )
    let awards = try state.playerOrder.map { playerID throws -> GameTransitionEvent.ShortCanalPlayerScore in
        guard let index = state.players.firstIndex(where: { $0.id == playerID }) else {
            throw ScoringRuleError.missingDefinition
        }
        let prior = priorAwards.first(where: { $0.playerID == playerID })
        let second = secondIndustry[playerID, default: 0]
        let cashPoints = min(15, max(0, state.players[index].cash) / 4)
        guard let income = incomeByPosition[state.players[index].incomePosition] else {
            throw ScoringRuleError.missingDefinition
        }
        state.players[index].victoryPoints = try checkedAdd(state.players[index].victoryPoints, second)
        state.players[index].victoryPoints = try checkedAdd(state.players[index].victoryPoints, cashPoints)
        state.players[index].victoryPoints = try checkedAdd(state.players[index].victoryPoints, income)
        if state.players[index].victoryPoints < 0 { state.players[index].victoryPoints = 0 }
        return .init(
            playerID: playerID,
            linkPoints: prior?.linkPoints ?? 0,
            industryPoints: prior?.industryPoints ?? 0,
            secondIndustryPoints: second,
            cashPoints: cashPoints,
            incomePoints: income,
            victoryPoints: state.players[index].victoryPoints
        )
    }
    return .shortCanalScored(.init(awards: awards))
}
```

`MatchActionLog.swift` `detailedSummary` 的转换 `switch`（132-152 行）在 `default` 之前加显式分支：

```swift
case let .shortCanalScored(details):
    for award in details.awards {
        lines.append(String(
            localizedKey: "短局追加分 \(award.playerID.rawValue):线分\(award.linkPoints) 产业分\(award.industryPoints) 二次产业分\(award.secondIndustryPoints) 现金分\(award.cashPoints) 收入分\(award.incomePoints) 终分\(award.victoryPoints)"
        ))
    }
```

（按该文件现有的行构造写法对齐——若它用的是普通 `append`/字符串插值而非 `String(localizedKey:)`，照既有样式写。）

`SessionDiagnostics` 不为 `shortCanalScored` 加描述，除非编译器因穷尽性要求（它对转换的 switch 若无 `default` 才补一行）。

- [ ] **Step 4: 跑测试全 PASS**

- [ ] **Step 5: 补 Task 8 挪下的断言**

`TurnScoringRulesTests.finalSeatAction…` canal 分支补第三条：

```swift
            #expect(event.transitions.contains { if case .shortCanalScored = $0 { true } else { false } } == false)
```

Run 全量命令确认 PASS。

- [ ] **Step 6: 提交**

```bash
git add ui-prototype/IndustrialCityBirmingham/GameCore/GameCore.swift \
        ui-prototype/IndustrialCityBirmingham/GameCore/Rules/ScoringRules.swift \
        ui-prototype/IndustrialCityBirmingham/Session/MatchActionLog.swift \
        ui-prototype/IndustrialCityBirminghamTests/ShortCanalRulesTests.swift \
        ui-prototype/IndustrialCityBirminghamTests/TurnScoringRulesTests.swift
git commit -m "引擎:applyShortCanalBonus 与 shortCanalScored 事件,追加分顺序与 VP 地板固定"
```

### Task 10: `completeRound` 短局分支 + 端到端测试

**Files:**
- Modify: `ui-prototype/IndustrialCityBirmingham/GameCore/Rules/TurnRules.swift:189-197`（completeRound）
- Test: `ui-prototype/IndustrialCityBirminghamTests/ShortCanalRulesTests.swift`

**Interfaces:**
- Consumes: Task 1 `returnScoredLinks`、Task 8 `isGameFinalRound`（短局运河末回合使 `resolveRoundEnd` 直达 `completeRound`）、Task 9 `applyShortCanalBonus`
- 结算顺序（原子，在最后一位玩家 `confirmTurnEnd` 内）：`refillHand`（既有，在 `resolveTurnEndConfirmation`）→ 重排顺位/清花费/跳收入（`isGameFinalRound`）→ `scoreEra(.canal)` → `applyShortCanalBonus` → `returnScoredLinks` → `resolveWinner`。不进 `eraIntermission`、不调 `prepareRailEra`。事件序：`roundEnded`、`eraScored`、`shortCanalScored`、`gameEnded`（4 个转换）。

- [ ] **Step 1: 写失败测试**

```swift
@Test func shortCanalEndsAfterCanalScoringWithoutRailPreparation() throws {
    let catalog = try verifiedCatalog()
    var state = try shortCanalState()
    let owner = state.playerOrder[0]
    // 一块翻面一级产业(短局不移除) + 一条线(计分后撤回)。
    var coal = try placement(
        ownerID: owner, industryID: "coal-mine", level: 1,
        placementID: "short-coal", locationID: "dudley", catalog: catalog.catalog
    )
    coal.isFlipped = true
    state.boardIndustryPlacements.append(coal)
    let route = try #require(catalog.catalog.board.routes.first { $0.id == "birmingham-coventry" })
    state.placedLinks.append(.init(routeID: route.id, ownerID: owner, era: .canal))
    mutate(owner, in: &state) { $0.linksRemaining = 13 }
    // 推到最后一回合的最后一家。
    state.roundNumber = state.canalRoundCapacity
    state.actionsRemaining = 1
    state.turnsCompletedInRound = state.playerCount - 1
    state.activePlayerID = state.playerOrder.last
    let roomID = GameCore.RoomID(rawValue: "short-end")
    let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
        ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
    })
    var engine = try state.makeHostEngine(roomID: roomID, reconnectTokens: tokens, protocolVersion: 1)
    let actor = try #require(state.activePlayerID)
    let card = try #require(state.players.first { $0.id == actor }?.hand.first)
    _ = engine.submit(.init(
        protocolVersion: 1, rulesetVersion: state.rulesetVersion, roomID: roomID,
        senderID: actor, reconnectToken: tokens[actor]!,
        baseVersion: state.authoritativeVersion, payload: .pass(.init(cardID: card.id))
    ), catalog: catalog)
    #expect(engine.gameState.turnPhase == .awaitingTurnEndConfirmation)
    let afterPass = engine.gameState
    let zonesBefore = afterPass.players.flatMap(\.hand).map(\.id)
        + afterPass.players.compactMap(\.privateBottomDiscard).map(\.id)
        + afterPass.standardDrawDeck.map(\.id)
        + afterPass.publicDiscard.map(\.id)
        + afterPass.wildLocationPool.map(\.id)
        + afterPass.wildIndustryPool.map(\.id)

    let confirm = engine.submit(.init(
        protocolVersion: 1, rulesetVersion: state.rulesetVersion, roomID: roomID,
        senderID: actor, reconnectToken: tokens[actor]!,
        baseVersion: engine.gameState.authoritativeVersion, payload: .confirmTurnEnd
    ), catalog: catalog)
    guard case .accepted(let event) = confirm else {
        Issue.record("short canal final confirm should end the game, got \(confirm)")
        return
    }

    // 事件序恰好 4 个:roundEnded、eraScored、shortCanalScored、gameEnded。
    #expect(event.transitions.count == 4)
    guard case .roundEnded = event.transitions[0],
          case .eraScored = event.transitions[1],
          case .shortCanalScored = event.transitions[2],
          case .gameEnded = event.transitions[3] else {
        Issue.record("short canal end must be roundEnded, eraScored, shortCanalScored, gameEnded")
        return
    }
    #expect(engine.gameState.era == .canal)
    #expect(engine.gameState.turnPhase == .ended)
    #expect(engine.gameState.matchMode == .shortCanal)
    #expect(engine.gameState.finalStandings?.isEmpty == false)
    // 不做铁路准备:一级产业还在、底牌还在、没有 railPrepared。
    #expect(engine.gameState.boardIndustryPlacements.contains { $0.placementID == "short-coal" })
    #expect(engine.gameState.players.allSatisfy { $0.privateBottomDiscard != nil })
    // 线已撤回,余量回补;牌区多重集不变(最后一家确认时的补牌只是搬牌)。
    #expect(engine.gameState.placedLinks.isEmpty)
    #expect(try #require(engine.gameState.players.first { $0.id == owner }).linksRemaining == 14)
    let zonesAfter = engine.gameState.players.flatMap(\.hand).map(\.id)
        + engine.gameState.players.compactMap(\.privateBottomDiscard).map(\.id)
        + engine.gameState.standardDrawDeck.map(\.id)
        + engine.gameState.publicDiscard.map(\.id)
        + engine.gameState.wildLocationPool.map(\.id)
        + engine.gameState.wildIndustryPool.map(\.id)
    #expect(zonesAfter.sorted() == zonesBefore.sorted())
    #expect(GameCore.GameStateAuthorityValidator.isValid(engine.gameState, catalog: catalog))
    // 重放一致:转换事件随 turnEndConfirmed 的重放自动复现。
    var replayed = afterPass
    try GameCore.GameRulesEngine.replay(event, expectedRoomID: roomID, to: &replayed, catalog: catalog)
    #expect(replayed == engine.gameState)
}
```

夹具依据：短局 canal 末回合 `isGameFinalRound` 为真 → `resolveRoundEnd` 跳过收入直达 `completeRound`；validator 对短局要求 `era == .canal` 且不得 `eraIntermission`（Task 6），`.ended` + `.canal` + 底牌在均通过（`era == .canal || privateBottomDiscard == nil`，`GameStateAuthorityValidator.swift:67`）。

- [ ] **Step 2: 跑测试确认 FAIL（现在短局运河末回合走 `enterEraIntermission`）**

- [ ] **Step 3: 实现 completeRound 分支**

`TurnRules.swift` `completeRound`（189-197 行）替换为：

```swift
            let scoring = try ScoringRules.scoreEra(state.era, state: &state, catalog: catalog)
            events.append(scoring)
            if state.matchMode == .shortCanal {
                // 短局终局:追加分 → 撤线 → 排名。不进 eraIntermission,不准备铁路。
                guard case .eraScored(let details) = scoring else {
                    throw GameRulesEngine.GameRulesInternalError.invariantViolation
                }
                events.append(try ScoringRules.applyShortCanalBonus(
                    priorAwards: details.awards, state: &state, catalog: catalog
                ))
                try ScoringRules.returnScoredLinks(state: &state)
                events.append(ScoringRules.resolveWinner(state: &state))
            } else if state.era == .canal {
                // 两阶段过渡:先进入"时代结算确认"暂停,全员确认后再 prepareRailEra。
                try enterEraIntermission(scoring: scoring, state: &state, catalog: catalog)
            } else {
                try ScoringRules.returnScoredLinks(state: &state)
                events.append(ScoringRules.resolveWinner(state: &state))
            }
            return events
```

- [ ] **Step 4: 跑测试全 PASS（短局 4 转换、标准局 2/3 转换、金哈希不变）**

Run 全量命令。重点确认：`eraTransitionBatchReplaysAtomicallyAndRejectsEveryTamperedPosition`（标准局事件数 canal 2 / rail 3）、`finalSeatAction…`、三份金哈希全 PASS。

- [ ] **Step 5: 提交**

```bash
git add ui-prototype/IndustrialCityBirmingham/GameCore/Rules/TurnRules.swift \
        ui-prototype/IndustrialCityBirminghamTests/ShortCanalRulesTests.swift
git commit -m "引擎:短局在运河计分+追加分+撤线后直接终局,不进铁路时代"
```

### Task 11: `MatchProjection` 手写编解码契约

**Files:**
- Modify: `ui-prototype/IndustrialCityBirmingham/GameCore/Model/MatchProjection.swift:89-109`（字段）、文件末尾（CodingKeys/init(from:)/encode(to:) 扩展）
- Test: `ui-prototype/IndustrialCityBirminghamTests/ShortCanalRulesTests.swift`

**Interfaces:**
- Produces: `MatchProjection.matchMode: MatchMode = .standard`（存储属性，PR 3 的局头读取）
- 规则：`init(from:)` 对 `matchMode` 用 `decodeIfPresent ?? .standard`；`encode(to:)` 只在 `.shortCanal` 时写键；其余字段保持合成实现写法（非可选 `encode`、可选 `encodeIfPresent`——同 Task 5 勘误）；不进 `computePublicChecksum()` 的 `PublicMaterial`（标准局 `publicChecksum` 必须不变）。

- [ ] **Step 1: 写失败测试**

```swift
@Test func matchProjectionDecodesLegacyJSONAndOmitsStandardModeKey() throws {
    // 手工构造一份"旧构建"的投影 JSON(没有 matchMode 键;可选键缺省)。
    let legacyJSON = Data("""
    {"era":"canal","roundNumber":1,"deckCount":10,"actionsRemaining":1,
     "players":[],"boardIndustryPlacements":[],"placedLinks":[],
     "coalMarket":{"resource":"coal","slots":[]},
     "ironMarket":{"resource":"iron","slots":[]},
     "publicSupply":{"coal":0,"iron":0,"beer":0,"mayUseSubstitutes":true},
     "merchants":[],"publicChecksum":"checksum","ownHand":[],
     "availableActions":[],"trivialOptions":[]}
    """.utf8)
    let decoded = try JSONDecoder().decode(GameCore.MatchProjection.self, from: legacyJSON)
    #expect(decoded.matchMode == .standard)
    let reencoded = try JSONEncoder().encode(decoded)
    #expect(String(data: reencoded, encoding: .utf8)?.contains("\"matchMode\"") == false)

    var short = decoded
    short.matchMode = .shortCanal
    let shortJSON = try JSONEncoder().encode(short)
    let text = try #require(String(data: shortJSON, encoding: .utf8))
    #expect(text.contains("\"matchMode\":\"shortCanal\""))
    #expect(try JSONDecoder().decode(GameCore.MatchProjection.self, from: shortJSON) == short)
}
```

- [ ] **Step 2: 跑测试确认编译失败（无 `matchMode` 成员）**

- [ ] **Step 3: 实现**

`MatchProjection` 存储属性加 `var matchMode: MatchMode = .standard`（放在 `turnActionsTaken` 之后）。文件末尾加：

```swift
extension GameCore.MatchProjection {
    private nonisolated enum CodingKeys: String, CodingKey {
        case era, roundNumber, deckCount, actionsRemaining, players
        case boardIndustryPlacements, placedLinks, coalMarket, ironMarket
        case publicSupply, merchants, forcedSaleDebtorID, publicChecksum, ownHand
        case availableActions, availableActionsByCardID, trivialOptions
        case turnActionsTaken, matchMode
    }

    nonisolated init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        era = try values.decode(GameCore.Era.self, forKey: .era)
        roundNumber = try values.decode(Int.self, forKey: .roundNumber)
        deckCount = try values.decode(Int.self, forKey: .deckCount)
        actionsRemaining = try values.decode(Int.self, forKey: .actionsRemaining)
        players = try values.decode([GameCore.MatchPlayerProjection].self, forKey: .players)
        boardIndustryPlacements = try values.decode(
            [GameCore.BoardIndustryPlacement].self, forKey: .boardIndustryPlacements
        )
        placedLinks = try values.decode([GameCore.PlacedLink].self, forKey: .placedLinks)
        coalMarket = try values.decode(GameCore.ResourceMarket.self, forKey: .coalMarket)
        ironMarket = try values.decode(GameCore.ResourceMarket.self, forKey: .ironMarket)
        publicSupply = try values.decode(GameCore.PublicSupply.self, forKey: .publicSupply)
        merchants = try values.decode([GameCore.MerchantPlacement].self, forKey: .merchants)
        forcedSaleDebtorID = try values.decodeIfPresent(
            GameCore.PlayerID.self, forKey: .forcedSaleDebtorID
        )
        publicChecksum = try values.decode(String.self, forKey: .publicChecksum)
        ownHand = try values.decode([GameCore.CardInstance].self, forKey: .ownHand)
        availableActions = try values.decode(
            [GameCore.ActionKind].self, forKey: .availableActions
        )
        availableActionsByCardID = try values.decodeIfPresent(
            [String: [GameCore.ActionKind]].self, forKey: .availableActionsByCardID
        )
        trivialOptions = try values.decode(
            [GameCore.ActionOption].self, forKey: .trivialOptions
        )
        turnActionsTaken = try values.decodeIfPresent(Int.self, forKey: .turnActionsTaken)
        matchMode = try values.decodeIfPresent(GameCore.MatchMode.self, forKey: .matchMode) ?? .standard
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(era, forKey: .era)
        try values.encode(roundNumber, forKey: .roundNumber)
        try values.encode(deckCount, forKey: .deckCount)
        try values.encode(actionsRemaining, forKey: .actionsRemaining)
        try values.encode(players, forKey: .players)
        try values.encode(boardIndustryPlacements, forKey: .boardIndustryPlacements)
        try values.encode(placedLinks, forKey: .placedLinks)
        try values.encode(coalMarket, forKey: .coalMarket)
        try values.encode(ironMarket, forKey: .ironMarket)
        try values.encode(publicSupply, forKey: .publicSupply)
        try values.encode(merchants, forKey: .merchants)
        try values.encodeIfPresent(forcedSaleDebtorID, forKey: .forcedSaleDebtorID)
        try values.encode(publicChecksum, forKey: .publicChecksum)
        try values.encode(ownHand, forKey: .ownHand)
        try values.encode(availableActions, forKey: .availableActions)
        try values.encodeIfPresent(availableActionsByCardID, forKey: .availableActionsByCardID)
        try values.encode(trivialOptions, forKey: .trivialOptions)
        try values.encodeIfPresent(turnActionsTaken, forKey: .turnActionsTaken)
        if matchMode != .standard {
            try values.encode(matchMode, forKey: .matchMode)
        }
    }
}
```

（字段名以 `MatchProjection.swift:90-109` 实际声明为准逐一对齐；`ActionKind`/`ActionOption` 的模块前缀按文件现有引用方式。）

同时在 `make(...)`（111-168 行）生成投影处补 `matchMode: state.matchMode`（该函数若用逐字段构造则加一行；合成 memberwise init 因新增带默认值属性仍兼容）。`PublicMaterial`（175-188 行）不动。

- [ ] **Step 4: 跑测试全 PASS（含 RealMatchProjectionTests 全部既有投影往返/校验和测试）+ 提交**

```bash
git add ui-prototype/IndustrialCityBirmingham/GameCore/Model/MatchProjection.swift \
        ui-prototype/IndustrialCityBirminghamTests/ShortCanalRulesTests.swift
git commit -m "引擎:MatchProjection 手写编解码,matchMode 缺键解为 standard、短局才写出"
```

### Task 12: `SnapshotStore` schema 5 盖章与短局读取门

**Files:**
- Modify: `ui-prototype/IndustrialCityBirmingham/Session/SnapshotStore.swift:239-240`（supportedSchemaVersions）、`382-410`（save 盖章）、`460-482`（decodeCommittedArchive 模式门）、`15-34`（RecoverableSessionReference）、`897-966`（recoverableHostRoomsValidated）
- Modify: `ui-prototype/IndustrialCityBirminghamTests/RealMatchProjectionTests.swift:295-297`（期望集合）
- Test: `ui-prototype/IndustrialCityBirminghamTests/PersistenceRecoveryTests.swift`（贴既有夹具新增测试）

**Interfaces:**
- Produces: `SnapshotEnvelope.supportedSchemaVersions == Set([2, 4, 5])`；`RecoverableSessionReference.protocolVersion: Int`（解码 `decodeIfPresent ?? 2`）；`save` 在「`archive.protocolVersion == 3` 且载荷是短局（host 的 `gameState.matchMode == .shortCanal`，或 guest 的 `snapshot.match?.matchMode == .shortCanal`）」时把信封 `schemaVersion` 改为 5，其余保持 4
- 读取门（`decodeCommittedArchive`）：schema 5 要能通过 `requiresCurrentSchema` 的"当前 schema"比较（视为短局的当前 schema）；通过后再查模式——schema 5 但不是短局 → `schemaMismatch`；schema 2/4 且解出 `.shortCanal` → `schemaMismatch`；无键 → `.standard`
- `recoverableHostRoomsValidated`：先按协议 2 `load(requiresCurrentSchema: true)`；仅当 `protocolMismatch` 时再用协议 3 试一次；成功把协议写进 `RecoverableSessionReference.protocolVersion`

- [ ] **Step 1: 写失败测试（`PersistenceRecoveryTests`，贴 `makeCompleteHostArchive`(2624 行)与 schema-2 手工信封(528-546 行)的既有手法）**

```swift
@Test func shortCanalHostArchiveSavesAsSchemaFiveAndReloadsWithCurrentSchema() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tokenStore = RoomTokenStore(adapter: InMemorySecureItemAdapter())
    let key = FixedSnapshotKeyProvider(key: Data(repeating: 0x33, count: 32))
    let catalog = try verifiedCatalog()
    let hostID = GameCore.PlayerID(rawValue: "host")
    let roomID = GameCore.RoomID(rawValue: "SHORT-SAVE")
    var selectedState: GameCore.GameState?
    for seed in 1...100 {
        var setup = GameCore.SetupRules(seed: UInt64(seed))
        let candidate = try setup.makeGame(
            catalog: catalog, playerIDs: [hostID, player], mode: .shortCanal
        ).state
        if candidate.activePlayerID == hostID { selectedState = candidate; break }
    }
    let gameState = try #require(selectedState)
    let tokens: [GameCore.PlayerID: GameCore.ReconnectToken] = [
        hostID: .init(rawValue: "host-secret"), player: .init(rawValue: "guest-secret"),
    ]
    for (playerID, token) in tokens {
        try await tokenStore.save(.init(roomID: roomID, playerID: playerID, reconnectToken: token))
    }
    let engine = try gameState.makeHostEngine(
        roomID: roomID, reconnectTokens: tokens, protocolVersion: 3
    )
    let archive = SessionArchive.host(
        protocolVersion: 3, rulesetVersion: catalog.catalog.rulesetVersion,
        recipientID: hostID, state: engine.state, gameState: engine.gameState,
        eventWindows: [:],
        tokenReferences: [.init(roomID: roomID, playerID: hostID), .init(roomID: roomID, playerID: player)],
        peersNeedingRecovery: [], commitSequence: 0
    )
    let store = SnapshotStore(directory: directory, keyProvider: key)
    try await store.save(archive)

    // 信封 schema 必须是 5(由 save 盖章,不是手改)。
    let plaintext = try SnapshotCrypto.open(
        try Data(contentsOf: store.committedFileURL), keyData: key.key
    )
    let envelope = try JSONDecoder().decode(SnapshotEnvelope.self, from: plaintext)
    #expect(envelope.schemaVersion == 5)

    // requiresCurrentSchema 把 schema 5 视为短局的当前 schema,读回 .shortCanal。
    let loaded = try await store.load(
        expected: .init(
            protocolVersion: 3, rulesetVersion: catalog.catalog.rulesetVersion,
            roomID: roomID, recipientID: hostID, role: .host
        ),
        requiresCurrentSchema: true
    )
    guard case let .host(host) = loaded.payload else {
        Issue.record("expected host archive")
        return
    }
    #expect(try #require(host.gameState).matchMode == .shortCanal)
}
```

第二个测试锁错配组合（三个形状共用一套手工密封落盘手法，照 `PersistenceRecoveryTests.swift:528-546`：`var envelope = try SnapshotEnvelope(archive:)` → 改 `schemaVersion` → `SnapshotCrypto.seal(JSONEncoder.canonical.encode(envelope), keyData:)` → 写 `store.committedFileURL`，写前 `createDirectory`）：

```swift
@Test func mismatchedSchemaModeCombinationsAreRejectedAsSchemaMismatch() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tokenStore = RoomTokenStore(adapter: InMemorySecureItemAdapter())
    let keyData = Data(repeating: 0x34, count: 32)
    let key = FixedSnapshotKeyProvider(key: keyData)
    let factory = SessionPersistenceFactory(baseDirectory: directory, tokenStore: tokenStore, keyProvider: key)
    let catalog = try verifiedCatalog()
    let hostID = GameCore.PlayerID(rawValue: "host")
    let guestID = GameCore.PlayerID(rawValue: "guest")

    func makeArchive(mode: GameCore.MatchMode) throws -> SessionArchive {
        var rules = GameCore.SetupRules(seed: 3)
        var state = try rules.makeGame(catalog: catalog, playerIDs: [hostID, guestID]).state
        state.matchMode = mode
        return SessionArchive.host(
            protocolVersion: 3, rulesetVersion: catalog.catalog.rulesetVersion,
            recipientID: hostID, state: .init(state), gameState: state,
            eventWindows: [:], tokenReferences: [], peersNeedingRecovery: [], commitSequence: 0
        )
    }

    func writeSealed(_ archive: SessionArchive, schemaVersion: Int, roomID: GameCore.RoomID) throws {
        var envelope = try SnapshotEnvelope(archive: archive)
        envelope.schemaVersion = schemaVersion
        let store = SnapshotStore(
            directory: factory.directory(roomID: roomID, playerID: hostID), keyProvider: key
        )
        try FileManager.default.createDirectory(
            at: store.committedFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encrypted = try SnapshotCrypto.seal(
            JSONEncoder.canonical.encode(envelope), keyData: keyData
        )
        try encrypted.write(to: store.committedFileURL)
    }

    func loadSealed(roomID: GameCore.RoomID) async throws -> SessionArchive {
        let store = SnapshotStore(
            directory: factory.directory(roomID: roomID, playerID: hostID), keyProvider: key
        )
        return try await store.load(
            expected: .init(
                protocolVersion: 3, rulesetVersion: catalog.catalog.rulesetVersion,
                roomID: roomID, recipientID: hostID, role: .host
            ),
            requiresCurrentSchema: true
        )
    }

    // schema 5 但内层是标准局:schemaMismatch(不是 incompleteAuthorityState),
    // 且不进入任何恢复路径。
    try writeSealed(try makeArchive(mode: .standard), schemaVersion: 5, roomID: .init(rawValue: "FIVE-STANDARD"))
    do { _ = try await loadSealed(roomID: .init(rawValue: "FIVE-STANDARD")); Issue.record("schema 5 + 标准局必须拒绝") }
    catch let error as SnapshotStoreError { #expect(error == .schemaMismatch) }

    // schema 4 夹带短局键:拒绝,不许剥键当标准运河局开下去。
    try writeSealed(try makeArchive(mode: .shortCanal), schemaVersion: 4, roomID: .init(rawValue: "FOUR-SHORT"))
    do { _ = try await loadSealed(roomID: .init(rawValue: "FOUR-SHORT")); Issue.record("schema 4 + 短局必须拒绝") }
    catch let error as SnapshotStoreError { #expect(error == .schemaMismatch) }

    // schema 2 夹带短局键:同样拒绝。
    try writeSealed(try makeArchive(mode: .shortCanal), schemaVersion: 2, roomID: .init(rawValue: "TWO-SHORT"))
    do { _ = try await loadSealed(roomID: .init(rawValue: "TWO-SHORT")); Issue.record("schema 2 + 短局必须拒绝") }
    catch let error as SnapshotStoreError { #expect(error == .schemaMismatch) }
}
```

- [ ] **Step 2: 跑测试确认 FAIL（现在 save 不盖章、schema 5 不受支持、错配组合能被读出）**

- [ ] **Step 3: 实现**

`SnapshotStore.swift`：

1. `supportedSchemaVersions`（240 行）→ `Set([2, currentSchemaVersion, 5])`。`currentSchemaVersion` 仍为 4。
2. `RecoverableSessionReference`（15-34 行）加 `var protocolVersion: Int = 2`，并手写 `init(from:)`：其余字段照合成解码写法，该键 `decodeIfPresent ?? 2`（属性带默认值时合成解码仍要求键存在，必须手写）。既有构造点（`recoverableHostRoomsValidated` 里的 `.init(roomID:playerID:role:rulesetVersion:)`）补 `protocolVersion:` 实参。
3. `save`（382-410 行）：`SnapshotEnvelope(archive:)` 之后、`encode`/`seal` 之前：

```swift
var envelope = try SnapshotEnvelope(archive: archive)
if archive.protocolVersion == 3 {
    let isShortCanal: Bool
    switch archive.payload {
    case .host(let host): isShortCanal = host.gameState?.matchMode == .shortCanal
    case .guest(let guest): isShortCanal = guest.snapshot.match?.matchMode == .shortCanal
    }
    if isShortCanal { envelope.schemaVersion = 5 }
}
```

（校验和只覆盖 `archive`，改 `schemaVersion` 不需要重算；后续 encode/seal/落盘沿用现有行。缺投影的客机档案不盖 5——`match?` 链式取值自然落到 false。）
4. `decodeCommittedArchive`（460-482 行）：`incompleteAuthorityState` 分支（471-473 行）的"当前 schema"比较放行 schema 5；checksum/migrating 校验之后、返回之前加模式门：

```swift
if requiresCurrentSchema,
   envelope.schemaVersion != SnapshotEnvelope.currentSchemaVersion,
   envelope.schemaVersion != 5 {
    throw SnapshotStoreError.incompleteAuthorityState
}
// …既有 checksum / migratingLegacyAuthorityFields / 隐私校验…
let decodedMode: GameCore.MatchMode?
switch envelope.archive.payload {
case .host(let host): decodedMode = host.gameState?.matchMode
case .guest(let guest): decodedMode = guest.snapshot.match?.matchMode
}
if envelope.schemaVersion == 5, decodedMode != .shortCanal {
    throw SnapshotStoreError.schemaMismatch
}
if envelope.schemaVersion != 5, decodedMode == .shortCanal {
    throw SnapshotStoreError.schemaMismatch
}
```

5. `recoverableHostRoomsValidated`（897-966 行）：`do` 块里先按现行为协议 2 `load(requiresCurrentSchema: true)`；`catch SnapshotStoreError.protocolMismatch` 时用同一 expectation 的 `protocolVersion: 3` 重试一次（同一 store）；成功的档案把 `protocolVersion: archive.protocolVersion` 写进引用。无 catalog 的夹具路径（协议 1）不动。
6. `RealMatchProjectionTests.swift:295-297` 期望改 `Set([2, 4, 5])`；`actionableProjectionUsesSnapshotSchemaFour` 的 `currentSchemaVersion == 4` 断言不动。不改 `RecoveryCoordinator.recover` 的 schema `switch`（全局约束）。

- [ ] **Step 4: 跑测试全 PASS + 提交**

```bash
git add ui-prototype/IndustrialCityBirmingham/Session/SnapshotStore.swift \
        ui-prototype/IndustrialCityBirminghamTests/RealMatchProjectionTests.swift \
        ui-prototype/IndustrialCityBirminghamTests/PersistenceRecoveryTests.swift
git commit -m "会话:schema 5 由 save 给协议3短局盖章;读取按模式拒绝错配信封"
```

---

# PR 3：真实大厅可以选择短局

依赖：PR 2。不选时主机保持 `.standard`、协议 2；现有 `startGame()` 测试不传模式仍开标准局。

### Task 13: `SessionProtocol.Payload.LobbyState` 增加 `matchMode`

**Files:**
- Modify: `ui-prototype/IndustrialCityBirmingham/Session/SessionProtocol.swift:21-36`
- Test: `ui-prototype/IndustrialCityBirminghamTests/SessionProtocolTests.swift`

**Interfaces:**
- Produces: `LobbyState.matchMode: GameCore.MatchMode`（存储属性，memberwise init 加尾参默认 `.standard`）；`init(from:)` 对 `matchMode` 用 `decodeIfPresent ?? .standard`，其余四键按现方式解码（`names`/`colors` 不改可缺性）
- 这是 `SessionProtocol.Payload.LobbyState`，不是 `DemoModels.LobbyState`（后者不许动）。

- [ ] **Step 1: 写失败测试（`SessionProtocolTests` 文件内，贴该文件既有编解码测试风格）**

```swift
@Test func lobbyStateDecodesWithoutMatchModeAndEncodesItOnlyForShortCanal() throws {
    let legacy = Data("""
    {"playerIDs":["host","p2"],"readyPlayerIDs":["host"],"names":{},"colors":{}}
    """.utf8)
    let decoded = try JSONDecoder().decode(
        SessionProtocol.Payload.LobbyState.self, from: legacy
    )
    #expect(decoded.matchMode == .standard)
    #expect(String(data: try JSONEncoder().encode(decoded), encoding: .utf8)?
        .contains("\"matchMode\"") == false)

    var short = decoded
    short.matchMode = .shortCanal
    let encoded = try JSONEncoder().encode(short)
    #expect(String(data: encoded, encoding: .utf8)?
        .contains("\"matchMode\":\"shortCanal\"") == true)
    #expect(try JSONDecoder().decode(SessionProtocol.Payload.LobbyState.self, from: encoded) == short)
}
```

- [ ] **Step 2: 跑测试确认编译失败，然后实现**

`LobbyState` 加 `var matchMode: GameCore.MatchMode = .standard`；memberwise init 加尾参 `matchMode: GameCore.MatchMode = .standard`；因 `matchMode` 是非可选存储属性，合成 encode 会无条件写出 `"matchMode":"standard"`（破坏旧客机消息的对称性），所以解码与编码都要手写：

```swift
private enum CodingKeys: String, CodingKey {
    case playerIDs, readyPlayerIDs, names, colors, matchMode
}

init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    playerIDs = try values.decode([GameCore.PlayerID].self, forKey: .playerIDs)
    readyPlayerIDs = try values.decode([GameCore.PlayerID].self, forKey: .readyPlayerIDs)
    names = try values.decode([String: String].self, forKey: .names)
    colors = try values.decode([String: String].self, forKey: .colors)
    matchMode = try values.decodeIfPresent(GameCore.MatchMode.self, forKey: .matchMode) ?? .standard
}

func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(playerIDs, forKey: .playerIDs)
    try values.encode(readyPlayerIDs, forKey: .readyPlayerIDs)
    try values.encode(names, forKey: .names)
    try values.encode(colors, forKey: .colors)
    if matchMode != .standard {
        try values.encode(matchMode, forKey: .matchMode)
    }
}
```

（`names`/`colors` 的解码写法以既有 `SessionProtocolTests` 全绿为准：若现网消息可能缺这两键，用 `decodeIfPresent ?? [:]`。）现有调用点 `broadcastLobbyState`（`SessionCoordinator.swift:1291-1296`）靠 init 默认值继续编译，Task 14 再把模式传进去。

- [ ] **Step 3: 跑测试全 PASS + 提交**

```bash
git add ui-prototype/IndustrialCityBirmingham/Session/SessionProtocol.swift \
        ui-prototype/IndustrialCityBirminghamTests/SessionProtocolTests.swift
git commit -m "会话:LobbyState 携带 matchMode,缺键解为 standard、短局才写出"
```

### Task 14: 协调器可变协议字段 + 模式选择传到开局与广播

**Files:**
- Modify: `ui-prototype/IndustrialCityBirmingham/Session/SessionCoordinator.swift:133`（`let`→`var configuration`）、`347-406`（startGame）、`1289-1308`（broadcastLobbyState）、`544-560`（handleAsHost 的协议/规则集 guard 拆分）
- Test: `ui-prototype/IndustrialCityBirminghamTests/SessionCoordinatorTests.swift`

**Interfaces:**
- Produces: `SessionCoordinator.matchMode: GameCore.MatchMode`（`private(set)`，`.standard` 起步）；`func setMatchMode(_ mode: GameCore.MatchMode) async throws`（主机专用；`startPhase != .notStarted` 抛 `gameAlreadyStarted`；协议/名册编舞在 Task 15，本任务先落"写模式 + 广播带模式"）
- 规则集不符从 `versionIncompatible` 的 guard 拆出去：协议不符 → 仍发 `versionIncompatible`；规则集不符 → `.rejection(.init(reasonCode: .rulesetVersionMismatch, …))`（reasonCode 以枚举现有名称为准）。客机对 `.rejection` 的处理保持硬失败，不翻转协议。

- [ ] **Step 1: 写失败测试**

`SessionCoordinatorTests` 加（用既有 `realCoordinator` 夹具，858-869 行；`eventually` 辅助在 892 行）：

```swift
@Test func setMatchModeRequiresHostAndFlowsIntoBroadcastAndStartGame() async throws {
    let catalog = try verifiedCatalog()
    let hub = LoopbackTransportHub()
    let host = realCoordinator(id: hostID, token: "t-host", transport: hub.makeTransport(peerID: hostID), catalog: catalog)
    try await host.createRoom()
    #expect(await host.matchMode == .standard)

    // 客机只读。
    let guest = realCoordinator(id: guestID, token: "t-guest", transport: hub.makeTransport(peerID: guestID), catalog: catalog)
    _ = try await guest.joinRoom()
    try await eventually { await host.playerIDs.contains(guestID) }
    do {
        try await guest.setMatchMode(.shortCanal)
        Issue.record("guest must not set match mode")
    } catch let error as SessionCoordinator.Error {
        #expect(error == .hostOnly)
    }

    // 主机切短局:模式可读、广播带上模式、客机名册仍同步。
    try await host.setMatchMode(.shortCanal)
    #expect(await host.matchMode == .shortCanal)
    try await eventually { await guest.playerIDs.contains(guestID) }
    // 开局:短局状态进入引擎与投影。
    try await host.setReady(true)
    try await guest.setReady(true)
    try await eventually { await host.readyPlayerIDs.count == 2 }
    try await host.startGame()
    try await eventually { await host.snapshot?.match?.matchMode == .shortCanal }
    try await eventually { await guest.snapshot?.match?.matchMode == .shortCanal }
}
```

另确认既有 `startGame()` 测试（不传模式）全部原样通过——标准局、协议 2，不新增断言。

- [ ] **Step 2: 跑测试确认 FAIL（无 `matchMode`/`setMatchMode`）**

- [ ] **Step 3: 实现**

`SessionCoordinator.swift`：
1. 133 行 `private let configuration` → `private var configuration`（`transport` 保持 `let`；不新建协调器。信封/`PlayerIntent`/两处档案/`makeHostEngine` 抄的都是 `configuration.protocolVersion`，改 `var` 后自动读到新值）。
2. 加 `private(set) var matchMode: GameCore.MatchMode = .standard`。
3. `setMatchMode`（本任务先做门禁与广播，协议升级编舞 Task 15 插入同函数）：

```swift
func setMatchMode(_ mode: GameCore.MatchMode) async throws {
    guard isHost else { throw Error.hostOnly }
    guard startPhase == .notStarted else { throw Error.gameAlreadyStarted }
    matchMode = mode
    await broadcastLobbyState()
}
```

4. `broadcastLobbyState`（1291-1296 行）的 `LobbyState(...)` 调用补 `matchMode: matchMode`。
5. `startGame` 的 `makeGame(catalog:playerIDs:colors:)`（≈366 行）补 `mode: matchMode`。
6. `handleAsHost` 的合并 guard（551-555 行）拆开：

```swift
guard envelope.protocolVersion == configuration.protocolVersion else {
    try? await send(.versionIncompatible, toTransportPeer: peer, recipient: envelope.senderID)
    return
}
guard envelope.rulesetVersion == configuration.rulesetVersion else {
    try? await send(.rejection(.init(
        reasonCode: .rulesetVersionMismatch,
        recoverySuggestion: "Update to the same ruleset version to join this room."
    )), toTransportPeer: peer, recipient: envelope.senderID)
    return
}
```

- [ ] **Step 4: 跑测试全 PASS + 提交**

`compatibilityMismatchIsRejectedBeforeLobbyMutation`（446-459 行）的参数化用例 `(1, "rules-v2")`（协议不符）仍须抛 `.incompatiblePeer`；用例 `(2, "rules-v1")`（规则集不符）若断言从 `.incompatiblePeer` 变为 rejection 路径的硬失败，更新断言为"仍不污染大厅（`host.playerIDs == [hostID]`）"，不得删除测试。

```bash
git add ui-prototype/IndustrialCityBirmingham/Session/SessionCoordinator.swift \
        ui-prototype/IndustrialCityBirminghamTests/SessionCoordinatorTests.swift
git commit -m "会话:协调器持有 matchMode,广播与开局携带模式;规则集不符改回 rejection"
```

### Task 15: `versionIncompatible` 协议编舞（主机名册 + 客机跟随）

**Files:**
- Modify: `ui-prototype/IndustrialCityBirmingham/Session/SessionCoordinator.swift`（setMatchMode 扩展、handleAsHost `.hello`、handleAsGuest `.versionIncompatible`）
- Test: `ui-prototype/IndustrialCityBirminghamTests/SessionCoordinatorTests.swift`

**Interfaces:**
- Consumes: Task 14 的 `setMatchMode`/`var configuration`
- 主机编舞（切到协议 `target ∈ {2,3}`）：
  1. **先写新协议**：`configuration.protocolVersion = target`；把除主机外已入座玩家记入 `needsProtocolRehello`，清掉他们的 `ready`；不删 `tokens`（`await send` 挂起期间按新协议回来的 hello 还能对上检查）。
  2. 逐个发 `.versionIncompatible`；`.hello` 处理里把按新协议回来的人移出 `needsProtocolRehello`，留在座位上。
  3. 全部发送返回后：仍带标记的人从 `tokens` 与 `ready` 移除，清空标记。
  4. `await broadcastLobbyState()`（缩小后的名册）。
- 客机编舞（`.versionIncompatible` 到达时）：若上一次翻转后还没收到任何接受性消息（`.lobbyState`/`.createRoom`）→ 停止并 `joinOutcome = .rejected(.incompatiblePeer)`；否则翻转存储协议（2→3、3→2）并**立刻用新值重新 hello 一次**。旧构建不认识 3，收到即 `.rejected(.incompatiblePeer)` 停止，不 hello。
- 切回协议 2 只允许大厅且棋盘未写出（`startPhase == .notStarted && engine == nil && snapshot == nil`），否则 `setMatchMode` 抛 `gameAlreadyStarted`。
- `startGame` 只给剩下的 `tokens` 发牌；`startPhase == .notStarted` 时被扫掉的新客机仍可重新入座。

- [ ] **Step 1: 写失败测试**

```swift
@Test func hostSwitchingProtocolPrunesSeatsThatNeverRehello() async throws {
    let catalog = try verifiedCatalog()
    let hub = LoopbackTransportHub()
    let host = realCoordinator(id: hostID, token: "t-host", transport: hub.makeTransport(peerID: hostID), catalog: catalog)
    try await host.createRoom()
    // 入座后断连的客机:收不到 versionIncompatible,永远不会重新 hello。
    let guest = realCoordinator(id: guestID, token: "t-guest", transport: hub.makeTransport(peerID: guestID), catalog: catalog)
    _ = try await guest.joinRoom()
    try await eventually { await host.playerIDs.contains(guestID) }
    await guest.disconnect()

    try await host.setMatchMode(.shortCanal)

    // 名册必须剔除不回来重新 hello 的座位;ready 里也不在;主机自己保留。
    try await eventually { await host.playerIDs.contains(guestID) == false }
    #expect(await host.readyPlayerIDs.contains(guestID) == false)
    #expect(await host.playerIDs.contains(hostID))
}

@Test func guestFollowsHostProtocolFlipAndStaysSeated() async throws {
    let catalog = try verifiedCatalog()
    let hub = LoopbackTransportHub()
    let host = realCoordinator(id: hostID, token: "t-host", transport: hub.makeTransport(peerID: hostID), catalog: catalog)
    try await host.createRoom()
    let guest = realCoordinator(id: guestID, token: "t-guest", transport: hub.makeTransport(peerID: guestID), catalog: catalog)
    _ = try await guest.joinRoom()
    try await eventually { await host.playerIDs.contains(guestID) }

    try await host.setMatchMode(.shortCanal)

    // 新客机跟随到协议 3 并重新 hello 成功,仍在大厅名册里,
    // 且后续能准备、主机仍能开局短局。
    try await eventually { await host.playerIDs.contains(guestID) }
    #expect(await host.matchMode == .shortCanal)
    try await guest.setReady(true)
    try await host.setReady(true)
    try await eventually { await host.readyPlayerIDs.count == 2 }
    try await host.startGame()
    try await eventually { await host.snapshot?.match?.matchMode == .shortCanal }
    try await eventually { await guest.snapshot?.match?.matchMode == .shortCanal }
}
```

说明：**"翻转后的 hello 再被拒即停"分支做不成确定性测试**——它要求主机在客机翻转 ack 尚未落定的窗口内再次切换协议，本质是时序赛跑。该分支的实现（`awaitingProtocolFollowAck` 守卫）靠代码评审与上面两个测试间接覆盖：跟随成功路径证明翻转只发生一次且随后被 `.lobbyState` 接受清标记；剔除路径证明不重新 hello 的座位出局。禁止为凑覆盖写依赖 `Task.sleep` 竞速的脆弱测试。

- [ ] **Step 2: 跑测试确认 FAIL（`setMatchMode` 还不改协议；断连客机仍留在名册）**

- [ ] **Step 3: 实现**

`SessionCoordinator` 加 `private var needsProtocolRehello: Set<GameCore.PlayerID> = []` 与 `private var awaitingProtocolFollowAck = false`。

`setMatchMode` 扩展为（门禁沿用 Task 14，补"棋盘未写出"守卫）：

```swift
func setMatchMode(_ mode: GameCore.MatchMode) async throws {
    guard isHost else { throw Error.hostOnly }
    guard startPhase == .notStarted, engine == nil, snapshot == nil else {
        throw Error.gameAlreadyStarted
    }
    let target = mode == .shortCanal ? 3 : 2
    let changed = matchMode != mode
    matchMode = mode
    guard changed, target != configuration.protocolVersion else {
        await broadcastLobbyState()
        return
    }
    // 1) 先写新协议:发通知期间按新协议 hello 的客机能对上检查。
    configuration.protocolVersion = target
    needsProtocolRehello = Set(playerIDs.filter { $0 != configuration.playerID })
    for player in needsProtocolRehello { ready.remove(player) }   // tokens 先不动
    // 2) 发 versionIncompatible;.hello 处理会把按新协议回来的人移出标记。
    for player in playerIDs where player != configuration.playerID {
        try? await send(.versionIncompatible, to: player)
    }
    // 3) 发送全部返回:仍带标记的座位移出名册。
    for player in needsProtocolRehello {
        tokens[player] = nil
        ready.remove(player)
    }
    needsProtocolRehello = []
    // 4) 广播缩小后的名册。
    await broadcastLobbyState()
}
```

`handleAsHost` `.hello` 分支（协议 guard 已通过处）加：

```swift
needsProtocolRehello.remove(envelope.senderID)
```

`handleAsGuest` `.versionIncompatible` 分支（762-764 行）改为：

```swift
case .versionIncompatible:
    guard acceptUnique(envelope, peer: peer) else { return }
    if awaitingProtocolFollowAck {
        // 翻转后的 hello 仍被拒:停止,不在 2/3 之间震荡。
        awaitingProtocolFollowAck = false
        joinOutcome = .rejected(.incompatiblePeer)
        return
    }
    // 跟随主机:2→3、3→2,立刻用改过的存储值重新 hello 一次。
    configuration.protocolVersion = configuration.protocolVersion == 3 ? 2 : 3
    awaitingProtocolFollowAck = true
    try? await send(
        .hello(reconnectToken: configuration.reconnectToken, displayName: configuration.displayName),
        to: configuration.hostPlayerID
    )
```

（`.hello` 的载荷构造照 `joinRoom()` 里的现成调用抄。）`.lobbyState` 与 `.createRoom` 接受处加 `awaitingProtocolFollowAck = false`（成功加入后主机再改模式可以再翻转一次）。客机恢复路径的协议探测在 Task 16。

- [ ] **Step 4: 跑测试全 PASS + 提交**

```bash
git add ui-prototype/IndustrialCityBirmingham/Session/SessionCoordinator.swift \
        ui-prototype/IndustrialCityBirminghamTests/SessionCoordinatorTests.swift
git commit -m "会话:协议2/3随模式切换,主机名册只留重新hello的座位,客机跟随一次即停"
```

### Task 16: 入座/恢复路径的协议探测

**Files:**
- Modify: `ui-prototype/IndustrialCityBirmingham/Session/SessionViewStore.swift:51-84`（NearbyHostRecoveryRoute.makeStore）、`355-385`（makeNearbyGuest）
- Test: `ui-prototype/IndustrialCityBirminghamTests/PersistenceRecoveryTests.swift`、`ui-prototype/IndustrialCityBirminghamTests/SessionViewStoreTests.swift`

**Interfaces:**
- Consumes: Task 12 的 `RecoverableSessionReference.protocolVersion`
- `NearbyHostRecoveryRoute.makeStore`：`protocolVersion: reference.protocolVersion`（不再写死 2；短局引用是 3，`makeCoordinator` 的 `load` 期望也就是 3，能读回存档）。
- `makeNearbyGuest`：先按协议 2 构造协调器并 `load`；仅当 `SnapshotStoreError.protocolMismatch` 时按协议 3 重试一次（同一 transport 与 persistenceFactory；成功后直接用协议 3 的协调器恢复，不返回协议 2 的那个绑定在同一目录上）。恢复路径 `requiresCurrentSchema` 保持默认 false。`makeNearbyHost` 新建标准房间仍传 2。

- [ ] **Step 1: 写失败测试（`PersistenceRecoveryTests`，贴 `verifiedRulesetHostArchiveListsRestoresAndAcceptsTheNextBuild`(227 行)的骨架）**

```swift
@Test func nearbyHostRecoveryRouteOpensShortCanalArchivesWithProtocolThree() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tokenStore = RoomTokenStore(adapter: InMemorySecureItemAdapter())
    let keyData = Data(repeating: 0x35, count: 32)
    let key = FixedSnapshotKeyProvider(key: keyData)
    let factory = SessionPersistenceFactory(baseDirectory: directory, tokenStore: tokenStore, keyProvider: key)
    let catalog = try verifiedCatalog()
    let hostID = GameCore.PlayerID(rawValue: "host")
    let roomID = GameCore.RoomID(rawValue: "SHORT-ROUTE")
    var selectedState: GameCore.GameState?
    for seed in 1...100 {
        var setup = GameCore.SetupRules(seed: UInt64(seed))
        let candidate = try setup.makeGame(
            catalog: catalog, playerIDs: [hostID, player], mode: .shortCanal
        ).state
        if candidate.activePlayerID == hostID { selectedState = candidate; break }
    }
    let gameState = try #require(selectedState)
    let tokens: [GameCore.PlayerID: GameCore.ReconnectToken] = [
        hostID: .init(rawValue: "host-secret"), player: .init(rawValue: "guest-secret"),
    ]
    for (playerID, token) in tokens {
        try await tokenStore.save(.init(roomID: roomID, playerID: playerID, reconnectToken: token))
    }
    let engine = try gameState.makeHostEngine(roomID: roomID, reconnectTokens: tokens, protocolVersion: 3)
    let archive = SessionArchive.host(
        protocolVersion: 3, rulesetVersion: catalog.catalog.rulesetVersion,
        recipientID: hostID, state: engine.state, gameState: engine.gameState,
        eventWindows: [:],
        tokenReferences: [.init(roomID: roomID, playerID: hostID), .init(roomID: roomID, playerID: player)],
        peersNeedingRecovery: [], commitSequence: 0
    )
    try await SnapshotStore(
        directory: factory.directory(roomID: roomID, playerID: hostID), keyProvider: key
    ).save(archive)

    // 房间列表先按协议 2 试、protocolMismatch 后按 3 再试,引用带协议 3。
    let reference = try #require(try await factory.recoverableHostRooms(catalog: catalog).first)
    #expect(reference.protocolVersion == 3)

    // 恢复路由用引用上的协议(不再写死 2),能连上并恢复出短局投影。
    let store = try await NearbyHostRecoveryRoute.makeStore(
        reference: reference,
        identity: .init(
            deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            roomID: roomID.rawValue
        ),
        persistenceFactory: factory,
        transport: LoopbackTransportHub().makeTransport(peerID: hostID),
        catalog: catalog
    )
    #expect(await store.connect() == nil)
    try await eventuallyMainActor { store.snapshot != nil }
    #expect(store.snapshot?.match?.matchMode == .shortCanal)
}
```

`SessionViewStoreTests` 再加一条客机探测测试（用 `verifiedCoordinator` 夹具与临时持久化目录）：客机目录里只有协议 3 的短局投影存档时，入座先按协议 2 `load`、`protocolMismatch` 后按 3 重试成功，恢复出的 `store.snapshot?.match?.matchMode == .shortCanal`，且该协调器后续提交行动的信封协议是 3（与同目录恢复出的主机协调器对局一次即可断言）。

- [ ] **Step 2: 跑测试确认 FAIL（makeStore 写死 2）**

- [ ] **Step 3: 实现**

`SessionViewStore.swift`：
1. `NearbyHostRecoveryRoute.makeStore` 65 行 `protocolVersion: 2` → `protocolVersion: reference.protocolVersion`。
2. `makeNearbyGuest`：把"构造协调器"提成私有函数 `makeGuestCoordinator(protocolVersion:)`；主流程先 2，`catch SnapshotStoreError.protocolMismatch` 时用 3 重试一次（重试用同一 transport 与 persistenceFactory；成功后直接用新协调器，不返回协议 2 的那个）。

- [ ] **Step 4: 跑测试全 PASS + 提交**

```bash
git add ui-prototype/IndustrialCityBirmingham/Session/SessionViewStore.swift \
        ui-prototype/IndustrialCityBirminghamTests/PersistenceRecoveryTests.swift \
        ui-prototype/IndustrialCityBirminghamTests/SessionViewStoreTests.swift
git commit -m "会话:恢复路由按引用协议打开短局存档,客机入座先2后3探测"
```


### Task 17: 大厅模式控件与对局展示

**Files:**
- Modify: `ui-prototype/IndustrialCityBirmingham/Features/Lobby/LobbyView.swift:104-172`（只改 `realLobby`）
- Modify: `ui-prototype/IndustrialCityBirmingham/Session/SessionViewStore.swift`（透传 `matchMode` 选择）
- Modify: `ui-prototype/IndustrialCityBirmingham/Features/Match/MatchHeaderView.swift`（加默认 `nil` 的标签参数）
- Modify: `ui-prototype/IndustrialCityBirmingham/Features/Match/FinalScoreboardView.swift`（加默认 `"游戏结束"` 的标题参数）
- Modify: `ui-prototype/IndustrialCityBirmingham/Features/Match/AuthoritativeMatchBoardView.swift:118-134`（读投影模式并下传）
- Test: `ui-prototype/IndustrialCityBirminghamTests/SessionViewStoreTests.swift`

**Interfaces:**
- Consumes: Task 14/15 的 `setMatchMode`、Task 11 的 `MatchProjection.matchMode`
- 数据路径：主机分段控件 → `store.setMatchMode(mode)` → `SessionCoordinator.matchMode` → `broadcastLobbyState(matchMode:)` → `startGame` 传 `makeGame(mode:)` → `MatchProjection.matchMode` → `AuthoritativeMatchBoardView` 读 `store.snapshot?.match?.matchMode`（客机渲染的就是 `ViewSnapshot.match`，不是主机内存里的 `GameState`）。客机是只读文字。
- **不改**：`RealMatchViewModel.make` 的 era 字符串（`RealMatchViewModel.swift:20` 继续把 `.canal` 写成 `"运河时代"`——`MapRouteEraStyle.currentEra` 只认识 `"运河时代"` 和 `"铁路时代"` 两个字符串，`MapRouteEraStyle.swift:40-46`，短局标题不得写入 `DemoMatchState.era`）、`DemoModels.LobbyState`、`#if DEBUG` 演示 `LobbyView`（175-481 行）。

- [ ] **Step 1: 写失败测试（`SessionViewStoreTests`，贴 `lobbyAuthorizationReflectsCoordinatorRoleAndReadyState`(155 行) 的夹具方式；`verifiedCoordinator` 在 277 行）**

```swift
@Test func matchModeSelectionIsHostOnlyAndFlowsIntoStartedMatch() async throws {
    let catalog = try verifiedCatalog()   // 该文件若无此辅助,从 SessionCoordinatorTests 抄同款
    let hub = LoopbackTransportHub()
    let host = verifiedCoordinator(id: hostID, token: "t-host", transport: hub.makeTransport(peerID: hostID), catalog: catalog)
    let guest = verifiedCoordinator(id: guestID, token: "t-guest", transport: hub.makeTransport(peerID: guestID), catalog: catalog)
    let hostStore = SessionViewStore(coordinator: host, role: .host)
    let guestStore = SessionViewStore(coordinator: guest, role: .guest)

    #expect(hostStore.matchModeSelection == .standard)
    #expect(guestStore.matchModeSelection == .standard)

    await hostStore.connect()
    await guestStore.connect()
    try await eventually { hostStore.players.count == 2 }

    // 客机改模式:报 hostOnly 文案错误,选择不变。
    await guestStore.setMatchMode(.shortCanal)
    #expect(guestStore.errorMessage != nil)
    #expect(guestStore.matchModeSelection == .standard)

    // 主机改模式:选择翻转,客机经广播读到同一模式。
    await hostStore.setMatchMode(.shortCanal)
    #expect(hostStore.matchModeSelection == .shortCanal)
    try await eventually { guestStore.matchModeSelection == .shortCanal }

    await hostStore.setReady(true)
    await guestStore.setReady(true)
    try await eventually { hostStore.readyPlayerIDs.count == 2 }
    await hostStore.startGame()
    try await eventually { hostStore.snapshot?.match?.matchMode == .shortCanal }
    try await eventually { guestStore.snapshot?.match?.matchMode == .shortCanal }
}
```

（`verifiedCatalog` 若不在 `SessionViewStoreTests` 里，按该文件现有 catalog 获取方式落笔；`errorMessage` 的断言以 `SessionViewStore.message(for:)` 产出的非空文案为准，不比对具体字符串。）

- [ ] **Step 2: 实现**

`SessionViewStore` 加（照该文件 `isReady`/`players` 的既有透传方式）：

```swift
var matchModeSelection: GameCore.MatchMode {
    get async { await coordinator.matchMode }
}

func setMatchMode(_ mode: GameCore.MatchMode) async {
    do { try await coordinator.setMatchMode(mode) }
    catch { errorMessage = Self.message(for: error) }
}
```

（`matchModeSelection` 若做同步存储属性镜像，按该文件既有 `players`/`readyPlayerIDs` 的状态订阅更新方式实现，以测试全绿为准。）

`realLobby` 在代表色选择器（`LobbyView.swift:125-136`）之后加（仅主机可改；客机只读）：

```swift
if store.isHost {
    Picker("对局模式", selection: Binding(
        get: { store.matchModeSelection },
        set: { mode in Task { await store.setMatchMode(mode) } }
    )) {
        Text("标准局").tag(GameCore.MatchMode.standard)
        Text("运河短局").tag(GameCore.MatchMode.shortCanal)
    }
    .pickerStyle(.segmented)
    .accessibilityIdentifier("real.matchMode")
} else if store.matchModeSelection == .shortCanal {
    Text("运河短局").font(.footnote)
}
```

`MatchHeaderView` 加 `var modeLabel: String? = nil`（init 尾参默认 `nil`），在时代文案旁渲染，`nil` 不显示。`FinalScoreboardView` 加 `var title: String = "游戏结束"`（init 尾参），17 行 `Text("游戏结束")` 改 `Text(title)`。`AuthoritativeMatchBoardView`（128-134 行）：

```swift
let matchMode = store.snapshot?.match?.matchMode ?? .standard
FinalScoreboardView(
    standings: /* 现有实参 */, projections: /* 现有实参 */, displayName: /* 现有实参 */,
    title: matchMode == .shortCanal ? "运河短局" : "游戏结束"
)
```

`MatchHeaderView` 调用处传 `modeLabel: matchMode == .shortCanal ? "运河短局" : nil`。

- [ ] **Step 3: 跑测试全 PASS + 提交（可选:按记忆 auto-e2e-harness 跑双模拟器冒烟）**

```bash
git add ui-prototype/IndustrialCityBirmingham/Features/Lobby/LobbyView.swift \
        ui-prototype/IndustrialCityBirmingham/Session/SessionViewStore.swift \
        ui-prototype/IndustrialCityBirmingham/Features/Match/MatchHeaderView.swift \
        ui-prototype/IndustrialCityBirmingham/Features/Match/FinalScoreboardView.swift \
        ui-prototype/IndustrialCityBirmingham/Features/Match/AuthoritativeMatchBoardView.swift \
        ui-prototype/IndustrialCityBirminghamTests/SessionViewStoreTests.swift
git commit -m "大厅:主机可选运河短局,局头与终局标题显示短局,客机只读"
```

---

## 验收清单（全做完后逐项跑一遍）

1. 三份金哈希原样通过（`seededCompleteGamesProduceReplayableDeterministicProofs` 2/3/4 人）。
2. 标准局存档仍协议 2、schema 4；`actionableProjectionUsesSnapshotSchemaFour` 与 `snapshotSchemaSupportIsExplicitAndDoesNotClaimSchemaThree`（期望 `[2, 4, 5]`）通过。
3. 短局 `save` → 信封 schema 5 → `load(requiresCurrentSchema: true)` 读回 `.shortCanal`（真实 `save` 路径，无手改 schema）。
4. schema 5+非短局、schema 4/2+短局两种错配都 `schemaMismatch` 且不恢复。
5. 短局终局：4 个转换（`roundEnded`/`eraScored`/`shortCanalScored`/`gameEnded`）、`era == .canal`、`.ended`、一级产业与底牌仍在、线撤回余量回补、牌区多重集不变、无 `railPrepared`。
6. 标准局运河末回合照发收入（现金 20→23）、铁路终局 3 个转换且 VP 只加一次。
7. 两份 `RULES.md` 的 5.1/6.1/7.6/9.1/10.1/10.3/11 相关小节两两一致（`diff <(sed -n '90,370p' RULES.md) <(sed -n '90,371p' ui-prototype/RULES.md)` 只应显示既有 §14/§15 差异与行号偏移）。

## 风险与回退

- 每份 PR 独立可回退。PR 2 回退后，schema 5/协议 3 的短局存档在旧构建的 `schemaMismatch`/`protocolMismatch` 处停下，**不得**迁移成标准运河局；标准局存档不受影响。丢掉的短局存档不能恢复成一盘可下的标准局。
- PR 3 回退只去掉选择器；已按 PR 2 写成 schema 5 的短局存档仍由含 PR 2 的构建读取。
- PR 1 的铁路终局撤线若回退，只影响终局棋盘上的线，不影响已计 VP。
- 任何一步金哈希 FAIL：先怀疑编码/事件序列被顺手改坏，修代码；禁止重录哈希、禁止改 `expectedHashes`。
