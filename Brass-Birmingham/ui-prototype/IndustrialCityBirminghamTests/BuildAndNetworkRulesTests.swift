import Foundation
import Testing
@testable import IndustrialCityBirmingham

struct BuildAndNetworkRulesTests {
    @Test func legalQueryRejectsUnboundedRequestAndIdentifierShapesWithStableError() throws {
        let catalog = try verifiedCatalog()
        let state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let card = try #require(state.players.first(where: { $0.id == actor })?.hand.first)
        let invalidDrafts: [GameCore.LegalActionQuery] = [
            .init(requestID: "", baseVersion: state.authoritativeVersion,
                  draft: .init(action: .pass, cardID: card.id, selections: [])),
            .init(requestID: String(repeating: "r", count: 129), baseVersion: state.authoritativeVersion,
                  draft: .init(action: .pass, cardID: card.id, selections: [])),
            .init(requestID: "oversized-card", baseVersion: state.authoritativeVersion,
                  draft: .init(action: .pass, cardID: String(repeating: "c", count: 257), selections: [])),
            .init(requestID: "too-many-selections", baseVersion: state.authoritativeVersion,
                  draft: .init(action: .scout, cardID: card.id,
                               selections: Array(repeating: .card(id: card.id), count: 33))),
        ]
        for query in invalidDrafts {
            #expect(throws: GameCore.LegalActionQueryError.malformedQuery) {
                try GameCore.LegalActionQueryEngine.respond(
                    to: query, actorID: actor, state: state, catalog: catalog
                )
            }
        }
    }

    @Test func legalQueryRejectsValidChoicesPresentedOutOfGrammarOrder() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let player = try #require(state.players.first(where: { $0.id == actor }))
        let build = try #require(player.industryStacks.compactMap(\.tiles.first).compactMap { tile in
            player.hand.compactMap { card in
                GameCore.BuildRules.legalBuildTargets(
                    actorID: actor, cardID: card.id, tile: tile, state: state, catalog: catalog
                ).first.map { (card, tile, $0) }
            }.first
        }.first)
        let card = build.0
        let tile = build.1
        let buildTarget = build.2

        #expect(throws: GameCore.LegalActionQueryError.invalidPrefix) {
            try GameCore.LegalActionQueryEngine.respond(
                to: .init(requestID: "build-order", baseVersion: state.authoritativeVersion,
                          draft: .init(action: .build, cardID: card.id, selections: [
                            .buildTarget(locationID: buildTarget.locationID, slotIndex: buildTarget.slotIndex),
                            .industryTile(id: tile.id),
                          ])),
                actorID: actor, state: state, catalog: catalog
            )
        }

        state.era = .rail
        let route = try #require(GameCore.TopologyRules.legalNetworkRoutes(
            playerID: actor, state: state, board: catalog.catalog.board
        ).first)
        #expect(throws: GameCore.LegalActionQueryError.invalidPrefix) {
            try GameCore.LegalActionQueryEngine.respond(
                to: .init(requestID: "network-order", baseVersion: state.authoritativeVersion,
                          draft: .init(action: .network, cardID: card.id, selections: [
                            .route(id: route), .networkLinkCount(1),
                          ])),
                actorID: actor, state: state, catalog: catalog
            )
        }
    }

    @Test func snapshotAvailabilityIsPerCardAndPrunesActionsWithoutACompletablePath() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        state.players[playerIndex].cash = 0
        let availability = try GameCore.SnapshotActionAvailability.make(
            state: state, recipient: actor, catalog: catalog
        )
        let handIDs = Set(state.players[playerIndex].hand.map(\.id))

        #expect(Set(availability.byCardID.keys) == handIDs)
        #expect(availability.byCardID.values.allSatisfy { $0.contains(.pass) })
        #expect(availability.byCardID.values.allSatisfy { !$0.contains(.build) })
        #expect(Set(availability.kinds) == Set(availability.byCardID.values.flatMap { $0 }))
    }

    @Test func snapshotAvailabilityCompletesWithinTheLoopbackJoinBudget() throws {
        let catalog = try verifiedCatalog()
        let state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let clock = ContinuousClock()
        let started = clock.now

        let availability = try GameCore.SnapshotActionAvailability.make(
            state: state, recipient: actor, catalog: catalog
        )

        #expect(availability.byCardID.isEmpty == false)
        #expect(started.duration(to: clock.now) < .seconds(1))
    }

    @Test func exactAvailabilitySearchDoesNotHideCompletionAfterThe129thBranch() throws {
        var expanded = 0
        let found = try GameCore.ExactCompletionSearch.containsCompletion(
            root: 0,
            key: { String($0) },
            expand: { node in
                expanded += 1
                if node == 0 { return .branches(Array(1...130)) }
                return node == 130 ? .complete : .deadEnd
            }
        )
        #expect(found)
        #expect(expanded == 131)
    }

    @Test func exactAvailabilitySearchContinuesAfterAnInvalidPrefixSibling() throws {
        let found = try GameCore.ExactCompletionSearch.containsCompletion(
            root: 0,
            key: { String($0) },
            expand: { node in
                if node == 0 { return .branches([1, 2]) }
                if node == 1 { throw GameCore.LegalActionQueryError.invalidPrefix }
                return .complete
            },
            isDeadEndError: { $0 is GameCore.LegalActionQueryError }
        )
        #expect(found)
    }

    @Test func locationCardBuildCommitsOneEventOneVersionAndOneAction() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        let card = GameCore.CardInstance(id: "location-dudley-test", definitionID: "location-dudley")
        state.players[playerIndex].hand = [card]
        state.players[playerIndex].cash = 20
        let beforeVersion = state.authoritativeVersion
        let beforeAction = state.actionNumber

        let target = try GameCore.BuildRules.validate(
            .init(cardID: card.id, locationID: "dudley", industryDefinitionID: "coal-mine", slotIndex: 0, resourceSources: []),
            actorID: actor,
            state: state,
            catalog: catalog
        )
        let event = try GameCore.GameRulesEngine.resolveBuild(
            target,
            roomID: .init(rawValue: "build-network-tests"),
            state: &state,
            catalog: catalog
        )

        #expect(state.boardIndustryPlacements.count == 1)
        #expect(state.boardIndustryPlacements[0].locationID == "dudley")
        #expect(state.boardIndustryPlacements[0].tile.level == 1)
        #expect(state.players[playerIndex].cash == 15)
        #expect(state.players[playerIndex].spent == 5)
        #expect(state.publicDiscard.last == card)
        #expect(state.authoritativeVersion.rawValue == beforeVersion.rawValue + 1)
        #expect(state.actionNumber == beforeAction + 1)
        #expect(event.version == state.authoritativeVersion)
        #expect(event.actionNumber == state.actionNumber)
    }

    @Test func legalQueryAdaptersExposeTypedEntriesForAllSevenActions() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let player = try #require(state.players.first(where: { $0.id == actor }))
        let card = try #require(player.hand.first)
        func response(
            _ action: GameCore.ActionKind,
            in candidate: GameCore.GameState? = nil
        ) throws -> GameCore.LegalActionResponse {
            let candidate = candidate ?? state
            return try GameCore.LegalActionQueryEngine.respond(
                to: .init(
                    requestID: action.rawValue,
                    baseVersion: candidate.authoritativeVersion,
                    draft: .init(action: action, cardID: card.id, selections: [])
                ),
                actorID: actor, state: candidate, catalog: catalog
            )
        }

        #expect(try response(.build).nextChoices.contains {
            if case .industryTile = $0.value { true } else { false }
        })
        #expect(try response(.network).nextChoices.contains {
            if case .route = $0.value { true } else { false }
        })
        #expect(try response(.develop).nextChoices.contains {
            if case .developTileCount = $0.value { true } else { false }
        })
        var sellState = state
        sellState.merchants = knownQueryMerchants()
        sellState.placedLinks = [
            .init(routeID: "birmingham-worcester", ownerID: actor, era: .canal),
            .init(routeID: "gloucester-worcester", ownerID: actor, era: .canal),
        ]
        let sellIndex = try #require(sellState.players.firstIndex { $0.id == actor })
        sellState.players[sellIndex].linksRemaining = 12
        sellState.boardIndustryPlacements = [
            .init(
                placementID: "query-sellable", locationID: "birmingham", slotIndex: 0,
                ownerID: actor,
                tile: .init(id: "query-cotton", industryDefinitionID: "cotton-mill", level: 1)
            ),
            .init(
                placementID: "query-beer", locationID: "walsall", slotIndex: 1,
                ownerID: actor,
                tile: .init(id: "query-beer-tile", industryDefinitionID: "brewery", level: 1),
                resourceCount: 1
            ),
        ]
        sellState.publicSupply.beer -= 1
        repairCardFixture(&sellState, catalog: catalog)
        #expect(try response(.sell, in: sellState).nextChoices.contains {
            if case .industryPlacement = $0.value { true } else { false }
        })
        #expect(try response(.scout).nextChoices.contains {
            if case .card = $0.value { true } else { false }
        })
        #expect(try response(.loan).completePayload != nil)
        #expect(try response(.pass).completePayload == .pass(.init(cardID: card.id)))
    }

    @Test func sellQueryLabelsEachMerchantWithMarketAcceptanceAndReward() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        let card = try #require(state.players[playerIndex].hand.first)
        state.merchants = knownQueryMerchants()
        state.placedLinks = [
            .init(routeID: "birmingham-worcester", ownerID: actor, era: .canal),
            .init(routeID: "gloucester-worcester", ownerID: actor, era: .canal),
            .init(routeID: "birmingham-oxford", ownerID: actor, era: .canal),
        ]
        state.boardIndustryPlacements = [
            .init(
                placementID: "merchant-label-sale",
                locationID: "birmingham",
                slotIndex: 0,
                ownerID: actor,
                tile: .init(
                    id: "merchant-label-cotton",
                    industryDefinitionID: "cotton-mill",
                    level: 1
                )
            ),
        ]
        repairCardFixture(&state, catalog: catalog)

        let response = try GameCore.LegalActionQueryEngine.respond(
            to: .init(
                requestID: "sell-merchant-labels",
                baseVersion: state.authoritativeVersion,
                draft: .init(
                    action: .sell,
                    cardID: card.id,
                    selections: [.industryPlacement(id: "merchant-label-sale")]
                )
            ),
            actorID: actor,
            state: state,
            catalog: catalog
        )
        let labelsBySlotID = Dictionary(uniqueKeysWithValues: response.nextChoices.compactMap {
            choice -> (String, String)? in
            guard case .merchant(let slotID) = choice.value else { return nil }
            return (slotID, choice.label)
        })

        #expect(labelsBySlotID["gloucester-2"] == "格洛斯特 · 棉纺厂 · 开发 1")
        #expect(labelsBySlotID["oxford-1"] == "牛津 · 任意制成品 · 收入 +2")
        #expect(labelsBySlotID["gloucester-1"] == nil, "空白商人不能用于出售")
        #expect(labelsBySlotID.values.allSatisfy { !$0.contains("商人市场") })
    }

    @Test func sellQueryMarksRewardUnavailableWhenMatchingMerchantBeerIsAlreadyUsed() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        let card = try #require(state.players[playerIndex].hand.first)
        state.merchants = knownQueryMerchants().map { merchant in
            guard merchant.slotID == "oxford-1" else { return merchant }
            return .init(
                slotID: merchant.slotID,
                merchantDefinitionID: merchant.merchantDefinitionID,
                hasBeer: false
            )
        }
        state.placedLinks = [
            .init(routeID: "birmingham-oxford", ownerID: actor, era: .canal),
        ]
        state.boardIndustryPlacements = [
            .init(
                placementID: "merchant-no-beer-sale",
                locationID: "birmingham",
                slotIndex: 0,
                ownerID: actor,
                tile: .init(
                    id: "merchant-no-beer-cotton",
                    industryDefinitionID: "cotton-mill",
                    level: 1
                )
            ),
        ]
        repairCardFixture(&state, catalog: catalog)

        let response = try GameCore.LegalActionQueryEngine.respond(
            to: .init(
                requestID: "sell-merchant-no-beer-label",
                baseVersion: state.authoritativeVersion,
                draft: .init(
                    action: .sell,
                    cardID: card.id,
                    selections: [.industryPlacement(id: "merchant-no-beer-sale")]
                )
            ),
            actorID: actor,
            state: state,
            catalog: catalog
        )
        let oxford = try #require(response.nextChoices.first {
            $0.value == .merchant(id: "oxford-1")
        })

        #expect(oxford.label == "牛津 · 任意制成品 · 啤酒已用尽 · 收入 +2（不可用）")
    }

    @Test func legalBuildQueryOnlyOffersIndustriesWithAValidTargetForTheSelectedLocationCard() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        let card = GameCore.CardInstance(
            id: "query-location-kidderminster",
            definitionID: "location-kidderminster"
        )
        state.players[playerIndex].hand = [card]
        state.players[playerIndex].cash = 100
        state.boardIndustryPlacements = [
            .init(
                placementID: "query-own-beer",
                locationID: "walsall",
                slotIndex: 1,
                ownerID: actor,
                tile: .init(
                    id: "query-own-beer-tile",
                    industryDefinitionID: "brewery",
                    level: 1
                ),
                resourceCount: 1
            ),
        ]
        state.publicSupply.beer -= 1
        repairCardFixture(&state, catalog: catalog)
        let canonicalCardID = try #require(state.players[playerIndex].hand.first?.id)

        let response = try GameCore.LegalActionQueryEngine.respond(
            to: .init(
                requestID: "kidderminster-build-industries",
                baseVersion: state.authoritativeVersion,
                draft: .init(action: .build, cardID: canonicalCardID, selections: [])
            ),
            actorID: actor,
            state: state,
            catalog: catalog
        )
        let tileIDs = response.nextChoices.compactMap { choice in
            if case .industryTile(let id) = choice.value { id } else { nil }
        }
        let topTilesByID = Dictionary(uniqueKeysWithValues: state.players[playerIndex]
            .industryStacks.compactMap(\.tiles.first)
            .map { ($0.id, $0) })
        let industries = Set(tileIDs.compactMap { topTilesByID[$0]?.industryDefinitionID })

        #expect(industries == ["cotton-mill", "coal-mine"])
        #expect(tileIDs.allSatisfy { tileID in
            guard let tile = topTilesByID[tileID] else { return false }
            return GameCore.BuildRules.legalBuildTargets(
                actorID: actor,
                cardID: canonicalCardID,
                tile: tile,
                state: state,
                catalog: catalog
            ).isEmpty == false
        })
    }

    @Test func railAndDevelopQueriesRequireAnExplicitAuthoritativeCountBeforeTargets() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        state.era = .rail
        let actor = try #require(state.activePlayerID)
        let card = try #require(state.players.first(where: { $0.id == actor })?.hand.first)

        let rail = try GameCore.LegalActionQueryEngine.respond(
            to: .init(requestID: "rail-count", baseVersion: state.authoritativeVersion,
                      draft: .init(action: .network, cardID: card.id, selections: [])),
            actorID: actor, state: state, catalog: catalog
        )
        #expect(rail.nextChoices.map(\.value) == [.networkLinkCount(1), .networkLinkCount(2)])

        let develop = try GameCore.LegalActionQueryEngine.respond(
            to: .init(requestID: "develop-count", baseVersion: state.authoritativeVersion,
                      draft: .init(action: .develop, cardID: card.id, selections: [])),
            actorID: actor, state: state, catalog: catalog
        )
        #expect(develop.nextChoices.map(\.value) == [.developTileCount(1), .developTileCount(2)])
    }

    @Test func twoTileDevelopQueryAlternatesValidatedHeadsAndIronThenDryRunsConfirmation() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        state.players[playerIndex].cash = 100
        let card = try #require(state.players[playerIndex].hand.first)
        var selections: [GameCore.LegalChoiceValue] = [.developTileCount(2)]

        func response() throws -> GameCore.LegalActionResponse {
            try GameCore.LegalActionQueryEngine.respond(
                to: .init(requestID: "develop-two", baseVersion: state.authoritativeVersion,
                          draft: .init(action: .develop, cardID: card.id, selections: selections)),
                actorID: actor, state: state, catalog: catalog
            )
        }

        let firstTile = try #require(try response().nextChoices.first)
        selections.append(firstTile.value)
        let firstIron = try #require(try response().nextChoices.first)
        selections.append(firstIron.value)
        let secondTile = try #require(try response().nextChoices.first)
        #expect({ if case .industryTile = secondTile.value { true } else { false } }())
        selections.append(secondTile.value)
        let secondIron = try #require(try response().nextChoices.first)
        selections.append(secondIron.value)

        let complete = try response()
        guard case .develop(let intent) = complete.completePayload else {
            Issue.record("Expected typed two-tile develop payload")
            return
        }
        #expect(intent.tileIDs.count == 2)
        #expect(intent.ironSources.count == 2)
        #expect((complete.confirmation?.cashDelta ?? 0) < 0)
        #expect(complete.confirmation?.resourceEffects.isEmpty == false)
        #expect(state.players[playerIndex].cash == 100, "Dry-run must not mutate authoritative state")
    }

    @Test func sellQueryCanContinueIntoASecondOrderedSaleBeforeCompleting() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        state.players[playerIndex].cash = 100
        let card = try #require(state.players[playerIndex].hand.first)
        state.merchants = knownQueryMerchants()
        state.placedLinks = [
            .init(routeID: "birmingham-worcester", ownerID: actor, era: .canal),
            .init(routeID: "gloucester-worcester", ownerID: actor, era: .canal),
        ]
        state.players[playerIndex].linksRemaining = 12
        state.boardIndustryPlacements = [
            .init(placementID: "sale-a", locationID: "birmingham", slotIndex: 0, ownerID: actor,
                  tile: .init(id: "sale-a-tile", industryDefinitionID: "cotton-mill", level: 1)),
            .init(placementID: "sale-b", locationID: "worcester", slotIndex: 0, ownerID: actor,
                  tile: .init(id: "sale-b-tile", industryDefinitionID: "cotton-mill", level: 1)),
            .init(placementID: "beer-a", locationID: "walsall", slotIndex: 1, ownerID: actor,
                  tile: .init(id: "beer-a-tile", industryDefinitionID: "brewery", level: 1), resourceCount: 1),
        ]
        state.publicSupply.beer -= 1
        repairCardFixture(&state, catalog: catalog)
        var selections: [GameCore.LegalChoiceValue] = []

        func response() throws -> GameCore.LegalActionResponse {
            try GameCore.LegalActionQueryEngine.respond(
                to: .init(requestID: "sell-two", baseVersion: state.authoritativeVersion,
                          draft: .init(action: .sell, cardID: card.id, selections: selections)),
                actorID: actor, state: state, catalog: catalog
            )
        }
        func chooseUntilDisposition() throws -> GameCore.LegalActionResponse {
            for _ in 0..<5 {
                let current = try response()
                if current.nextChoices.contains(where: {
                    if case .sellDisposition = $0.value { true } else { false }
                }) { return current }
                selections.append(try #require(current.nextChoices.first).value)
            }
            Issue.record("Sell query did not reach disposition")
            return try response()
        }

        selections.append(try #require(try response().nextChoices.first).value)
        selections.append(try #require(try response().nextChoices.first).value)
        let firstDisposition = try chooseUntilDisposition()
        let continueChoice = try #require(firstDisposition.nextChoices.first(where: {
            $0.value == .sellDisposition(continueSelling: true)
        }))
        selections.append(continueChoice.value)
        selections.append(try #require(try response().nextChoices.first).value)
        selections.append(try #require(try response().nextChoices.first).value)
        let secondDisposition = try chooseUntilDisposition()
        selections.append(try #require(secondDisposition.nextChoices.first(where: {
            $0.value == .sellDisposition(continueSelling: false)
        })).value)

        let complete = try response()
        guard case .sell(let intent) = complete.completePayload else {
            Issue.record("Expected typed multi-sale payload")
            return
        }
        #expect(intent.sales.map(\.industryPlacementID) == ["sale-a", "sale-b"])
        #expect((complete.confirmation?.incomeDelta ?? 0) > 0)
        #expect(state.boardIndustryPlacements.filter(\.isFlipped).isEmpty)
    }

    @Test func twoRailQueryRequestsSecondRouteOnlyAfterFirstCoalAndDryRunsAllResources() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        state.era = .rail
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        state.players[playerIndex].cash = 100
        let card = GameCore.CardInstance(id: "wild-industry-1", definitionID: "wild-industry")
        state.players[playerIndex].hand = [card]
        let opponent = try #require(state.players.first { $0.id != actor }).id
        state.placedLinks = [
            .init(routeID: "birmingham-oxford", ownerID: opponent, era: .rail),
            .init(routeID: "birmingham-walsall", ownerID: opponent, era: .rail),
        ]
        state.boardIndustryPlacements = [
            .init(placementID: "rail-beer", locationID: "walsall", slotIndex: 1, ownerID: actor,
                  tile: .init(id: "rail-beer-tile", industryDefinitionID: "brewery", level: 2), resourceCount: 1),
        ]
        state.publicSupply.beer -= 1
        repairCardFixture(&state, catalog: catalog)
        let linksBeforeQuery = state.placedLinks
        var selections: [GameCore.LegalChoiceValue] = [.networkLinkCount(2)]
        func response() throws -> GameCore.LegalActionResponse {
            try GameCore.LegalActionQueryEngine.respond(
                to: .init(requestID: "rail-two", baseVersion: state.authoritativeVersion,
                          draft: .init(action: .network, cardID: card.id, selections: selections)),
                actorID: actor, state: state, catalog: catalog
            )
        }

        let firstRoute = try #require(try response().nextChoices.first(where: {
            $0.value == .route(id: "tamworth-walsall")
        }))
        #expect({ if case .route = firstRoute.value { true } else { false } }())
        selections.append(firstRoute.value)
        let firstCoal = try #require(try response().nextChoices.first)
        selections.append(firstCoal.value)
        let secondRoute = try #require(try response().nextChoices.first)
        #expect({ if case .route = secondRoute.value { true } else { false } }())
        selections.append(secondRoute.value)
        let secondCoal = try #require(try response().nextChoices.first)
        selections.append(secondCoal.value)
        let beer = try #require(try response().nextChoices.first)
        selections.append(beer.value)

        let complete = try response()
        guard case .network(let intent) = complete.completePayload else {
            Issue.record("Expected typed two-rail payload")
            return
        }
        #expect(intent.routeIDs.count == 2)
        #expect(intent.coalSources.count == 2)
        #expect(intent.beerSource != nil)
        #expect(complete.confirmation?.cashDelta == -18)
        #expect(complete.confirmation?.resourceEffects.isEmpty == false)
        #expect(state.placedLinks == linksBeforeQuery)
    }

    @Test func legalQueryRejectsForeignOrOutOfOrderPrefixValues() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        state.era = .rail
        let actor = try #require(state.activePlayerID)
        let card = try #require(state.players.first(where: { $0.id == actor })?.hand.first)
        func query(_ action: GameCore.ActionKind, _ selections: [GameCore.LegalChoiceValue]) throws {
            _ = try GameCore.LegalActionQueryEngine.respond(
                to: .init(requestID: "malicious", baseVersion: state.authoritativeVersion,
                          draft: .init(action: action, cardID: card.id, selections: selections)),
                actorID: actor, state: state, catalog: catalog
            )
        }

        #expect(throws: GameCore.LegalActionQueryError.invalidPrefix) {
            try query(.network, [.route(id: "birmingham-tamworth")])
        }
        #expect(throws: GameCore.LegalActionQueryError.invalidPrefix) {
            try query(.develop, [.developTileCount(1), .card(id: card.id)])
        }
        #expect(throws: GameCore.LegalActionQueryError.invalidPrefix) {
            try query(.sell, [.card(id: card.id)])
        }
        #expect(throws: GameCore.LegalActionQueryError.invalidPrefix) {
            try query(.pass, [.networkLinkCount(1)])
        }
    }

    @Test func canalNetworkRejectsDisconnectedAtomicallyThenPlacesOneLinkForThreePounds() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        let card = GameCore.CardInstance(id: "location-birmingham-2", definitionID: "location-birmingham")
        state.players[playerIndex].hand = [card]
        state.players[playerIndex].cash = 20
        state.boardIndustryPlacements = [
            .init(
                locationID: "birmingham", slotIndex: 1, ownerID: actor,
                tile: .init(id: "network-anchor", industryDefinitionID: "manufacturer", level: 1)
            ),
        ]
        let original = state

        #expect(throws: GameCore.NetworkRuleError.self) {
            try GameCore.NetworkRules.validate(
                .init(cardID: card.id, routeIDs: ["burton-on-trent-derby"], coalSources: [], beerSource: nil),
                actorID: actor,
                state: state,
                catalog: catalog
            )
        }
        #expect(state == original)

        let target = try GameCore.NetworkRules.validate(
            .init(cardID: card.id, routeIDs: ["birmingham-tamworth"], coalSources: [], beerSource: nil),
            actorID: actor,
            state: state,
            catalog: catalog
        )
        let event = try GameCore.GameRulesEngine.resolveNetwork(
            target,
            roomID: .init(rawValue: "build-network-tests"),
            state: &state,
            catalog: catalog
        )

        #expect(state.placedLinks == [.init(routeID: "birmingham-tamworth", ownerID: actor, era: .canal)])
        #expect(state.players[playerIndex].cash == 17)
        #expect(state.players[playerIndex].spent == 3)
        #expect(state.players[playerIndex].linksRemaining == 13)
        #expect(state.publicDiscard.last == card)
        #expect(event.version.rawValue == original.authoritativeVersion.rawValue + 1)
        #expect(event.actionNumber == original.actionNumber + 1)
    }

    @Test func buildEventStrictlyReplaysToTheSameCanonicalState() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        let card = GameCore.CardInstance(id: "replay-card", definitionID: "location-dudley")
        state.players[playerIndex].hand = [card]
        state.players[playerIndex].cash = 20
        let before = state
        let target = try GameCore.BuildRules.validate(
            .init(cardID: card.id, locationID: "dudley", industryDefinitionID: "coal-mine", slotIndex: 0, resourceSources: []),
            actorID: actor, state: state, catalog: catalog
        )
        let event = try GameCore.GameRulesEngine.resolveBuild(
            target, roomID: .init(rawValue: "build-network-tests"), state: &state, catalog: catalog
        )
        var replayed = before

        try GameCore.GameRulesEngine.replay(
            event, expectedRoomID: .init(rawValue: "build-network-tests"),
            to: &replayed, catalog: catalog
        )

        #expect(try replayed.canonicalBytes() == state.canonicalBytes())
        var unchanged = before
        let tampered = GameCore.AuthoritativeGameEvent(
            roomID: event.roomID, actor: event.actor,
            previousVersion: event.previousVersion, version: event.version,
            actionNumber: event.actionNumber + 1, payload: event.payload
        )
        #expect(throws: GameCore.GameRulesEngine.ReplayError.invalidEvent) {
            try GameCore.GameRulesEngine.replay(
                tampered, expectedRoomID: .init(rawValue: "build-network-tests"),
                to: &unchanged, catalog: catalog
            )
        }
        #expect(unchanged == before)
    }

    @Test func mixedPassBuildAndNetworkEventsReplayStrictlyAndRejectTamperedPass() throws {
        let catalog = try verifiedCatalog()
        var initial = try setupState(catalog: catalog)
        initial.roundNumber = 2
        initial.actionsRemaining = 2
        let first = try #require(initial.activePlayerID)
        let firstIndex = try #require(initial.players.firstIndex { $0.id == first })
        let second = try #require(initial.players.first(where: { $0.id != first })?.id)
        let secondIndex = try #require(initial.players.firstIndex { $0.id == second })
        initial.players[firstIndex].hand = [
            .init(id: "location-birmingham-1", definitionID: "location-birmingham"),
            .init(id: "location-dudley-1", definitionID: "location-dudley"),
        ]
        initial.players[secondIndex].hand = [
            .init(id: "location-birmingham-2", definitionID: "location-birmingham")
        ]
        initial.players[firstIndex].cash = 20
        initial.players[secondIndex].cash = 20
        initial.boardIndustryPlacements = [
            .init(
                locationID: "birmingham", slotIndex: 1, ownerID: second,
                tile: .init(id: "network-anchor", industryDefinitionID: "manufacturer", level: 1)
            )
        ]
        let roomID = GameCore.RoomID(rawValue: "mixed-replay")
        repairCardFixture(&initial, catalog: catalog)
        let tokens = Dictionary(uniqueKeysWithValues: initial.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        var host = try initial.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 1
        )

        func intent(
            sender: GameCore.PlayerID,
            version: GameCore.AuthoritativeVersion,
            payload: GameCore.PlayerIntent.Payload
        ) -> GameCore.PlayerIntent {
            .init(
                protocolVersion: 1, rulesetVersion: initial.rulesetVersion,
                roomID: roomID, senderID: sender, reconnectToken: tokens[sender]!,
                baseVersion: version, payload: payload
            )
        }
        let pass = try #require(host.submit(intent(
            sender: first, version: host.gameState.authoritativeVersion,
            payload: .pass(.init(cardID: "location-birmingham-1"))
        ), catalog: catalog).acceptedEvent)
        let build = try #require(host.submit(intent(
            sender: first, version: host.gameState.authoritativeVersion,
            payload: .build(.init(
                cardID: "location-dudley-1", locationID: "dudley",
                industryDefinitionID: "coal-mine", slotIndex: 0, resourceSources: []
            ))
        ), catalog: catalog).acceptedEvent)
        let network = try #require(host.submit(intent(
            sender: second, version: host.gameState.authoritativeVersion,
            payload: .network(.init(
                cardID: "location-birmingham-2", routeIDs: ["birmingham-tamworth"],
                coalSources: [], beerSource: nil
            ))
        ), catalog: catalog).acceptedEvent)

        var replayed = initial
        for event in [pass, build, network] {
            try GameCore.GameRulesEngine.replay(
                event, expectedRoomID: roomID, to: &replayed, catalog: catalog
            )
        }
        #expect(replayed == host.gameState)

        var unchanged = initial
        let tampered = GameCore.AuthoritativeGameEvent(
            roomID: pass.roomID, actor: pass.actor,
            previousVersion: pass.previousVersion, version: pass.version,
            actionNumber: pass.actionNumber,
            payload: .passed(discardedCardID: "forged-card")
        )
        #expect(throws: GameCore.GameRulesEngine.ReplayError.invalidEvent) {
            try GameCore.GameRulesEngine.replay(
                tampered, expectedRoomID: roomID, to: &unchanged, catalog: catalog
            )
        }
        #expect(unchanged == initial)
    }

    @Test func opponentCoalOverbuildRequiresGlobalAndMarketExhaustionThenPreservesOldOwnerScore() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let opponent = try #require(state.players.first(where: { $0.id != actor }))
        let actorIndex = try #require(state.players.firstIndex(where: { $0.id == actor }))
        let opponentIndex = try #require(state.players.firstIndex(where: { $0.id == opponent.id }))
        let actorStack = try #require(state.players[actorIndex].industryStacks.firstIndex(where: {
            $0.industryDefinitionID == "coal-mine"
        }))
        let opponentStack = try #require(state.players[opponentIndex].industryStacks.firstIndex(where: {
            $0.industryDefinitionID == "coal-mine"
        }))
        state.players[actorIndex].industryStacks[actorStack].tiles.removeFirst()
        let oldTile = state.players[opponentIndex].industryStacks[opponentStack].tiles.removeFirst()
        let card = GameCore.CardInstance(id: "opponent-overbuild", definitionID: "location-dudley")
        state.players[actorIndex].hand = [card]
        state.players[actorIndex].cash = 20
        state.players[opponentIndex].incomePosition = 12
        state.players[opponentIndex].victoryPoints = 7
        state.boardIndustryPlacements = [
            .init(locationID: "dudley", slotIndex: 0, ownerID: opponent.id, tile: oldTile)
        ]
        state.coalMarket.slots.indices.forEach { state.coalMarket.slots[$0].hasCube = false }
        state.publicSupply.coal = 30

        var blocked = state
        blocked.coalMarket.slots[0].hasCube = true
        blocked.publicSupply.coal = 29
        #expect(throws: GameCore.BuildRuleError.illegalOverbuild) {
            try GameCore.BuildRules.validate(
                .init(cardID: card.id, locationID: "dudley", industryDefinitionID: "coal-mine", slotIndex: 0, resourceSources: []),
                actorID: actor, state: blocked, catalog: catalog
            )
        }

        var mapBlocked = state
        mapBlocked.boardIndustryPlacements.append(.init(
            locationID: "cannock", slotIndex: 0, ownerID: opponent.id,
            tile: .init(id: "remaining-coal", industryDefinitionID: "coal-mine", level: 1),
            resourceCount: 1
        ))
        mapBlocked.publicSupply.coal = 29
        #expect(throws: GameCore.BuildRuleError.illegalOverbuild) {
            try GameCore.BuildRules.validate(
                .init(cardID: card.id, locationID: "dudley", industryDefinitionID: "coal-mine", slotIndex: 0, resourceSources: []),
                actorID: actor, state: mapBlocked, catalog: catalog
            )
        }

        let target = try GameCore.BuildRules.validate(
            .init(cardID: card.id, locationID: "dudley", industryDefinitionID: "coal-mine", slotIndex: 0, resourceSources: []),
            actorID: actor, state: state, catalog: catalog
        )
        _ = try GameCore.GameRulesEngine.resolveBuild(
            target, roomID: .init(rawValue: "build-network-tests"), state: &state, catalog: catalog
        )
        #expect(state.boardIndustryPlacements.count == 1)
        #expect(state.boardIndustryPlacements[0].ownerID == actor)
        #expect(state.boardIndustryPlacements[0].tile.level == 2)
        #expect(state.players[opponentIndex].incomePosition == 12)
        #expect(state.players[opponentIndex].victoryPoints == 7)
    }

    @Test func opponentIronOverbuildRejectsMapOrMarketResourceAndSucceedsOnlyWhenExhausted() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let opponent = try #require(state.players.first(where: { $0.id != actor })).id
        let actorIndex = try #require(state.players.firstIndex(where: { $0.id == actor }))
        let opponentIndex = try #require(state.players.firstIndex(where: { $0.id == opponent }))
        let actorStack = try #require(state.players[actorIndex].industryStacks.firstIndex(where: {
            $0.industryDefinitionID == "iron-works"
        }))
        let opponentStack = try #require(state.players[opponentIndex].industryStacks.firstIndex(where: {
            $0.industryDefinitionID == "iron-works"
        }))
        state.players[actorIndex].industryStacks[actorStack].tiles.removeFirst()
        let oldTile = state.players[opponentIndex].industryStacks[opponentStack].tiles.removeFirst()
        let card = GameCore.CardInstance(id: "location-dudley-1", definitionID: "location-dudley")
        state.players[actorIndex].hand = [card]
        state.players[actorIndex].cash = 40
        state.boardIndustryPlacements = [
            .init(
                locationID: "dudley", slotIndex: 0, ownerID: opponent,
                tile: .init(id: "overbuild-coal", industryDefinitionID: "coal-mine", level: 1),
                resourceCount: 1
            ),
            .init(locationID: "dudley", slotIndex: 1, ownerID: opponent, tile: oldTile),
        ]
        state.publicSupply.coal -= 1
        state.ironMarket.slots.indices.forEach { state.ironMarket.slots[$0].hasCube = false }
        state.publicSupply.iron = 18
        repairCardFixture(&state, catalog: catalog)
        let intent = GameCore.BuildIntent(
            cardID: card.id, locationID: "dudley",
            industryDefinitionID: "iron-works", slotIndex: 1,
            resourceSources: [.industry(placementID: "dudley#0")]
        )

        var mapBlocked = state
        mapBlocked.boardIndustryPlacements.append(.init(
            locationID: "coalbrookdale", slotIndex: 1, ownerID: opponent,
            tile: .init(id: "remaining-iron", industryDefinitionID: "iron-works", level: 1),
            resourceCount: 1
        ))
        mapBlocked.publicSupply.iron = 17
        #expect(throws: GameCore.BuildRuleError.illegalOverbuild) {
            try GameCore.BuildRules.validate(intent, actorID: actor, state: mapBlocked, catalog: catalog)
        }
        var marketBlocked = state
        marketBlocked.ironMarket.slots[0].hasCube = true
        marketBlocked.publicSupply.iron = 17
        #expect(throws: GameCore.BuildRuleError.illegalOverbuild) {
            try GameCore.BuildRules.validate(intent, actorID: actor, state: marketBlocked, catalog: catalog)
        }

        let target = try GameCore.BuildRules.validate(intent, actorID: actor, state: state, catalog: catalog)
        _ = try GameCore.GameRulesEngine.resolveBuild(
            target, roomID: .init(rawValue: "build-network-tests"), state: &state, catalog: catalog
        )
        #expect(state.boardIndustryPlacements.filter { $0.locationID == "dudley" && $0.slotIndex == 1 }.count == 1)
        #expect(state.boardIndustryPlacements.first(where: { $0.placementID == "dudley#1" })?.ownerID == actor)
        #expect(state.boardIndustryPlacements.first(where: { $0.placementID == "dudley#1" })?.tile.level == 2)
    }

    @Test func wildBuildReturnsToPoolAndCanalOwnOneAndWrongEraFailClosed() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex(where: { $0.id == actor }))
        let wild = GameCore.CardInstance(id: "wild-build", definitionID: "wild-industry")
        state.players[playerIndex].hand = [wild]
        state.players[playerIndex].cash = 20
        let poolCount = state.wildIndustryPool.count
        let target = try GameCore.BuildRules.validate(
            .init(cardID: wild.id, locationID: "dudley", industryDefinitionID: "coal-mine", slotIndex: 0, resourceSources: []),
            actorID: actor, state: state, catalog: catalog
        )
        _ = try GameCore.GameRulesEngine.resolveBuild(
            target, roomID: .init(rawValue: "build-network-tests"), state: &state, catalog: catalog
        )
        #expect(state.wildIndustryPool.count == poolCount + 1)
        #expect(state.wildIndustryPool.last == wild)
        #expect(state.publicDiscard.contains(wild) == false)

        var wildLocationState = try setupState(catalog: catalog)
        let wildLocationActor = try #require(wildLocationState.activePlayerID)
        let wildLocationIndex = try #require(wildLocationState.players.firstIndex { $0.id == wildLocationActor })
        let wildLocation = GameCore.CardInstance(id: "wild-location-build", definitionID: "wild-location")
        wildLocationState.players[wildLocationIndex].hand = [wildLocation]
        let wildLocationPoolCount = wildLocationState.wildLocationPool.count
        let wildLocationTarget = try GameCore.BuildRules.validate(
            .init(
                cardID: wildLocation.id, locationID: "dudley",
                industryDefinitionID: "coal-mine", slotIndex: 0, resourceSources: []
            ),
            actorID: wildLocationActor, state: wildLocationState, catalog: catalog
        )
        let wildLocationEvent = try GameCore.GameRulesEngine.resolveBuild(
            wildLocationTarget, roomID: .init(rawValue: "build-network-tests"),
            state: &wildLocationState, catalog: catalog
        )
        #expect(wildLocationState.wildLocationPool.count == wildLocationPoolCount + 1)
        #expect(wildLocationState.wildLocationPool.last == wildLocation)
        #expect(wildLocationState.publicDiscard.contains(wildLocation) == false)
        guard case let .built(eventIntent, placement, effects) = wildLocationEvent.payload else {
            Issue.record("Expected wild-location build event")
            return
        }
        #expect(eventIntent.cardID == wildLocation.id)
        #expect(placement == wildLocationState.boardIndustryPlacements.first(where: {
            $0.placementID == "dudley#0"
        }))
        #expect(effects.contains(.marketDeliveryResolved(placementID: "dudley#0")))

        var canal = try setupState(catalog: catalog)
        let canalActor = try #require(canal.activePlayerID)
        let canalIndex = try #require(canal.players.firstIndex(where: { $0.id == canalActor }))
        canal.players[canalIndex].hand = [.init(id: "birmingham", definitionID: "location-birmingham")]
        canal.boardIndustryPlacements = [
            .init(
                locationID: "birmingham", slotIndex: 2, ownerID: canalActor,
                tile: .init(id: "existing-iron", industryDefinitionID: "iron-works", level: 1)
            )
        ]
        #expect(throws: GameCore.BuildRuleError.canalLocationLimit) {
            try GameCore.BuildRules.validate(
                .init(
                    cardID: "birmingham", locationID: "birmingham",
                    industryDefinitionID: "manufacturer", slotIndex: 1,
                    resourceSources: [.marketSlot(resource: .coal, index: 1), .merchantBeer(slotID: "oxford-1")]
                ),
                actorID: canalActor, state: canal, catalog: catalog
            )
        }

        var rail = try setupState(catalog: catalog)
        rail.era = .rail
        let railActor = try #require(rail.activePlayerID)
        let railIndex = try #require(rail.players.firstIndex(where: { $0.id == railActor }))
        rail.players[railIndex].hand = [.init(id: "brewery", definitionID: "industry-brewery")]
        #expect(throws: GameCore.BuildRuleError.wrongEra) {
            try GameCore.BuildRules.validate(
                .init(
                    cardID: "brewery", locationID: "cannock-farm",
                    industryDefinitionID: "brewery", slotIndex: 0,
                    resourceSources: [.marketSlot(resource: .iron, index: 2)]
                ),
                actorID: railActor, state: rail, catalog: catalog
            )
        }
    }

    @Test func cardFarmSlotPriorityAndFirstBuildRulesAreEnforced() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })

        state.players[playerIndex].hand = [
            .init(id: "industry-coal-mine-2-plus-1", definitionID: "industry-coal-mine-2-plus"),
            .init(id: "wild-location-1", definitionID: "wild-location"),
            .init(id: "location-birmingham-1", definitionID: "location-birmingham"),
        ]
        repairCardFixture(&state, catalog: catalog)
        _ = try GameCore.BuildRules.validate(
            .init(cardID: "industry-coal-mine-2-plus-1", locationID: "dudley", industryDefinitionID: "coal-mine", slotIndex: 0, resourceSources: []),
            actorID: actor, state: state, catalog: catalog
        )
        state.players[playerIndex].hand = [
            .init(id: "industry-brewery-1", definitionID: "industry-brewery")
        ]
        repairCardFixture(&state, catalog: catalog)
        let farmTarget = try GameCore.BuildRules.validate(
            .init(
                cardID: "industry-brewery-1", locationID: "cannock-farm",
                industryDefinitionID: "brewery", slotIndex: 0,
                resourceSources: [.marketSlot(resource: .iron, index: 2)]
            ),
            actorID: actor, state: state, catalog: catalog
        )
        let ironBefore = state.ironMarket.slots[2].hasCube
        let farmEvent = try GameCore.GameRulesEngine.resolveBuild(
            farmTarget, roomID: .init(rawValue: "build-network-tests"),
            state: &state, catalog: catalog
        )
        #expect(state.boardIndustryPlacements.contains {
            $0.placementID == "cannock-farm#0" && $0.ownerID == actor
        })
        #expect(ironBefore)
        #expect(state.ironMarket.slots[2].hasCube == false)
        guard case let .built(_, _, farmEffects) = farmEvent.payload else {
            Issue.record("Expected farm build event")
            return
        }
        #expect(farmEffects.contains(.resourceRemoved(
            resource: .iron,
            source: .marketSlot(resource: .iron, index: 2),
            consumerLocationID: "cannock-farm"
        )))

        state = try setupState(catalog: catalog)
        let resetActor = try #require(state.activePlayerID)
        let resetIndex = try #require(state.players.firstIndex { $0.id == resetActor })
        state.players[resetIndex].hand = [
            .init(id: "industry-coal-mine-2-plus-1", definitionID: "industry-coal-mine-2-plus"),
            .init(id: "wild-location-1", definitionID: "wild-location"),
            .init(id: "location-birmingham-1", definitionID: "location-birmingham"),
        ]
        repairCardFixture(&state, catalog: catalog)
        let resetTokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        var rejectedFarmHost = try state.makeHostEngine(
            roomID: .init(rawValue: "farm-rejection"),
            reconnectTokens: resetTokens, protocolVersion: 1
        )
        let rejectedFarmBefore = rejectedFarmHost.gameState
        let rejectedFarmIntent = GameCore.PlayerIntent(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion,
            roomID: .init(rawValue: "farm-rejection"), senderID: resetActor,
            reconnectToken: resetTokens[resetActor]!, baseVersion: state.authoritativeVersion,
            payload: .build(.init(
                cardID: "wild-location-1", locationID: "cannock-farm",
                industryDefinitionID: "brewery", slotIndex: 0,
                resourceSources: [.marketSlot(resource: .iron, index: 2)]
            ))
        )
        let rejectedFarmResult = rejectedFarmHost.submit(rejectedFarmIntent, catalog: catalog)
        guard case .rejected = rejectedFarmResult else {
            Issue.record("Expected farm rejection through host action dispatch, got \(rejectedFarmResult)")
            return
        }
        #expect(rejectedFarmHost.gameState == rejectedFarmBefore)
        #expect(rejectedFarmHost.gameState.authoritativeVersion == rejectedFarmBefore.authoritativeVersion)
        #expect(rejectedFarmHost.gameState.actionNumber == rejectedFarmBefore.actionNumber)
        #expect(throws: GameCore.BuildRuleError.farmRestricted) {
            try GameCore.BuildRules.validate(
                .init(cardID: "wild-location-1", locationID: "cannock-farm", industryDefinitionID: "brewery", slotIndex: 0, resourceSources: [.marketSlot(resource: .iron, index: 2)]),
                actorID: resetActor, state: state, catalog: catalog
            )
        }
        #expect(throws: GameCore.BuildRuleError.slotPriority) {
            try GameCore.BuildRules.validate(
                .init(cardID: "location-birmingham-1", locationID: "birmingham", industryDefinitionID: "manufacturer", slotIndex: 0, resourceSources: [.marketSlot(resource: .coal, index: 1)]),
                actorID: resetActor, state: state, catalog: catalog
            )
        }
    }

    @Test func ownOverbuildReturnsResourcesAndUsesNextHigherTile() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        let stackIndex = try #require(state.players[playerIndex].industryStacks.firstIndex { $0.industryDefinitionID == "coal-mine" })
        let levelOne = state.players[playerIndex].industryStacks[stackIndex].tiles.removeFirst()
        let card = GameCore.CardInstance(id: "overbuild", definitionID: "location-dudley")
        state.players[playerIndex].hand = [card]
        state.players[playerIndex].cash = 20
        state.boardIndustryPlacements = [
            .init(locationID: "dudley", slotIndex: 0, ownerID: actor, tile: levelOne, resourceCount: 1),
        ]
        state.publicSupply.coal -= 1
        let target = try GameCore.BuildRules.validate(
            .init(cardID: card.id, locationID: "dudley", industryDefinitionID: "coal-mine", slotIndex: 0, resourceSources: []),
            actorID: actor, state: state, catalog: catalog
        )

        _ = try GameCore.GameRulesEngine.resolveBuild(
            target, roomID: .init(rawValue: "build-network-tests"), state: &state, catalog: catalog
        )

        #expect(state.boardIndustryPlacements.count == 1)
        #expect(state.boardIndustryPlacements[0].tile.level == 2)
        #expect(state.boardIndustryPlacements[0].tile.id != levelOne.id)
    }

    @Test func doubleRailConsumesCoalInOrderLetsFirstLinkUnlockSecondAndUsesOwnBeerAnywhere() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        state.era = .rail
        state.actionsRemaining = 2
        let actor = try #require(state.activePlayerID)
        let opponent = try #require(state.players.first { $0.id != actor }).id
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        let card = GameCore.CardInstance(id: "wild-industry-1", definitionID: "wild-industry")
        state.players[playerIndex].hand = [card]
        state.players[playerIndex].cash = 30
        state.placedLinks = [
            .init(routeID: "birmingham-oxford", ownerID: opponent, era: .rail),
            .init(routeID: "birmingham-walsall", ownerID: opponent, era: .rail),
        ]
        state.boardIndustryPlacements = [
            .init(
                locationID: "walsall", slotIndex: 1, ownerID: actor,
                tile: .init(id: "own-beer", industryDefinitionID: "brewery", level: 2),
                resourceCount: 1
            ),
        ]
        state.publicSupply.beer -= 1
        repairCardFixture(&state, catalog: catalog)
        let before = state
        let wildPoolCount = state.wildIndustryPool.count
        let intent = GameCore.NetworkIntent(
            cardID: card.id,
            routeIDs: ["tamworth-walsall", "burton-on-trent-tamworth"],
            coalSources: [
                .marketSlot(resource: .coal, index: 1),
                .marketSlot(resource: .coal, index: 2),
            ],
            beerSource: .industry(placementID: "walsall#1")
        )
        let merchantBeerIntent = GameCore.NetworkIntent(
            cardID: card.id, routeIDs: intent.routeIDs,
            coalSources: intent.coalSources, beerSource: .merchantBeer(slotID: "oxford-1")
        )
        #expect(throws: GameCore.NetworkRuleError.illegalBeer) {
            try GameCore.NetworkRules.validate(
                merchantBeerIntent, actorID: actor, state: state, catalog: catalog
            )
        }
        #expect(state == before)
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        let roomID = GameCore.RoomID(rawValue: "merchant-beer-rejection")
        var merchantHost = try state.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 1
        )
        let merchantHostBefore = merchantHost.gameState
        let merchantAction = GameCore.PlayerIntent(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion,
            roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
            baseVersion: state.authoritativeVersion, payload: .network(merchantBeerIntent)
        )
        let merchantResult = merchantHost.submit(merchantAction, catalog: catalog)
        guard case .rejected = merchantResult else {
            Issue.record("Expected merchant beer rejection through host action dispatch, got \(merchantResult)")
            return
        }
        #expect(merchantHost.gameState == merchantHostBefore)
        #expect(merchantHost.gameState.authoritativeVersion == merchantHostBefore.authoritativeVersion)
        #expect(merchantHost.gameState.actionNumber == merchantHostBefore.actionNumber)

        let target = try GameCore.NetworkRules.validate(
            intent, actorID: actor, state: state, catalog: catalog
        )
        let event = try GameCore.GameRulesEngine.resolveNetwork(
            target, roomID: .init(rawValue: "build-network-tests"), state: &state, catalog: catalog
        )

        #expect(state.players[playerIndex].cash == 12)
        #expect(state.players[playerIndex].spent == 18)
        #expect(state.players[playerIndex].linksRemaining == 12)
        #expect(state.boardIndustryPlacements[0].resourceCount == 0)
        #expect(state.placedLinks.suffix(2).map(\.routeID) == intent.routeIDs)
        #expect(state.wildIndustryPool.count == wildPoolCount + 1)
        #expect(state.wildIndustryPool.last == card)
        #expect(state.publicDiscard.contains(card) == false)
        #expect(event.version.rawValue == before.authoritativeVersion.rawValue + 1)
        var replayed = before
        try GameCore.GameRulesEngine.replay(
            event, expectedRoomID: .init(rawValue: "build-network-tests"), to: &replayed, catalog: catalog
        )
        #expect(replayed == state)
        var unchanged = before
        let tampered = GameCore.AuthoritativeGameEvent(
            roomID: event.roomID, actor: event.actor,
            previousVersion: event.previousVersion, version: event.version,
            actionNumber: event.actionNumber,
            payload: .networkBuilt(intent: intent, links: [], resourceEffects: [])
        )
        #expect(throws: GameCore.GameRulesEngine.ReplayError.invalidEvent) {
            try GameCore.GameRulesEngine.replay(
                tampered, expectedRoomID: .init(rawValue: "build-network-tests"),
                to: &unchanged, catalog: catalog
            )
        }
        #expect(unchanged == before)
    }

    @Test func opponentBeerConnectsOnlyAfterSecondRailAndWrongOrderOrSecondRouteRejectAtomically() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        state.era = .rail
        state.actionsRemaining = 2
        let actor = try #require(state.activePlayerID)
        let opponent = try #require(state.players.first(where: { $0.id != actor })).id
        let actorIndex = try #require(state.players.firstIndex(where: { $0.id == actor }))
        let opponentIndex = try #require(state.players.firstIndex(where: { $0.id == opponent }))
        let card = GameCore.CardInstance(id: "location-birmingham-1", definitionID: "location-birmingham")
        state.players[actorIndex].hand = [card]
        state.players[actorIndex].cash = 30
        state.placedLinks = [
            .init(routeID: "birmingham-oxford", ownerID: opponent, era: .rail),
            .init(routeID: "birmingham-walsall", ownerID: opponent, era: .rail),
        ]
        state.boardIndustryPlacements = [
            .init(
                locationID: "walsall", slotIndex: 0, ownerID: actor,
                tile: .init(id: "rail-anchor", industryDefinitionID: "manufacturer", level: 2)
            ),
            .init(
                locationID: "burton-on-trent", slotIndex: 1, ownerID: opponent,
                tile: .init(id: "opponent-rail-beer", industryDefinitionID: "brewery", level: 2),
                resourceCount: 1
            ),
        ]
        state.publicSupply.beer -= 1
        repairCardFixture(&state, catalog: catalog)
        let beer = GameCore.ResourceSource.industry(placementID: "burton-on-trent#1")
        var afterFirst = state
        afterFirst.placedLinks.append(.init(routeID: "tamworth-walsall", ownerID: actor, era: .rail))
        #expect(GameCore.GameRulesEngine.legalResourceSources(
            resource: .beer, consumerLocationID: "tamworth", context: .network,
            state: afterFirst, catalog: catalog
        ).contains(beer) == false)
        var afterSecond = afterFirst
        afterSecond.placedLinks.append(.init(routeID: "burton-on-trent-tamworth", ownerID: actor, era: .rail))
        #expect(GameCore.GameRulesEngine.legalResourceSources(
            resource: .beer, consumerLocationID: "tamworth", context: .network,
            state: afterSecond, catalog: catalog
        ).contains(beer))

        let original = state
        let coal: [GameCore.ResourceSource] = [
            .marketSlot(resource: .coal, index: 1),
            .marketSlot(resource: .coal, index: 2),
        ]
        #expect(throws: GameCore.NetworkRuleError.disconnectedRoute) {
            try GameCore.NetworkRules.validate(
                .init(
                    cardID: card.id,
                    routeIDs: ["burton-on-trent-tamworth", "tamworth-walsall"],
                    coalSources: coal, beerSource: beer
                ),
                actorID: actor, state: state, catalog: catalog
            )
        }
        #expect(state == original)
        #expect(throws: GameCore.NetworkRuleError.disconnectedRoute) {
            try GameCore.NetworkRules.validate(
                .init(
                    cardID: card.id,
                    routeIDs: ["tamworth-walsall", "burton-on-trent-derby"],
                    coalSources: coal, beerSource: beer
                ),
                actorID: actor, state: state, catalog: catalog
            )
        }
        #expect(state == original)

        let intent = GameCore.NetworkIntent(
            cardID: card.id,
            routeIDs: ["tamworth-walsall", "burton-on-trent-tamworth"],
            coalSources: coal, beerSource: beer
        )
        let target = try GameCore.NetworkRules.validate(intent, actorID: actor, state: state, catalog: catalog)
        _ = try GameCore.GameRulesEngine.resolveNetwork(
            target, roomID: .init(rawValue: "build-network-tests"), state: &state, catalog: catalog
        )
        #expect(state.boardIndustryPlacements.first(where: {
            $0.placementID == "burton-on-trent#1"
        })?.resourceCount == 0)
        #expect(state.players[opponentIndex].incomePosition > original.players[opponentIndex].incomePosition)
    }

    @Test func singleRailCostsFiveConsumesOneCoalAndRejectsCashLinksAndOccupiedRoute() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        state.era = .rail
        state.actionsRemaining = 2
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex(where: { $0.id == actor }))
        let card = GameCore.CardInstance(id: "location-birmingham-1", definitionID: "location-birmingham")
        state.players[playerIndex].hand = [card]
        state.players[playerIndex].cash = 20
        repairCardFixture(&state, catalog: catalog)
        let choice = try #require(catalog.catalog.board.routes.lazy.compactMap { route -> (String, GameCore.ResourceSource)? in
            guard route.eras.contains(.rail), route.playerCounts.contains(state.playerCount) else { return nil }
            var candidate = state
            candidate.placedLinks.append(.init(routeID: route.id, ownerID: actor, era: .rail))
            return route.adjacentLocationIDs.lazy.compactMap { locationID in
                GameCore.GameRulesEngine.legalResourceSources(
                    resource: .coal, consumerLocationID: locationID, context: .network,
                    state: candidate, catalog: catalog
                ).first.map { (route.id, $0) }
            }.first
        }.first)
        let intent = GameCore.NetworkIntent(
            cardID: card.id, routeIDs: [choice.0], coalSources: [choice.1], beerSource: nil
        )

        var noCash = state
        noCash.players[playerIndex].cash = 4
        #expect(throws: GameCore.NetworkRuleError.insufficientCash) {
            try GameCore.NetworkRules.validate(intent, actorID: actor, state: noCash, catalog: catalog)
        }
        var noLinks = state
        noLinks.players[playerIndex].linksRemaining = 0
        #expect(throws: GameCore.NetworkRuleError.insufficientLinks) {
            try GameCore.NetworkRules.validate(intent, actorID: actor, state: noLinks, catalog: catalog)
        }
        var occupied = state
        occupied.placedLinks = [.init(routeID: choice.0, ownerID: state.players.first(where: { $0.id != actor })!.id, era: .rail)]
        #expect(throws: GameCore.NetworkRuleError.occupiedRoute) {
            try GameCore.NetworkRules.validate(intent, actorID: actor, state: occupied, catalog: catalog)
        }
        #expect(throws: GameCore.NetworkRuleError.illegalCoal) {
            try GameCore.NetworkRules.validate(
                .init(cardID: card.id, routeIDs: [choice.0], coalSources: [], beerSource: nil),
                actorID: actor, state: state, catalog: catalog
            )
        }

        let target = try GameCore.NetworkRules.validate(intent, actorID: actor, state: state, catalog: catalog)
        let cashBefore = state.players[playerIndex].cash
        let linksBefore = state.players[playerIndex].linksRemaining
        let sourceBefore = resourceCount(for: choice.1, in: state)
        let event = try GameCore.GameRulesEngine.resolveNetwork(
            target, roomID: .init(rawValue: "build-network-tests"), state: &state, catalog: catalog
        )
        #expect(state.players[playerIndex].cash <= cashBefore - 5)
        #expect(state.players[playerIndex].spent >= 5)
        #expect(state.players[playerIndex].linksRemaining == linksBefore - 1)
        #expect(state.placedLinks.last?.routeID == choice.0)
        #expect(resourceCount(for: choice.1, in: state) == sourceBefore - 1)
        guard case let .networkBuilt(_, _, effects) = event.payload else {
            Issue.record("Expected network build event")
            return
        }
        #expect(effects.contains {
            if case let .resourceRemoved(resource, source, _) = $0 {
                return resource == .coal && source == choice.1
            }
            return false
        })
    }

    @Test func buildSecondResourceFailureLeavesCanonicalActionStateUnchanged() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex(where: { $0.id == actor }))
        let card = GameCore.CardInstance(id: "wild-location-1", definitionID: "wild-location")
        state.players[playerIndex].hand = [card]
        state.players[playerIndex].cash = 100
        state.boardIndustryPlacements = [
            .init(
                locationID: "walsall", slotIndex: 1, ownerID: actor,
                tile: .init(id: "atomic-beer", industryDefinitionID: "brewery", level: 1),
                resourceCount: 1
            )
        ]
        state.publicSupply.beer -= 1
        repairCardFixture(&state, catalog: catalog)
        let tile = try #require(state.players[playerIndex].industryStacks.first(where: {
            $0.industryDefinitionID == "pottery"
        })?.tiles.first)
        let target = try #require(GameCore.BuildRules.legalBuildTargets(
            actorID: actor, cardID: card.id, tile: tile, state: state, catalog: catalog
        ).first)
        let iron = try #require(GameCore.GameRulesEngine.legalResourceSources(
            resource: .iron, consumerLocationID: target.locationID,
            context: .standard, state: state, catalog: catalog
        ).first)
        let before = state
        #expect(throws: GameCore.BuildRuleError.illegalResourcePlan) {
            try GameCore.BuildRules.validate(.init(
                cardID: card.id, locationID: target.locationID,
                industryDefinitionID: "pottery", slotIndex: target.slotIndex,
                resourceSources: [iron, .industry(placementID: "missing-beer")]
            ), actorID: actor, state: state, catalog: catalog)
        }
        #expect(state == before)
    }

    @Test func coalBuildActionUsesSubstituteProductionDeliversFlipsAndEmitsSettledPlacementInOrder() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let opponent = try #require(state.players.first(where: { $0.id != actor })).id
        let actorIndex = try #require(state.players.firstIndex(where: { $0.id == actor }))
        let card = GameCore.CardInstance(id: "location-dudley-1", definitionID: "location-dudley")
        state.players[actorIndex].hand = [card]
        state.players[actorIndex].cash = 20
        state.placedLinks = [
            .init(routeID: "birmingham-dudley", ownerID: opponent, era: .canal),
            .init(routeID: "birmingham-oxford", ownerID: opponent, era: .canal),
        ]
        let occupied: [(String, Int)] = [
            ("leek", 1), ("belper", 1), ("stone", 1),
            ("cannock", 0), ("cannock", 1), ("burton-on-trent", 0),
            ("tamworth", 0), ("tamworth", 1), ("wolverhampton", 1),
        ]
        state.boardIndustryPlacements = occupied.enumerated().map { index, slot in
            .init(
                locationID: slot.0, slotIndex: slot.1, ownerID: opponent,
                tile: .init(id: "substitute-coal-\(index)", industryDefinitionID: "coal-mine", level: 1),
                resourceCount: 2
            )
        }
        state.publicSupply.coal = 0
        state.coalMarket.slots.indices.forEach { state.coalMarket.slots[$0].hasCube = true }
        state.coalMarket.slots[12].hasCube = false
        state.coalMarket.slots[13].hasCube = false
        repairCardFixture(&state, catalog: catalog)
        let beforeIncome = state.players[actorIndex].incomePosition
        let beforeCash = state.players[actorIndex].cash

        let target = try GameCore.BuildRules.validate(
            .init(
                cardID: card.id, locationID: "dudley",
                industryDefinitionID: "coal-mine", slotIndex: 0, resourceSources: []
            ),
            actorID: actor, state: state, catalog: catalog
        )
        let event = try GameCore.GameRulesEngine.resolveBuild(
            target, roomID: .init(rawValue: "build-network-tests"), state: &state, catalog: catalog
        )
        let built = try #require(state.boardIndustryPlacements.first(where: { $0.placementID == "dudley#0" }))
        #expect(built.resourceCount == 0)
        #expect(built.marketDeliveryResolved)
        #expect(built.isFlipped)
        #expect(state.publicSupply.coal == 0)
        #expect(state.coalMarket.slots[12].hasCube)
        #expect(state.coalMarket.slots[13].hasCube)
        #expect(state.players[actorIndex].cash == beforeCash - 5 + 14)
        #expect(state.players[actorIndex].incomePosition == beforeIncome + 4)
        #expect(state.boardIndustryPlacements.filter {
            $0.tile.industryDefinitionID == "coal-mine"
        }.reduce(0) { $0 + $1.resourceCount } + state.coalMarket.slots.filter(\.hasCube).count + state.publicSupply.coal == 32)

        guard case let .built(_, eventPlacement, effects) = event.payload else {
            Issue.record("Expected build event")
            return
        }
        #expect(eventPlacement == built)
        #expect(effects == [
            .resourceRemoved(resource: .coal, source: .industry(placementID: "dudley#0"), consumerLocationID: "dudley"),
            .marketDelivered(placementID: "dudley#0", resource: .coal, slotIndex: 12, price: 7),
            .cashReceived(playerID: actor, amount: 7),
            .resourceRemoved(resource: .coal, source: .industry(placementID: "dudley#0"), consumerLocationID: "dudley"),
            .marketDelivered(placementID: "dudley#0", resource: .coal, slotIndex: 13, price: 7),
            .cashReceived(playerID: actor, amount: 7),
            .marketDeliveryResolved(placementID: "dudley#0"),
            .industryFlipped(placementID: "dudley#0"),
            .incomeAdvanced(playerID: actor, from: beforeIncome, to: beforeIncome + 4),
        ])
    }

    @Test func ironBuildActionUsesSubstituteProductionAndCompletesDeliveryInsideOneEvent() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let opponent = try #require(state.players.first(where: { $0.id != actor })).id
        let actorIndex = try #require(state.players.firstIndex(where: { $0.id == actor }))
        let card = GameCore.CardInstance(id: "location-dudley-1", definitionID: "location-dudley")
        state.players[actorIndex].hand = [card]
        state.players[actorIndex].cash = 30
        let ironSlots: [(String, Int)] = [
            ("stoke-on-trent", 1), ("derby", 2), ("walsall", 0),
        ]
        state.boardIndustryPlacements = ironSlots.enumerated().map { index, slot in
            .init(
                locationID: slot.0, slotIndex: slot.1, ownerID: opponent,
                tile: .init(id: "substitute-iron-\(index)", industryDefinitionID: "iron-works", level: 1),
                resourceCount: 4
            )
        } + [
            .init(
                locationID: "dudley", slotIndex: 0, ownerID: opponent,
                tile: .init(id: "iron-build-coal", industryDefinitionID: "coal-mine", level: 1),
                resourceCount: 1
            ),
        ]
        state.publicSupply.iron = 0
        state.publicSupply.coal -= 1
        state.ironMarket.slots.indices.forEach { state.ironMarket.slots[$0].hasCube = true }
        for index in 6...9 { state.ironMarket.slots[index].hasCube = false }
        repairCardFixture(&state, catalog: catalog)
        let beforeIncome = state.players[actorIndex].incomePosition
        let target = try GameCore.BuildRules.validate(
            .init(
                cardID: card.id, locationID: "dudley",
                industryDefinitionID: "iron-works", slotIndex: 1,
                resourceSources: [.industry(placementID: "dudley#0")]
            ),
            actorID: actor, state: state, catalog: catalog
        )
        let event = try GameCore.GameRulesEngine.resolveBuild(
            target, roomID: .init(rawValue: "build-network-tests"), state: &state, catalog: catalog
        )
        let built = try #require(state.boardIndustryPlacements.first(where: { $0.placementID == "dudley#1" }))
        #expect(built.resourceCount == 0)
        #expect(built.marketDeliveryResolved)
        #expect(built.isFlipped)
        #expect(state.publicSupply.iron == 0)
        #expect(state.ironMarket.slots.allSatisfy { $0.hasCube })
        #expect(state.players[actorIndex].incomePosition == beforeIncome + 3)
        #expect(state.boardIndustryPlacements.filter {
            $0.tile.industryDefinitionID == "iron-works"
        }.reduce(0) { $0 + $1.resourceCount } + state.ironMarket.slots.filter(\.hasCube).count + state.publicSupply.iron == 22)
        guard case let .built(_, eventPlacement, effects) = event.payload else {
            Issue.record("Expected build event")
            return
        }
        #expect(eventPlacement == built)
        #expect(effects.suffix(3) == [
            .marketDeliveryResolved(placementID: "dudley#1"),
            .industryFlipped(placementID: "dudley#1"),
            .incomeAdvanced(playerID: actor, from: beforeIncome, to: beforeIncome + 3),
        ])
        #expect(event.version.rawValue == event.previousVersion.rawValue + 1)
    }

    @Test func rulesTwelveSeparatesCardsPlayerNetworkPlayerCountAndResourceConnectivity() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let opponent = try #require(state.players.first(where: { $0.id != actor })).id
        let actorIndex = try #require(state.players.firstIndex(where: { $0.id == actor }))
        state.players[actorIndex].hand = [
            .init(id: "location-dudley-1", definitionID: "location-dudley"),
            .init(id: "industry-coal-mine-2-plus-1", definitionID: "industry-coal-mine-2-plus"),
        ]
        state.boardIndustryPlacements = [
            .init(
                locationID: "walsall", slotIndex: 1, ownerID: actor,
                tile: .init(id: "player-network-anchor", industryDefinitionID: "manufacturer", level: 1)
            ),
        ]
        state.placedLinks = [
            .init(routeID: "birmingham-walsall", ownerID: opponent, era: .canal),
            .init(routeID: "birmingham-dudley", ownerID: opponent, era: .canal),
        ]
        repairCardFixture(&state, catalog: catalog)
        let locationTarget = try GameCore.BuildRules.validate(
            .init(
                cardID: "location-dudley-1", locationID: "dudley",
                industryDefinitionID: "coal-mine", slotIndex: 0, resourceSources: []
            ),
            actorID: actor, state: state, catalog: catalog
        )
        var locationActionState = state
        let locationEvent = try GameCore.GameRulesEngine.resolveBuild(
            locationTarget,
            roomID: .init(rawValue: "build-network-tests"),
            state: &locationActionState,
            catalog: catalog
        )
        #expect(locationActionState.boardIndustryPlacements.contains {
            $0.locationID == "dudley" && $0.ownerID == actor
        })
        #expect(locationEvent.version.rawValue == locationEvent.previousVersion.rawValue + 1)
        #expect(throws: GameCore.BuildRuleError.outsideNetwork) {
            try GameCore.BuildRules.validate(
                .init(
                    cardID: "industry-coal-mine-2-plus-1", locationID: "dudley",
                    industryDefinitionID: "coal-mine", slotIndex: 0, resourceSources: []
                ),
                actorID: actor, state: state, catalog: catalog
            )
        }
        #expect(GameCore.TopologyRules.isInPlayerNetwork(
            playerID: actor, locationID: "dudley", state: state, board: catalog.catalog.board
        ) == false)
        state.boardIndustryPlacements.append(.init(
            locationID: "dudley", slotIndex: 0, ownerID: opponent,
            tile: .init(id: "resource-through-opponent-link", industryDefinitionID: "coal-mine", level: 1),
            resourceCount: 1
        ))
        state.publicSupply.coal -= 1
        #expect(GameCore.GameRulesEngine.legalResourceSources(
            resource: .coal, consumerLocationID: "birmingham", context: .standard,
            state: state, catalog: catalog
        ).contains(.industry(placementID: "dudley#0")))
        state.players[actorIndex].hand = [
            .init(id: "location-birmingham-1", definitionID: "location-birmingham")
        ]
        repairCardFixture(&state, catalog: catalog)
        let connectedBuild = try GameCore.BuildRules.validate(
            .init(
                cardID: "location-birmingham-1", locationID: "birmingham",
                industryDefinitionID: "iron-works", slotIndex: 2,
                resourceSources: [.industry(placementID: "dudley#0")]
            ),
            actorID: actor, state: state, catalog: catalog
        )
        let connectedEvent = try GameCore.GameRulesEngine.resolveBuild(
            connectedBuild, roomID: .init(rawValue: "build-network-tests"),
            state: &state, catalog: catalog
        )
        #expect(state.boardIndustryPlacements.first(where: { $0.placementID == "dudley#0" })?.resourceCount == 0)
        guard case let .built(_, _, effects) = connectedEvent.payload else {
            Issue.record("Expected connected build event")
            return
        }
        #expect(effects.contains(.resourceRemoved(
            resource: .coal, source: .industry(placementID: "dudley#0"),
            consumerLocationID: "birmingham"
        )))

        var lowCount = try setupState(catalog: catalog)
        let excludedDefinition = "location-leek"
        #expect(lowCount.players.flatMap(\.hand).contains(where: { $0.definitionID == excludedDefinition }) == false)
        #expect(lowCount.standardDrawDeck.contains(where: { $0.definitionID == excludedDefinition }) == false)
        let lowActor = try #require(lowCount.activePlayerID)
        let lowIndex = try #require(lowCount.players.firstIndex(where: { $0.id == lowActor }))
        lowCount.players[lowIndex].hand = [.init(id: "removed-location-card", definitionID: excludedDefinition)]
        let removedCardTarget = try GameCore.BuildRules.validate(
            .init(
                cardID: "removed-location-card", locationID: "leek",
                industryDefinitionID: "coal-mine", slotIndex: 1, resourceSources: []
            ),
            actorID: lowActor, state: lowCount, catalog: catalog
        )
        _ = removedCardTarget
    }

    @Test func networkRejectsWrongEraRouteCountAndDuplicateBeforeMutation() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex(where: { $0.id == actor }))
        let card = GameCore.CardInstance(id: "network-shape", definitionID: "location-birmingham")
        state.players[playerIndex].hand = [card]
        state.players[playerIndex].cash = 30
        let canal = state
        #expect(throws: GameCore.NetworkRuleError.wrongEra) {
            try GameCore.NetworkRules.validate(
                .init(cardID: card.id, routeIDs: ["belper-leek"], coalSources: [], beerSource: nil),
                actorID: actor, state: state, catalog: catalog
            )
        }
        #expect(throws: GameCore.NetworkRuleError.invalidRouteCount) {
            try GameCore.NetworkRules.validate(
                .init(
                    cardID: card.id,
                    routeIDs: ["birmingham-dudley", "dudley-wolverhampton"],
                    coalSources: [], beerSource: nil
                ),
                actorID: actor, state: state, catalog: catalog
            )
        }
        #expect(state == canal)
        state.era = .rail
        #expect(throws: GameCore.NetworkRuleError.duplicateRoute) {
            try GameCore.NetworkRules.validate(
                .init(
                    cardID: card.id,
                    routeIDs: ["tamworth-walsall", "tamworth-walsall"],
                    coalSources: [
                        .marketSlot(resource: .coal, index: 1),
                        .marketSlot(resource: .coal, index: 2),
                    ],
                    beerSource: .industry(placementID: "missing")
                ),
                actorID: actor, state: state, catalog: catalog
            )
        }
    }

    @Test func hostAcceptsCodableBuildIntentAndEmitsCodableActionEvent() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        let card = GameCore.CardInstance(id: "location-dudley-1", definitionID: "location-dudley")
        state.players[playerIndex].hand = [card]
        state.players[playerIndex].cash = 20
        repairCardFixture(&state, catalog: catalog)
        let roomID = GameCore.RoomID(rawValue: "host-build-room")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        var host = try state.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 1
        )
        let intent = GameCore.PlayerIntent(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion,
            roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
            baseVersion: state.authoritativeVersion,
            payload: .build(.init(
                cardID: card.id, locationID: "dudley",
                industryDefinitionID: "coal-mine", slotIndex: 0, resourceSources: []
            ))
        )
        let roundTrippedIntent = try JSONDecoder().decode(
            GameCore.PlayerIntent.self, from: JSONEncoder().encode(intent)
        )
        #expect(roundTrippedIntent == intent)

        guard case .accepted(let event) = host.submit(intent, catalog: catalog) else {
            Issue.record("Expected validated host build acceptance")
            return
        }
        let roundTrippedEvent = try JSONDecoder().decode(
            GameCore.AuthoritativeGameEvent.self, from: JSONEncoder().encode(event)
        )
        #expect(roundTrippedEvent == event)
        #expect(host.gameState.authoritativeVersion.rawValue == state.authoritativeVersion.rawValue + 1)
        #expect(host.gameState.actionNumber == state.actionNumber + 1)
    }

    @Test func buildValidationRejectsUntrustedResourceSourcesBeforeResolutionAndHostStaysAtomic() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        state.players[playerIndex].hand = [
            .init(id: "industry-brewery-1", definitionID: "industry-brewery")
        ]
        repairCardFixture(&state, catalog: catalog)
        let roomID = GameCore.RoomID(rawValue: "malicious-build")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        let maliciousSources: [GameCore.ResourceSource] = [
            .unlimitedMarket(resource: .iron, price: -1),
            .unlimitedMarket(resource: .iron, price: Int.max),
            .marketSlot(resource: .iron, index: -1),
            .marketSlot(resource: .iron, index: Int.max),
            .marketSlot(resource: .coal, index: 1),
        ]

        for source in maliciousSources {
            let build = GameCore.BuildIntent(
                cardID: "industry-brewery-1", locationID: "cannock-farm",
                industryDefinitionID: "brewery", slotIndex: 0,
                resourceSources: [source]
            )
            #expect(throws: GameCore.BuildRuleError.illegalResourcePlan) {
                try GameCore.BuildRules.validate(
                    build, actorID: actor, state: state, catalog: catalog
                )
            }
            repairCardFixture(&state, catalog: catalog)
            var host = try state.makeHostEngine(
                roomID: roomID, reconnectTokens: tokens, protocolVersion: 1
            )
            let original = host.gameState
            let encoded = try JSONEncoder().encode(GameCore.PlayerIntent(
                protocolVersion: 1, rulesetVersion: state.rulesetVersion,
                roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
                baseVersion: state.authoritativeVersion, payload: .build(build)
            ))
            let decoded = try JSONDecoder().decode(GameCore.PlayerIntent.self, from: encoded)
            guard case .rejected = host.submit(decoded, catalog: catalog) else {
                Issue.record("Expected malicious Codable resource source rejection: \(source)")
                continue
            }
            #expect(host.gameState == original)
        }

        var duplicateState = try setupState(catalog: catalog)
        let duplicateActor = try #require(duplicateState.activePlayerID)
        let duplicateIndex = try #require(duplicateState.players.firstIndex { $0.id == duplicateActor })
        duplicateState.players[duplicateIndex].hand = [
            .init(id: "location-birmingham-1", definitionID: "location-birmingham")
        ]
        let stackIndex = try #require(duplicateState.players[duplicateIndex].industryStacks.firstIndex {
            $0.industryDefinitionID == "manufacturer"
        })
        duplicateState.players[duplicateIndex].industryStacks[stackIndex].tiles.removeFirst(3)
        let tile = try #require(duplicateState.players[duplicateIndex].industryStacks[stackIndex].tiles.first)
        duplicateState.placedLinks = [
            .init(routeID: "birmingham-oxford", ownerID: duplicateActor, era: .canal)
        ]
        repairCardFixture(&duplicateState, catalog: catalog)
        let target = try #require(GameCore.BuildRules.legalBuildTargets(
            actorID: duplicateActor, cardID: "location-birmingham-1", tile: tile,
            state: duplicateState, catalog: catalog
        ).first)
        #expect(throws: GameCore.BuildRuleError.illegalResourcePlan) {
            try GameCore.BuildRules.validate(
                .init(
                    cardID: "location-birmingham-1", locationID: target.locationID,
                    industryDefinitionID: "manufacturer", slotIndex: target.slotIndex,
                    resourceSources: [
                        .marketSlot(resource: .coal, index: 1),
                        .marketSlot(resource: .coal, index: 1),
                    ]
                ),
                actorID: duplicateActor, state: duplicateState, catalog: catalog
            )
        }
    }

    @Test func emptyCompatibleSlotMustBeUsedBeforeAnyOverbuildAndEnumerationMatchesValidation() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        state.era = .rail
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        let card = GameCore.CardInstance(
            id: "location-birmingham-1", definitionID: "location-birmingham"
        )
        state.players[playerIndex].hand = [card]
        let stackIndex = try #require(state.players[playerIndex].industryStacks.firstIndex { $0.industryDefinitionID == "manufacturer" })
        let old = state.players[playerIndex].industryStacks[stackIndex].tiles.removeFirst()
        state.boardIndustryPlacements = [
            .init(locationID: "birmingham", slotIndex: 1, ownerID: actor, tile: old),
            .init(
                locationID: "walsall", slotIndex: 1, ownerID: actor,
                tile: .init(id: "enumeration-beer", industryDefinitionID: "brewery", level: 2),
                resourceCount: 1
            ),
        ]
        state.publicSupply.beer -= 1
        repairCardFixture(&state, catalog: catalog)
        let next = try #require(state.players[playerIndex].industryStacks[stackIndex].tiles.first)
        let sources: [GameCore.ResourceSource] = [.marketSlot(resource: .iron, index: 2), .merchantBeer(slotID: "oxford-1")]

        #expect(GameCore.GameRulesEngine.legalResourceSources(
            resource: .iron, consumerLocationID: "birmingham", context: .standard,
            state: state, catalog: catalog
        ).isEmpty == false)
        #expect(GameCore.GameRulesEngine.legalResourceSources(
            resource: .beer, consumerLocationID: "birmingham", context: .standard,
            state: state, catalog: catalog
        ).isEmpty == false)

        #expect(throws: GameCore.BuildRuleError.emptySlotAvailable) {
            try GameCore.BuildRules.validate(
                .init(cardID: card.id, locationID: "birmingham", industryDefinitionID: "manufacturer", slotIndex: 1, resourceSources: sources),
                actorID: actor, state: state, catalog: catalog
            )
        }
        let targets = GameCore.BuildRules.legalBuildTargets(
            actorID: actor, cardID: card.id, tile: next, state: state, catalog: catalog
        )
        #expect(targets == [.init(locationID: "birmingham", slotIndex: 3)])
    }

    private func setupState(catalog: GameCore.VerifiedGameDataCatalog) throws -> GameCore.GameState {
        var rules = GameCore.SetupRules(seed: 7)
        let players = ["p1", "p2"].map { GameCore.PlayerID(rawValue: $0) }
        return try rules.makeGame(catalog: catalog, playerIDs: players).state
    }

    private func knownQueryMerchants() -> [GameCore.MerchantPlacement] {
        [
            .init(slotID: "shrewsbury-1", merchantDefinitionID: "blank-2-plus", hasBeer: false),
            .init(slotID: "gloucester-1", merchantDefinitionID: "blank-2-plus", hasBeer: false),
            .init(slotID: "gloucester-2", merchantDefinitionID: "cotton-2-plus", hasBeer: true),
            .init(slotID: "oxford-1", merchantDefinitionID: "any-2-plus", hasBeer: true),
            .init(slotID: "oxford-2", merchantDefinitionID: "manufacturer-2-plus", hasBeer: true),
        ]
    }

    private func resourceCount(
        for source: GameCore.ResourceSource,
        in state: GameCore.GameState
    ) -> Int {
        switch source {
        case .industry(let placementID):
            return state.boardIndustryPlacements.first(where: { $0.placementID == placementID })?.resourceCount ?? 0
        case .marketSlot(let resource, let index):
            if resource == .coal, state.coalMarket.slots.indices.contains(index) {
                return state.coalMarket.slots[index].hasCube ? 1 : 0
            }
            if resource == .iron, state.ironMarket.slots.indices.contains(index) {
                return state.ironMarket.slots[index].hasCube ? 1 : 0
            }
            return 0
        case .merchantBeer(let slotID):
            return state.merchants.first(where: { $0.slotID == slotID })?.hasBeer == true ? 1 : 0
        case .unlimitedMarket:
            return 0
        }
    }

    private func verifiedCatalog() throws -> GameCore.VerifiedGameDataCatalog {
        let paths = ["map.json", "industries.json", "cards.json", "merchants.json", "income-track.json"]
        let files = try Dictionary(uniqueKeysWithValues: paths.map { path in
            let name = String(path.dropLast(".json".count))
            let url = try #require(Bundle.main.url(forResource: name, withExtension: "json"))
            return (path, try Data(contentsOf: url))
        })
        let manifest = GameCore.GameDataManifest(
            rulesetVersion: "v2018.11",
            verificationStatus: .verified,
            files: paths.map { .init(path: $0, sha256: GameCore.GameDataLoader.sha256(files[$0]!)) },
            sources: [
                .init(
                    id: "build-network-tests", url: "https://example.invalid/rules",
                    component: "rules", version: "2018.11", page: "all",
                    transcriber: "test", transcribedOn: "2026-08-18",
                    checker: "independent-test", checkedOn: "2026-08-18"
                ),
            ]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: JSONEncoder().encode(manifest), files: files
        )
    }
}

private extension GameCore.SubmissionResult {
    var acceptedEvent: GameCore.AuthoritativeGameEvent? {
        guard case .accepted(let event) = self else { return nil }
        return event
    }
}
