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
        #expect(event.transitions.contains { if case .railPrepared = $0 { true } else { false } } == false)
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
        #expect(try #require(state.players.first { $0.id == owner }).victoryPoints
            == cottonLevel.linkPoints + coalLevel.victoryPoints + cottonLevel.victoryPoints)

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
        // 收入 6(pos 21)在 VP 10 上加 6。
        var richState = try shortCanalState()
        mutate(richState.playerOrder[0], in: &richState) {
            $0.victoryPoints = 10; $0.cash = 0; $0.incomePosition = 21
        }
        guard case .shortCanalScored(let rich) = try GameCore.ScoringRules.applyShortCanalBonus(
            priorAwards: [], state: &richState, catalog: catalog
        ), let richAward = rich.awards.first(where: { $0.playerID == richState.playerOrder[0] }) else {
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
        // 名义收入分:两人都是 1(等级),最终 VP 都是 7+1(现金)+1(收入)=9。
        #expect(details.awards.allSatisfy { $0.incomePoints == 1 && $0.victoryPoints == 9 })
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

        func renumbered(_ events: [GameCore.SetupEvent]) -> [GameCore.SetupEvent] {
            events.enumerated().map { .init(sequence: $0.offset, payload: $0.element.payload) }
        }
        // 显式 .standard 视为非法(缺事件才是 standard)。
        var explicit = standard.events
        explicit.insert(
            .init(sequence: 1, payload: .matchModeSelected(.standard)), at: 1
        )
        #expect(throws: GameCore.SetupError.self) {
            _ = try GameCore.SetupRules.replay(renumbered(explicit), catalog: catalog)
        }
        // 位置错(出现在 turnStateInitialized 之后)同样拒绝。
        var misplaced = standard.events
        misplaced.insert(
            .init(sequence: 2, payload: .matchModeSelected(.shortCanal)), at: 3
        )
        #expect(throws: GameCore.SetupError.self) {
            _ = try GameCore.SetupRules.replay(renumbered(misplaced), catalog: catalog)
        }
    }

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
        // 短局不得进入铁路时代(夹具清掉底牌,除模式外其余条款全合法)。
        var railed = try shortState()
        railed.era = .rail
        for playerIndex in railed.players.indices {
            if let bottom = railed.players[playerIndex].privateBottomDiscard {
                railed.players[playerIndex].privateBottomDiscard = nil
                railed.standardDrawDeck.append(bottom)
            }
        }
        #expect(GameCore.GameStateAuthorityValidator.isValid(railed, catalog: catalog) == false)
        // 短局不得进入时代间暂停(夹具按 validTurnPhase 的 eraIntermission 条款配齐)。
        var paused = try shortState()
        paused.roundNumber = paused.canalRoundCapacity
        paused.actionsRemaining = 0
        paused.turnsCompletedInRound = 0
        paused.turnPhase = .eraIntermission(.init(
            settledEra: .canal,
            awards: paused.players.map {
                .init(playerID: $0.id, linkPoints: 0, industryPoints: 0, incomeLevel: 0)
            },
            confirmedPlayerIDs: []
        ))
        #expect(GameCore.GameStateAuthorityValidator.isValid(paused, catalog: catalog) == false)
        // 标准局不受新条款影响(多解出来的 .standard 与今天等价)。
        var standard = try shortState()
        standard.matchMode = .standard
        #expect(GameCore.GameStateAuthorityValidator.isValid(standard, catalog: catalog))
    }

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
