import Foundation
import Testing
@testable import IndustrialCityBirmingham

struct TurnScoringRulesTests {
    @Test(arguments: [2, 3, 4])
    func firstCanalRoundGivesEachSeatOneActionThenTwoAndRefillsToEight(playerCount: Int) throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: playerCount, catalog: catalog)
        let originalOrder = state.playerOrder
        let drawCountBefore = state.standardDrawDeck.count
        let roomID = GameCore.RoomID(rawValue: "turn-room")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        var engine = try state.makeHostEngine(roomID: roomID, reconnectTokens: tokens, protocolVersion: 1)

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
            guard case .accepted(let event) = result else {
                Issue.record("seat \(seat) should complete its first-round action")
                continue
            }
            if seat == originalOrder.count - 1 {
                #expect(event.transitions.contains { if case .roundEnded = $0 { true } else { false } })
            }
        }

        #expect(engine.gameState.roundNumber == 2)
        #expect(engine.gameState.actionsRemaining == 2)
        #expect(engine.gameState.activePlayerID == originalOrder.first)
        #expect(engine.gameState.playerOrder == originalOrder)
        #expect(engine.gameState.standardDrawDeck.count == drawCountBefore - playerCount)
        #expect(engine.gameState.players.allSatisfy { $0.hand.count == 8 })
        #expect(engine.gameState.actionNumber == playerCount)
        #expect(engine.gameState.authoritativeVersion.rawValue == playerCount)
    }

    @Test func authorityRejectsEarlyCardExhaustionThatWouldStrandTheNextRound() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let actor = state.playerOrder[1]
        let actorIndex = try #require(state.players.firstIndex { $0.id == actor })
        let actionCard = state.players[actorIndex].hand.removeFirst()
        let finalDrawCard = state.standardDrawDeck.removeFirst()
        state.publicDiscard.append(contentsOf: state.standardDrawDeck)
        state.standardDrawDeck = [finalDrawCard]
        for playerIndex in state.players.indices {
            state.publicDiscard.append(contentsOf: state.players[playerIndex].hand)
            state.players[playerIndex].hand = playerIndex == actorIndex ? [actionCard] : []
        }
        state.roundNumber = 2
        state.turnsCompletedInRound = 1
        state.actionsRemaining = 1
        state.activePlayerID = actor
        state.actionNumber = 5
        state.authoritativeVersion = .init(rawValue: 5)

        #expect(GameCore.GameStateAuthorityValidator.isValid(state, catalog: catalog) == false)

        let roomID = GameCore.RoomID(rawValue: "early-card-exhaustion")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        var engine = try state.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 1
        )
        let before = engine.gameState
        let result = engine.submit(.init(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion,
            roomID: roomID, senderID: actor,
            reconnectToken: try #require(tokens[actor]),
            baseVersion: state.authoritativeVersion,
            payload: .pass(.init(cardID: actionCard.id))
        ), catalog: catalog)

        #expect(result == .internalFailure(.init(code: .invalidAuthorityState)))
        #expect(engine.gameState == before)
    }

    @Test func authorityRejectsBoardIndustryWhosePhysicalTileBelongsToAnotherPlayer() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let declaredOwner = state.players[0].id
        let physicalOwnerIndex = 1
        let stackIndex = try #require(state.players[physicalOwnerIndex].industryStacks.firstIndex {
            $0.industryDefinitionID == "brewery"
        })
        let tile = state.players[physicalOwnerIndex].industryStacks[stackIndex].tiles.removeFirst()
        let location = try #require(catalog.catalog.board.locations.first { location in
            location.playerCounts.contains(state.playerCount)
                && location.industrySlots.contains { $0.contains(tile.industryDefinitionID) }
        })
        let slotIndex = try #require(location.industrySlots.firstIndex {
            $0.contains(tile.industryDefinitionID)
        })
        state.boardIndustryPlacements = [.init(
            placementID: "forged-owner", locationID: location.id, slotIndex: slotIndex,
            ownerID: declaredOwner, tile: tile, resourceCount: 0, isFlipped: true
        )]

        #expect(GameCore.GameStateAuthorityValidator.isValid(state, catalog: catalog) == false)
    }

    @Test func authorityRejectsTamperedRailOpeningHandDistribution() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        _ = try GameCore.GameRulesEngine.prepareRailEra(state: &state, catalog: catalog)
        #expect(state.players.map(\.hand.count) == [8, 8])
        #expect(state.standardDrawDeck.count == 24)
        #expect(GameCore.GameStateAuthorityValidator.isValid(state, catalog: catalog))

        let displaced = state.players[0].hand.removeLast()
        state.standardDrawDeck.append(displaced)
        #expect(state.players.map(\.hand.count) == [7, 8])
        #expect(state.standardDrawDeck.count == 25)

        #expect(GameCore.GameStateAuthorityValidator.isValid(state, catalog: catalog) == false)
    }

    @Test func authorityRejectsRailOpeningStateBeforeEveryNonblankMerchantIsRefilled() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        _ = try GameCore.GameRulesEngine.prepareRailEra(state: &state, catalog: catalog)
        #expect(GameCore.GameStateAuthorityValidator.isValid(state, catalog: catalog))

        let merchantsByID = Dictionary(uniqueKeysWithValues: catalog.catalog.merchants.map { ($0.id, $0) })
        let merchantIndex = try #require(state.merchants.firstIndex { placement in
            placement.hasBeer
                && merchantsByID[placement.merchantDefinitionID]?.acceptedIndustryIDs.isEmpty == false
        })
        state.merchants[merchantIndex].hasBeer = false
        state.publicSupply.beer += 1

        #expect(GameCore.GameStateAuthorityValidator.isValid(state, catalog: catalog) == false)
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

    @Test func incomePausesForTheDebtorToChooseOrderedHalfCostSalesThenLosesOnlyAvailableVictoryPoints() throws {
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
        #expect(debtorAfter.victoryPoints == max(0, 4 - max(0, 10 - saleCost / 2)))
        #expect(debtorAfter.victoryPointDebt == 0)
        #expect(state.authoritativeVersion.rawValue == previousVersion.rawValue + 1)
        #expect(state.actionNumber == previousActionNumber + 1)
        #expect(event.payload == .forcedSaleResolved(.init(placementIDs: [sale.placementID])))
    }

    @Test(arguments: [GameCore.Era.canal, .rail])
    func eraTransitionBatchReplaysAtomicallyAndRejectsEveryTamperedPosition(era: GameCore.Era) throws {
        let catalog = try verifiedCatalog()
        var source = try setup(playerCount: 2, catalog: catalog)
        let lastCard = try prepareFinalAction(in: &source, era: era)
        let actor = try #require(source.activePlayerID)
        let actorIndex = try #require(source.players.firstIndex { $0.id == actor })
        source.players[actorIndex].hand.removeAll()
        source.publicDiscard.append(lastCard)
        source.actionsRemaining = 0
        source.turnsCompletedInRound = source.playerCount
        source.players.indices.forEach { source.players[$0].incomePosition = 15 }
        let before = source
        let events = try GameCore.GameRulesEngine.resolveRoundEnd(state: &source, catalog: catalog)

        #expect(events.count == 3)
        var replayed = before
        try GameCore.GameRulesEngine.replay(events, to: &replayed, catalog: catalog)
        #expect(replayed == source)

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

    @Test func eraScoringCountsEveryHyperedgeAdjacentFlippedIndustryAndRemovesOnlyEraLinks() throws {
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
        #expect(player.victoryPoints == expectedLinkPoints + ownIndustryPoints)
        #expect(state.placedLinks.map(\.era) == [.rail])
        guard case .eraScored(let details) = event else {
            Issue.record("expected era scoring event")
            return
        }
        #expect(details.removedRouteIDs == [route.id])
    }

    @Test func eraLinkScoringIncludesTheTwoIconsAtAnAdjacentMerchantLocation() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let owner = state.playerOrder[0]
        var ironWorks = try placement(
            ownerID: owner, industryID: "iron-works", level: 1,
            placementID: "coalbrookdale-iron", locationID: "coalbrookdale",
            catalog: catalog.catalog
        )
        ironWorks.isFlipped = true
        state.boardIndustryPlacements = [ironWorks]
        state.placedLinks = [
            .init(routeID: "coalbrookdale-shrewsbury", ownerID: owner, era: .canal),
        ]
        let industryLinkPoints = try #require(
            catalog.catalog.industries.first { $0.id == "iron-works" }?
                .levels.first { $0.level == 1 }?.linkPoints
        )

        let event = try GameCore.GameRulesEngine.scoreEra(
            .canal, state: &state, catalog: catalog
        )

        guard case .eraScored(let details) = event,
              let ownerAward = details.awards.first(where: { $0.playerID == owner })
        else {
            Issue.record("expected an era score for the link owner")
            return
        }
        #expect(ownerAward.linkPoints == industryLinkPoints + 2)
    }

    @Test func eraLinkScoringCountsPrintedMerchantIconsOnceWhenTwoMerchantTilesShareTheLocation() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let owner = state.playerOrder[0]
        let gloucesterSlotIDs = Set(catalog.catalog.board.merchantSlots.filter {
            $0.locationID == "gloucester"
        }.map(\.id))
        #expect(state.merchants.filter { gloucesterSlotIDs.contains($0.slotID) }.count == 2)
        state.boardIndustryPlacements = []
        state.placedLinks = [
            .init(routeID: "gloucester-worcester", ownerID: owner, era: .canal),
        ]

        let event = try GameCore.GameRulesEngine.scoreEra(
            .canal, state: &state, catalog: catalog
        )

        guard case .eraScored(let details) = event,
              let ownerAward = details.awards.first(where: { $0.playerID == owner })
        else {
            Issue.record("expected an era score for the link owner")
            return
        }
        #expect(ownerAward.linkPoints == 2)
    }

    @Test func eraLinkScoringUsesPrintedMerchantIconsEvenWhenNoMerchantTileWasPlacedThere() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let owner = state.playerOrder[0]
        let warringtonSlotIDs = Set(catalog.catalog.board.merchantSlots.filter {
            $0.locationID == "warrington"
        }.map(\.id))
        #expect(state.merchants.contains { warringtonSlotIDs.contains($0.slotID) } == false)
        state.boardIndustryPlacements = []
        state.placedLinks = [
            .init(routeID: "stoke-on-trent-warrington", ownerID: owner, era: .canal),
        ]

        let event = try GameCore.GameRulesEngine.scoreEra(
            .canal, state: &state, catalog: catalog
        )

        guard case .eraScored(let details) = event,
              let ownerAward = details.awards.first(where: { $0.playerID == owner })
        else {
            Issue.record("expected an era score for the link owner")
            return
        }
        #expect(ownerAward.linkPoints == 2)
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
            ownerID: debtor, industryID: "brewery", level: 1,
            placementID: "choice-b", catalog: catalog.catalog
        )
        let otherLocation = try #require(catalog.catalog.board.locations.first { location in
            location.id != first.locationID
                && location.industrySlots.contains { $0.contains(second.tile.industryDefinitionID) }
        })
        second.locationID = otherLocation.id
        second.slotIndex = try #require(otherLocation.industrySlots.firstIndex {
            $0.contains(second.tile.industryDefinitionID)
        })
        state.boardIndustryPlacements = [first, second]
        repairIndustryFixture(&state, catalog: catalog)
        state.publicDiscard.append(contentsOf: state.standardDrawDeck.prefix(2))
        state.standardDrawDeck.removeFirst(2)
        state.actionNumber = 2
        state.authoritativeVersion = .init(rawValue: 2)
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

    @Test func forcedSaleLegalQueryCompletesAfterTheLastAssetEvenWhenProceedsAreInsufficient() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let debtor = state.playerOrder[0]
        let onlyAsset = try placement(
            ownerID: debtor, industryID: "brewery", level: 2,
            placementID: "only-asset", catalog: catalog.catalog
        )
        let liquidationValue = try #require(
            GameCore.TurnRules.liquidationValue(of: onlyAsset, catalog: catalog.catalog)
        )
        state.boardIndustryPlacements = [onlyAsset]
        state.activePlayerID = debtor
        state.turnPhase = .forcedSale(.init(
            playerID: debtor, shortfall: liquidationValue + 1,
            eligiblePlacementIDs: [onlyAsset.placementID]
        ))

        let response = try GameCore.LegalActionQueryEngine.respond(
            to: .init(
                requestID: "forced-insufficient",
                baseVersion: state.authoritativeVersion,
                draft: .init(
                    action: .forcedSale, cardID: nil,
                    selections: [.industryPlacement(id: onlyAsset.placementID)]
                )
            ),
            actorID: debtor, state: state, catalog: catalog
        )

        #expect(response.nextChoices.isEmpty)
        #expect(response.completePayload == .forcedSale(.init(placementIDs: [onlyAsset.placementID])))
    }

    @Test func negativeIncomeWithoutAssetsCannotReduceVictoryPointsEarnedLater() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let debtor = state.playerOrder[0]
        let opponent = state.playerOrder[1]
        state.boardIndustryPlacements.removeAll()
        mutatePlayer(debtor, in: &state) {
            $0.cash = 0
            $0.incomePosition = 0
            $0.victoryPoints = 0
        }
        mutatePlayer(opponent, in: &state) {
            $0.cash = 0
            $0.incomePosition = 10
            $0.victoryPoints = 0
        }

        _ = try GameCore.GameRulesEngine.resolveRoundEnd(state: &state, catalog: catalog)
        let afterIncome = try #require(state.players.first { $0.id == debtor })
        #expect(afterIncome.victoryPoints == 0)
        #expect(afterIncome.victoryPointDebt == 0)

        mutatePlayer(debtor, in: &state) { $0.victoryPoints = 10 }
        mutatePlayer(opponent, in: &state) { $0.victoryPoints = 6 }
        let event = try GameCore.GameRulesEngine.resolveWinner(state: &state)
        guard case .gameEnded(let details) = event else {
            Issue.record("expected winner event")
            return
        }
        #expect(details.standings.first == [debtor])
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

        let event = try GameCore.GameRulesEngine.prepareRailEra(state: &state, catalog: catalog)

        let preserved = try #require(state.players.first { $0.id == owner })
        #expect(state.era == .rail)
        #expect(state.boardIndustryPlacements.map(\.placementID) == ["level-2"])
        #expect(state.placedLinks.isEmpty)
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
        let lastCard = try prepareFinalAction(in: &state, era: .rail)
        let lastActor = try #require(state.activePlayerID)
        let lastActorIndex = try #require(state.players.firstIndex { $0.id == lastActor })
        state.players[lastActorIndex].hand.removeAll()
        state.publicDiscard.append(lastCard)
        state.actionsRemaining = 0
        state.turnsCompletedInRound = 0
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
        #expect(state.finalStandings == details.standings)

        let restoredState = try JSONDecoder().decode(
            GameCore.GameState.self,
            from: JSONEncoder.canonical.encode(state)
        )
        #expect(restoredState.finalStandings == details.standings)
        #expect(GameCore.GameStateAuthorityValidator.isValid(restoredState, catalog: catalog))

        let roomID = GameCore.RoomID(rawValue: "ended-room")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        var engine = try state.makeHostEngine(roomID: roomID, reconnectTokens: tokens, protocolVersion: 1)
        let snapshot = try engine.snapshot(for: order[0], catalog: catalog)
        #expect(snapshot.match?.finalStandings == details.standings)
        let winner = try #require(state.activePlayerID)
        let rejected = engine.submit(.init(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion, roomID: roomID,
            senderID: winner, reconnectToken: try #require(tokens[winner]),
            baseVersion: state.authoritativeVersion,
            payload: .pass(.init(cardID: "already-ended"))
        ), catalog: catalog)
        guard case .rejected(let rejection) = rejected else {
            Issue.record("an ended game must reject ordinary actions")
            return
        }
        #expect(rejection.reasonCode == .invalidAction)
    }

    @Test func winnerUsesOfficialVictoryPointsAndIgnoresLegacyDeferredDebt() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let leader = state.playerOrder[0]
        let challenger = state.playerOrder[1]
        mutatePlayer(leader, in: &state) {
            $0.victoryPoints = 10
            $0.victoryPointDebt = 2
            $0.incomePosition = 10
            $0.cash = 0
        }
        mutatePlayer(challenger, in: &state) {
            $0.victoryPoints = 9
            $0.victoryPointDebt = 0
            $0.incomePosition = 15
            $0.cash = 100
        }

        let event = try GameCore.GameRulesEngine.resolveWinner(state: &state)

        guard case .gameEnded(let details) = event else {
            Issue.record("expected a game-ended event")
            return
        }
        #expect(details.standings.first == [leader])
        #expect(state.finalStandings?.first == [leader])
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

        let valuedDebtorEvent = try engine.clientEvent(
            event, for: debtor, catalog: catalog
        )
        #expect(valuedDebtorEvent.snapshot.forcedSale?.options == [
            .init(placementID: "a-sale", liquidationValue: 3),
            .init(placementID: "z-sale", liquidationValue: 4),
        ])
        let envelope = SessionProtocol.SessionEnvelope(
            protocolVersion: 2, rulesetVersion: state.rulesetVersion,
            roomID: roomID, messageID: .init(rawValue: "forced-sale-required"),
            senderID: observer, recipientID: debtor,
            authoritativeVersion: event.version,
            payload: .clientEvent(valuedDebtorEvent)
        )
        try SessionProtocol.EnvelopeValidator().validate(
            clientEvent: valuedDebtorEvent, in: envelope,
            expectedRoster: Set(state.players.map(\.id))
        )

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

    @Test func recipientSnapshotValidatorRejectsForcedSaleDetailsForANondebtor() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let debtor = state.playerOrder[0]
        let observer = state.playerOrder[1]
        mutatePlayer(debtor, in: &state) { $0.cash = 0; $0.incomePosition = 0 }
        state.boardIndustryPlacements = [
            try placement(
                ownerID: debtor, industryID: "manufacturer", level: 1,
                placementID: "private-sale", catalog: catalog.catalog
            ),
        ]
        _ = try GameCore.GameRulesEngine.resolveRoundEnd(state: &state, catalog: catalog)
        let roomID = GameCore.RoomID(rawValue: "forced-sale-privacy")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        let engine = try state.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 2
        )
        let debtorSnapshot = try engine.snapshot(for: debtor, catalog: catalog)
        let observerSnapshot = try engine.snapshot(for: observer, catalog: catalog)
        let leakedForcedSale = try #require(debtorSnapshot.forcedSale)
        let checksum = try GameCore.snapshotChecksum(
            roomID: observerSnapshot.roomID,
            recipient: observerSnapshot.recipient,
            gameVariant: observerSnapshot.gameVariant,
            players: observerSnapshot.players,
            activePlayerID: observerSnapshot.activePlayerID,
            turn: observerSnapshot.turn,
            actionNumber: observerSnapshot.actionNumber,
            authoritativeVersion: observerSnapshot.authoritativeVersion,
            discardPile: observerSnapshot.discardPile,
            forcedSale: leakedForcedSale,
            match: observerSnapshot.match
        )
        let leaked = GameCore.ViewSnapshot(
            roomID: observerSnapshot.roomID,
            recipient: observerSnapshot.recipient,
            players: observerSnapshot.players,
            activePlayerID: observerSnapshot.activePlayerID,
            turn: observerSnapshot.turn,
            actionNumber: observerSnapshot.actionNumber,
            authoritativeVersion: observerSnapshot.authoritativeVersion,
            discardPile: observerSnapshot.discardPile,
            forcedSale: leakedForcedSale,
            match: observerSnapshot.match,
            gameVariant: observerSnapshot.gameVariant,
            checksum: checksum
        )

        #expect(throws: GameCore.RecipientSnapshotValidationError.privateSurfaceViolation) {
            try GameCore.RecipientSnapshotValidator.validate(
                leaked,
                context: .init(
                    protocolVersion: 2,
                    rulesetVersion: state.rulesetVersion,
                    roomID: roomID,
                    recipient: observer,
                    roster: Set(state.playerOrder),
                    authoritativeVersion: state.authoritativeVersion
                )
            )
        }
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
        pending.publicDiscard.append(contentsOf: pending.standardDrawDeck.prefix(2))
        pending.standardDrawDeck.removeFirst(2)
        pending.actionNumber = 2
        pending.authoritativeVersion = .init(rawValue: 2)
        let debtor = pending.playerOrder[0]
        pending.boardIndustryPlacements = [
            try placement(ownerID: debtor, industryID: "manufacturer", level: 1, placementID: "z-sale", catalog: catalog.catalog),
            try placement(ownerID: debtor, industryID: "brewery", level: 2, placementID: "a-sale", catalog: catalog.catalog),
        ]
        repairIndustryFixture(&pending, catalog: catalog)
        pending.actionsRemaining = 0
        pending.activePlayerID = debtor
        pending.roundIncomeCursor = 1
        let debtorIndex = try #require(pending.players.firstIndex { $0.id == debtor })
        pending.players[debtorIndex].cash = 0
        pending.players[debtorIndex].incomePosition = 0
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
        var impossibleCash = pending
        impossibleCash.players[debtorIndex].cash = 17
        #expect(GameCore.GameStateAuthorityValidator.isValid(
            impossibleCash, catalog: catalog
        ) == false)
        var nonnegativeIncome = pending
        nonnegativeIncome.players[debtorIndex].incomePosition = 10
        #expect(GameCore.GameStateAuthorityValidator.isValid(
            nonnegativeIncome, catalog: catalog
        ) == false)
        var excessiveShortfall = pending
        excessiveShortfall.turnPhase = .forcedSale(.init(
            playerID: debtor, shortfall: 11,
            eligiblePlacementIDs: ["a-sale", "z-sale"]
        ))
        #expect(GameCore.GameStateAuthorityValidator.isValid(
            excessiveShortfall, catalog: catalog
        ) == false)
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
        state.publicDiscard.append(state.standardDrawDeck.removeFirst())
        state.actionNumber = 1
        state.authoritativeVersion = .init(rawValue: 1)
        state.players[actorIndex].cash = Int.max
        state.players[actorIndex].incomePosition = 15
        let card = try #require(state.players[actorIndex].hand.first)
        let roomID = GameCore.RoomID(rawValue: "income-overflow")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        var host = try state.makeHostEngine(roomID: roomID, reconnectTokens: tokens, protocolVersion: 1)
        let before = host.gameState

        let result = host.submit(.init(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion, roomID: roomID,
            senderID: actor, reconnectToken: tokens[actor]!,
            baseVersion: state.authoritativeVersion, payload: .pass(.init(cardID: card.id))
        ), catalog: catalog)

        #expect(result == .internalFailure(.init(code: .arithmeticOverflow)))
        #expect(host.gameState == before)
    }

    @Test func eraVictoryPointOverflowIsInternalAndLeavesHostAuthorityUnchanged() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let card = try prepareFinalAction(in: &state, era: .canal)
        let actor = try #require(state.activePlayerID)
        let actorIndex = try #require(state.players.firstIndex { $0.id == actor })
        state.players.indices.forEach { state.players[$0].incomePosition = 10 }
        state.players[actorIndex].victoryPoints = Int.max
        var scored = try placement(
            ownerID: actor, industryID: "manufacturer", level: 2,
            placementID: "vp-overflow", catalog: catalog.catalog
        )
        scored.isFlipped = true
        state.boardIndustryPlacements = [scored]
        repairIndustryFixture(&state, catalog: catalog)
        let roomID = GameCore.RoomID(rawValue: "vp-overflow")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        var host = try state.makeHostEngine(roomID: roomID, reconnectTokens: tokens, protocolVersion: 1)
        let before = host.gameState

        let result = host.submit(.init(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion, roomID: roomID,
            senderID: actor, reconnectToken: tokens[actor]!,
            baseVersion: state.authoritativeVersion, payload: .pass(.init(cardID: card.id))
        ), catalog: catalog)

        #expect(result == .internalFailure(.init(code: .arithmeticOverflow)))
        #expect(host.gameState == before)
    }

    @Test(arguments: [GameCore.Era.canal, .rail])
    func finalSeatActionAtomicallyCarriesReplayableEraTransitionsAndRailSkipsIncome(era: GameCore.Era) throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        let card = try prepareFinalAction(in: &state, era: era)
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

        let result = engine.submit(.init(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion, roomID: roomID,
            senderID: actor, reconnectToken: try #require(tokens[actor]),
            baseVersion: state.authoritativeVersion, payload: .pass(.init(cardID: card.id))
        ), catalog: catalog)
        guard case .accepted(let event) = result else {
            Issue.record("the final seat action should settle the \(era) era atomically, got \(result)")
            return
        }
        #expect(event.transitions.contains { if case .roundEnded = $0 { true } else { false } })
        #expect(event.transitions.contains { if case .eraScored = $0 { true } else { false } })
        if era == .canal {
            #expect(event.transitions.contains { if case .railPrepared = $0 { true } else { false } })
            #expect(engine.gameState.era == .rail)
        } else {
            #expect(event.transitions.contains { if case .gameEnded = $0 { true } else { false } })
            #expect(engine.gameState.turnPhase == .ended)
            #expect(Dictionary(uniqueKeysWithValues: engine.gameState.players.map { ($0.id, $0.cash) }) == cashBefore)
        }
        var replayed = state
        try GameCore.GameRulesEngine.replay(
            event, expectedRoomID: roomID, to: &replayed, catalog: catalog
        )
        #expect(replayed == engine.gameState)
    }

    @Test(arguments: [GameCore.Era.canal, .rail])
    func authorityRejectsFinalRoundStateWhileDeckAndHandsExceedRemainingActions(
        era: GameCore.Era
    ) throws {
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

        #expect(GameCore.GameStateAuthorityValidator.isValid(state, catalog: catalog) == false)

        let actor = try #require(state.activePlayerID)
        let card = try #require(state.players.first { $0.id == actor }?.hand.first)
        let roomID = GameCore.RoomID(rawValue: "invalid-final-card-progress-\(era.rawValue)")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        var engine = try state.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 1
        )
        let before = engine.gameState

        #expect(engine.submit(.init(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion,
            roomID: roomID, senderID: actor,
            reconnectToken: try #require(tokens[actor]),
            baseVersion: state.authoritativeVersion,
            payload: .pass(.init(cardID: card.id))
        ), catalog: catalog) == .internalFailure(.init(code: .invalidAuthorityState)))
        #expect(engine.gameState == before)
    }

    @Test func authorityRejectsAnActiveEraThatHasNoDrawDeckOrPlayerCards() throws {
        let catalog = try verifiedCatalog()
        var state = try setup(playerCount: 2, catalog: catalog)
        state.publicDiscard.append(contentsOf: state.standardDrawDeck)
        state.standardDrawDeck.removeAll()
        for index in state.players.indices {
            state.publicDiscard.append(contentsOf: state.players[index].hand)
            state.players[index].hand.removeAll()
        }

        #expect(GameCore.GameStateAuthorityValidator.isValid(state, catalog: catalog) == false)

        state.turnPhase = .ended
        state.actionsRemaining = 0
        state.turnsCompletedInRound = 0
        state.finalStandings = [state.playerOrder]
        #expect(GameCore.GameStateAuthorityValidator.isValid(state, catalog: catalog) == false)
    }

    @Test func authorityRejectsARecoveryStateWhoseActiveSeatCannotFinishItsTurn() throws {
        let catalog = try verifiedCatalog()
        let roomID = GameCore.RoomID(rawValue: "stranded-active-seat")
        let initial = try setup(playerCount: 2, catalog: catalog)
        let tokens = Dictionary(uniqueKeysWithValues: initial.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        let firstActor = try #require(initial.activePlayerID)
        let firstCard = try #require(
            initial.players.first { $0.id == firstActor }?.hand.first
        )
        var liveHost = try initial.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 1
        )
        guard case .accepted = liveHost.submit(.init(
            protocolVersion: 1, rulesetVersion: initial.rulesetVersion,
            roomID: roomID, senderID: firstActor,
            reconnectToken: try #require(tokens[firstActor]),
            baseVersion: initial.authoritativeVersion,
            payload: .pass(.init(cardID: firstCard.id))
        ), catalog: catalog) else {
            Issue.record("the legal first pass must establish the recovery boundary")
            return
        }

        var corrupted = liveHost.gameState
        let strandedActor = try #require(corrupted.activePlayerID)
        let strandedIndex = try #require(
            corrupted.players.firstIndex { $0.id == strandedActor }
        )
        let strandedCards = corrupted.players[strandedIndex].hand
        #expect(strandedCards.count == 8)
        corrupted.players[strandedIndex].hand.removeAll()
        corrupted.standardDrawDeck.append(contentsOf: strandedCards)

        #expect(corrupted.actionsRemaining == 1)
        #expect(corrupted.players[strandedIndex].hand.isEmpty)
        #expect(GameCore.GameStateAuthorityValidator.isValid(corrupted, catalog: catalog) == false)

        var restoredHost = try corrupted.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 1
        )
        let before = restoredHost.gameState
        let result = restoredHost.submit(.init(
            protocolVersion: 1, rulesetVersion: corrupted.rulesetVersion,
            roomID: roomID, senderID: strandedActor,
            reconnectToken: try #require(tokens[strandedActor]),
            baseVersion: corrupted.authoritativeVersion,
            payload: .pass(.init(cardID: try #require(strandedCards.first).id))
        ), catalog: catalog)
        if case .accepted = result {
            Issue.record("an invalid recovery state must never accept another action")
        }
        #expect(restoredHost.gameState == before)
    }

    @Test func authorityRejectsCardZoneSwapsInvalidInitialHandsMissingBottomCardsAndBiasedOrder() throws {
        let catalog = try verifiedCatalog()
        let state = try setup(playerCount: 2, catalog: catalog)

        var zoneSwap = state
        let standard = zoneSwap.standardDrawDeck[0]
        let wild = try #require(zoneSwap.wildLocationPool.last)
        zoneSwap.standardDrawDeck[0] = wild
        zoneSwap.wildLocationPool[zoneSwap.wildLocationPool.count - 1] = standard
        #expect(GameCore.GameStateAuthorityValidator.isValid(zoneSwap, catalog: catalog) == false)

        var unevenHands = state
        unevenHands.players[0].hand.append(unevenHands.players[1].hand.removeLast())
        #expect(unevenHands.players.map(\.hand.count) == [9, 7])
        #expect(GameCore.GameStateAuthorityValidator.isValid(unevenHands, catalog: catalog) == false)

        var missingBottomCard = state
        let bottom = try #require(missingBottomCard.players[0].privateBottomDiscard)
        missingBottomCard.players[0].privateBottomDiscard = nil
        missingBottomCard.standardDrawDeck.append(bottom)
        #expect(GameCore.GameStateAuthorityValidator.isValid(missingBottomCard, catalog: catalog) == false)

        var biasedOrder = state
        biasedOrder.playerOrder.swapAt(0, 1)
        biasedOrder.activePlayerID = biasedOrder.playerOrder[0]
        #expect(GameCore.GameStateAuthorityValidator.isValid(biasedOrder, catalog: catalog) == false)
    }

    private func setup(playerCount: Int, catalog: GameCore.VerifiedGameDataCatalog) throws -> GameCore.GameState {
        var rules = GameCore.SetupRules(seed: UInt64(9_000 + playerCount))
        return try rules.makeGame(
            catalog: catalog,
            playerIDs: (1...playerCount).map { .init(rawValue: "p\($0)") }
        ).state
    }

    private func prepareFinalAction(
        in state: inout GameCore.GameState,
        era: GameCore.Era
    ) throws -> GameCore.CardInstance {
        state.era = era
        var playableCards = state.standardDrawDeck
        state.standardDrawDeck.removeAll()
        for index in state.players.indices {
            playableCards.append(contentsOf: state.players[index].hand)
            state.players[index].hand.removeAll()
            if era == .rail, let bottom = state.players[index].privateBottomDiscard {
                playableCards.append(bottom)
                state.players[index].privateBottomDiscard = nil
            }
        }
        try #require(playableCards.isEmpty == false)
        let card = playableCards.removeLast()
        state.publicDiscard.append(contentsOf: playableCards)
        let actor = try #require(state.playerOrder.last)
        let actorIndex = try #require(state.players.firstIndex { $0.id == actor })
        state.players[actorIndex].hand = [card]
        state.roundNumber = era == .canal ? state.canalRoundCapacity : state.railRoundCapacity
        state.actionsRemaining = 1
        state.turnsCompletedInRound = state.playerCount - 1
        state.activePlayerID = actor
        state.turnPhase = .active
        state.roundIncomeCursor = nil
        return card
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
