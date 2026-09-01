import Foundation
import Testing
@testable import IndustrialCityBirmingham

struct DevelopSellSimpleActionTests {
    private let roomID = GameCore.RoomID(rawValue: "remaining-actions")

    @Test func developValidatesAndResolvesTwoLowestTilesInOrderWithIronPriority() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        let manufacturerIndex = try #require(state.players[playerIndex].industryStacks.firstIndex {
            $0.industryDefinitionID == "manufacturer"
        })
        let first = state.players[playerIndex].industryStacks[manufacturerIndex].tiles[0]
        let second = state.players[playerIndex].industryStacks[manufacturerIndex].tiles[1]
        let card = GameCore.CardInstance(id: "location-birmingham-1", definitionID: "location-birmingham")
        state.players[playerIndex].hand = [card]
        state.boardIndustryPlacements = [
            .init(
                placementID: "map-iron", locationID: "derby", slotIndex: 2, ownerID: actor,
                tile: .init(id: "iron-tile", industryDefinitionID: "iron-works", level: 1),
                resourceCount: 1
            ),
        ]
        state.publicSupply.iron -= 1
        repairCardFixture(&state, catalog: catalog)
        let marketIndex = try #require(state.ironMarket.slots.firstIndex(where: { $0.hasCube }))
        let intent = GameCore.DevelopIntent(
            cardID: card.id,
            tileIDs: [first.id, second.id],
            ironSources: [.industry(placementID: "map-iron"), .marketSlot(resource: .iron, index: marketIndex)]
        )
        let target = try GameCore.DevelopRules.validate(
            intent, actorID: actor, state: state, catalog: catalog
        )
        #expect(target.tiles.map(\.id) == [first.id, second.id])
        let before = state

        let event = try GameCore.GameRulesEngine.resolveDevelop(
            target, roomID: roomID, state: &state, catalog: catalog
        )

        #expect(state.players[playerIndex].industryStacks[manufacturerIndex].tiles.first?.id != first.id)
        #expect(state.players[playerIndex].industryStacks[manufacturerIndex].tiles.first?.id != second.id)
        #expect(state.boardIndustryPlacements[0].resourceCount == 0)
        #expect(state.ironMarket.slots[marketIndex].hasCube == false)
        #expect(state.authoritativeVersion.rawValue == before.authoritativeVersion.rawValue + 1)
        #expect(state.actionNumber == before.actionNumber + 1)
        var replayed = before
        try GameCore.GameRulesEngine.replay(event, expectedRoomID: roomID, to: &replayed, catalog: catalog)
        #expect(replayed == state)

    }

    @Test func developRejectsNonLowestAndBulbPotteryAtomically() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        state.players[playerIndex].hand = [.init(id: "location-birmingham-1", definitionID: "location-birmingham")]
        let manufacturer = try #require(state.players[playerIndex].industryStacks.first {
            $0.industryDefinitionID == "manufacturer"
        })
        let pottery = try #require(state.players[playerIndex].industryStacks.first {
            $0.industryDefinitionID == "pottery"
        })
        let original = state
        for tileID in [manufacturer.tiles[1].id, pottery.tiles[0].id] {
            #expect(throws: GameCore.DevelopRuleError.self) {
                try GameCore.DevelopRules.validate(
                    .init(cardID: "location-birmingham-1", tileIDs: [tileID], ironSources: [.unlimitedMarket(resource: .iron, price: 6)]),
                    actorID: actor, state: state, catalog: catalog
                )
            }
            #expect(state == original)
        }
    }

    @Test func sellUsesConcreteConnectedMerchantConsumesAtMostOneMerchantBeerAndAppliesRewards() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        state.players[playerIndex].hand = [.init(id: "location-birmingham-1", definitionID: "location-birmingham")]
        state.players[playerIndex].incomePosition = 10
        state.merchants = knownMerchants()
        state.placedLinks = [.init(routeID: "birmingham-oxford", ownerID: actor, era: .canal)]
        state.boardIndustryPlacements = [
            .init(
                placementID: "cotton", locationID: "birmingham", slotIndex: 0, ownerID: actor,
                tile: .init(id: "cotton-tile", industryDefinitionID: "cotton-mill", level: 1)
            ),
            .init(
                placementID: "own-beer", locationID: "walsall", slotIndex: 1, ownerID: actor,
                tile: .init(id: "beer-tile", industryDefinitionID: "brewery", level: 1), resourceCount: 1
            ),
        ]
        state.publicSupply.beer -= 1
        repairCardFixture(&state, catalog: catalog)
        let intent = GameCore.SellIntent(
            cardID: "location-birmingham-1",
            sales: [.init(
                industryPlacementID: "cotton", merchantSlotID: "oxford-1",
                beerSources: [.merchantBeer(slotID: "oxford-1")]
            )]
        )
        let target = try GameCore.SellRules.validate(intent, actorID: actor, state: state, catalog: catalog)
        #expect(target.sales.map(\.placement.placementID) == ["cotton"])
        let before = state

        let event = try GameCore.GameRulesEngine.resolveSell(
            target, roomID: roomID, state: &state, catalog: catalog
        )

        #expect(state.boardIndustryPlacements.first { $0.placementID == "cotton" }?.isFlipped == true)
        #expect(state.merchants.first { $0.slotID == "oxford-1" }?.hasBeer == false)
        #expect(state.players[playerIndex].incomePosition == 17)
        #expect(state.authoritativeVersion.rawValue == before.authoritativeVersion.rawValue + 1)
        #expect(state.actionNumber == before.actionNumber + 1)
        var replayed = before
        try GameCore.GameRulesEngine.replay(event, expectedRoomID: roomID, to: &replayed, catalog: catalog)
        #expect(replayed == state)

        state.activePlayerID = actor
        state.players[playerIndex].hand = [.init(id: "location-birmingham-1", definitionID: "location-birmingham")]
        repairCardFixture(&state, catalog: catalog)
        let flippedState = state
        #expect(throws: GameCore.SellRuleError.alreadyFlipped) {
            try GameCore.SellRules.validate(
                .init(cardID: "location-birmingham-1", sales: [.init(
                    industryPlacementID: "cotton", merchantSlotID: "oxford-1", beerSources: []
                )]),
                actorID: actor, state: state, catalog: catalog
            )
        }
        #expect(state == flippedState)
    }

    @Test func sellRecordsMerchantRewardBeforeFlippingIndustryAndAdvancingItsIncome() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog, playerCount: 4)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        state.players[playerIndex].hand = [
            .init(id: "sell-order-card", definitionID: "location-birmingham")
        ]
        state.players[playerIndex].incomePosition = 10
        state.merchants = merchantsFor4Players(
            acceptingAt: "oxford-1",
            industryID: "manufacturer"
        )
        state.placedLinks = [
            .init(routeID: "birmingham-oxford", ownerID: actor, era: .canal),
        ]
        state.players[playerIndex].linksRemaining = 13
        state.boardIndustryPlacements = [
            .init(
                placementID: "sell-order-industry",
                locationID: "birmingham",
                slotIndex: 1,
                ownerID: actor,
                tile: .init(
                    id: "sell-order-manufacturer",
                    industryDefinitionID: "manufacturer",
                    level: 1
                )
            ),
        ]
        repairCardFixture(&state, catalog: catalog)
        let cardID = try #require(state.players[playerIndex].hand.first?.id)
        let target = try GameCore.SellRules.validate(
            .init(
                cardID: cardID,
                sales: [.init(
                    industryPlacementID: "sell-order-industry",
                    merchantSlotID: "oxford-1",
                    beerSources: [.merchantBeer(slotID: "oxford-1")]
                )]
            ),
            actorID: actor,
            state: state,
            catalog: catalog
        )

        let event = try GameCore.GameRulesEngine.resolveSell(
            target,
            roomID: roomID,
            state: &state,
            catalog: catalog
        )
        guard case .sold(_, _, let effects) = event.payload else {
            Issue.record("Expected sold event")
            return
        }

        #expect(effects == [
            .resourceRemoved(
                resource: .beer,
                source: .merchantBeer(slotID: "oxford-1"),
                consumerLocationID: "birmingham"
            ),
            .incomeAdvanced(playerID: actor, from: 10, to: 12),
            .industryFlipped(placementID: "sell-order-industry"),
            .incomeAdvanced(playerID: actor, from: 12, to: 17),
        ])
    }

    @Test func sellRejectsBlankWrongTypeDisconnectedFlippedAndSecondInvalidSaleWithoutMutation() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let index = try #require(state.players.firstIndex { $0.id == actor })
        state.players[index].hand = [.init(id: "location-birmingham-1", definitionID: "location-birmingham")]
        state.merchants = knownMerchants()
        state.placedLinks = [.init(routeID: "birmingham-oxford", ownerID: actor, era: .canal)]
        state.boardIndustryPlacements = [
            .init(
                placementID: "cotton", locationID: "birmingham", slotIndex: 0, ownerID: actor,
                tile: .init(id: "cotton-tile", industryDefinitionID: "cotton-mill", level: 1)
            ),
            .init(
                placementID: "coal", locationID: "dudley", slotIndex: 0, ownerID: actor,
                tile: .init(id: "coal-tile", industryDefinitionID: "coal-mine", level: 1)
            ),
        ]
        repairCardFixture(&state, catalog: catalog)
        let original = state
        let invalid: [GameCore.SellIntent] = [
            .init(cardID: "location-birmingham-1", sales: [.init(industryPlacementID: "cotton", merchantSlotID: "shrewsbury-1", beerSources: [])]),
            .init(cardID: "location-birmingham-1", sales: [.init(industryPlacementID: "coal", merchantSlotID: "oxford-1", beerSources: [])]),
            .init(cardID: "location-birmingham-1", sales: [
                .init(industryPlacementID: "cotton", merchantSlotID: "oxford-1", beerSources: [.merchantBeer(slotID: "oxford-1")]),
                .init(industryPlacementID: "missing", merchantSlotID: "oxford-1", beerSources: []),
            ]),
        ]
        _ = try GameCore.SellRules.validate(
            .init(cardID: "location-birmingham-1", sales: [.init(
                industryPlacementID: "cotton", merchantSlotID: "oxford-1",
                beerSources: [.merchantBeer(slotID: "oxford-1")]
            )]),
            actorID: actor, state: state, catalog: catalog
        )
        for intent in invalid {
            #expect(throws: GameCore.SellRuleError.self) {
                try GameCore.SellRules.validate(intent, actorID: actor, state: state, catalog: catalog)
            }
            #expect(state == original)
        }
    }

    @Test func sellAppliesEveryCatalogMerchantRewardOnlyWhenMerchantBeerIsUsed() throws {
        let catalog = try verifiedCatalog()
        struct RewardCase {
            var slotID: String
            var industryID: String
            var locationID: String = "birmingham"
            var slotIndex: Int = 0
            var routes: [String]
            var expectedIncome: Int
            var expectedCash: Int
            var expectedVP: Int
            var expectsDevelop: Bool
        }
        let cases = [
            RewardCase(
                slotID: "shrewsbury-1", industryID: "cotton-mill",
                routes: ["birmingham-walsall", "walsall-wolverhampton", "coalbrookdale-wolverhampton", "coalbrookdale-shrewsbury"],
                expectedIncome: 5, expectedCash: 0, expectedVP: 4, expectsDevelop: false
            ),
            RewardCase(
                slotID: "gloucester-1", industryID: "cotton-mill",
                routes: ["birmingham-worcester", "gloucester-worcester"],
                expectedIncome: 5, expectedCash: 0, expectedVP: 0, expectsDevelop: true
            ),
            RewardCase(
                slotID: "gloucester-2", industryID: "cotton-mill",
                routes: ["birmingham-worcester", "gloucester-worcester"],
                expectedIncome: 5, expectedCash: 0, expectedVP: 0, expectsDevelop: true
            ),
            RewardCase(
                slotID: "oxford-1", industryID: "manufacturer",
                routes: ["birmingham-oxford"],
                expectedIncome: 7, expectedCash: 0, expectedVP: 0, expectsDevelop: false
            ),
            RewardCase(
                slotID: "oxford-2", industryID: "cotton-mill",
                routes: ["birmingham-oxford"],
                expectedIncome: 7, expectedCash: 0, expectedVP: 0, expectsDevelop: false
            ),
            RewardCase(
                slotID: "warrington-1", industryID: "pottery",
                locationID: "stoke-on-trent", slotIndex: 1,
                routes: ["stoke-on-trent-warrington"],
                expectedIncome: 5, expectedCash: 5, expectedVP: 0, expectsDevelop: false
            ),
            RewardCase(
                slotID: "warrington-2", industryID: "pottery",
                locationID: "stoke-on-trent", slotIndex: 1,
                routes: ["stoke-on-trent-warrington"],
                expectedIncome: 5, expectedCash: 5, expectedVP: 0, expectsDevelop: false
            ),
            RewardCase(
                slotID: "nottingham-1", industryID: "cotton-mill",
                routes: ["birmingham-tamworth", "burton-on-trent-tamworth", "burton-on-trent-derby", "derby-nottingham"],
                expectedIncome: 5, expectedCash: 0, expectedVP: 3, expectsDevelop: false
            ),
            RewardCase(
                slotID: "nottingham-2", industryID: "cotton-mill",
                routes: ["birmingham-tamworth", "burton-on-trent-tamworth", "burton-on-trent-derby", "derby-nottingham"],
                expectedIncome: 5, expectedCash: 0, expectedVP: 3, expectsDevelop: false
            ),
        ]

        for value in cases {
            var state = try setupState(catalog: catalog, playerCount: 4)
            let actor = try #require(state.activePlayerID)
            let index = try #require(state.players.firstIndex { $0.id == actor })
            state.players[index].hand = [.init(id: "location-birmingham-1", definitionID: "location-birmingham")]
            state.players[index].incomePosition = 10
            state.players[index].cash = 17
            state.players[index].victoryPoints = 0
            state.merchants = merchantsFor4Players(
                acceptingAt: value.slotID, industryID: value.industryID
            )
            state.placedLinks = value.routes.map { .init(routeID: $0, ownerID: actor, era: .canal) }
            state.players[index].linksRemaining = 14 - value.routes.count
            state.boardIndustryPlacements = [
                .init(
                    placementID: "sold", locationID: value.locationID, slotIndex: value.slotIndex, ownerID: actor,
                    tile: .init(id: "sold-tile", industryDefinitionID: value.industryID, level: 1)
                ),
            ]
            repairCardFixture(&state, catalog: catalog)
            let developTile = try #require(state.players[index].industryStacks.first {
                $0.industryDefinitionID == "manufacturer"
            }?.tiles.first)
            let developCount = state.players[index].industryStacks.flatMap(\.tiles).count
            let target = try GameCore.SellRules.validate(
                .init(cardID: "location-birmingham-1", sales: [.init(
                    industryPlacementID: "sold", merchantSlotID: value.slotID,
                    beerSources: [.merchantBeer(slotID: value.slotID)],
                    bonusDevelopTileID: value.expectsDevelop ? developTile.id : nil
                )]),
                actorID: actor, state: state, catalog: catalog
            )
            _ = try GameCore.GameRulesEngine.resolveSell(
                target, roomID: roomID, state: &state, catalog: catalog
            )
            #expect(state.players[index].incomePosition == 10 + value.expectedIncome)
            #expect(state.players[index].cash == 17 + value.expectedCash)
            #expect(state.players[index].victoryPoints == value.expectedVP)
            #expect(state.players[index].industryStacks.flatMap(\.tiles).count == developCount - (value.expectsDevelop ? 1 : 0))
        }
    }

    @Test func sellMoneyAndVictoryPointRewardOverflowReturnsInternalFailureWithoutMutation() throws {
        let catalog = try verifiedCatalog()
        struct OverflowCase {
            let slotID: String
            let industryID: String
            let locationID: String
            let slotIndex: Int
            let routes: [String]
            let setLimit: (inout GameCore.SetupPlayer) -> Void
        }
        let cases = [
            OverflowCase(
                slotID: "warrington-1", industryID: "pottery",
                locationID: "stoke-on-trent", slotIndex: 1,
                routes: ["stoke-on-trent-warrington"],
                setLimit: { $0.cash = Int.max }
            ),
            OverflowCase(
                slotID: "shrewsbury-1", industryID: "cotton-mill",
                locationID: "birmingham", slotIndex: 0,
                routes: ["birmingham-walsall", "walsall-wolverhampton", "coalbrookdale-wolverhampton", "coalbrookdale-shrewsbury"],
                setLimit: { $0.victoryPoints = Int.max }
            ),
        ]

        for value in cases {
            var state = try setupState(catalog: catalog, playerCount: 4)
            let actor = try #require(state.activePlayerID)
            let index = try #require(state.players.firstIndex { $0.id == actor })
            state.players[index].hand = [.init(id: "location-birmingham-1", definitionID: "location-birmingham")]
            value.setLimit(&state.players[index])
            state.merchants = merchantsFor4Players(
                acceptingAt: value.slotID, industryID: value.industryID
            )
            state.placedLinks = value.routes.map { .init(routeID: $0, ownerID: actor, era: .canal) }
            state.players[index].linksRemaining = 14 - value.routes.count
            state.boardIndustryPlacements = [.init(
                placementID: "sold", locationID: value.locationID, slotIndex: value.slotIndex,
                ownerID: actor,
                tile: .init(id: "sold-tile", industryDefinitionID: value.industryID, level: 1)
            )]
            repairCardFixture(&state, catalog: catalog)
            let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
                ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
            })
            var host = try state.makeHostEngine(
                roomID: roomID, reconnectTokens: tokens, protocolVersion: 1
            )
            let before = host.gameState
            let result = host.submit(.init(
                protocolVersion: 1, rulesetVersion: state.rulesetVersion, roomID: roomID,
                senderID: actor, reconnectToken: tokens[actor]!, baseVersion: state.authoritativeVersion,
                payload: .sell(.init(cardID: "location-birmingham-1", sales: [.init(
                    industryPlacementID: "sold", merchantSlotID: value.slotID,
                    beerSources: [.merchantBeer(slotID: value.slotID)]
                )]))
            ), catalog: catalog)

            #expect(result == .internalFailure(.init(code: .arithmeticOverflow)))
            #expect(host.gameState == before)
        }
    }

    @Test func multiSellResolvesProgressivelyAndTwoBeerSaleRejectsTwoMerchantBeersAtomically() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog, playerCount: 3)
        let actor = try #require(state.activePlayerID)
        let index = try #require(state.players.firstIndex { $0.id == actor })
        state.players[index].hand = [.init(id: "location-birmingham-1", definitionID: "location-birmingham")]
        state.merchants = knownMerchants3Player()
        state.placedLinks = [.init(routeID: "stoke-on-trent-warrington", ownerID: actor, era: .canal)]
        state.boardIndustryPlacements = [
            .init(
                placementID: "pottery", locationID: "stoke-on-trent", slotIndex: 1, ownerID: actor,
                tile: .init(id: "pottery-3", industryDefinitionID: "pottery", level: 3)
            ),
            .init(
                placementID: "own-beer", locationID: "walsall", slotIndex: 1, ownerID: actor,
                tile: .init(id: "beer", industryDefinitionID: "brewery", level: 1), resourceCount: 1
            ),
        ]
        state.publicSupply.beer -= 1
        repairCardFixture(&state, catalog: catalog)
        let original = state
        let duplicateMerchant = GameCore.SellIntent(
            cardID: "location-birmingham-1",
            sales: [.init(
                industryPlacementID: "pottery", merchantSlotID: "warrington-1",
                beerSources: [.merchantBeer(slotID: "warrington-1"), .merchantBeer(slotID: "warrington-1")]
            )]
        )
        #expect(throws: GameCore.SellRuleError.illegalBeer) {
            try GameCore.SellRules.validate(
                duplicateMerchant, actorID: actor, state: state, catalog: catalog
            )
        }
        #expect(state == original)

        let target = try GameCore.SellRules.validate(
            .init(cardID: "location-birmingham-1", sales: [.init(
                industryPlacementID: "pottery", merchantSlotID: "warrington-1",
                beerSources: [
                    .merchantBeer(slotID: "warrington-1"),
                    .industry(placementID: "own-beer"),
                ]
            )]),
            actorID: actor, state: state, catalog: catalog
        )
        _ = try GameCore.GameRulesEngine.resolveSell(
            target, roomID: roomID, state: &state, catalog: catalog
        )
        #expect(state.boardIndustryPlacements.first { $0.placementID == "pottery" }?.isFlipped == true)
        #expect(state.boardIndustryPlacements.first { $0.placementID == "own-beer" }?.resourceCount == 0)
        #expect(state.players[index].cash == original.players[index].cash + 5)

        var multi = try setupState(catalog: catalog)
        let multiActor = try #require(multi.activePlayerID)
        let multiIndex = try #require(multi.players.firstIndex { $0.id == multiActor })
        multi.players[multiIndex].hand = [.init(id: "location-birmingham-1", definitionID: "location-birmingham")]
        multi.merchants = knownMerchants()
        multi.placedLinks = [
            .init(routeID: "birmingham-worcester", ownerID: multiActor, era: .canal),
            .init(routeID: "gloucester-worcester", ownerID: multiActor, era: .canal),
        ]
        multi.players[multiIndex].linksRemaining = 12
        multi.boardIndustryPlacements = [
            .init(
                placementID: "cotton-one", locationID: "birmingham", slotIndex: 0, ownerID: multiActor,
                tile: .init(id: "cotton-one-tile", industryDefinitionID: "cotton-mill", level: 1)
            ),
            .init(
                placementID: "cotton-two", locationID: "worcester", slotIndex: 0, ownerID: multiActor,
                tile: .init(id: "cotton-two-tile", industryDefinitionID: "cotton-mill", level: 1)
            ),
            .init(
                placementID: "multi-own-beer", locationID: "walsall", slotIndex: 1, ownerID: multiActor,
                tile: .init(id: "multi-beer", industryDefinitionID: "brewery", level: 1), resourceCount: 1
            ),
        ]
        multi.publicSupply.beer -= 1
        repairCardFixture(&multi, catalog: catalog)
        let bonusTile = try #require(multi.players[multiIndex].industryStacks.first {
            $0.industryDefinitionID == "manufacturer"
        }?.tiles.first)
        let beforeVersion = multi.authoritativeVersion
        let beforeAction = multi.actionNumber
        let multiTarget = try GameCore.SellRules.validate(
            .init(cardID: "location-birmingham-1", sales: [
                .init(
                    industryPlacementID: "cotton-one", merchantSlotID: "gloucester-2",
                    beerSources: [.merchantBeer(slotID: "gloucester-2")],
                    bonusDevelopTileID: bonusTile.id
                ),
                .init(
                    industryPlacementID: "cotton-two", merchantSlotID: "gloucester-2",
                    beerSources: [.industry(placementID: "multi-own-beer")]
                ),
            ]),
            actorID: multiActor, state: multi, catalog: catalog
        )
        _ = try GameCore.GameRulesEngine.resolveSell(
            multiTarget, roomID: roomID, state: &multi, catalog: catalog
        )
        #expect(multi.boardIndustryPlacements.filter {
            ["cotton-one", "cotton-two"].contains($0.placementID)
        }.allSatisfy { $0.isFlipped })
        #expect(multi.authoritativeVersion.rawValue == beforeVersion.rawValue + 1)
        #expect(multi.actionNumber == beforeAction + 1)
    }

    @Test func loanMovesDownThreeIncomeLevelsAndHonorsMinusTenFloor() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let index = try #require(state.players.firstIndex { $0.id == actor })
        state.players[index].hand = [.init(id: "loan-card", definitionID: "location-birmingham")]
        state.players[index].incomePosition = 20 // displayed income 5
        let target = try GameCore.SimpleActionRules.validateLoan(
            .init(cardID: "loan-card"), actorID: actor, state: state, catalog: catalog
        )
        let before = state
        let event = try GameCore.GameRulesEngine.resolveLoan(
            target, roomID: roomID, state: &state, catalog: catalog
        )
        #expect(state.players[index].cash == 47)
        #expect(state.players[index].incomePosition == 14) // highest position displaying income 2
        var replayed = before
        try GameCore.GameRulesEngine.replay(
            event, expectedRoomID: roomID, to: &replayed, catalog: catalog
        )
        #expect(replayed == state)

        var floor = try setupState(catalog: catalog)
        let floorActor = try #require(floor.activePlayerID)
        let floorIndex = try #require(floor.players.firstIndex { $0.id == floorActor })
        floor.players[floorIndex].hand = [.init(id: "loan-card", definitionID: "location-birmingham")]
        floor.players[floorIndex].incomePosition = 2
        #expect(throws: GameCore.SimpleActionRuleError.incomeFloor) {
            try GameCore.SimpleActionRules.validateLoan(
                .init(cardID: "loan-card"), actorID: floorActor, state: floor, catalog: catalog
            )
        }
    }

    @Test func loanOverflowIsExcludedFromAvailabilityAndLegalQuery() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        state.players[playerIndex].cash = Int.max
        state.players[playerIndex].hand = [
            .init(id: "loan-overflow-card", definitionID: "location-birmingham")
        ]
        repairCardFixture(&state, catalog: catalog)
        let cardID = try #require(state.players[playerIndex].hand.first?.id)

        let availability = try GameCore.SnapshotActionAvailability.make(
            state: state,
            recipient: actor,
            catalog: catalog
        )
        #expect(availability.kinds.contains(.loan) == false)
        #expect(availability.byCardID[cardID]?.contains(.loan) == false)
        #expect(availability.trivialOptions.contains(where: { $0.action == .loan }) == false)
        #expect(throws: GameCore.LegalActionQueryError.invalidPrefix) {
            try GameCore.LegalActionQueryEngine.respond(
                to: .init(
                    requestID: "loan-overflow-query",
                    baseVersion: state.authoritativeVersion,
                    draft: .init(action: .loan, cardID: cardID, selections: [])
                ),
                actorID: actor,
                state: state,
                catalog: catalog
            )
        }
    }

    @Test func loanQueryConfirmationUsesDisplayedIncomeLevelsRatherThanTrackPositions() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        state.players[playerIndex].incomePosition = 20 // displayed income 5
        state.players[playerIndex].hand = [
            .init(id: "loan-confirmation-card", definitionID: "location-birmingham")
        ]
        repairCardFixture(&state, catalog: catalog)
        let cardID = try #require(state.players[playerIndex].hand.first?.id)

        let response = try GameCore.LegalActionQueryEngine.respond(
            to: .init(
                requestID: "loan-displayed-income",
                baseVersion: state.authoritativeVersion,
                draft: .init(action: .loan, cardID: cardID, selections: [])
            ),
            actorID: actor,
            state: state,
            catalog: catalog
        )

        #expect(response.completePayload == .loan(.init(cardID: cardID)))
        #expect(response.confirmation?.cashDelta == 30)
        #expect(response.confirmation?.incomeDelta == -3)
    }

    @Test func scoutDiscardsThreeDistinctNormalCardsTakesBothWildsAndRejectsWhenWildHeld() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let index = try #require(state.players.firstIndex { $0.id == actor })
        state.players[index].hand = [
            .init(id: "c1", definitionID: "location-birmingham"),
            .init(id: "c2", definitionID: "location-dudley"),
            .init(id: "c3", definitionID: "industry-brewery"),
        ]
        let locationWild = try #require(state.wildLocationPool.last)
        let industryWild = try #require(state.wildIndustryPool.last)
        let target = try GameCore.SimpleActionRules.validateScout(
            .init(cardIDs: ["c1", "c2", "c3"]), actorID: actor, state: state, catalog: catalog
        )
        let before = state
        let event = try GameCore.GameRulesEngine.resolveScout(
            target, roomID: roomID, state: &state, catalog: catalog
        )
        #expect(state.players[index].hand.contains(locationWild))
        #expect(state.players[index].hand.contains(industryWild))
        #expect(state.publicDiscard.suffix(3).map(\.id) == ["c1", "c2", "c3"])
        var replayed = before
        try GameCore.GameRulesEngine.replay(
            event, expectedRoomID: roomID, to: &replayed, catalog: catalog
        )
        #expect(replayed == state)

        state.activePlayerID = actor
        #expect(throws: GameCore.SimpleActionRuleError.wildHeld) {
            try GameCore.SimpleActionRules.validateScout(
                .init(cardIDs: state.players[index].hand.map(\.id)),
                actorID: actor, state: state, catalog: catalog
            )
        }
    }

    @Test func catalogAwareHostDispatchesRemainingActionsAtomically() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let index = try #require(state.players.firstIndex { $0.id == actor })
        state.players[index].hand = [.init(id: "location-birmingham-1", definitionID: "location-birmingham")]
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        repairCardFixture(&state, catalog: catalog)
        state.actionNumber = 1
        var host = try state.makeHostEngine(roomID: roomID, reconnectTokens: tokens, protocolVersion: 1)
        let intent = GameCore.PlayerIntent(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion, roomID: roomID,
            senderID: actor, reconnectToken: tokens[actor]!, baseVersion: state.authoritativeVersion,
            payload: .loan(.init(cardID: "location-birmingham-1"))
        )
        guard case .accepted = host.submit(intent, catalog: catalog) else {
            Issue.record("Expected accepted catalog-aware loan")
            return
        }
        #expect(host.gameState.players[index].cash == state.players[index].cash + 30)

        var invalid = try state.makeHostEngine(roomID: roomID, reconnectTokens: tokens, protocolVersion: 1)
        let before = invalid.gameState
        let bad = GameCore.PlayerIntent(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion, roomID: roomID,
            senderID: actor, reconnectToken: tokens[actor]!, baseVersion: state.authoritativeVersion,
            payload: .develop(.init(cardID: "location-birmingham-1", tileIDs: ["missing"], ironSources: [.unlimitedMarket(resource: .iron, price: 6)]))
        )
        guard case .rejected = invalid.submit(bad, catalog: catalog) else {
            Issue.record("Expected rejected develop")
            return
        }
        #expect(invalid.gameState == before)
    }

    @Test func loanCashOverflowReturnsStableInternalFailureAndLeavesAuthorityUnchanged() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        state.players[playerIndex].cash = Int.max
        state.players[playerIndex].hand = [
            .init(id: "location-birmingham-1", definitionID: "location-birmingham")
        ]
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        repairCardFixture(&state, catalog: catalog)
        var host = try state.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 1
        )
        let before = host.gameState
        let result = host.submit(.init(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion, roomID: roomID,
            senderID: actor, reconnectToken: tokens[actor]!, baseVersion: state.authoritativeVersion,
            payload: .loan(.init(cardID: "location-birmingham-1"))
        ), catalog: catalog)

        #expect(result == .internalFailure(.init(code: .arithmeticOverflow)))
        #expect(try JSONDecoder().decode(
            GameCore.SubmissionResult.self, from: JSONEncoder.canonical.encode(result)
        ) == result)
        #expect(host.gameState == before)
    }

    @Test func legacySessionAndTestingSurfacesAreDebugGuarded() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let coordinator = try String(contentsOf: repository.appendingPathComponent(
            "IndustrialCityBirmingham/Session/SessionCoordinator.swift"
        ), encoding: .utf8)
        let viewStore = try String(contentsOf: repository.appendingPathComponent(
            "IndustrialCityBirmingham/Session/SessionViewStore.swift"
        ), encoding: .utf8)
        let environment = try String(contentsOf: repository.appendingPathComponent(
            "IndustrialCityBirmingham/App/AppEnvironment.swift"
        ), encoding: .utf8)
        let loader = try String(contentsOf: repository.appendingPathComponent(
            "IndustrialCityBirmingham/GameCore/Data/GameDataLoader.swift"
        ), encoding: .utf8)
        let matchView = try String(contentsOf: repository.appendingPathComponent(
            "IndustrialCityBirmingham/Features/Match/MatchView.swift"
        ), encoding: .utf8)
        let lobbyView = try String(contentsOf: repository.appendingPathComponent(
            "IndustrialCityBirmingham/Features/Lobby/LobbyView.swift"
        ), encoding: .utf8)

        #expect(coordinator.contains("#if DEBUG\n        case fixtureOnlyLegacy"))
        #expect(coordinator.contains("#if DEBUG\n    private func submitFixtureOnly"))
        #expect(viewStore.contains("#if DEBUG\n    convenience init"))
        #expect(viewStore.contains("    static func localUIFixture"))
        #expect(viewStore.contains("#if DEBUG\n    func setRecoveringForTesting"))
        #expect(environment.contains("#if DEBUG\n        case fixture"))
        #expect(environment.contains("#if DEBUG\n    struct LocalHarness"))
        #expect(loader.contains("#if DEBUG\n        static func loadVerifiedSetupCatalogForTesting"))
        #expect(!viewStore.contains("AppEnvironment.LocalHarness.Role"))
        #expect(!viewStore.contains("catalog suppliedCatalog:"))
        #expect(!viewStore.contains("port: UInt16? = nil"))
        #expect(!viewStore.contains("fixtureGuest: SessionCoordinator? = nil"))
        #expect(viewStore.contains("#if DEBUG\n    private var harnessPort"))
        #expect(viewStore.contains("#if DEBUG\n    var showsRecoveryUIFixtureControl"))
        #expect(viewStore.contains("#if DEBUG\n    func advanceRecoveryUIFixture"))
        #expect(matchView.contains("#if DEBUG\n            if store.showsRecoveryUIFixtureControl"))
        #expect(lobbyView.contains("#if DEBUG\n                if runsScriptHarness"))
    }

    @Test func catalogAwarePassReturnsWildCardToPoolAndReplaysExactly() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        let wild = try #require(state.wildLocationPool.last)
        state.wildLocationPool.removeLast()
        state.players[playerIndex].hand = [wild]
        repairCardFixture(&state, catalog: catalog)
        state.actionNumber = 1
        let before = state

        let target = try GameCore.SimpleActionRules.validatePass(
            .init(cardID: wild.id), actorID: actor, state: state, catalog: catalog
        )
        let event = try GameCore.GameRulesEngine.resolvePass(
            target, roomID: roomID, state: &state, catalog: catalog
        )

        #expect(state.wildLocationPool.last == wild)
        #expect(state.publicDiscard.contains(wild) == false)
        var replayed = before
        try GameCore.GameRulesEngine.replay(
            event, expectedRoomID: roomID, to: &replayed, catalog: catalog
        )
        #expect(replayed == state)
    }

    @Test func scoutClientEventShowsNewWildIDsOnlyToActor() throws {
        let catalog = try verifiedCatalog()
        var state = try setupState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let opponent = try #require(state.players.first(where: { $0.id != actor })?.id)
        let playerIndex = try #require(state.players.firstIndex { $0.id == actor })
        state.players[playerIndex].hand = [
            .init(id: "location-birmingham-1", definitionID: "location-birmingham"),
            .init(id: "location-dudley-1", definitionID: "location-dudley"),
            .init(id: "industry-brewery-1", definitionID: "industry-brewery"),
        ]
        let newLocationWildID = try #require(state.wildLocationPool.last?.id)
        let newIndustryWildID = try #require(state.wildIndustryPool.last?.id)
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "token-\($0.id.rawValue)"))
        })
        repairCardFixture(&state, catalog: catalog)
        let scoutCardIDs = Array(state.players[playerIndex].hand.prefix(3).map(\.id))
        state.actionNumber = 1
        var host = try state.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 1
        )
        let intent = GameCore.PlayerIntent(
            protocolVersion: 1, rulesetVersion: state.rulesetVersion,
            roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
            baseVersion: state.authoritativeVersion,
            payload: .scout(.init(cardIDs: scoutCardIDs))
        )
        guard case .accepted(let event) = host.submit(intent, catalog: catalog) else {
            Issue.record("Expected accepted scout")
            return
        }

        let actorBytes = try JSONEncoder.canonical.encode(host.clientEvent(event, for: actor))
        let opponentBytes = try JSONEncoder.canonical.encode(host.clientEvent(event, for: opponent))
        #expect(actorBytes.contains(Data(newLocationWildID.utf8)))
        #expect(actorBytes.contains(Data(newIndustryWildID.utf8)))
        #expect(opponentBytes.contains(Data(newLocationWildID.utf8)) == false)
        #expect(opponentBytes.contains(Data(newIndustryWildID.utf8)) == false)
    }

    @Test func remainingActionEventPersistsThroughEncryptedGuestSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remaining-actions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let actor = GameCore.PlayerID(rawValue: "guest")
        let visible = [GameCore.VisiblePlayer(id: actor, handCount: 1, hand: ["next-card"])]
        let checksum = try GameCore.snapshotChecksum(
            roomID: roomID, recipient: actor, players: visible, activePlayerID: actor,
            turn: 1, actionNumber: 1, authoritativeVersion: .init(rawValue: 1),
            discardPile: ["loan-card"]
        )
        let snapshot = GameCore.ViewSnapshot(
            roomID: roomID, recipient: actor, players: visible, activePlayerID: actor,
            turn: 1, actionNumber: 1, authoritativeVersion: .init(rawValue: 1),
            discardPile: ["loan-card"], checksum: checksum
        )
        let event = GameCore.AuthoritativeGameEvent(
            roomID: roomID, actor: actor,
            previousVersion: .init(rawValue: 0), version: .init(rawValue: 1),
            actionNumber: 1,
            payload: .loanTaken(
                intent: .init(cardID: "loan-card"),
                previousIncomePosition: 10, incomePosition: 7
            )
        )
        let envelope = SessionProtocol.SessionEnvelope(
            protocolVersion: 1, rulesetVersion: "v2018.11", roomID: roomID,
            messageID: .init(rawValue: "loan-event"), senderID: actor, recipientID: actor,
            authoritativeVersion: .init(rawValue: 1),
            payload: .clientEvent(.init(event: event, snapshot: snapshot))
        )
        let archive = SessionArchive.guest(
            protocolVersion: 1, rulesetVersion: "v2018.11", hostPlayerID: actor,
            snapshot: snapshot, eventWindow: [envelope],
            tokenReference: .init(roomID: roomID, playerID: actor), commitSequence: 1
        )
        let store = SnapshotStore(
            directory: directory,
            keyProvider: RemainingActionsSnapshotKeyProvider(key: Data(repeating: 0x27, count: 32))
        )
        try await store.save(archive)
        let restored = try await store.load(expected: .init(
            protocolVersion: 1, rulesetVersion: "v2018.11", roomID: roomID,
            recipientID: actor, role: .guest
        ))
        #expect(restored == archive)
    }

    @Test func snapshotStoreRejectsNonActorGuestArchiveContainingScoutDetails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scout-privacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hostID = GameCore.PlayerID(rawValue: "host")
        let guestID = GameCore.PlayerID(rawValue: "guest")
        let visible = [
            GameCore.VisiblePlayer(id: hostID, handCount: 7, hand: nil),
            GameCore.VisiblePlayer(id: guestID, handCount: 8, hand: ["guest-private"]),
        ]
        let snapshot = GameCore.ViewSnapshot(
            roomID: roomID, recipient: guestID, players: visible,
            activePlayerID: guestID, turn: 1, actionNumber: 1,
            authoritativeVersion: .init(rawValue: 1), discardPile: ["one", "two", "three"],
            checksum: try GameCore.snapshotChecksum(
                roomID: roomID, recipient: guestID, players: visible,
                activePlayerID: guestID, turn: 1, actionNumber: 1,
                authoritativeVersion: .init(rawValue: 1), discardPile: ["one", "two", "three"]
            )
        )
        let details = GameCore.AuthoritativeGameEvent.ScoutDetails(
            intent: .init(cardIDs: ["one", "two", "three"]),
            discardedCards: [
                .init(id: "one", definitionID: "location-birmingham"),
                .init(id: "two", definitionID: "location-dudley"),
                .init(id: "three", definitionID: "industry-brewery"),
            ],
            wildLocationCard: .init(id: "secret-location-wild", definitionID: "wild-location"),
            wildIndustryCard: .init(id: "secret-industry-wild", definitionID: "wild-industry")
        )
        func archive(details: GameCore.AuthoritativeGameEvent.ScoutDetails?) -> SessionArchive {
            let event = GameCore.AuthoritativeGameEvent(
                roomID: roomID, actor: hostID, previousVersion: .init(rawValue: 0),
                version: .init(rawValue: 1), actionNumber: 1, payload: .scouted(details)
            )
            let envelope = SessionProtocol.SessionEnvelope(
                protocolVersion: 1, rulesetVersion: "v2018.11", roomID: roomID,
                messageID: .init(rawValue: "scout"), senderID: hostID,
                recipientID: guestID, authoritativeVersion: .init(rawValue: 1),
                payload: .clientEvent(.init(event: event, snapshot: snapshot))
            )
            return .guest(
                protocolVersion: 1, rulesetVersion: "v2018.11", hostPlayerID: hostID,
                snapshot: snapshot, eventWindow: [envelope],
                tokenReference: .init(roomID: roomID, playerID: guestID), commitSequence: 1
            )
        }
        let store = SnapshotStore(
            directory: directory,
            keyProvider: RemainingActionsSnapshotKeyProvider(key: Data(repeating: 0x19, count: 32))
        )
        await #expect(throws: SnapshotStoreError.privacyViolation) {
            try await store.save(archive(details: details))
        }
        try await store.save(archive(details: nil))
    }

    private func setupState(
        catalog: GameCore.VerifiedGameDataCatalog,
        playerCount: Int = 2
    ) throws -> GameCore.GameState {
        var rules = GameCore.SetupRules(seed: 17)
        return try rules.makeGame(
            catalog: catalog,
            playerIDs: (1...playerCount).map { .init(rawValue: "p\($0)") }
        ).state
    }

    private func knownMerchants() -> [GameCore.MerchantPlacement] {
        [
            .init(slotID: "shrewsbury-1", merchantDefinitionID: "blank-2-plus", hasBeer: false),
            .init(slotID: "gloucester-1", merchantDefinitionID: "blank-2-plus", hasBeer: false),
            .init(slotID: "gloucester-2", merchantDefinitionID: "cotton-2-plus", hasBeer: true),
            .init(slotID: "oxford-1", merchantDefinitionID: "any-2-plus", hasBeer: true),
            .init(slotID: "oxford-2", merchantDefinitionID: "manufacturer-2-plus", hasBeer: true),
        ]
    }

    private func knownMerchants3Player() -> [GameCore.MerchantPlacement] {
        [
            .init(slotID: "shrewsbury-1", merchantDefinitionID: "cotton-2-plus", hasBeer: true),
            .init(slotID: "gloucester-1", merchantDefinitionID: "blank-2-plus", hasBeer: false),
            .init(slotID: "gloucester-2", merchantDefinitionID: "any-2-plus", hasBeer: true),
            .init(slotID: "oxford-1", merchantDefinitionID: "manufacturer-2-plus", hasBeer: true),
            .init(slotID: "oxford-2", merchantDefinitionID: "manufacturer-3-plus", hasBeer: true),
            .init(slotID: "warrington-1", merchantDefinitionID: "pottery-3-plus", hasBeer: true),
            .init(slotID: "warrington-2", merchantDefinitionID: "blank-2-plus", hasBeer: false),
        ]
    }

    private func merchantsFor4Players(
        acceptingAt selectedSlotID: String,
        industryID: String
    ) -> [GameCore.MerchantPlacement] {
        let selectedMerchantID: String
        switch industryID {
        case "cotton-mill": selectedMerchantID = "cotton-2-plus"
        case "manufacturer": selectedMerchantID = "manufacturer-2-plus"
        case "pottery": selectedMerchantID = "pottery-3-plus"
        default: preconditionFailure("Unsupported sell fixture industry")
        }
        var merchantIDs = [
            "blank-2-plus", "blank-2-plus", "any-2-plus", "cotton-2-plus",
            "manufacturer-2-plus", "manufacturer-3-plus", "pottery-3-plus",
            "any-4", "cotton-4",
        ]
        merchantIDs.remove(at: merchantIDs.firstIndex(of: selectedMerchantID)!)
        let slotIDs = [
            "shrewsbury-1", "gloucester-1", "gloucester-2", "oxford-1", "oxford-2",
            "warrington-1", "warrington-2", "nottingham-1", "nottingham-2",
        ]
        return slotIDs.map { slotID in
            let merchantID = slotID == selectedSlotID ? selectedMerchantID : merchantIDs.removeFirst()
            return .init(
                slotID: slotID, merchantDefinitionID: merchantID,
                hasBeer: merchantID.hasPrefix("blank-") == false
            )
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
                id: "remaining-actions-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-08-19",
                checker: "independent-test", checkedOn: "2026-08-19"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }
}

private struct RemainingActionsSnapshotKeyProvider: SnapshotKeyProvider {
    let key: Data
    func keyData() throws -> Data { key }
}
