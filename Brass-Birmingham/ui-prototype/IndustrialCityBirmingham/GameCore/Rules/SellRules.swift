import Foundation

extension GameCore {
    nonisolated struct SellSelection: Codable, Equatable, Sendable {
        var industryPlacementID: String
        var merchantSlotID: String
        var beerSources: [ResourceSource]
        var bonusDevelopTileID: String?

        init(
            industryPlacementID: String,
            merchantSlotID: String,
            beerSources: [ResourceSource],
            bonusDevelopTileID: String? = nil
        ) {
            self.industryPlacementID = industryPlacementID
            self.merchantSlotID = merchantSlotID
            self.beerSources = beerSources
            self.bonusDevelopTileID = bonusDevelopTileID
        }
    }

    nonisolated struct SellIntent: Codable, Equatable, Sendable {
        var cardID: String
        var sales: [SellSelection]
    }

    nonisolated struct ValidatedSellTarget: Equatable, Sendable {
        struct Sale: Equatable, Sendable {
            let selection: SellSelection
            let placement: BoardIndustryPlacement
            let merchant: MerchantPlacement
            let resourceRequests: [ResourceRequest]
            let incomeReward: Int
            let bonus: BoardDefinition.MerchantSlot.Bonus?
            let bonusDevelopTile: IndustryTile?
        }

        let actorID: PlayerID
        let intent: SellIntent
        let card: CardInstance
        let sales: [Sale]

        fileprivate init(actorID: PlayerID, intent: SellIntent, card: CardInstance, sales: [Sale]) {
            self.actorID = actorID
            self.intent = intent
            self.card = card
            self.sales = sales
        }
    }

    nonisolated enum SellRuleError: String, Codable, Equatable, Error, Sendable {
        case notActivePlayer, missingCard, emptySale, duplicateIndustry, unknownIndustry
        case alreadyFlipped, unsellableIndustry, unknownMerchant, blankMerchant
        case merchantDoesNotAccept, disconnectedMerchant, wrongBeerCount, illegalBeer
        case missingBonusDevelopTile, illegalBonusDevelopTile
    }

    nonisolated enum SellRules {
        static func validate(
            _ intent: SellIntent,
            actorID: PlayerID,
            state: GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog
        ) throws -> ValidatedSellTarget {
            guard state.activePlayerID == actorID,
                  let playerIndex = state.players.firstIndex(where: { $0.id == actorID })
            else { throw SellRuleError.notActivePlayer }
            guard let card = state.players[playerIndex].hand.first(where: { $0.id == intent.cardID })
            else { throw SellRuleError.missingCard }
            guard intent.sales.isEmpty == false else { throw SellRuleError.emptySale }
            guard Set(intent.sales.map(\.industryPlacementID)).count == intent.sales.count
            else { throw SellRuleError.duplicateIndustry }

            let catalog = verifiedCatalog.catalog
            var candidate = state
            var sales: [ValidatedSellTarget.Sale] = []
            for selection in intent.sales {
                guard let placementIndex = candidate.boardIndustryPlacements.firstIndex(where: {
                    $0.placementID == selection.industryPlacementID && $0.ownerID == actorID
                }) else { throw SellRuleError.unknownIndustry }
                let placement = candidate.boardIndustryPlacements[placementIndex]
                guard placement.isFlipped == false else { throw SellRuleError.alreadyFlipped }
                guard ["cotton-mill", "manufacturer", "pottery"].contains(placement.tile.industryDefinitionID),
                      let level = catalog.industries.first(where: {
                          $0.id == placement.tile.industryDefinitionID
                      })?.levels.first(where: { $0.level == placement.tile.level })
                else { throw SellRuleError.unsellableIndustry }
                guard let merchant = candidate.merchants.first(where: { $0.slotID == selection.merchantSlotID }),
                      let merchantSlot = catalog.board.merchantSlots.first(where: {
                          $0.id == selection.merchantSlotID && $0.playerCounts.contains(candidate.playerCount)
                      }),
                      let merchantDefinition = catalog.merchants.first(where: {
                          $0.id == merchant.merchantDefinitionID && $0.playerCounts.contains(candidate.playerCount)
                      })
                else { throw SellRuleError.unknownMerchant }
                guard merchantDefinition.acceptedIndustryIDs.isEmpty == false else { throw SellRuleError.blankMerchant }
                guard merchantDefinition.acceptedIndustryIDs.contains(placement.tile.industryDefinitionID)
                else { throw SellRuleError.merchantDoesNotAccept }
                guard TopologyRules.hasRoute(
                    from: placement.locationID, to: merchantSlot.locationID,
                    state: candidate, board: catalog.board
                ) else { throw SellRuleError.disconnectedMerchant }
                guard selection.beerSources.count == level.beerCost else { throw SellRuleError.wrongBeerCount }
                let merchantBeerCount = selection.beerSources.filter {
                    if case .merchantBeer = $0 { true } else { false }
                }.count
                let merchantSourcesMatch = selection.beerSources.allSatisfy { source in
                    if case .merchantBeer(let slotID) = source {
                        return slotID == selection.merchantSlotID
                    }
                    return true
                }
                guard merchantBeerCount <= 1, merchantSourcesMatch
                else { throw SellRuleError.illegalBeer }
                let requests = selection.beerSources.map {
                    ResourceRequest(
                        resource: .beer,
                        consumerLocationID: placement.locationID,
                        context: .selling(merchantSlotID: selection.merchantSlotID),
                        source: $0
                    )
                }
                do {
                    _ = try ResourceRules.consumeValidatedRequests(
                        requests, actorID: actorID, state: &candidate, catalog: verifiedCatalog
                    )
                } catch let internalError as GameRulesEngine.GameRulesInternalError {
                    throw internalError
                } catch {
                    throw SellRuleError.illegalBeer
                }

                candidate.boardIndustryPlacements[placementIndex].isFlipped = true
                try advanceIncome(level.incomeReward, playerIndex: playerIndex, state: &candidate, catalog: catalog)

                let receivesBonus = merchantBeerCount == 1
                var bonusDevelopTile: IndustryTile?
                if receivesBonus {
                    switch merchantSlot.bonus.kind {
                    case .develop:
                        guard let tileID = selection.bonusDevelopTileID else {
                            throw SellRuleError.missingBonusDevelopTile
                        }
                        guard let stackIndex = candidate.players[playerIndex].industryStacks.firstIndex(where: {
                            $0.tiles.first?.id == tileID
                        }),
                            let tile = candidate.players[playerIndex].industryStacks[stackIndex].tiles.first,
                            let tileLevel = catalog.industries.first(where: {
                                $0.id == tile.industryDefinitionID
                            })?.levels.first(where: { $0.level == tile.level }),
                            tileLevel.canDevelop
                        else { throw SellRuleError.illegalBonusDevelopTile }
                        candidate.players[playerIndex].industryStacks[stackIndex].tiles.removeFirst()
                        bonusDevelopTile = tile
                    case .income:
                        try advanceIncome(
                            merchantSlot.bonus.amount, playerIndex: playerIndex,
                            state: &candidate, catalog: catalog
                        )
                    case .money:
                        candidate.players[playerIndex].cash = try checkedAdd(
                            candidate.players[playerIndex].cash, merchantSlot.bonus.amount
                        )
                    case .victoryPoints:
                        candidate.players[playerIndex].victoryPoints = try checkedAdd(
                            candidate.players[playerIndex].victoryPoints, merchantSlot.bonus.amount
                        )
                    }
                } else if selection.bonusDevelopTileID != nil {
                    throw SellRuleError.illegalBonusDevelopTile
                }
                sales.append(.init(
                    selection: selection,
                    placement: placement,
                    merchant: merchant,
                    resourceRequests: requests,
                    incomeReward: level.incomeReward,
                    bonus: receivesBonus ? merchantSlot.bonus : nil,
                    bonusDevelopTile: bonusDevelopTile
                ))
            }
            return ValidatedSellTarget(actorID: actorID, intent: intent, card: card, sales: sales)
        }

        static func apply(
            _ target: ValidatedSellTarget,
            state: inout GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog
        ) throws -> [ResourceEffect] {
            guard state.activePlayerID == target.actorID,
                  let playerIndex = state.players.firstIndex(where: { $0.id == target.actorID })
            else { throw SellRuleError.notActivePlayer }
            var effects: [ResourceEffect] = []
            for sale in target.sales {
                guard let placementIndex = state.boardIndustryPlacements.firstIndex(where: {
                    $0 == sale.placement && $0.isFlipped == false
                }) else { throw SellRuleError.unknownIndustry }
                effects += try ResourceRules.consumeValidatedRequests(
                    sale.resourceRequests, actorID: target.actorID,
                    state: &state, catalog: verifiedCatalog
                )
                state.boardIndustryPlacements[placementIndex].isFlipped = true
                effects.append(.industryFlipped(placementID: sale.placement.placementID))
                effects += try incomeEffects(
                    sale.incomeReward, actorID: target.actorID,
                    playerIndex: playerIndex, state: &state, catalog: verifiedCatalog.catalog
                )
                if let bonus = sale.bonus {
                    switch bonus.kind {
                    case .develop:
                        guard let tile = sale.bonusDevelopTile,
                              let stackIndex = state.players[playerIndex].industryStacks.firstIndex(where: {
                                  $0.industryDefinitionID == tile.industryDefinitionID && $0.tiles.first == tile
                              }) else { throw SellRuleError.illegalBonusDevelopTile }
                        state.players[playerIndex].industryStacks[stackIndex].tiles.removeFirst()
                        effects.append(.industryDeveloped(playerID: target.actorID, tile: tile))
                    case .income:
                        effects += try incomeEffects(
                            bonus.amount, actorID: target.actorID,
                            playerIndex: playerIndex, state: &state, catalog: verifiedCatalog.catalog
                        )
                    case .money:
                        state.players[playerIndex].cash = try checkedAdd(
                            state.players[playerIndex].cash, bonus.amount
                        )
                        effects.append(.cashReceived(playerID: target.actorID, amount: bonus.amount))
                    case .victoryPoints:
                        state.players[playerIndex].victoryPoints = try checkedAdd(
                            state.players[playerIndex].victoryPoints, bonus.amount
                        )
                        effects.append(.victoryPointsReceived(playerID: target.actorID, amount: bonus.amount))
                    }
                }
            }
            return effects
        }

        private static func advanceIncome(
            _ amount: Int,
            playerIndex: Int,
            state: inout GameState,
            catalog: GameDataCatalog
        ) throws {
            let cap = catalog.incomeTrack.entries.map(\.position).max() ?? state.players[playerIndex].incomePosition
            state.players[playerIndex].incomePosition = min(
                cap, try checkedAdd(state.players[playerIndex].incomePosition, amount)
            )
        }

        private static func incomeEffects(
            _ amount: Int,
            actorID: PlayerID,
            playerIndex: Int,
            state: inout GameState,
            catalog: GameDataCatalog
        ) throws -> [ResourceEffect] {
            let old = state.players[playerIndex].incomePosition
            try advanceIncome(amount, playerIndex: playerIndex, state: &state, catalog: catalog)
            return [.incomeAdvanced(playerID: actorID, from: old, to: state.players[playerIndex].incomePosition)]
        }

        private static func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
            let (value, overflow) = lhs.addingReportingOverflow(rhs)
            guard !overflow else {
                throw GameRulesEngine.GameRulesInternalError.arithmeticOverflow
            }
            return value
        }
    }
}
