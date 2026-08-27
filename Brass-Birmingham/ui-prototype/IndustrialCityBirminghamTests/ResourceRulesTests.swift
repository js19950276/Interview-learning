import Foundation
import Testing
@testable import IndustrialCityBirmingham

struct ResourceRulesTests {
    private let player = GameCore.PlayerID(rawValue: "player-1")
    private let opponent = GameCore.PlayerID(rawValue: "player-2")

    @Test func coalReturnsOnlyNearestConnectedTierWithStableTieChoices() throws {
        let catalog = try verifiedCatalog()
        var state = makeState()
        state.boardIndustryPlacements = [
            industry("coal-b", at: "dudley", owner: opponent, kind: "coal-mine", resource: 2),
            industry("coal-a", at: "tamworth", owner: player, kind: "coal-mine", resource: 2),
            industry("coal-far", at: "burton-on-trent", owner: opponent, kind: "coal-mine", resource: 2),
        ]
        state.placedLinks = [
            link("birmingham-dudley"), link("birmingham-tamworth"),
            link("burton-on-trent-tamworth"),
        ]
        rebalanceResources(&state)

        let sources = GameCore.GameRulesEngine.legalResourceSources(
            resource: .coal,
            consumerLocationID: "birmingham",
            context: .standard,
            state: state,
            catalog: catalog
        )

        #expect(sources == [.industry(placementID: "coal-a"), .industry(placementID: "coal-b")])
    }

    @Test func coalRecomputesNearestSourceAfterASelectedMineIsExhausted() throws {
        let catalog = try verifiedCatalog()
        var state = makeState()
        state.boardIndustryPlacements = [
            industry("near", at: "tamworth", owner: opponent, kind: "coal-mine", resource: 1),
            industry("far", at: "burton-on-trent", owner: opponent, kind: "coal-mine", resource: 1),
        ]
        state.placedLinks = [link("birmingham-tamworth"), link("burton-on-trent-tamworth")]
        rebalanceResources(&state)
        let plan = buildPlan(
            actorID: player,
            baseVersion: state.authoritativeVersion,
            requests: [
                .init(resource: .coal, consumerLocationID: "birmingham", context: .standard, source: .industry(placementID: "near")),
                .init(resource: .coal, consumerLocationID: "birmingham", context: .standard, source: .industry(placementID: "far")),
            ],
            slotIndex: 0,
            industryDefinitionID: "manufacturer",
            level: 3
        )

        let events = try applyPlan(plan, to: &state, catalog: catalog)

        #expect(state.boardIndustryPlacements.allSatisfy { $0.resourceCount == 0 && $0.isFlipped })
        #expect(events.effects.starts(with: [
            .resourceRemoved(resource: .coal, source: .industry(placementID: "near"), consumerLocationID: "birmingham"),
            .industryFlipped(placementID: "near"),
        ]))
    }

    @Test func coalMarketRequiresEdgeConnectionUsesCheapestFilledSlotThenUnlimitedEight() throws {
        let catalog = try verifiedCatalog()
        var state = makeState()
        state.placedLinks = [link("birmingham-oxford")]
        state.coalMarket = coalMarket(filledIndices: [2])
        rebalanceResources(&state)

        #expect(GameCore.GameRulesEngine.legalResourceSources(
            resource: .coal, consumerLocationID: "birmingham", context: .standard,
            state: state, catalog: catalog
        ) == [.marketSlot(resource: .coal, index: 2)])

        let first = buildPlan(actorID: player, baseVersion: state.authoritativeVersion, requests: [
            .init(resource: .coal, consumerLocationID: "birmingham", context: .standard, source: .marketSlot(resource: .coal, index: 2)),
        ])
        _ = try applyPlan(first, to: &state, catalog: catalog)
        #expect(state.players[0].cash == 28)
        #expect(GameCore.GameRulesEngine.legalResourceSources(
            resource: .coal, consumerLocationID: "birmingham", context: .standard,
            state: state, catalog: catalog
        ) == [.unlimitedMarket(resource: .coal, price: 8)])

        var disconnected = makeState()
        #expect(GameCore.GameRulesEngine.legalResourceSources(
            resource: .coal, consumerLocationID: "birmingham", context: .standard,
            state: disconnected, catalog: catalog
        ).isEmpty)
    }

    @Test func ironUsesAnyMapSourceBeforeCheapestMarketThenUnlimitedSix() throws {
        let catalog = try verifiedCatalog()
        var state = makeState()
        state.boardIndustryPlacements = [
            industry("z-iron", at: "stoke-on-trent", owner: opponent, kind: "iron-works", resource: 1),
            industry("a-iron", at: "derby", owner: player, kind: "iron-works", resource: 1),
        ]
        state.ironMarket = ironMarket(filledIndices: [0])
        rebalanceResources(&state)
        #expect(GameCore.GameRulesEngine.legalResourceSources(
            resource: .iron, consumerLocationID: "birmingham", context: .standard,
            state: state, catalog: catalog
        ) == [.industry(placementID: "a-iron"), .industry(placementID: "z-iron")])

        state.boardIndustryPlacements = []
        state.ironMarket = ironMarket(filledIndices: [0])
        rebalanceResources(&state)
        #expect(GameCore.GameRulesEngine.legalResourceSources(
            resource: .iron, consumerLocationID: "missing", context: .standard,
            state: state, catalog: catalog
        ) == [.marketSlot(resource: .iron, index: 0)])
        state.ironMarket.slots[0].hasCube = false
        rebalanceResources(&state)
        #expect(GameCore.GameRulesEngine.legalResourceSources(
            resource: .iron, consumerLocationID: "missing", context: .standard,
            state: state, catalog: catalog
        ) == [.unlimitedMarket(resource: .iron, price: 6)])
    }

    @Test func beerAllowsOwnAnywhereOpponentConnectedAndOnlySelectedMerchantWhenSelling() throws {
        let catalog = try verifiedCatalog()
        var state = makeState()
        state.boardIndustryPlacements = [
            industry("own-beer", at: "derby", owner: player, kind: "brewery", resource: 1),
            industry("opponent-beer", at: "walsall", owner: opponent, kind: "brewery", resource: 1),
        ]
        state.placedLinks = [link("birmingham-walsall"), link("birmingham-oxford")]
        rebalanceResources(&state)

        #expect(GameCore.GameRulesEngine.legalResourceSources(
            resource: .beer, consumerLocationID: "birmingham", context: .selling(merchantSlotID: "oxford-1"),
            state: state, catalog: catalog
        ) == [.industry(placementID: "opponent-beer"), .industry(placementID: "own-beer"), .merchantBeer(slotID: "oxford-1")])
        #expect(GameCore.GameRulesEngine.legalResourceSources(
            resource: .beer, consumerLocationID: "birmingham", context: .network,
            state: state, catalog: catalog
        ) == [.industry(placementID: "opponent-beer"), .industry(placementID: "own-beer")])
    }

    @Test func newCoalAndIronDeliverHighestPriceEmptySlotsPayAndFlipInEventOrder() throws {
        let catalog = try verifiedCatalog()
        var coalState = makeState()
        coalState.placedLinks = [link("birmingham-tamworth"), link("birmingham-oxford")]
        coalState.boardIndustryPlacements = [industry("coal", at: "tamworth", owner: player, kind: "coal-mine", level: 1, resource: 2)]
        coalState.coalMarket = coalMarket(filledIndices: Set(0..<14).subtracting([0, 12]))
        rebalanceResources(&coalState)

        let coalEvents = try deliverResources(
            placementID: "coal",
            baseVersion: coalState.authoritativeVersion,
            state: &coalState,
            catalog: catalog
        )
        #expect(coalState.coalMarket.slots[0].hasCube)
        #expect(coalState.coalMarket.slots[12].hasCube)
        #expect(coalState.players[0].cash == 38)
        #expect(coalState.boardIndustryPlacements[0].isFlipped)
        #expect(coalState.players[0].incomePosition == 14)
        #expect(coalEvents.effects.suffix(2) == [
            .industryFlipped(placementID: "coal"),
            .incomeAdvanced(playerID: player, from: 10, to: 14),
        ])

        var ironState = makeState()
        ironState.boardIndustryPlacements = [industry("iron", at: "stoke-on-trent", owner: player, kind: "iron-works", level: 1, resource: 1)]
        ironState.ironMarket = ironMarket(filledIndices: Set(0..<10).subtracting([9]))
        rebalanceResources(&ironState)
        _ = try deliverResources(
            placementID: "iron",
            baseVersion: ironState.authoritativeVersion,
            state: &ironState,
            catalog: catalog
        )
        #expect(ironState.players[0].cash == 34)
        #expect(ironState.boardIndustryPlacements[0].isFlipped)
        #expect(ironState.boardIndustryPlacements[0].marketDeliveryResolved)
        #expect(ironState.players[0].incomePosition == 13)
        let resolvedIron = ironState
        #expect(throws: GameCore.ResourceRuleError.marketDeliveryAlreadyResolved) {
            try deliverResources(
                placementID: "iron",
                baseVersion: ironState.authoritativeVersion,
                state: &ironState,
                catalog: catalog
            )
        }
        #expect(ironState == resolvedIron)
    }

    @Test func newIndustryMarketDeliveryResolvesExactlyOnceEvenWhenResourcesRemainOrNothingMoves() throws {
        let catalog = try verifiedCatalog()
        var state = makeState()
        state.placedLinks = [link("birmingham-tamworth"), link("birmingham-oxford")]
        state.boardIndustryPlacements = [industry("coal-once", at: "tamworth", owner: player, kind: "coal-mine", resource: 2)]
        state.coalMarket = coalMarket(filledIndices: Set(0..<14).subtracting([13]))
        rebalanceResources(&state)
        let baseVersion = state.authoritativeVersion

        let events = try deliverResources(
            placementID: "coal-once",
            baseVersion: baseVersion,
            state: &state,
            catalog: catalog
        )
        #expect(state.boardIndustryPlacements[0].resourceCount == 1)
        #expect(state.boardIndustryPlacements[0].marketDeliveryResolved)
        #expect(state.authoritativeVersion.rawValue == baseVersion.rawValue + 1)
        #expect(events.effects.contains(.marketDeliveryResolved(placementID: "coal-once")))

        state.coalMarket.slots[12].hasCube = false
        rebalanceResources(&state)
        let afterFirst = state
        #expect(throws: GameCore.ResourceRuleError.self) {
            try deliverResources(
                placementID: "coal-once",
                baseVersion: state.authoritativeVersion,
                state: &state,
                catalog: catalog
            )
        }
        #expect(state == afterFirst)

        var disconnectedCoal = makeState()
        disconnectedCoal.boardIndustryPlacements = [industry("coal-full", at: "tamworth", owner: player, kind: "coal-mine", resource: 1)]
        disconnectedCoal.coalMarket = coalMarket(filledIndices: Set(0..<14))
        rebalanceResources(&disconnectedCoal)
        let disconnectedBase = disconnectedCoal.authoritativeVersion
        let noMoveEvents = try deliverResources(
            placementID: "coal-full",
            baseVersion: disconnectedBase,
            state: &disconnectedCoal,
            catalog: catalog
        )
        #expect(disconnectedCoal.boardIndustryPlacements[0].resourceCount == 1)
        #expect(disconnectedCoal.boardIndustryPlacements[0].marketDeliveryResolved)
        #expect(disconnectedCoal.authoritativeVersion.rawValue == disconnectedBase.rawValue + 1)
        #expect(noMoveEvents.effects == [.marketDeliveryResolved(placementID: "coal-full")])

        var stale = makeState()
        stale.boardIndustryPlacements = [industry("iron-stale", at: "stoke-on-trent", owner: player, kind: "iron-works", resource: 1)]
        rebalanceResources(&stale)
        let staleOriginal = stale
        #expect(throws: GameCore.ResourceRuleError.self) {
            try deliverResources(
                placementID: "iron-stale",
                baseVersion: .init(rawValue: 999),
                state: &stale,
                catalog: catalog
            )
        }
        #expect(stale == staleOriginal)
    }

    @Test func invalidSecondResourceBeerUnknownDuplicateStaleAndTopologyAreAtomic() throws {
        let catalog = try verifiedCatalog()
        var state = makeState()
        state.boardIndustryPlacements = [industry("coal", at: "tamworth", owner: opponent, kind: "coal-mine", resource: 1)]
        state.placedLinks = [link("birmingham-tamworth")]
        rebalanceResources(&state)
        let original = state
        let insufficient = buildPlan(actorID: player, baseVersion: state.authoritativeVersion, requests: [
            .init(resource: .coal, consumerLocationID: "birmingham", context: .standard, source: .industry(placementID: "coal")),
            .init(resource: .coal, consumerLocationID: "birmingham", context: .standard, source: .industry(placementID: "coal")),
        ], slotIndex: 0, industryDefinitionID: "manufacturer", level: 3)
        #expect(throws: GameCore.ResourceRuleError.self) { try applyPlan(insufficient, to: &state, catalog: catalog) }
        #expect(state == original)

        var illegalSecondBeer = original
        let mixedPlan = buildPlan(actorID: player, baseVersion: illegalSecondBeer.authoritativeVersion, requests: [
            .init(resource: .coal, consumerLocationID: "birmingham", context: .standard, source: .industry(placementID: "coal")),
            .init(resource: .beer, consumerLocationID: "birmingham", context: .network, source: .merchantBeer(slotID: "missing")),
        ], slotIndex: 0, industryDefinitionID: "cotton-mill", level: 2)
        #expect(throws: GameCore.ResourceRuleError.self) { try applyPlan(mixedPlan, to: &illegalSecondBeer, catalog: catalog) }
        #expect(illegalSecondBeer == original)

        for source in [GameCore.ResourceSource.industry(placementID: "missing"), .merchantBeer(slotID: "missing")] {
            var candidate = original
            let plan = buildPlan(actorID: player, baseVersion: candidate.authoritativeVersion, requests: [
                .init(resource: .beer, consumerLocationID: "birmingham", context: .standard, source: source),
            ], slotIndex: 0, industryDefinitionID: "cotton-mill", level: 1)
            #expect(throws: GameCore.ResourceRuleError.self) { try applyPlan(plan, to: &candidate, catalog: catalog) }
            #expect(candidate == original)
        }

        var stale = original
        let stalePlan = developPlan(actorID: player, baseVersion: .init(rawValue: 99), requests: [])
        #expect(throws: GameCore.ResourceRuleError.self) { try applyPlan(stalePlan, to: &stale, catalog: catalog) }
        #expect(stale == original)

        var invalidTopology = original
        invalidTopology.placedLinks.append(link("birmingham-tamworth"))
        #expect(GameCore.GameRulesEngine.legalResourceSources(
            resource: .coal, consumerLocationID: "birmingham", context: .standard,
            state: invalidTopology, catalog: catalog
        ).isEmpty)

        var duplicatePlacement = original
        duplicatePlacement.boardIndustryPlacements.append(
            industry("coal", at: "cannock", owner: player, kind: "coal-mine", resource: 1)
        )
        rebalanceResources(&duplicatePlacement)
        #expect(GameCore.GameRulesEngine.legalResourceSources(
            resource: .coal, consumerLocationID: "birmingham", context: .standard,
            state: duplicatePlacement, catalog: catalog
        ).isEmpty)

        var unknownReference = makeState()
        unknownReference.boardIndustryPlacements = [
            industry("unknown-location", at: "missing", owner: player, kind: "iron-works", resource: 1),
        ]
        rebalanceResources(&unknownReference)
        #expect(GameCore.GameRulesEngine.legalResourceSources(
            resource: .iron, consumerLocationID: "birmingham", context: .standard,
            state: unknownReference, catalog: catalog
        ).isEmpty)
    }

    @Test func merchantBeerRequiresConnectionAndPlansRejectNonActiveActors() throws {
        let catalog = try verifiedCatalog()
        var state = makeState()
        rebalanceResources(&state)

        #expect(GameCore.GameRulesEngine.legalResourceSources(
            resource: .beer,
            consumerLocationID: "birmingham",
            context: .selling(merchantSlotID: "oxford-1"),
            state: state,
            catalog: catalog
        ).isEmpty)

        let original = state
        let plan = developPlan(actorID: opponent, baseVersion: state.authoritativeVersion, requests: [])
        #expect(throws: GameCore.ResourceRuleError.self) {
            try applyPlan(plan, to: &state, catalog: catalog)
        }
        #expect(state == original)
    }

    @Test func authorityCompletenessCatalogReferencesMarketShapesAndComponentTotalsFailClosed() throws {
        let catalog = try verifiedCatalog()
        var baseline = makeState()
        baseline.boardIndustryPlacements = [industry("iron-valid", at: "stoke-on-trent", owner: player, kind: "iron-works", resource: 1)]
        rebalanceResources(&baseline)

        var invalidStates: [GameCore.GameState] = []
        var rulesetMismatch = baseline
        rulesetMismatch.rulesetVersion = "wrong"
        invalidStates.append(rulesetMismatch)
        var negativePrice = baseline
        negativePrice.coalMarket.slots[0].price = -100
        invalidStates.append(negativePrice)
        var wrongCoalShape = baseline
        wrongCoalShape.coalMarket.slots.removeLast()
        invalidStates.append(wrongCoalShape)
        var wrongIronShape = baseline
        wrongIronShape.ironMarket.slots.swapAt(0, 9)
        invalidStates.append(wrongIronShape)
        var negativeSupply = baseline
        negativeSupply.publicSupply.beer = -1
        invalidStates.append(negativeSupply)
        var negativePlacement = baseline
        negativePlacement.boardIndustryPlacements[0].resourceCount = -1
        invalidStates.append(negativePlacement)
        var duplicatePlayers = baseline
        duplicatePlayers.players[1].id = duplicatePlayers.players[0].id
        invalidStates.append(duplicatePlayers)
        var unknownOwner = baseline
        unknownOwner.boardIndustryPlacements[0].ownerID = .init(rawValue: "missing-owner")
        invalidStates.append(unknownOwner)
        var unknownDefinition = baseline
        unknownDefinition.boardIndustryPlacements[0].tile.industryDefinitionID = "missing-industry"
        invalidStates.append(unknownDefinition)
        var incomplete = baseline
        incomplete.authorityCompleteness = nil
        invalidStates.append(incomplete)

        var resourceDeficit = baseline
        resourceDeficit.publicSupply.coal -= 1
        invalidStates.append(resourceDeficit)

        for invalid in invalidStates {
            #expect(GameCore.GameRulesEngine.legalResourceSources(
                resource: .iron,
                consumerLocationID: "birmingham",
                context: .standard,
                state: invalid,
                catalog: catalog
            ).isEmpty)

            var applyState = invalid
            let applyOriginal = applyState
            let plan = developPlan(
                actorID: player,
                baseVersion: applyState.authoritativeVersion,
                requests: []
            )
            #expect(throws: GameCore.ResourceRuleError.invalidState) {
                try applyPlan(plan, to: &applyState, catalog: catalog)
            }
            #expect(applyState == applyOriginal)

            var deliveryState = invalid
            let deliveryOriginal = deliveryState
            #expect(throws: GameCore.ResourceRuleError.invalidState) {
                try deliverResources(
                    placementID: "iron-valid",
                    baseVersion: deliveryState.authoritativeVersion,
                    state: &deliveryState,
                    catalog: catalog
                )
            }
            #expect(deliveryState == deliveryOriginal)
        }
    }

    @Test func sequentialPlansRecomputeAcrossSameMineAndMapToMarketWhilePreservingComponents() throws {
        let catalog = try verifiedCatalog()

        var sameMine = makeState()
        sameMine.boardIndustryPlacements = [industry("coal-two", at: "tamworth", owner: opponent, kind: "coal-mine", resource: 2)]
        rebalanceResources(&sameMine)
        let sameMineBefore = componentTotals(sameMine)
        sameMine.placedLinks = [link("birmingham-tamworth")]
        let sameMinePlan = buildPlan(actorID: player, baseVersion: sameMine.authoritativeVersion, requests: [
            .init(resource: .coal, consumerLocationID: "birmingham", context: .standard, source: .industry(placementID: "coal-two")),
            .init(resource: .coal, consumerLocationID: "birmingham", context: .standard, source: .industry(placementID: "coal-two")),
        ], slotIndex: 0, industryDefinitionID: "manufacturer", level: 3)
        _ = try applyPlan(sameMinePlan, to: &sameMine, catalog: catalog)
        #expect(sameMine.boardIndustryPlacements[0].isFlipped)
        #expect(componentTotals(sameMine) == sameMineBefore)

        var coalMixed = makeState()
        coalMixed.boardIndustryPlacements = [industry("last-coal", at: "tamworth", owner: opponent, kind: "coal-mine", resource: 1)]
        coalMixed.placedLinks = [link("birmingham-tamworth"), link("birmingham-oxford")]
        coalMixed.coalMarket = coalMarket(filledIndices: [0])
        rebalanceResources(&coalMixed)
        let coalBefore = componentTotals(coalMixed)
        let coalPlan = buildPlan(actorID: player, baseVersion: coalMixed.authoritativeVersion, requests: [
            .init(resource: .coal, consumerLocationID: "birmingham", context: .standard, source: .industry(placementID: "last-coal")),
            .init(resource: .coal, consumerLocationID: "birmingham", context: .standard, source: .marketSlot(resource: .coal, index: 0)),
        ], slotIndex: 0, industryDefinitionID: "manufacturer", level: 3)
        _ = try applyPlan(coalPlan, to: &coalMixed, catalog: catalog)
        #expect(coalMixed.players[0].cash == 29)
        #expect(componentTotals(coalMixed) == coalBefore)

        var ironMixed = makeState()
        ironMixed.boardIndustryPlacements = [industry("last-iron", at: "stoke-on-trent", owner: opponent, kind: "iron-works", resource: 1)]
        ironMixed.ironMarket = ironMarket(filledIndices: [0])
        rebalanceResources(&ironMixed)
        let ironBefore = componentTotals(ironMixed)
        let ironPlan = developPlan(actorID: player, baseVersion: ironMixed.authoritativeVersion, requests: [
            .init(resource: .iron, consumerLocationID: "", context: .standard, source: .industry(placementID: "last-iron")),
            .init(resource: .iron, consumerLocationID: "", context: .standard, source: .marketSlot(resource: .iron, index: 0)),
        ], tileIDs: ["develop-1", "develop-2"])
        _ = try applyPlan(ironPlan, to: &ironMixed, catalog: catalog)
        #expect(ironMixed.players[0].cash == 29)
        #expect(componentTotals(ironMixed) == ironBefore)

        var atMerchantEdge = makeState()
        atMerchantEdge.coalMarket = coalMarket(filledIndices: [0])
        rebalanceResources(&atMerchantEdge)
        #expect(GameCore.GameRulesEngine.legalResourceSources(
            resource: .coal,
            consumerLocationID: "oxford",
            context: .standard,
            state: atMerchantEdge,
            catalog: catalog
        ) == [.marketSlot(resource: .coal, index: 0)])

        var noOp = makeState()
        let noOpOriginal = noOp
        #expect(throws: GameCore.ResourceRuleError.self) {
            try applyPlan(
                developPlan(actorID: player, baseVersion: noOp.authoritativeVersion, requests: []),
                to: &noOp,
                catalog: catalog
            )
        }
        #expect(noOp == noOpOriginal)
    }

    @Test func legacyIndustryPlacementDecodingDefaultsNewAuthorityFieldsSafely() throws {
        let placement = industry("legacy", at: "tamworth", owner: player, kind: "coal-mine", resource: 2)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(placement)) as? [String: Any])
        object.removeValue(forKey: "placementID")
        object.removeValue(forKey: "resourceCount")
        object.removeValue(forKey: "isFlipped")
        object.removeValue(forKey: "marketDeliveryResolved")

        let decoded = try JSONDecoder().decode(
            GameCore.BoardIndustryPlacement.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.placementID == "tamworth#0")
        #expect(decoded.resourceCount == 0)
        #expect(decoded.isFlipped == false)
        #expect(decoded.marketDeliveryResolved == false)
    }

    @Test func placementResourcesCannotExceedCatalogProductionForItsLevelAndEra() throws {
        let catalog = try verifiedCatalog()
        let cases: [(GameCore.ResourceKind, GameCore.BoardIndustryPlacement)] = [
            (.coal, industry("coal-over", at: "tamworth", owner: player, kind: "coal-mine", level: 1, resource: 30)),
            (.iron, industry("iron-over", at: "stoke-on-trent", owner: player, kind: "iron-works", level: 1, resource: 18)),
            (.beer, industry("beer-over", at: "derby", owner: player, kind: "brewery", level: 1, resource: 15)),
        ]

        for (resource, placement) in cases {
            var state = makeState()
            state.boardIndustryPlacements = [placement]
            state.coalMarket = coalMarket(filledIndices: [])
            state.ironMarket = ironMarket(filledIndices: [])
            rebalanceResources(&state)

            #expect(GameCore.GameRulesEngine.legalResourceSources(
                resource: resource,
                consumerLocationID: placement.locationID,
                context: .standard,
                state: state,
                catalog: catalog
            ).isEmpty)
            let original = state
            #expect(throws: GameCore.ResourceRuleError.invalidState) {
                try applyPlan(
                    developPlan(actorID: player, baseVersion: state.authoritativeVersion, requests: []),
                    to: &state,
                    catalog: catalog
                )
            }
            #expect(state == original)
        }

        var railOnlyMismatch = makeState()
        railOnlyMismatch.era = .rail
        railOnlyMismatch.boardIndustryPlacements = [
            industry("canal-beer", at: "derby", owner: player, kind: "brewery", level: 1, resource: 1),
        ]
        rebalanceResources(&railOnlyMismatch)
        #expect(GameCore.GameRulesEngine.legalResourceSources(
            resource: .beer,
            consumerLocationID: "derby",
            context: .standard,
            state: railOnlyMismatch,
            catalog: catalog
        ).isEmpty)
    }

    @Test func merchantPlacementsMustExactlyMatchActiveCatalogSlotsTilesAndBeer() throws {
        let catalog = try verifiedCatalog()
        let baseline = makeState()
        var invalidStates: [GameCore.GameState] = []

        var inactiveDefinition = baseline
        inactiveDefinition.merchants[0].merchantDefinitionID = "manufacturer-3-plus"
        inactiveDefinition.merchants[0].hasBeer = true
        rebalanceResources(&inactiveDefinition)
        invalidStates.append(inactiveDefinition)

        var inactiveSlot = baseline
        inactiveSlot.merchants[0].slotID = "warrington-1"
        invalidStates.append(inactiveSlot)

        var blankWithBeer = baseline
        blankWithBeer.merchants[0].hasBeer = true
        rebalanceResources(&blankWithBeer)
        invalidStates.append(blankWithBeer)

        var duplicateTile = baseline
        duplicateTile.merchants[3].merchantDefinitionID = "cotton-2-plus"
        invalidStates.append(duplicateTile)

        var duplicateSlot = baseline
        duplicateSlot.merchants[1].slotID = duplicateSlot.merchants[0].slotID
        invalidStates.append(duplicateSlot)

        for invalid in invalidStates {
            #expect(GameCore.GameRulesEngine.legalResourceSources(
                resource: .iron,
                consumerLocationID: "birmingham",
                context: .standard,
                state: invalid,
                catalog: catalog
            ).isEmpty)
            var state = invalid
            let original = state
            #expect(throws: GameCore.ResourceRuleError.invalidState) {
                try applyPlan(
                    developPlan(actorID: player, baseVersion: state.authoritativeVersion, requests: []),
                    to: &state,
                    catalog: catalog
                )
            }
            #expect(state == original)
        }
    }

    @Test func disabledSubstitutesInvalidateAuthorityAndNeverExposeUnlimitedMarkets() throws {
        let catalog = try verifiedCatalog()
        var state = makeState()
        state.placedLinks = [link("birmingham-oxford")]
        state.coalMarket = coalMarket(filledIndices: [])
        state.ironMarket = ironMarket(filledIndices: [])
        state.publicSupply.mayUseSubstitutes = false
        rebalanceResources(&state)

        #expect(GameCore.GameRulesEngine.legalResourceSources(
            resource: .coal,
            consumerLocationID: "birmingham",
            context: .standard,
            state: state,
            catalog: catalog
        ).isEmpty)
        #expect(GameCore.GameRulesEngine.legalResourceSources(
            resource: .iron,
            consumerLocationID: "birmingham",
            context: .standard,
            state: state,
            catalog: catalog
        ).isEmpty)

        let original = state
        #expect(throws: GameCore.ResourceRuleError.invalidState) {
            try applyPlan(
                developPlan(actorID: player, baseVersion: state.authoritativeVersion, requests: []),
                to: &state,
                catalog: catalog
            )
        }
        #expect(state == original)
    }

    @Test func consumedNonblankMerchantBeerRemainsAValidDynamicStateForLaterResources() throws {
        let catalog = try verifiedCatalog()
        var state = makeState()
        state.placedLinks = [link("birmingham-oxford")]
        state.boardIndustryPlacements = [industry("sold-industry", at: "birmingham", owner: player, kind: "manufacturer", level: 6, resource: 0)]
        state.boardIndustryPlacements[0].slotIndex = 3
        rebalanceResources(&state)
        state.publicSupply.beer = 15
        let initialBeerSupply = state.publicSupply.beer
        let beerPlan = GameCore.ResourcePlan(
            context: .init(
                roomID: .init(rawValue: "resource-rules-test"),
                actionID: "sell-consume-merchant",
                actorID: player,
                target: .sell(industryPlacementID: "sold-industry", merchantSlotID: "oxford-1")
            ),
            baseVersion: state.authoritativeVersion,
            requests: [
                .init(
                    resource: .beer,
                    consumerLocationID: "birmingham",
                    context: .selling(merchantSlotID: "oxford-1"),
                    source: .merchantBeer(slotID: "oxford-1")
                ),
            ]
        )

        _ = try applyPlan(beerPlan, to: &state, catalog: catalog)

        #expect(state.merchants.first(where: { $0.slotID == "oxford-1" })?.hasBeer == false)
        #expect(state.publicSupply.beer == initialBeerSupply)
        #expect(GameCore.GameStateAuthorityValidator.isValid(state, catalog: catalog))
        #expect(GameCore.GameRulesEngine.legalResourceSources(
            resource: .coal,
            consumerLocationID: "birmingham",
            context: .standard,
            state: state,
            catalog: catalog
        ) == [.marketSlot(resource: .coal, index: 0)])
        #expect(GameCore.GameRulesEngine.legalResourceSources(
            resource: .iron,
            consumerLocationID: "birmingham",
            context: .standard,
            state: state,
            catalog: catalog
        ) == [.marketSlot(resource: .iron, index: 0)])

        let ironPlan = developPlan(
            actorID: player,
            baseVersion: state.authoritativeVersion,
            requests: [
                .init(
                    resource: .iron,
                    consumerLocationID: "",
                    context: .standard,
                    source: .marketSlot(resource: .iron, index: 0)
                ),
            ]
        )
        _ = try applyPlan(ironPlan, to: &state, catalog: catalog)
        #expect(componentTotals(state) == (coal: 30, iron: 18, beer: 17))
    }

    @Test func actionBoundPreparationRejectsMixedContextAndCommitsOneReplayableEvent() throws {
        let catalog = try verifiedCatalog()
        var state = makeState()
        state.placedLinks = [link("birmingham-oxford")]
        state.boardIndustryPlacements = [industry("sell-target", at: "birmingham", owner: player, kind: "manufacturer", level: 5, resource: 0)]
        state.boardIndustryPlacements[0].slotIndex = 3
        rebalanceResources(&state)
        let context = GameCore.ResourceActionContext(
            roomID: .init(rawValue: "room"),
            actionID: "action-iron-1",
            actorID: player,
            target: .develop(tileIDs: ["develop-1"])
        )
        let request = GameCore.ResourceRequest(
            resource: .iron,
            consumerLocationID: "",
            context: .standard,
            source: .marketSlot(resource: .iron, index: 0)
        )
        let proposal = GameCore.ResourcePlan(
            context: context,
            baseVersion: state.authoritativeVersion,
            requests: [request]
        )
        let original = state
        let transaction = try ResourceRulesTestDriver.prepareResourceTransaction(
            proposal,
            expectedRoomID: .init(rawValue: "room"),
            state: state,
            catalog: catalog
        )

        let event = try ResourceRulesTestDriver.applyResourceTransaction(
            transaction,
            expectedRoomID: .init(rawValue: "room"),
            to: &state,
            catalog: catalog
        )

        #expect(event.actionID == "action-iron-1")
        #expect(event.effects.filter { if case .resourceRemoved = $0 { true } else { false } }.count == 1)
        #expect(state.authoritativeVersion.rawValue == original.authoritativeVersion.rawValue + 1)
        #expect(state.appliedResourceActionIDs?.contains("action-iron-1") == true)

        var replayed = original
        try ResourceRulesTestDriver.replayResourceTransaction(event, expectedRoomID: .init(rawValue: "room"), to: &replayed, catalog: catalog)
        #expect(replayed == state)

        var wrongRoom = original
        #expect(throws: GameCore.ResourceRuleError.self) {
            try ResourceRulesTestDriver.replayResourceTransaction(event, expectedRoomID: .init(rawValue: "other-room"), to: &wrongRoom, catalog: catalog)
        }
        #expect(wrongRoom == original)

        var truncated = event
        truncated.effects.removeLast()
        var replayTarget = original
        #expect(throws: GameCore.ResourceRuleError.self) {
            try ResourceRulesTestDriver.replayResourceTransaction(truncated, expectedRoomID: .init(rawValue: "room"), to: &replayTarget, catalog: catalog)
        }
        #expect(replayTarget == original)

        var reordered = event
        reordered.effects.reverse()
        replayTarget = original
        #expect(throws: GameCore.ResourceRuleError.self) {
            try ResourceRulesTestDriver.replayResourceTransaction(reordered, expectedRoomID: .init(rawValue: "room"), to: &replayTarget, catalog: catalog)
        }
        #expect(replayTarget == original)

        let invalidContexts: [GameCore.ResourcePlan] = [
            .init(
                context: context,
                baseVersion: original.authoritativeVersion,
                requests: [.init(resource: .iron, consumerLocationID: "tamworth", context: .standard, source: request.source)]
            ),
            .init(
                context: .init(
                    roomID: .init(rawValue: "room"), actionID: "network-merchant", actorID: player,
                    target: .network(routeIDs: ["birmingham-dudley"], consumerLocationID: "birmingham")
                ),
                baseVersion: original.authoritativeVersion,
                requests: [.init(resource: .beer, consumerLocationID: "birmingham", context: .selling(merchantSlotID: "oxford-1"), source: .merchantBeer(slotID: "oxford-1"))]
            ),
            .init(
                context: .init(
                    roomID: .init(rawValue: "room"), actionID: "sell-two-merchants", actorID: player,
                    target: .sell(industryPlacementID: "sell-target", merchantSlotID: "oxford-1")
                ),
                baseVersion: original.authoritativeVersion,
                requests: [
                    .init(resource: .beer, consumerLocationID: "birmingham", context: .selling(merchantSlotID: "oxford-1"), source: .merchantBeer(slotID: "oxford-1")),
                    .init(resource: .beer, consumerLocationID: "birmingham", context: .selling(merchantSlotID: "gloucester-2"), source: .merchantBeer(slotID: "gloucester-2")),
                ]
            ),
            .init(
                context: .init(
                    roomID: .init(rawValue: "room"), actionID: "wrong-count", actorID: player,
                    target: .develop(tileIDs: ["develop-1", "develop-2"])
                ),
                baseVersion: original.authoritativeVersion,
                requests: [request]
            ),
            .init(
                context: .init(
                    roomID: .init(rawValue: "room"), actionID: "", actorID: player,
                    target: .develop(tileIDs: ["develop-1"])
                ),
                baseVersion: original.authoritativeVersion,
                requests: [request]
            ),
        ]
        for invalid in invalidContexts {
            #expect(throws: GameCore.ResourceRuleError.self) {
                try ResourceRulesTestDriver.prepareResourceTransaction(
                    invalid,
                    expectedRoomID: .init(rawValue: "room"),
                    state: original,
                    catalog: catalog
                )
            }
        }

        let repeated = GameCore.ResourcePlan(
            context: context,
            baseVersion: state.authoritativeVersion,
            requests: [request]
        )
        #expect(throws: GameCore.ResourceRuleError.self) {
            try ResourceRulesTestDriver.prepareResourceTransaction(
                repeated,
                expectedRoomID: .init(rawValue: "room"),
                state: state,
                catalog: catalog
            )
        }
    }

    @Test func numericAuthorityBoundsAndDeliveryOverflowFailClosedAtomically() throws {
        let catalog = try verifiedCatalog()
        let request = GameCore.ResourceRequest(
            resource: .iron,
            consumerLocationID: "birmingham",
            context: .standard,
            source: .marketSlot(resource: .iron, index: 0)
        )
        var invalidStates: [GameCore.GameState] = []
        var income = makeState(); income.players[0].incomePosition = 100; invalidStates.append(income)
        var cash = makeState(); cash.players[0].cash = -1; invalidStates.append(cash)
        var negativeVersion = makeState(); negativeVersion.authoritativeVersion = .init(rawValue: -1); invalidStates.append(negativeVersion)
        var maximumVersion = makeState(); maximumVersion.authoritativeVersion = .init(rawValue: Int.max); invalidStates.append(maximumVersion)
        var hugeSupply = makeState(); hugeSupply.publicSupply.coal = Int.max; invalidStates.append(hugeSupply)
        var excessiveSupply = makeState(); excessiveSupply.publicSupply.iron = 19; invalidStates.append(excessiveSupply)

        for var invalid in invalidStates {
            let original = invalid
            #expect(GameCore.GameRulesEngine.legalResourceSources(
                resource: .iron,
                consumerLocationID: "birmingham",
                context: .standard,
                state: invalid,
                catalog: catalog
            ).isEmpty)
            #expect(throws: GameCore.ResourceRuleError.self) {
                try applyPlan(
                    developPlan(actorID: player, baseVersion: invalid.authoritativeVersion, requests: [request]),
                    to: &invalid,
                    catalog: catalog
                )
            }
            #expect(invalid == original)
        }

        var overflow = makeState()
        overflow.players[0].cash = Int.max
        overflow.boardIndustryPlacements = [industry("iron-overflow", at: "birmingham", owner: player, kind: "iron-works", resource: 1)]
        overflow.ironMarket = ironMarket(filledIndices: Set(0..<9))
        rebalanceResources(&overflow)
        let original = overflow
        #expect(throws: GameCore.GameRulesEngine.GameRulesInternalError.arithmeticOverflow) {
            try deliverResources(
                placementID: "iron-overflow",
                baseVersion: overflow.authoritativeVersion,
                state: &overflow,
                catalog: catalog
            )
        }
        #expect(overflow == original)
    }

    @Test func physicalIndustryIdentityAndDeliveryTransactionReplayAreStrict() throws {
        let catalog = try verifiedCatalog()
        let first = industry("first", at: "birmingham", owner: player, kind: "coal-mine", resource: 1)
        var duplicateSlot = makeState()
        var second = first
        second.placementID = "second"
        second.tile.id = "tile-second"
        duplicateSlot.boardIndustryPlacements = [first, second]
        rebalanceResources(&duplicateSlot)

        var duplicateTile = makeState()
        second.locationID = "tamworth"
        second.slotIndex = 0
        second.tile.id = first.tile.id
        duplicateTile.boardIndustryPlacements = [first, second]
        rebalanceResources(&duplicateTile)

        var outOfBounds = makeState()
        var invalidSlot = first
        invalidSlot.slotIndex = 99
        outOfBounds.boardIndustryPlacements = [invalidSlot]
        rebalanceResources(&outOfBounds)

        for invalid in [duplicateSlot, duplicateTile, outOfBounds] {
            #expect(GameCore.GameRulesEngine.legalResourceSources(
                resource: .coal,
                consumerLocationID: "birmingham",
                context: .standard,
                state: invalid,
                catalog: catalog
            ).isEmpty)
        }

        var delivered = makeState()
        delivered.boardIndustryPlacements = [industry("iron-replay", at: "birmingham", owner: player, kind: "iron-works", resource: 1)]
        delivered.ironMarket = ironMarket(filledIndices: Set(0..<9))
        rebalanceResources(&delivered)
        let before = delivered
        let event = try deliverResources(
            placementID: "iron-replay",
            baseVersion: delivered.authoritativeVersion,
            state: &delivered,
            catalog: catalog,
            actionID: "delivery-replay"
        )
        #expect(event.effects.contains(.marketDeliveryResolved(placementID: "iron-replay")))
        var forged = event
        forged.context.actorID = opponent
        var forgedTarget = before
        #expect(throws: GameCore.ResourceRuleError.self) {
            try ResourceRulesTestDriver.replayResourceTransaction(
                forged,
                expectedRoomID: .init(rawValue: "resource-rules-test"),
                to: &forgedTarget,
                catalog: catalog
            )
        }
        #expect(forgedTarget == before)
        var replayed = before
        try ResourceRulesTestDriver.replayResourceTransaction(event, expectedRoomID: .init(rawValue: "resource-rules-test"), to: &replayed, catalog: catalog)
        #expect(replayed == delivered)
        let replayedOriginal = replayed
        #expect(throws: GameCore.ResourceRuleError.self) {
            try ResourceRulesTestDriver.replayResourceTransaction(event, expectedRoomID: .init(rawValue: "resource-rules-test"), to: &replayed, catalog: catalog)
        }
        #expect(replayed == replayedOriginal)
    }

    @Test func authorityDerivesRequirementsFromConcreteActionTargetsAndRoom() throws {
        let catalog = try verifiedCatalog()
        var state = makeState()
        state.boardIndustryPlacements = [industry("build-beer", at: "walsall", owner: player, kind: "brewery", resource: 1)]
        rebalanceResources(&state)
        let context = GameCore.ResourceActionContext(
            roomID: .init(rawValue: "room"),
            actionID: "build-cotton-2",
            actorID: player,
            target: .build(
                locationID: "birmingham",
                slotIndex: 0,
                industryDefinitionID: "cotton-mill",
                level: 2
            )
        )
        let requests: [GameCore.ResourceRequest] = [
            .init(resource: .coal, consumerLocationID: "birmingham", context: .standard, source: .marketSlot(resource: .coal, index: 0)),
            .init(resource: .beer, consumerLocationID: "birmingham", context: .standard, source: .industry(placementID: "build-beer")),
        ]
        state.placedLinks = [link("birmingham-oxford")]
        let proposal = GameCore.ResourcePlan(context: context, baseVersion: state.authoritativeVersion, requests: requests)
        let transaction = try ResourceRulesTestDriver.prepareResourceTransaction(
            proposal,
            expectedRoomID: .init(rawValue: "room"),
            state: state,
            catalog: catalog
        )
        _ = try ResourceRulesTestDriver.applyResourceTransaction(
            transaction,
            expectedRoomID: .init(rawValue: "room"),
            to: &state,
            catalog: catalog
        )

        var rail = makeState()
        rail.era = .rail
        rail.placedLinks = [.init(routeID: "birmingham-oxford", ownerID: opponent, era: .rail)]
        rail.boardIndustryPlacements = [industry("network-beer", at: "walsall", owner: player, kind: "brewery", level: 2, resource: 1)]
        rebalanceResources(&rail)
        repairCardFixture(&rail, catalog: catalog)
        let network = GameCore.ResourcePlan(
            context: .init(
                roomID: .init(rawValue: "room"), actionID: "double-rail", actorID: player,
                target: .network(
                    routeIDs: ["birmingham-dudley", "birmingham-tamworth"],
                    consumerLocationID: "birmingham"
                )
            ),
            baseVersion: rail.authoritativeVersion,
            requests: [
                .init(resource: .coal, consumerLocationID: "birmingham", context: .network, source: .marketSlot(resource: .coal, index: 0)),
                .init(resource: .coal, consumerLocationID: "birmingham", context: .network, source: .marketSlot(resource: .coal, index: 1)),
                .init(resource: .beer, consumerLocationID: "birmingham", context: .network, source: .industry(placementID: "network-beer")),
            ]
        )
        var merchantNetwork = network
        merchantNetwork.context.actionID = "double-rail-merchant"
        merchantNetwork.requests[2].source = .merchantBeer(slotID: "oxford-1")
        #expect(throws: GameCore.ResourceRuleError.self) {
            try ResourceRulesTestDriver.prepareResourceTransaction(
                merchantNetwork,
                expectedRoomID: .init(rawValue: "room"),
                state: rail,
                catalog: catalog
            )
        }
        _ = try applyPlan(network, to: &rail, catalog: catalog)

        var wrongRoom = makeState()
        #expect(throws: GameCore.ResourceRuleError.self) {
            try ResourceRulesTestDriver.prepareResourceTransaction(
                .init(context: context, baseVersion: wrongRoom.authoritativeVersion, requests: requests),
                expectedRoomID: .init(rawValue: "other"),
                state: wrongRoom,
                catalog: catalog
            )
        }

        let wrongPairing = GameCore.ResourcePlan(
            context: .init(
                roomID: .init(rawValue: "room"), actionID: "develop-wrong", actorID: player,
                target: .develop(tileIDs: ["develop-1"])
            ),
            baseVersion: wrongRoom.authoritativeVersion,
            requests: [.init(resource: .coal, consumerLocationID: "", context: .standard, source: .marketSlot(resource: .coal, index: 0))]
        )
        #expect(throws: GameCore.ResourceRuleError.self) {
            try ResourceRulesTestDriver.prepareResourceTransaction(
                wrongPairing,
                expectedRoomID: .init(rawValue: "room"),
                state: wrongRoom,
                catalog: catalog
            )
        }
    }

    @Test func actionIDsRemainUniquePastSixtyFourTransactionsAndSourceHasNoTestBypass() throws {
        let catalog = try verifiedCatalog()
        var state = makeState()
        state.appliedResourceActionIDs = (1...65).map { "action-\($0)" }
        let original = state
        let repeated = GameCore.ResourcePlan(
            context: .init(
                roomID: .init(rawValue: "room"), actionID: "action-1", actorID: player,
                target: .develop(tileIDs: ["develop-1"])
            ),
            baseVersion: state.authoritativeVersion,
            requests: [.init(resource: .iron, consumerLocationID: "", context: .standard, source: .marketSlot(resource: .iron, index: 0))]
        )
        #expect(throws: GameCore.ResourceRuleError.self) {
            try ResourceRulesTestDriver.prepareResourceTransaction(
                repeated,
                expectedRoomID: .init(rawValue: "room"),
                state: state,
                catalog: catalog
            )
        }
        #expect(state == original)

        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "IndustrialCityBirmingham/GameCore/Rules/ResourceRules.swift"))
        let engineSource = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "IndustrialCityBirmingham/GameCore/Rules/GameRulesEngine.swift"))
        #expect(source.contains("ForTesting") == false)
        #expect(source.contains("deliverNewIndustryResources") == false)
        #expect(engineSource.contains("prepareResourceTransaction") == false)
        #expect(engineSource.contains("applyResourceTransaction") == false)
        #expect(engineSource.contains("replayResourceTransaction") == false)
        #expect(engineSource.contains("prepareResourceMarketDelivery") == false)
    }

    private func applyPlan(
        _ plan: GameCore.ResourcePlan,
        to state: inout GameCore.GameState,
        catalog: GameCore.VerifiedGameDataCatalog
    ) throws -> GameCore.AuthoritativeResourceTransactionEvent {
        let transaction = try ResourceRulesTestDriver.prepareResourceTransaction(
            plan,
            expectedRoomID: plan.context.roomID,
            state: state,
            catalog: catalog
        )
        return try ResourceRulesTestDriver.applyResourceTransaction(
            transaction,
            expectedRoomID: plan.context.roomID,
            to: &state,
            catalog: catalog
        )
    }

    private func deliverResources(
        placementID: String,
        baseVersion: GameCore.AuthoritativeVersion,
        state: inout GameCore.GameState,
        catalog: GameCore.VerifiedGameDataCatalog,
        actionID: String? = nil
    ) throws -> GameCore.AuthoritativeResourceTransactionEvent {
        let placement = try #require(state.boardIndustryPlacements.first { $0.placementID == placementID })
        let roomID = GameCore.RoomID(rawValue: "resource-rules-test")
        let context = GameCore.ResourceActionContext(
            roomID: roomID,
            actionID: actionID ?? "delivery-\(placementID)-\(baseVersion.rawValue)",
            actorID: placement.ownerID,
            target: .build(
                locationID: placement.locationID,
                slotIndex: placement.slotIndex,
                industryDefinitionID: placement.tile.industryDefinitionID,
                level: placement.tile.level
            )
        )
        let transaction = try ResourceRulesTestDriver.prepareResourceMarketDelivery(
            context: context,
            placementID: placementID,
            baseVersion: baseVersion,
            expectedRoomID: roomID,
            state: state,
            catalog: catalog
        )
        return try ResourceRulesTestDriver.applyResourceTransaction(
            transaction,
            expectedRoomID: roomID,
            to: &state,
            catalog: catalog
        )
    }

    private func buildPlan(
        actorID: GameCore.PlayerID,
        baseVersion: GameCore.AuthoritativeVersion,
        requests: [GameCore.ResourceRequest],
        locationID: String = "birmingham",
        slotIndex: Int = 2,
        industryDefinitionID: String = "iron-works",
        level: Int = 1,
        actionID: String = UUID().uuidString
    ) -> GameCore.ResourcePlan {
        .init(
            context: .init(
                roomID: .init(rawValue: "resource-rules-test"),
                actionID: actionID,
                actorID: actorID,
                target: .build(
                    locationID: locationID,
                    slotIndex: slotIndex,
                    industryDefinitionID: industryDefinitionID,
                    level: level
                )
            ),
            baseVersion: baseVersion,
            requests: requests
        )
    }

    private func developPlan(
        actorID: GameCore.PlayerID,
        baseVersion: GameCore.AuthoritativeVersion,
        requests: [GameCore.ResourceRequest],
        tileIDs: [String] = ["develop-1"],
        actionID: String = UUID().uuidString
    ) -> GameCore.ResourcePlan {
        .init(
            context: .init(
                roomID: .init(rawValue: "resource-rules-test"),
                actionID: actionID,
                actorID: actorID,
                target: .develop(tileIDs: tileIDs)
            ),
            baseVersion: baseVersion,
            requests: requests
        )
    }

    private func makeState() -> GameCore.GameState {
        var setup = GameCore.SetupRules(seed: 1)
        var state = try! setup.makeGame(
            catalog: verifiedCatalog(), playerIDs: [player, opponent]
        ).state
        state.players.sort { lhs, _ in lhs.id == player }
        state.activePlayerID = player
        state.playerOrder = [player, opponent]
        state.authoritativeVersion = .init(rawValue: 1)
        state.players[0].cash = 30
        state.players[0].incomePosition = 10
        let manufacturerIndex = state.players[0].industryStacks.firstIndex {
            $0.industryDefinitionID == "manufacturer"
        }!
        state.players[0].industryStacks[manufacturerIndex].tiles[0].id = "develop-1"
        state.players[0].industryStacks[manufacturerIndex].tiles[1].id = "develop-2"
        state.coalMarket = coalMarket(filledIndices: Set(0..<14))
        state.ironMarket = ironMarket(filledIndices: Set(0..<10))
        state.merchants = validMerchants()
        rebalanceResources(&state)
        return state
    }

    private func validMerchants() -> [GameCore.MerchantPlacement] {
        [
            .init(slotID: "shrewsbury-1", merchantDefinitionID: "blank-2-plus", hasBeer: false),
            .init(slotID: "gloucester-1", merchantDefinitionID: "blank-2-plus", hasBeer: false),
            .init(slotID: "gloucester-2", merchantDefinitionID: "cotton-2-plus", hasBeer: true),
            .init(slotID: "oxford-1", merchantDefinitionID: "any-2-plus", hasBeer: true),
            .init(slotID: "oxford-2", merchantDefinitionID: "manufacturer-2-plus", hasBeer: true),
        ]
    }

    private func coalMarket(filledIndices: Set<Int>) -> GameCore.ResourceMarket {
        .init(resource: .coal, slots: (1...7).flatMap { price in
            Array(repeating: price, count: 2)
        }.enumerated().map { .init(price: $0.element, hasCube: filledIndices.contains($0.offset)) })
    }

    private func ironMarket(filledIndices: Set<Int>) -> GameCore.ResourceMarket {
        let prices = [1, 1, 1, 2, 2, 2, 3, 3, 4, 4]
        return .init(resource: .iron, slots: prices.enumerated().map {
            .init(price: $0.element, hasCube: filledIndices.contains($0.offset))
        })
    }

    private func rebalanceResources(_ state: inout GameCore.GameState) {
        let boardCoal = state.boardIndustryPlacements.filter { $0.tile.industryDefinitionID == "coal-mine" }.reduce(0) { $0 + max(0, $1.resourceCount) }
        let boardIron = state.boardIndustryPlacements.filter { $0.tile.industryDefinitionID == "iron-works" }.reduce(0) { $0 + max(0, $1.resourceCount) }
        let boardBeer = state.boardIndustryPlacements.filter { $0.tile.industryDefinitionID == "brewery" }.reduce(0) { $0 + max(0, $1.resourceCount) }
        state.publicSupply.coal = 30 - boardCoal - state.coalMarket.slots.filter(\.hasCube).count
        state.publicSupply.iron = 18 - boardIron - state.ironMarket.slots.filter(\.hasCube).count
        state.publicSupply.beer = 15 - boardBeer - state.merchants.filter(\.hasBeer).count
    }

    private func componentTotals(_ state: GameCore.GameState) -> (coal: Int, iron: Int, beer: Int) {
        let boardCoal = state.boardIndustryPlacements.filter { $0.tile.industryDefinitionID == "coal-mine" }.reduce(0) { $0 + $1.resourceCount }
        let boardIron = state.boardIndustryPlacements.filter { $0.tile.industryDefinitionID == "iron-works" }.reduce(0) { $0 + $1.resourceCount }
        let boardBeer = state.boardIndustryPlacements.filter { $0.tile.industryDefinitionID == "brewery" }.reduce(0) { $0 + $1.resourceCount }
        return (
            boardCoal + state.coalMarket.slots.filter(\.hasCube).count + state.publicSupply.coal,
            boardIron + state.ironMarket.slots.filter(\.hasCube).count + state.publicSupply.iron,
            boardBeer + state.merchants.filter(\.hasBeer).count + state.publicSupply.beer
        )
    }

    private func industry(
        _ placementID: String,
        at locationID: String,
        owner: GameCore.PlayerID,
        kind: String,
        level: Int = 1,
        resource: Int
    ) -> GameCore.BoardIndustryPlacement {
        .init(
            placementID: placementID,
            locationID: locationID,
            slotIndex: slotIndex(for: kind, locationID: locationID),
            ownerID: owner,
            tile: .init(id: "tile-\(placementID)", industryDefinitionID: kind, level: level),
            resourceCount: resource,
            isFlipped: false
        )
    }

    private func link(_ routeID: String) -> GameCore.PlacedLink {
        .init(routeID: routeID, ownerID: opponent, era: .canal)
    }

    private func slotIndex(for kind: String, locationID: String) -> Int {
        switch (kind, locationID) {
        case ("iron-works", "birmingham"): 2
        case ("iron-works", "stoke-on-trent"): 1
        case ("iron-works", "derby"): 2
        case ("brewery", "walsall"): 1
        default: 0
        }
    }

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
            "map.json": encoder.encode(catalog.board), "industries.json": encoder.encode(catalog.industries),
            "cards.json": encoder.encode(catalog.cards), "merchants.json": encoder.encode(catalog.merchants),
            "income-track.json": encoder.encode(catalog.incomeTrack),
        ]
        let manifest = GameCore.GameDataManifest(
            rulesetVersion: catalog.rulesetVersion,
            verificationStatus: .verified,
            files: files.keys.sorted().map { .init(path: $0, sha256: GameCore.GameDataLoader.sha256(files[$0]!)) },
            sources: [.init(id: "resource-test-proof", url: "https://example.com/resource-test", component: "resource rules", version: "v2018.11", page: "test", transcriber: "test", transcribedOn: "2026-08-18", checker: "test checker", checkedOn: "2026-08-18")]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }
}

/// Test-target-only access to the legacy transaction primitives. Production action
/// submission has no raw ResourcePlan prepare/apply/replay entry point.
private enum ResourceRulesTestDriver {
    private static let authority = GameCore.GameRulesEngine.Authority()

    static func prepareResourceTransaction(
        _ plan: GameCore.ResourcePlan,
        expectedRoomID: GameCore.RoomID,
        state: GameCore.GameState,
        catalog: GameCore.VerifiedGameDataCatalog
    ) throws -> GameCore.ValidatedResourceTransaction {
        try GameCore.ResourceRules.prepare(
            plan, expectedRoomID: expectedRoomID, state: state,
            catalog: catalog, authority: authority
        )
    }

    static func applyResourceTransaction(
        _ transaction: GameCore.ValidatedResourceTransaction,
        expectedRoomID: GameCore.RoomID,
        to state: inout GameCore.GameState,
        catalog: GameCore.VerifiedGameDataCatalog
    ) throws -> GameCore.AuthoritativeResourceTransactionEvent {
        try GameCore.ResourceRules.apply(
            transaction, expectedRoomID: expectedRoomID, to: &state,
            catalog: catalog, authority: authority
        )
    }

    static func prepareResourceMarketDelivery(
        context: GameCore.ResourceActionContext,
        placementID: String,
        baseVersion: GameCore.AuthoritativeVersion,
        expectedRoomID: GameCore.RoomID,
        state: GameCore.GameState,
        catalog: GameCore.VerifiedGameDataCatalog
    ) throws -> GameCore.ValidatedResourceTransaction {
        try GameCore.ResourceRules.prepareMarketDelivery(
            context: context, placementID: placementID, baseVersion: baseVersion,
            expectedRoomID: expectedRoomID, state: state, catalog: catalog,
            authority: authority
        )
    }

    static func replayResourceTransaction(
        _ event: GameCore.AuthoritativeResourceTransactionEvent,
        expectedRoomID: GameCore.RoomID,
        to state: inout GameCore.GameState,
        catalog: GameCore.VerifiedGameDataCatalog
    ) throws {
        try GameCore.ResourceRules.replay(
            event, expectedRoomID: expectedRoomID, to: &state,
            catalog: catalog, authority: authority
        )
    }
}
