import Foundation
import Testing
@testable import IndustrialCityBirmingham

struct TurnScoringRulesTests {
    @Test(arguments: [2, 3, 4])
    func firstCanalRoundGivesEachSeatOneActionThenTwoAndRefillsToEight(playerCount: Int) throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: playerCount, catalog: catalog)
        let originalOrder = state.playerOrder
        let exhausted = Array(state.standardDrawDeck.dropFirst(playerCount - 1))
        state.standardDrawDeck = Array(state.standardDrawDeck.prefix(playerCount - 1))
        state.publicDiscard.append(contentsOf: exhausted)
        let availableDraws = state.standardDrawDeck.count
        let roomID = GameCore.RoomID(rawValue: "turn-room")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        var engine = try state.makeHostEngine(roomID: roomID, reconnectTokens: tokens, protocolVersion: 1)

        var lastConfirmEvent: GameCore.AuthoritativeGameEvent?
        for (seat, playerID) in originalOrder.enumerated() {
            let player = try #require(engine.gameState.players.first { $0.id == playerID })
            let card = try #require(player.hand.first)
            let result = engine.submit(.init(
                protocolVersion: 1, rulesetVersion: engine.rulesetVersion,
                roomID: roomID, senderID: playerID,
                reconnectToken: try #require(tokens[playerID]),
                baseVersion: engine.gameState.authoritativeVersion,
                payload: .pass(.init(cardID: card.id))
            ), catalog: catalog)
            guard case .accepted = result else {
                Issue.record("seat \(seat) should complete its first-round action")
                continue
            }
            // 新流程:行动落地后确认过轮;最后一家确认触发回合末结算。
            let confirm = engine.submit(.init(
                protocolVersion: 1, rulesetVersion: engine.rulesetVersion,
                roomID: roomID, senderID: playerID,
                reconnectToken: try #require(tokens[playerID]),
                baseVersion: engine.gameState.authoritativeVersion,
                payload: .confirmTurnEnd
            ), catalog: catalog)
            guard case .accepted(let confirmEvent) = confirm else {
                Issue.record("seat \(seat) turn-end confirm rejected: \(confirm)")
                continue
            }
            lastConfirmEvent = confirmEvent
        }
        if playerCount > 0 {
            #expect(lastConfirmEvent?.transitions.contains { if case .roundEnded = $0 { true } else { false } } == true)
        }

        #expect(engine.gameState.roundNumber == 2)
        #expect(engine.gameState.actionsRemaining == 2)
        #expect(engine.gameState.activePlayerID == originalOrder.first)
        #expect(engine.gameState.playerOrder == originalOrder)
        #expect(engine.gameState.standardDrawDeck.isEmpty)
        #expect(engine.gameState.players.reduce(0) { $0 + $1.hand.count } == playerCount * 7 + availableDraws)
        // 每人 1 行动 + 1 过轮确认,各占一个版本号。
        #expect(engine.gameState.actionNumber == playerCount * 2)
        #expect(engine.gameState.authoritativeVersion.rawValue == playerCount * 2)
    }

    @Test func roundEndUsesStableAscendingSpendingOrderAndResetsTurnState() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 4, catalog: catalog)
        let oldOrder = state.playerOrder
        setSpent(9, for: oldOrder[0], in: &state)
        setSpent(2, for: oldOrder[1], in: &state)
        setSpent(2, for: oldOrder[2], in: &state)
        setSpent(5, for: oldOrder[3], in: &state)

        let events = try GameCore.GameRulesEngine.resolveRoundEnd(state: &state, catalog: catalog)

        #expect(state.playerOrder == [oldOrder[1], oldOrder[2], oldOrder[3], oldOrder[0]])
        #expect(state.players.allSatisfy { $0.spent == 0 })
        #expect(state.turnsCompletedInRound == 0)
        #expect(state.actionsRemaining == 2)
        var replayed = try setup(playerCount: 4, catalog: catalog)
        setSpent(9, for: oldOrder[0], in: &replayed)
        setSpent(2, for: oldOrder[1], in: &replayed)
        setSpent(2, for: oldOrder[2], in: &replayed)
        setSpent(5, for: oldOrder[3], in: &replayed)
        try GameCore.GameRulesEngine.replay(events, to: &replayed, catalog: catalog)
        #expect(replayed == state)
    }

    @Test func incomePausesForTheDebtorToChooseOrderedHalfCostSalesThenCreatesDebt() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let positive = state.playerOrder[0]
        let debtor = state.playerOrder[1]
        mutatePlayer(positive, in: &state) { $0.cash = 10; $0.incomePosition = 15 }
        mutatePlayer(debtor, in: &state) { $0.cash = 0; $0.incomePosition = 0; $0.victoryPoints = 4 }
        var sale = try placement(
            ownerID: debtor, industryID: "brewery", level: 2,
            placementID: "forced-sale", catalog: catalog.catalog
        )
        sale.resourceCount = 1
        state.publicSupply.beer = 15
        state.boardIndustryPlacements.append(sale)

        let pendingEvents = try GameCore.GameRulesEngine.resolveRoundEnd(state: &state, catalog: catalog)
        let positiveAfter = try #require(state.players.first { $0.id == positive })
        let saleCost = try #require(catalog.catalog.industries.first { $0.id == "brewery" }?
            .levels.first { $0.level == 2 }?.buildCost)

        #expect(positiveAfter.cash == 13)
        #expect(state.boardIndustryPlacements.contains { $0.placementID == sale.placementID })
        #expect(state.turnPhase == .forcedSale(.init(
            playerID: debtor, shortfall: 10, eligiblePlacementIDs: [sale.placementID]
        )))
        guard pendingEvents.count == 1, case .forcedSaleRequired = pendingEvents[0] else {
            Issue.record("expected forced-sale pending event")
            return
        }

        let previousVersion = state.authoritativeVersion
        let previousActionNumber = state.actionNumber
        let event = try GameCore.GameRulesEngine.resolveForcedSale(
            .init(placementIDs: [sale.placementID]), actorID: debtor,
            roomID: .init(rawValue: "income-room"), state: &state, catalog: catalog
        )
        let debtorAfter = try #require(state.players.first { $0.id == debtor })
        #expect(state.boardIndustryPlacements.contains { $0.placementID == sale.placementID } == false)
        #expect(state.publicSupply.beer == 15)
        #expect(debtorAfter.cash == 0)
        // 官方规则:每缺 £1 立即失去 1 VP,最多失去现有 VP(此处 4)。
        #expect(debtorAfter.victoryPointDebt == min(4, max(0, 10 - saleCost / 2)))
        #expect(debtorAfter.victoryPoints == 0)
        #expect(state.authoritativeVersion.rawValue == previousVersion.rawValue + 1)
        #expect(state.actionNumber == previousActionNumber + 1)
        #expect(event.payload == .forcedSaleResolved(.init(placementIDs: [sale.placementID])))
    }

    @Test func roundEndResortsTurnOrderByAscendingSpentStably() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let first = state.playerOrder[0]
        let second = state.playerOrder[1]
        // RULES.md §6.2:回合末按本回合花费从少到多重排下回合顺位,平手保持相对顺序。
        mutatePlayer(first, in: &state) { $0.spent = 5 }
        state.turnsCompletedInRound = state.playerCount
        state.actionsRemaining = 0
        _ = try GameCore.GameRulesEngine.resolveRoundEnd(state: &state, catalog: catalog)
        #expect(state.playerOrder == [second, first])
        #expect(state.players.allSatisfy { $0.spent == 0 })
        #expect(state.activePlayerID == second)
    }

    @Test(arguments: [GameCore.Era.canal, .rail])
    func eraTransitionBatchReplaysAtomicallyAndRejectsEveryTamperedPosition(era: GameCore.Era) throws {
        let catalog = try verifiedCatalog()
        var source = try setup(playerCount: 2, catalog: catalog)
        source.era = era
        source.roundNumber = era == .canal ? source.canalRoundCapacity : source.railRoundCapacity
        source.players.indices.forEach { source.players[$0].incomePosition = 15 }
        let before = source
        let events = try GameCore.GameRulesEngine.resolveRoundEnd(state: &source, catalog: catalog)

        // 运河:roundEnded + eraScored 后进入结算确认,railPrepared 延后到全员确认;
        // 铁路:roundEnded + eraScored + gameEnded。
        #expect(events.count == (era == .canal ? 2 : 3))
        var replayed = before
        try GameCore.GameRulesEngine.replay(events, to: &replayed, catalog: catalog)
        #expect(replayed == source)

        if era == .canal {
            // 逐个确认;最后一家的确认事件携带 railPrepared 并切换时代。
            var confirmEvents: [GameCore.AuthoritativeGameEvent] = []
            for player in before.players.map(\.id) {
                let target = try GameCore.SimpleActionRules.validateEraConfirmation(
                    actorID: player, state: source, catalog: catalog
                )
                confirmEvents.append(try GameCore.GameRulesEngine.resolveEraConfirmation(
                    target, roomID: .init(rawValue: "era-batch"), state: &source, catalog: catalog
                ))
            }
            #expect(source.era == .rail)
            #expect(source.turnPhase == .active)
            #expect(confirmEvents.last?.transitions.contains { transition in
                if case .railPrepared = transition { return true }
                return false
            } == true)
        }

        for index in events.indices {
            var tampered = events
            tampered[index] = events[(index + 1) % events.count]
            var untouched = before
            #expect(throws: GameCore.GameRulesEngine.ReplayError.invalidEvent) {
                try GameCore.GameRulesEngine.replay(tampered, to: &untouched, catalog: catalog)
            }
            #expect(untouched == before)
        }
    }

    @Test func eraScoringCountsEveryHyperedgeAdjacentFlippedIndustryAndKeepsAllLinks() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let owner = state.playerOrder[0]
        let route = try #require(catalog.catalog.board.routes.first { $0.adjacentLocationIDs.count == 3 })
        for (index, locationID) in route.adjacentLocationIDs.enumerated() {
            let location = try #require(catalog.catalog.board.locations.first { $0.id == locationID })
            let industryID = try #require(location.industrySlots.flatMap { $0 }.first { candidate in
                catalog.catalog.industries.first { $0.id == candidate }?.levels.contains { $0.level == 2 } == true
            })
            var value = try placement(
                ownerID: state.playerOrder[index % state.playerCount], industryID: industryID,
                level: 2, placementID: "adjacent-\(index)", locationID: locationID,
                catalog: catalog.catalog
            )
            value.isFlipped = true
            state.boardIndustryPlacements.append(value)
        }
        state.placedLinks = [
            .init(routeID: route.id, ownerID: owner, era: .canal),
            .init(routeID: route.id, ownerID: owner, era: .rail),
        ]
        let expectedLinkPoints = state.boardIndustryPlacements.reduce(0) { total, placement in
            total + (catalog.catalog.industries.first { $0.id == placement.tile.industryDefinitionID }?
                .levels.first { $0.level == placement.tile.level }?.linkPoints ?? 0)
        }

        let event = try GameCore.GameRulesEngine.scoreEra(.canal, state: &state, catalog: catalog)

        let player = try #require(state.players.first { $0.id == owner })
        let ownIndustryPoints = state.boardIndustryPlacements.filter { $0.ownerID == owner }.reduce(0) { total, placement in
            total + (catalog.catalog.industries.first { $0.id == placement.tile.industryDefinitionID }?
                .levels.first { $0.level == placement.tile.level }?.victoryPoints ?? 0)
        }
        // 官方规则:每个时代末"所有"己方连线各计一次分(本场景同一线放了两条,
        // 物理上不可能,但引擎按连线逐条计分 → 线分×2)。
        #expect(player.victoryPoints == expectedLinkPoints * 2 + ownIndustryPoints)
        // 计分函数本身不撤线:运河线待 eraIntermission 确认后的 prepareRailEra 退回。
        #expect(state.placedLinks.map(\.era) == [.canal, .rail])
        guard case .eraScored(let details) = event else {
            Issue.record("expected era scoring event")
            return
        }
        #expect(details.removedRouteIDs.isEmpty)
    }

    @Test func eraScoringCountsAdjacentMerchantTileLinkIcons() throws {
        // RULES.md §10.1：连接图标可来自已翻面的产业和贸易商板块。
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let owner = state.playerOrder[0]
        // 2 人局的 5 个贸易商摆在 gloucester×2 / oxford×2 / shrewsbury×1。
        let route = try #require(catalog.catalog.board.routes.first { $0.id == "gloucester-worcester" })
        let locationBySlotID = Dictionary(uniqueKeysWithValues:
            catalog.catalog.board.merchantSlots.map { ($0.id, $0.locationID) }
        )
        let expectedMerchantPoints = state.merchants.reduce(0) { total, merchant in
            guard locationBySlotID[merchant.slotID] == "gloucester",
                  let definition = catalog.catalog.merchants.first(where: { $0.id == merchant.merchantDefinitionID })
            else { return total }
            return total + definition.linkPoints
        }
        #expect(expectedMerchantPoints > 0)
        #expect(state.boardIndustryPlacements.isEmpty)
        state.placedLinks = [.init(routeID: route.id, ownerID: owner, era: .canal)]

        let event = try GameCore.GameRulesEngine.scoreEra(.canal, state: &state, catalog: catalog)

        let player = try #require(state.players.first { $0.id == owner })
        #expect(player.victoryPoints == expectedMerchantPoints)
        guard case .eraScored(let details) = event else {
            Issue.record("expected era scoring event")
            return
        }
        // 计分函数不撤线;removedRouteIDs 恒空,撤线在确认后的 prepareRailEra。
        #expect(details.removedRouteIDs.isEmpty)
    }

    @Test func pendingForcedSaleRejectsOtherActionsAndIncompletePrefixesWithoutConsumingAHandAction() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let debtor = state.playerOrder[0]
        mutatePlayer(debtor, in: &state) { $0.cash = 0; $0.incomePosition = 0 }
        let first = try placement(
            ownerID: debtor, industryID: "manufacturer", level: 1,
            placementID: "choice-a", catalog: catalog.catalog
        )
        var second = try placement(
            ownerID: debtor, industryID: "manufacturer", level: 1,
            placementID: "choice-b", catalog: catalog.catalog
        )
        let otherLocation = try #require(catalog.catalog.board.locations.first { location in
            location.id != first.locationID && location.industrySlots.contains { $0.contains("manufacturer") }
        })
        second.locationID = otherLocation.id
        second.slotIndex = try #require(otherLocation.industrySlots.firstIndex { $0.contains("manufacturer") })
        state.boardIndustryPlacements = [first, second]
        _ = try GameCore.GameRulesEngine.resolveRoundEnd(state: &state, catalog: catalog)
        let roomID = GameCore.RoomID(rawValue: "forced-sale-room")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        var engine = try state.makeHostEngine(roomID: roomID, reconnectTokens: tokens, protocolVersion: 1)
        let handBefore = try #require(engine.gameState.players.first { $0.id == debtor }) .hand
        let actionsBefore = engine.gameState.actionsRemaining

        let ordinary = engine.submit(.init(
            protocolVersion: 1, rulesetVersion: engine.rulesetVersion, roomID: roomID,
            senderID: debtor, reconnectToken: try #require(tokens[debtor]),
            baseVersion: engine.gameState.authoritativeVersion,
            payload: .pass(.init(cardID: try #require(handBefore.first).id))
        ), catalog: catalog)
        #expect(ordinary == .rejected(.init(
            reasonCode: .invalidAction,
            recoverySuggestion: "Refresh the authoritative state and choose a legal action target."
        )))

        let incomplete = engine.submit(.init(
            protocolVersion: 1, rulesetVersion: engine.rulesetVersion, roomID: roomID,
            senderID: debtor, reconnectToken: try #require(tokens[debtor]),
            baseVersion: engine.gameState.authoritativeVersion,
            payload: .forcedSale(.init(placementIDs: [first.placementID]))
        ), catalog: catalog)
        guard case .rejected(let rejection) = incomplete else {
            Issue.record("an incomplete forced-sale prefix must be rejected")
            return
        }
        #expect(rejection.reasonCode == .invalidAction)

        let accepted = engine.submit(.init(
            protocolVersion: 1, rulesetVersion: engine.rulesetVersion, roomID: roomID,
            senderID: debtor, reconnectToken: try #require(tokens[debtor]),
            baseVersion: engine.gameState.authoritativeVersion,
            payload: .forcedSale(.init(placementIDs: [second.placementID, first.placementID]))
        ), catalog: catalog)
        guard case .accepted(let event) = accepted else {
            Issue.record("selling every eligible tile must resolve the remaining amount as VP debt")
            return
        }
        #expect(event.previousVersion.rawValue + 1 == event.version.rawValue)
        #expect(engine.gameState.actionsRemaining == actionsBefore || engine.gameState.roundNumber > state.roundNumber)
        #expect(engine.gameState.players.first { $0.id == debtor }?.hand == handBefore)
        #expect(try JSONDecoder().decode(
            GameCore.AuthoritativeGameEvent.self, from: JSONEncoder().encode(event)
        ) == event)
        #expect(try JSONDecoder().decode(
            GameCore.GameState.self, from: JSONEncoder().encode(engine.gameState)
        ) == engine.gameState)
    }

    @Test func forcedSaleLegalQueryPreservesLowThenHighClickOrderDespiteLexicographicOrder() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let debtor = state.playerOrder[0]
        var firstCandidate = try placement(
            ownerID: debtor, industryID: "brewery", level: 2,
            placementID: "candidate-one", catalog: catalog.catalog
        )
        var secondCandidate = try placement(
            ownerID: debtor, industryID: "manufacturer", level: 1,
            placementID: "candidate-two", catalog: catalog.catalog
        )
        let otherLocation = try #require(catalog.catalog.board.locations.first {
            $0.id != firstCandidate.locationID && $0.industrySlots.contains { $0.contains("manufacturer") }
        })
        secondCandidate.locationID = otherLocation.id
        secondCandidate.slotIndex = try #require(otherLocation.industrySlots.firstIndex { $0.contains("manufacturer") })
        let firstValue = try #require(GameCore.TurnRules.liquidationValue(of: firstCandidate, catalog: catalog.catalog))
        let secondValue = try #require(GameCore.TurnRules.liquidationValue(of: secondCandidate, catalog: catalog.catalog))
        var low = firstValue < secondValue ? firstCandidate : secondCandidate
        var high = firstValue < secondValue ? secondCandidate : firstCandidate
        low.placementID = "z-low"
        high.placementID = "a-high"
        state.boardIndustryPlacements = [high, low]
        let highValue = try #require(GameCore.TurnRules.liquidationValue(of: high, catalog: catalog.catalog))
        let lowValue = try #require(GameCore.TurnRules.liquidationValue(of: low, catalog: catalog.catalog))
        #expect(highValue > lowValue)
        state.activePlayerID = debtor
        state.turnPhase = .forcedSale(.init(
            playerID: debtor, shortfall: highValue + lowValue,
            eligiblePlacementIDs: ["a-high", "z-low"]
        ))

        let first = try GameCore.LegalActionQueryEngine.respond(
            to: .init(
                requestID: "forced-1", baseVersion: state.authoritativeVersion,
                draft: .init(action: .forcedSale, cardID: nil, selections: [.industryPlacement(id: "z-low")])
            ), actorID: debtor, state: state, catalog: catalog
        )
        #expect(first.nextChoices.map(\.value) == [.industryPlacement(id: "a-high")])
        #expect(first.completePayload == nil)

        let complete = try GameCore.LegalActionQueryEngine.respond(
            to: .init(
                requestID: "forced-2", baseVersion: state.authoritativeVersion,
                draft: .init(action: .forcedSale, cardID: nil, selections: [
                    .industryPlacement(id: "z-low"), .industryPlacement(id: "a-high"),
                ])
            ), actorID: debtor, state: state, catalog: catalog
        )
        #expect(complete.completePayload == .forcedSale(.init(placementIDs: ["z-low", "a-high"])))
    }

    @Test func canalPreparationPreservesMarketsRefillsMerchantsRedealsAndPreservesLongLivedState() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 3, catalog: catalog)
        let owner = state.playerOrder[0]
        var levelOne = try placement(ownerID: owner, industryID: "brewery", level: 1, placementID: "level-1", catalog: catalog.catalog)
        levelOne.resourceCount = 1
        var levelTwo = try placement(ownerID: owner, industryID: "manufacturer", level: 2, placementID: "level-2", catalog: catalog.catalog)
        levelTwo.isFlipped = true
        state.boardIndustryPlacements += [levelOne, levelTwo]
        state.coalMarket.slots.indices.forEach { state.coalMarket.slots[$0].hasCube = false }
        state.ironMarket.slots.indices.forEach { state.ironMarket.slots[$0].hasCube = false }
        state.publicSupply.coal = 30
        state.publicSupply.iron = 18
        let merchantsByID = Dictionary(uniqueKeysWithValues: catalog.catalog.merchants.map { ($0.id, $0) })
        for index in state.merchants.indices where state.merchants[index].hasBeer {
            state.merchants[index].hasBeer = false
            state.publicSupply.beer += 1
        }
        let refillCount = state.merchants.filter {
            merchantsByID[$0.merchantDefinitionID]?.acceptedIndustryIDs.isEmpty == false
        }.count
        let coalBefore = state.coalMarket
        let ironBefore = state.ironMarket
        let activeCardIDsBefore = Set(
            state.players.flatMap(\.hand).map(\.id)
                + state.players.compactMap(\.privateBottomDiscard).map(\.id)
                + state.standardDrawDeck.map(\.id)
                + state.publicDiscard.map(\.id)
        )
        let beerBefore = state.publicSupply.beer
        mutatePlayer(owner, in: &state) { $0.cash = 41; $0.incomePosition = 19; $0.victoryPoints = 12 }
        // 运河连线计分后撤下并退回主人:先各放 1 条线并扣减余量,过渡后应清空并回补。
        let otherOwner = try #require(state.playerOrder.dropFirst().first)
        let canalRoutes = catalog.catalog.board.routes.filter {
            $0.eras.contains(.canal) && $0.playerCounts.contains(3)
        }
        let ownerRoute = try #require(canalRoutes.first)
        let otherRoute = try #require(canalRoutes.dropFirst().first)
        state.placedLinks.append(.init(routeID: ownerRoute.id, ownerID: owner, era: .canal))
        state.placedLinks.append(.init(routeID: otherRoute.id, ownerID: otherOwner, era: .canal))
        mutatePlayer(owner, in: &state) { $0.linksRemaining = 13 }
        mutatePlayer(otherOwner, in: &state) { $0.linksRemaining = 12 }

        let event = try GameCore.GameRulesEngine.prepareRailEra(state: &state, catalog: catalog)

        let preserved = try #require(state.players.first { $0.id == owner })
        #expect(state.era == .rail)
        #expect(state.boardIndustryPlacements.map(\.placementID) == ["level-2"])
        #expect(state.placedLinks.isEmpty)
        // 官方规则:连线片撤下退回主人,余量回补(不超过 14)。
        #expect(preserved.linksRemaining == 14)
        let otherPreserved = try #require(state.players.first { $0.id == otherOwner })
        #expect(otherPreserved.linksRemaining == 13)
        #expect(state.coalMarket == coalBefore)
        #expect(state.ironMarket == ironBefore)
        #expect(state.merchants.allSatisfy {
            merchantsByID[$0.merchantDefinitionID]?.acceptedIndustryIDs.isEmpty == true || $0.hasBeer
        })
        #expect(state.publicSupply.beer == min(15, beerBefore + 1) - refillCount)
        #expect(state.players.allSatisfy { $0.hand.count == 8 })
        #expect(state.players.allSatisfy { $0.privateBottomDiscard == nil })
        #expect(Set(state.players.flatMap(\.hand).map(\.id) + state.standardDrawDeck.map(\.id)) == activeCardIDsBefore)
        #expect(state.publicDiscard.isEmpty)
        #expect(preserved.cash == 41 && preserved.incomePosition == 19 && preserved.victoryPoints == 12)
        // 官方规则:被移除的一级板块退回游戏盒(移出游戏),垫板块堆保持不变。
        let originalStacks = try setup(playerCount: 3, catalog: catalog).players.first { $0.id == owner }?.industryStacks
        #expect(preserved.industryStacks == originalStacks)
        guard case .railPrepared(let details) = event else {
            Issue.record("expected rail event")
            return
        }
        #expect(details.removedPlacementIDs == ["level-1"])
    }

    @Test(arguments: [2, 3, 4])
    func railRedealUsesExactlyTheLegalCanalCardComposition(playerCount: Int) throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: playerCount, catalog: catalog)
        state.publicDiscard.append(contentsOf: state.standardDrawDeck.prefix(playerCount))
        state.standardDrawDeck.removeFirst(playerCount)
        let expected = state.players.flatMap(\.hand)
            + state.players.compactMap(\.privateBottomDiscard)
            + state.standardDrawDeck + state.publicDiscard
        #expect(expected.count == [2: 40, 3: 54, 4: 64][playerCount])

        _ = try GameCore.GameRulesEngine.prepareRailEra(state: &state, catalog: catalog)

        let actual = state.players.flatMap(\.hand) + state.standardDrawDeck + state.publicDiscard
        #expect(actual.map(\.id).sorted() == expected.map(\.id).sorted())
        #expect(actual.map(\.definitionID).sorted() == expected.map(\.definitionID).sorted())
        #expect(state.players.allSatisfy { $0.hand.count == 8 })
        #expect(state.players.allSatisfy { $0.privateBottomDiscard == nil })
        #expect(state.publicDiscard.isEmpty)
        #expect(GameCore.GameStateAuthorityValidator.isValid(state, catalog: catalog))

        var malformedRail = state
        malformedRail.players[0].privateBottomDiscard = malformedRail.standardDrawDeck.removeFirst()
        #expect(GameCore.GameStateAuthorityValidator.isValid(malformedRail, catalog: catalog) == false)
    }

    @Test func finalRailScoringRepeatsPreservedLevelTwoAwardsNoIncomeAndResolvesAllWinnerTies() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 4, catalog: catalog)
        state.era = .rail
        state.roundNumber = state.railRoundCapacity
        let order = state.playerOrder
        mutatePlayer(order[0], in: &state) { $0.victoryPoints = 20; $0.incomePosition = 12; $0.cash = 5 }
        mutatePlayer(order[1], in: &state) { $0.victoryPoints = 20; $0.incomePosition = 11; $0.cash = 99 }
        mutatePlayer(order[2], in: &state) { $0.victoryPoints = 20; $0.incomePosition = 12; $0.cash = 4 }
        mutatePlayer(order[3], in: &state) { $0.victoryPoints = 20; $0.incomePosition = 12; $0.cash = 5 }
        let cashBefore = Dictionary(uniqueKeysWithValues: state.players.map { ($0.id, $0.cash) })

        let scoring = try GameCore.GameRulesEngine.scoreEra(.rail, state: &state, catalog: catalog)
        let ended = try GameCore.GameRulesEngine.resolveWinner(state: &state)

        #expect(cashBefore == Dictionary(uniqueKeysWithValues: state.players.map { ($0.id, $0.cash) }))
        #expect(state.turnPhase == .ended)
        guard case .eraScored = scoring, case .gameEnded(let details) = ended else {
            Issue.record("expected final scoring and game end events")
            return
        }
        #expect(details.standings == [[order[0], order[3]], [order[2]], [order[1]]])

        let roomID = GameCore.RoomID(rawValue: "ended-room")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        var engine = try state.makeHostEngine(roomID: roomID, reconnectTokens: tokens, protocolVersion: 1)
        let winner = try #require(state.activePlayerID)
        let card = try #require(state.players.first { $0.id == winner }?.hand.first)
        let rejected = engine.submit(.init(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion, roomID: roomID,
            senderID: winner, reconnectToken: try #require(tokens[winner]),
            baseVersion: state.authoritativeVersion, payload: .pass(.init(cardID: card.id))
        ), catalog: catalog)
        guard case .rejected(let rejection) = rejected else {
            Issue.record("an ended game must reject ordinary actions")
            return
        }
        #expect(rejection.reasonCode == .invalidAction)
    }

    @Test func winnerFloorsVictoryPointDebtAtZero() throws {
        // RULES.md §6.3：每缺 £1 失去 1 VP，VP 最低降到 0。
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let debtor = state.playerOrder[0]
        let clean = state.playerOrder[1]
        mutatePlayer(debtor, in: &state) { $0.victoryPoints = 0; $0.victoryPointDebt = 5 }
        mutatePlayer(clean, in: &state) { $0.victoryPoints = 0 }

        let event = try GameCore.GameRulesEngine.resolveWinner(state: &state)

        guard case .gameEnded(let details) = event else {
            Issue.record("expected game end event")
            return
        }
        // 债务不得把有效 VP 压到 0 以下：两人应并列，而不是债务人垫底。
        #expect(details.standings.count == 1)
        #expect(Set(details.standings[0]) == Set([debtor, clean]))
    }

    @Test func forcedSaleQueryCompletesWhenEverythingIsSoldButProceedsFallShort() throws {
        // RULES.md §6.3：全卖仍不足时差额转 VP 债。这条合法路径必须产出可提交意图，
        // 否则负债人会卡死在选择界面并暂停整局。
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let debtor = state.playerOrder[0]
        let first = try placement(
            ownerID: debtor, industryID: "manufacturer", level: 1,
            placementID: "short-a", catalog: catalog.catalog
        )
        var second = try placement(
            ownerID: debtor, industryID: "manufacturer", level: 1,
            placementID: "short-b", catalog: catalog.catalog
        )
        let otherLocation = try #require(catalog.catalog.board.locations.first { location in
            location.id != first.locationID && location.industrySlots.contains {
                $0.contains("manufacturer")
            }
        })
        second.locationID = otherLocation.id
        second.slotIndex = try #require(otherLocation.industrySlots.firstIndex {
            $0.contains("manufacturer")
        })
        state.boardIndustryPlacements = [first, second]
        // 制造厂一级清算价 £4/块，两块 £8 < £10：全卖也补不上缺口。
        state.turnPhase = .forcedSale(.init(
            playerID: debtor, shortfall: 10,
            eligiblePlacementIDs: ["short-a", "short-b"]
        ))

        let complete = try GameCore.LegalActionQueryEngine.respond(
            to: .init(requestID: "short-all", baseVersion: state.authoritativeVersion,
                      draft: .init(action: .forcedSale, cardID: nil, selections: [
                        .industryPlacement(id: "short-a"), .industryPlacement(id: "short-b"),
                      ])),
            actorID: debtor, state: state, catalog: catalog
        )
        guard case .forcedSale(let intent) = complete.completePayload else {
            Issue.record("selling everything must complete even when proceeds fall short")
            return
        }
        #expect(intent.placementIDs == ["short-a", "short-b"])

        let partial = try GameCore.LegalActionQueryEngine.respond(
            to: .init(requestID: "short-one", baseVersion: state.authoritativeVersion,
                      draft: .init(action: .forcedSale, cardID: nil,
                                   selections: [.industryPlacement(id: "short-a")])),
            actorID: debtor, state: state, catalog: catalog
        )
        #expect(partial.completePayload == nil)
        #expect(partial.nextChoices.isEmpty == false)
    }

    @Test func pendingPhasePersistsInHostArchiveAndLegacyStateDefaultsNewFields() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let debtor = state.playerOrder[0]
        mutatePlayer(debtor, in: &state) { $0.cash = 0; $0.incomePosition = 0 }
        state.boardIndustryPlacements = [try placement(
            ownerID: debtor, industryID: "manufacturer", level: 1,
            placementID: "persisted-choice", catalog: catalog.catalog
        )]
        _ = try GameCore.GameRulesEngine.resolveRoundEnd(state: &state, catalog: catalog)
        let roomID = GameCore.RoomID(rawValue: "persisted-pending-room")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        let engine = try state.makeHostEngine(roomID: roomID, reconnectTokens: tokens, protocolVersion: 1)
        let archive = SessionArchive.host(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion,
            recipientID: debtor, state: engine.state, gameState: state,
            eventWindows: [:],
            tokenReferences: state.players.map { .init(roomID: roomID, playerID: $0.id) },
            peersNeedingRecovery: [], commitSequence: 1
        )
        let envelope = try SnapshotEnvelope(archive: archive)
        let restored = try JSONDecoder().decode(
            SnapshotEnvelope.self, from: JSONEncoder.canonical.encode(envelope)
        )
        guard case .host(let host) = restored.archive.payload else {
            Issue.record("expected host archive")
            return
        }
        #expect(host.gameState?.turnPhase == state.turnPhase)
        #expect(host.gameState?.roundIncomeCursor == state.roundIncomeCursor)

        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(try setup(playerCount: 2, catalog: catalog))
        ) as? [String: Any])
        object.removeValue(forKey: "turnPhase")
        object.removeValue(forKey: "roundIncomeCursor")
        if var players = object["players"] as? [[String: Any]] {
            for index in players.indices { players[index].removeValue(forKey: "victoryPointDebt") }
            object["players"] = players
        }
        let legacy = try JSONDecoder().decode(
            GameCore.GameState.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
        #expect(legacy.turnPhase == .active)
        #expect(legacy.roundIncomeCursor == nil)
        #expect(legacy.players.allSatisfy { $0.victoryPointDebt == 0 })
    }

    @Test func forcedSaleProjectionIsVisibleOnlyToTheDebtorAndSurvivesGuestArchiveRoundTrip() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let debtor = state.playerOrder[0]
        let observer = state.playerOrder[1]
        mutatePlayer(debtor, in: &state) { $0.cash = 0; $0.incomePosition = 0 }
        state.boardIndustryPlacements = [
            try placement(ownerID: debtor, industryID: "manufacturer", level: 1, placementID: "z-sale", catalog: catalog.catalog),
            try placement(ownerID: debtor, industryID: "brewery", level: 2, placementID: "a-sale", catalog: catalog.catalog),
        ]
        _ = try GameCore.GameRulesEngine.resolveRoundEnd(state: &state, catalog: catalog)
        let roomID = GameCore.RoomID(rawValue: "projection-room")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        let engine = try state.makeHostEngine(roomID: roomID, reconnectTokens: tokens, protocolVersion: 1)

        let debtorSnapshot = try engine.snapshot(for: debtor)
        let observerSnapshot = try engine.snapshot(for: observer)
        #expect(debtorSnapshot.forcedSale == .init(shortfall: 10, eligiblePlacementIDs: ["a-sale", "z-sale"]))
        #expect(observerSnapshot.forcedSale == nil)

        let pending = try #require({
            if case .forcedSale(let value) = state.turnPhase { return value }
            return nil
        }())
        let event = GameCore.AuthoritativeGameEvent(
            roomID: roomID, actor: debtor,
            previousVersion: .init(rawValue: state.authoritativeVersion.rawValue - 1),
            version: state.authoritativeVersion, actionNumber: state.actionNumber,
            payload: .forcedSaleResolved(.init(placementIDs: [])),
            transitions: [.forcedSaleRequired(pending)]
        )
        let debtorEvent = try engine.clientEvent(event, for: debtor)
        let observerEvent = try engine.clientEvent(event, for: observer)
        #expect(debtorEvent.event.transitions == [.forcedSaleRequired(pending)])
        #expect(observerEvent.event.transitions == [.forcedSaleRequiredMarker(debtor)])
        let observerBytes = try JSONEncoder.canonical.encode(observerEvent)
        #expect(observerBytes.contains(Data("shortfall".utf8)) == false)
        for placementID in pending.eligiblePlacementIDs {
            #expect(observerBytes.contains(Data(placementID.utf8)) == false)
        }

        let archive = SessionArchive.guest(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion,
            hostPlayerID: observer, snapshot: debtorSnapshot,
            eventWindow: [], tokenReference: .init(roomID: roomID, playerID: debtor),
            commitSequence: 1
        )
        let restored = try JSONDecoder().decode(
            SessionArchive.self, from: JSONEncoder.canonical.encode(archive)
        )
        guard case .guest(let guest) = restored.payload else {
            Issue.record("expected guest archive")
            return
        }
        #expect(guest.snapshot.forcedSale == debtorSnapshot.forcedSale)
    }

    @Test func authorityRejectsRoundOverflowCardLossAndIncompleteOrUnsortedForcedSaleEligibility() throws {
        let catalog = try verifiedCatalog()
        let valid = try setup(playerCount: 2, catalog: catalog)
        #expect(GameCore.GameStateAuthorityValidator.isValid(valid, catalog: catalog))

        var roundOverflow = valid
        roundOverflow.roundNumber = roundOverflow.canalRoundCapacity + 1
        #expect(GameCore.GameStateAuthorityValidator.isValid(roundOverflow, catalog: catalog) == false)

        var missingCard = valid
        missingCard.players[0].hand.removeFirst()
        #expect(GameCore.GameStateAuthorityValidator.isValid(missingCard, catalog: catalog) == false)

        var wrongActiveSeat = valid
        wrongActiveSeat.activePlayerID = wrongActiveSeat.playerOrder[1]
        #expect(GameCore.GameStateAuthorityValidator.isValid(wrongActiveSeat, catalog: catalog) == false)

        var wrongFirstCanalBudget = valid
        wrongFirstCanalBudget.actionsRemaining = 2
        #expect(GameCore.GameStateAuthorityValidator.isValid(wrongFirstCanalBudget, catalog: catalog) == false)

        var pending = valid
        let debtor = pending.playerOrder[0]
        pending.boardIndustryPlacements = [
            try placement(ownerID: debtor, industryID: "manufacturer", level: 1, placementID: "z-sale", catalog: catalog.catalog),
            try placement(ownerID: debtor, industryID: "brewery", level: 2, placementID: "a-sale", catalog: catalog.catalog),
        ]
        pending.actionsRemaining = 0
        pending.activePlayerID = debtor
        pending.roundIncomeCursor = 1
        pending.turnPhase = .forcedSale(.init(
            playerID: debtor, shortfall: 1, eligiblePlacementIDs: ["a-sale"]
        ))
        #expect(GameCore.GameStateAuthorityValidator.isValid(pending, catalog: catalog) == false)
        pending.turnPhase = .forcedSale(.init(
            playerID: debtor, shortfall: 1, eligiblePlacementIDs: ["z-sale", "a-sale"]
        ))
        #expect(GameCore.GameStateAuthorityValidator.isValid(pending, catalog: catalog) == false)
        pending.turnPhase = .forcedSale(.init(
            playerID: debtor, shortfall: 1, eligiblePlacementIDs: ["a-sale", "z-sale"]
        ))
        #expect(GameCore.GameStateAuthorityValidator.isValid(pending, catalog: catalog))
        var wrongCursor = pending
        wrongCursor.roundIncomeCursor = 0
        #expect(GameCore.GameStateAuthorityValidator.isValid(wrongCursor, catalog: catalog) == false)
        wrongCursor = pending
        wrongCursor.roundIncomeCursor = 2
        #expect(GameCore.GameStateAuthorityValidator.isValid(wrongCursor, catalog: catalog) == false)
        var wrongTurnCount = pending
        wrongTurnCount.turnsCompletedInRound = 1
        #expect(GameCore.GameStateAuthorityValidator.isValid(wrongTurnCount, catalog: catalog) == false)
    }

    @Test func cardLossStateRejectsAnyLivePassOrBuildWithoutMutatingAuthority() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let actorIndex = try #require(state.players.firstIndex { $0.id == actor })
        let passCard = try #require(state.players[actorIndex].hand.first)
        state.standardDrawDeck.removeLast()
        let before = state
        let roomID = GameCore.RoomID(rawValue: "card-loss-room")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        var engine = try state.makeHostEngine(roomID: roomID, reconnectTokens: tokens, protocolVersion: 1)

        let result = engine.submit(.init(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion,
            roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
            baseVersion: state.authoritativeVersion, payload: .pass(.init(cardID: passCard.id))
        ), catalog: catalog)

        #expect(result == .internalFailure(.init(code: .invalidAuthorityState)))
        #expect(engine.gameState == before)

        let buildResult = engine.submit(.init(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion,
            roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
            baseVersion: state.authoritativeVersion,
            payload: .build(.init(
                cardID: passCard.id, locationID: "dudley",
                industryDefinitionID: "coal-mine", slotIndex: 0,
                resourceSources: []
            ))
        ), catalog: catalog)

        #expect(buildResult == .internalFailure(.init(code: .invalidAuthorityState)))
        #expect(engine.gameState == before)

        var malformedPhase = try setup(playerCount: 2, catalog: catalog)
        malformedPhase.activePlayerID = malformedPhase.playerOrder[1]
        let malformedActor = malformedPhase.playerOrder[1]
        let malformedCard = try #require(
            malformedPhase.players.first { $0.id == malformedActor }?.hand.first
        )
        var malformedHost = try malformedPhase.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 1
        )
        let malformedBefore = malformedHost.gameState
        let malformedResult = malformedHost.submit(.init(
            protocolVersion: 1, rulesetVersion: malformedPhase.rulesetVersion,
            roomID: roomID, senderID: malformedActor, reconnectToken: tokens[malformedActor]!,
            baseVersion: malformedPhase.authoritativeVersion,
            payload: .pass(.init(cardID: malformedCard.id))
        ), catalog: catalog)
        #expect(malformedResult == .internalFailure(.init(code: .invalidAuthorityState)))
        #expect(malformedHost.gameState == malformedBefore)
    }

    @Test func renamedCardInstanceRejectsAuthorityAndLivePassOrBuildAtomically() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let actorIndex = try #require(state.players.firstIndex { $0.id == actor })
        let original = try #require(state.players[actorIndex].hand.first)
        let renamed = GameCore.CardInstance(
            id: "forged-instance-id", definitionID: original.definitionID
        )
        state.players[actorIndex].hand[0] = renamed
        #expect(GameCore.GameStateAuthorityValidator.isValid(state, catalog: catalog) == false)

        let roomID = GameCore.RoomID(rawValue: "renamed-card-room")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        var host = try state.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 1
        )
        let before = host.gameState
        func intent(_ payload: GameCore.PlayerIntent.Payload) -> GameCore.PlayerIntent {
            .init(
                protocolVersion: 1, rulesetVersion: state.rulesetVersion,
                roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
                baseVersion: state.authoritativeVersion, payload: payload
            )
        }

        #expect(host.submit(intent(.pass(.init(cardID: renamed.id))), catalog: catalog)
            == .internalFailure(.init(code: .invalidAuthorityState)))
        #expect(host.gameState == before)
        #expect(host.submit(intent(.build(.init(
            cardID: renamed.id, locationID: "dudley",
            industryDefinitionID: "coal-mine", slotIndex: 0, resourceSources: []
        ))), catalog: catalog) == .internalFailure(.init(code: .invalidAuthorityState)))
        #expect(host.gameState == before)
    }

    @Test func roundIncomeCashOverflowIsInternalAndLeavesHostAuthorityUnchanged() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let actor = state.playerOrder.last!
        let actorIndex = try #require(state.players.firstIndex { $0.id == actor })
        state.activePlayerID = actor
        state.turnsCompletedInRound = state.playerCount - 1
        state.actionsRemaining = 1
        state.players[actorIndex].cash = Int.max
        state.players[actorIndex].incomePosition = 15
        let card = try #require(state.players[actorIndex].hand.first)
        let roomID = GameCore.RoomID(rawValue: "income-overflow")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        var host = try state.makeHostEngine(roomID: roomID, reconnectTokens: tokens, protocolVersion: 1)
        let before = host.gameState

        let passResult = host.submit(.init(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion, roomID: roomID,
            senderID: actor, reconnectToken: tokens[actor]!,
            baseVersion: state.authoritativeVersion, payload: .pass(.init(cardID: card.id))
        ), catalog: catalog)
        guard case .accepted = passResult else {
            Issue.record("final pass should be accepted, got \(passResult)")
            return
        }
        #expect(host.gameState.turnPhase == .awaitingTurnEndConfirmation)
        let afterPass = host.gameState

        // 回合末结算随过轮确认发生;溢出必须表现为内部失败且不破坏权威状态。
        let confirmResult = host.submit(.init(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion, roomID: roomID,
            senderID: actor, reconnectToken: tokens[actor]!,
            baseVersion: host.gameState.authoritativeVersion, payload: .confirmTurnEnd
        ), catalog: catalog)
        #expect(confirmResult == .internalFailure(.init(code: .arithmeticOverflow)))
        #expect(host.gameState == afterPass)
    }

    @Test func eraVictoryPointOverflowIsInternalAndLeavesHostAuthorityUnchanged() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let actor = state.playerOrder.last!
        let actorIndex = try #require(state.players.firstIndex { $0.id == actor })
        state.activePlayerID = actor
        state.roundNumber = state.canalRoundCapacity
        state.turnsCompletedInRound = state.playerCount - 1
        state.actionsRemaining = 1
        state.players.indices.forEach { state.players[$0].incomePosition = 10 }
        state.players[actorIndex].victoryPoints = Int.max
        var scored = try placement(
            ownerID: actor, industryID: "manufacturer", level: 2,
            placementID: "vp-overflow", catalog: catalog.catalog
        )
        scored.isFlipped = true
        state.boardIndustryPlacements = [scored]
        let card = try #require(state.players[actorIndex].hand.first)
        let roomID = GameCore.RoomID(rawValue: "vp-overflow")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        var host = try state.makeHostEngine(roomID: roomID, reconnectTokens: tokens, protocolVersion: 1)
        let before = host.gameState

        let passResult = host.submit(.init(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion, roomID: roomID,
            senderID: actor, reconnectToken: tokens[actor]!,
            baseVersion: state.authoritativeVersion, payload: .pass(.init(cardID: card.id))
        ), catalog: catalog)
        guard case .accepted = passResult else {
            Issue.record("final pass should be accepted, got \(passResult)")
            return
        }
        #expect(host.gameState.turnPhase == .awaitingTurnEndConfirmation)
        let afterPass = host.gameState

        // 回合末结算随过轮确认发生;溢出必须表现为内部失败且不破坏权威状态。
        let confirmResult = host.submit(.init(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion, roomID: roomID,
            senderID: actor, reconnectToken: tokens[actor]!,
            baseVersion: host.gameState.authoritativeVersion, payload: .confirmTurnEnd
        ), catalog: catalog)
        #expect(confirmResult == .internalFailure(.init(code: .arithmeticOverflow)))
        #expect(host.gameState == afterPass)
    }

    @Test(arguments: [GameCore.Era.canal, .rail])
    func finalSeatActionAtomicallyCarriesReplayableEraTransitionsAndRailSkipsIncome(era: GameCore.Era) throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        state.era = era
        if era == .rail {
            for index in state.players.indices {
                if let bottom = state.players[index].privateBottomDiscard {
                    state.standardDrawDeck.append(bottom)
                    state.players[index].privateBottomDiscard = nil
                }
            }
        }
        state.roundNumber = era == .canal ? state.canalRoundCapacity : state.railRoundCapacity
        state.actionsRemaining = 1
        state.turnsCompletedInRound = state.playerCount - 1
        state.activePlayerID = state.playerOrder.last
        for index in state.players.indices {
            state.players[index].cash = 20
            state.players[index].incomePosition = 15
        }
        let cashBefore = Dictionary(uniqueKeysWithValues: state.players.map { ($0.id, $0.cash) })
        let roomID = GameCore.RoomID(rawValue: "atomic-\(era.rawValue)")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        var engine = try state.makeHostEngine(roomID: roomID, reconnectTokens: tokens, protocolVersion: 1)
        let actor = try #require(state.activePlayerID)
        let card = try #require(state.players.first { $0.id == actor }?.hand.first)

        let passResult = engine.submit(.init(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion, roomID: roomID,
            senderID: actor, reconnectToken: try #require(tokens[actor]),
            baseVersion: state.authoritativeVersion, payload: .pass(.init(cardID: card.id))
        ), catalog: catalog)
        guard case .accepted = passResult else {
            Issue.record("the final seat action should be accepted, got \(passResult)")
            return
        }
        // 新流程:最后一家行动落地后停在待确认,回合末结算随确认事件原子发生。
        #expect(engine.gameState.turnPhase == .awaitingTurnEndConfirmation)
        let afterPass = engine.gameState
        let confirmResult = engine.submit(.init(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion, roomID: roomID,
            senderID: actor, reconnectToken: try #require(tokens[actor]),
            baseVersion: engine.gameState.authoritativeVersion, payload: .confirmTurnEnd
        ), catalog: catalog)
        guard case .accepted(let event) = confirmResult else {
            Issue.record("the final seat confirm should settle the \(era) era atomically, got \(confirmResult)")
            return
        }
        #expect(event.transitions.contains { if case .roundEnded = $0 { true } else { false } })
        #expect(event.transitions.contains { if case .eraScored = $0 { true } else { false } })
        let postEventState = engine.gameState
        if era == .canal {
            #expect(engine.gameState.era == .canal)
            guard case .eraIntermission(let intermission) = engine.gameState.turnPhase else {
                Issue.record("canal end should pause at the era intermission, got \(engine.gameState.turnPhase)")
                return
            }
            #expect(intermission.awards.count == state.players.count)
            // 标准局运河末回合不是游戏最后一回合:照常发收入
            //(夹具 incomePosition 15 = £3,现金 20 → 23),不得提前跳过。
            #expect(Dictionary(uniqueKeysWithValues: engine.gameState.players.map { ($0.id, $0.cash) })
                == Dictionary(uniqueKeysWithValues: state.players.map { ($0.id, 23) }))
            #expect(event.transitions.contains { if case .shortCanalScored = $0 { true } else { false } } == false)
            // 全员确认后进入铁路时代;最后一家的确认事件携带 railPrepared。
            var lastConfirmEvent: GameCore.AuthoritativeGameEvent?
            for player in state.players.map(\.id) {
                let confirmResult = engine.submit(.init(
                    protocolVersion: 1, rulesetVersion: state.rulesetVersion, roomID: roomID,
                    senderID: player, reconnectToken: try #require(tokens[player]),
                    baseVersion: engine.gameState.authoritativeVersion,
                    payload: .confirmEraIntermission
                ), catalog: catalog)
                guard case .accepted(let confirmEvent) = confirmResult else {
                    Issue.record("era confirmation rejected for \(player.rawValue): \(confirmResult)")
                    return
                }
                lastConfirmEvent = confirmEvent
            }
            #expect(engine.gameState.era == .rail)
            #expect(engine.gameState.turnPhase == .active)
            #expect(lastConfirmEvent?.transitions.contains { if case .railPrepared = $0 { true } else { false } } == true)
        } else {
            #expect(event.transitions.contains { if case .gameEnded = $0 { true } else { false } })
            #expect(engine.gameState.turnPhase == .ended)
            #expect(Dictionary(uniqueKeysWithValues: engine.gameState.players.map { ($0.id, $0.cash) }) == cashBefore)
        }
        var replayed = afterPass
        try GameCore.GameRulesEngine.replay(
            event, expectedRoomID: roomID, to: &replayed, catalog: catalog
        )
        #expect(replayed == postEventState)
    }

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

    @Test func eraPreparationFailsClosedWhenALinkHasNoOwner() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let owner = state.playerOrder[0]
        state.placedLinks = [
            .init(routeID: "birmingham-coventry", ownerID: owner, era: .canal),
            .init(routeID: "birmingham-coventry", ownerID: .init(rawValue: "ghost"), era: .canal),
        ]
        mutatePlayer(owner, in: &state) { $0.linksRemaining = 13 }

        // 合法对局的线都有主人;孤儿线让时代准备整体失败,而不是被静默跳过后清空。
        #expect(throws: GameCore.ScoringRuleError.missingDefinition) {
            _ = try GameCore.GameRulesEngine.prepareRailEra(state: &state, catalog: catalog)
        }
        // 抛错时撤线尚未发生:线还在,余量未加。
        #expect(state.placedLinks.count == 2)
        #expect(state.players.first { $0.id == owner }?.linksRemaining == 13)
        #expect(state.era == .canal)
    }

    private func setup(playerCount: Int, catalog: GameCore.VerifiedGameDataCatalog) throws -> GameCore.GameState {
        var rules = GameCore.SetupRules(seed: UInt64(9_000 + playerCount))
        return try rules.makeGame(
            catalog: catalog,
            playerIDs: (1...playerCount).map { .init(rawValue: "p\($0)") }
        ).state
    }

    private func setSpent(_ amount: Int, for playerID: GameCore.PlayerID, in state: inout GameCore.GameState) {
        mutatePlayer(playerID, in: &state) { $0.spent = amount }
    }

    private func mutatePlayer(
        _ playerID: GameCore.PlayerID,
        in state: inout GameCore.GameState,
        _ mutation: (inout GameCore.SetupPlayer) -> Void
    ) {
        guard let index = state.players.firstIndex(where: { $0.id == playerID }) else { return }
        mutation(&state.players[index])
    }

    private func placement(
        ownerID: GameCore.PlayerID,
        industryID: String,
        level: Int,
        placementID: String,
        locationID requestedLocationID: String? = nil,
        catalog: GameCore.GameDataCatalog
    ) throws -> GameCore.BoardIndustryPlacement {
        let location = try #require(catalog.board.locations.first { location in
            (requestedLocationID == nil || location.id == requestedLocationID)
                && location.industrySlots.contains { $0.contains(industryID) }
        })
        let slotIndex = try #require(location.industrySlots.firstIndex { $0.contains(industryID) })
        return .init(
            placementID: placementID, locationID: location.id, slotIndex: slotIndex,
            ownerID: ownerID,
            tile: .init(id: "tile-\(placementID)", industryDefinitionID: industryID, level: level)
        )
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
                id: "turn-scoring-test", url: "https://example.com/turn-scoring-test",
                component: "test catalog", version: catalog.rulesetVersion, page: "fixture",
                transcriber: "turn-test-author", transcribedOn: "2026-08-19",
                checker: "turn-test-reviewer", checkedOn: "2026-08-19"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }
}
