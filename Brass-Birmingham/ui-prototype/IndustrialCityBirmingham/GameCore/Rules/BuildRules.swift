import Foundation

extension GameCore {
    nonisolated struct BuildIntent: Codable, Equatable, Sendable {
        var cardID: String
        var locationID: String
        var industryDefinitionID: String
        var slotIndex: Int
        var resourceSources: [ResourceSource]
    }

    nonisolated struct ValidatedBuildTarget: Equatable, Sendable {
        let actorID: PlayerID
        let intent: BuildIntent
        let card: CardInstance
        let tile: IndustryTile
        let buildCost: Int
        let resourceRequests: [ResourceRequest]
        let overbuildPlacementID: String?

        fileprivate init(
            actorID: PlayerID,
            intent: BuildIntent,
            card: CardInstance,
            tile: IndustryTile,
            buildCost: Int,
            resourceRequests: [ResourceRequest],
            overbuildPlacementID: String?
        ) {
            self.actorID = actorID
            self.intent = intent
            self.card = card
            self.tile = tile
            self.buildCost = buildCost
            self.resourceRequests = resourceRequests
            self.overbuildPlacementID = overbuildPlacementID
        }
    }

    nonisolated struct BuildTarget: Codable, Equatable, Sendable {
        var locationID: String
        var slotIndex: Int
    }

    nonisolated enum BuildRuleError: String, Codable, Equatable, Error, Sendable {
        case notActivePlayer, missingCard, invalidCard, invalidLocation, invalidIndustry
        case invalidSlot, slotPriority, outsideNetwork, wrongEra, wrongTile, farmRestricted
        case canalLocationLimit, emptySlotAvailable, illegalOverbuild, insufficientCash, illegalResourcePlan
    }

    nonisolated enum BuildRules {
        static func validate(
            _ intent: BuildIntent,
            actorID: PlayerID,
            state: GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog
        ) throws -> ValidatedBuildTarget {
            guard state.activePlayerID == actorID,
                  let player = state.players.first(where: { $0.id == actorID })
            else { throw BuildRuleError.notActivePlayer }
            guard let card = player.hand.first(where: { $0.id == intent.cardID })
            else { throw BuildRuleError.missingCard }
            let catalog = verifiedCatalog.catalog
            guard let cardDefinition = catalog.cards.first(where: { $0.id == card.definitionID })
            else { throw BuildRuleError.invalidCard }
            guard let location = catalog.board.locations.first(where: {
                $0.id == intent.locationID && $0.playerCounts.contains(state.playerCount)
            }) else { throw BuildRuleError.invalidLocation }
            guard let industry = catalog.industries.first(where: { $0.id == intent.industryDefinitionID }),
                  let stack = player.industryStacks.first(where: { $0.industryDefinitionID == intent.industryDefinitionID }),
                  let tile = stack.tiles.first,
                  let level = industry.levels.first(where: { $0.level == tile.level })
            else { throw BuildRuleError.wrongTile }
            guard (state.era == .canal ? level.canalEra : level.railEra) else {
                throw BuildRuleError.wrongEra
            }
            guard location.industrySlots.indices.contains(intent.slotIndex),
                  location.industrySlots[intent.slotIndex].contains(intent.industryDefinitionID)
            else { throw BuildRuleError.invalidSlot }

            switch cardDefinition.kind {
            case .location:
                guard cardDefinition.targetIDs.contains(intent.locationID) else { throw BuildRuleError.invalidCard }
            case .industry:
                guard cardDefinition.targetIDs.contains(intent.industryDefinitionID) else { throw BuildRuleError.invalidCard }
                if hasOwnNetwork(actorID, state: state),
                   TopologyRules.isInPlayerNetwork(playerID: actorID, locationID: intent.locationID, state: state, board: catalog.board) == false {
                    throw BuildRuleError.outsideNetwork
                }
            case .wildLocation:
                guard location.kind != .breweryFarm else { throw BuildRuleError.farmRestricted }
            case .wildIndustry:
                if hasOwnNetwork(actorID, state: state),
                   TopologyRules.isInPlayerNetwork(playerID: actorID, locationID: intent.locationID, state: state, board: catalog.board) == false {
                    throw BuildRuleError.outsideNetwork
                }
            }
            if location.kind == .breweryFarm {
                guard intent.industryDefinitionID == "brewery",
                      cardDefinition.kind == .industry || cardDefinition.kind == .wildIndustry
                else { throw BuildRuleError.farmRestricted }
            }
            if state.era == .canal,
               state.boardIndustryPlacements.contains(where: {
                   $0.ownerID == actorID && $0.locationID == intent.locationID
                        && $0.slotIndex != intent.slotIndex
               }) {
                throw BuildRuleError.canalLocationLimit
            }

            let existing = state.boardIndustryPlacements.first(where: {
                $0.locationID == intent.locationID && $0.slotIndex == intent.slotIndex
            })
            let compatibleEmptySlots = location.industrySlots.indices.filter { index in
                location.industrySlots[index].contains(intent.industryDefinitionID)
                    && state.boardIndustryPlacements.contains(where: {
                        $0.locationID == location.id && $0.slotIndex == index
                    }) == false
            }
            let prioritizedEmptySlots: [Int]
            let singleEmptySlots = compatibleEmptySlots.filter {
                location.industrySlots[$0] == [intent.industryDefinitionID]
            }
            prioritizedEmptySlots = singleEmptySlots.isEmpty ? compatibleEmptySlots : singleEmptySlots
            if existing == nil {
                if prioritizedEmptySlots.contains(intent.slotIndex) == false {
                    throw BuildRuleError.slotPriority
                }
            } else if let existing {
                guard prioritizedEmptySlots.isEmpty else { throw BuildRuleError.emptySlotAvailable }
                guard existing.tile.industryDefinitionID == intent.industryDefinitionID,
                      tile.level > existing.tile.level
                else { throw BuildRuleError.illegalOverbuild }
                if existing.ownerID != actorID {
                    guard ["coal-mine", "iron-works"].contains(intent.industryDefinitionID),
                          resourceExhausted(intent.industryDefinitionID, state: state)
                    else { throw BuildRuleError.illegalOverbuild }
                }
            }

            let requirements: [ResourceKind] =
                Array(repeating: .coal, count: level.coalCost)
                + Array(repeating: .iron, count: level.ironCost)
                + Array(repeating: .beer, count: level.beerCost)
            guard requirements.count == intent.resourceSources.count else {
                throw BuildRuleError.illegalResourcePlan
            }
            let requests = zip(requirements, intent.resourceSources).map {
                ResourceRequest(resource: $0.0, consumerLocationID: intent.locationID, context: .standard, source: $0.1)
            }
            var sourceState = state
            var marketCost = 0
            for request in requests {
                let legalSources = GameRulesEngine.legalResourceSources(
                    resource: request.resource,
                    consumerLocationID: request.consumerLocationID,
                    context: request.context,
                    state: sourceState,
                    catalog: verifiedCatalog
                )
                guard legalSources.contains(request.source) else {
                    throw BuildRuleError.illegalResourcePlan
                }
                let sourceCost: Int
                switch request.source {
                case .marketSlot(let resource, let index):
                    let market = resource == .coal ? sourceState.coalMarket : sourceState.ironMarket
                    guard market.slots.indices.contains(index), market.slots[index].price >= 0 else {
                        throw BuildRuleError.illegalResourcePlan
                    }
                    sourceCost = market.slots[index].price
                case .unlimitedMarket(let resource, _):
                    guard resource == request.resource else {
                        throw BuildRuleError.illegalResourcePlan
                    }
                    sourceCost = resource == .coal ? 8 : 6
                case .industry, .merchantBeer:
                    sourceCost = 0
                }
                let (nextCost, overflow) = marketCost.addingReportingOverflow(sourceCost)
                guard !overflow else { throw BuildRuleError.illegalResourcePlan }
                marketCost = nextCost
                consumeForEnumeration(
                    resource: request.resource, source: request.source, state: &sourceState
                )
            }
            let (totalCost, overflow) = level.buildCost.addingReportingOverflow(marketCost)
            guard !overflow else { throw BuildRuleError.illegalResourcePlan }
            guard player.cash >= totalCost else { throw BuildRuleError.insufficientCash }
            return ValidatedBuildTarget(
                actorID: actorID, intent: intent, card: card, tile: tile,
                buildCost: level.buildCost, resourceRequests: requests,
                overbuildPlacementID: existing?.placementID
            )
        }

        static func legalBuildTargets(
            actorID: PlayerID,
            cardID: String,
            tile: IndustryTile,
            state: GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog
        ) -> [BuildTarget] {
            legalBuildTargets(
                actorID: actorID,
                cardID: cardID,
                tile: tile,
                state: state,
                catalog: verifiedCatalog,
                maximumCount: nil
            )
        }

        static func hasLegalBuildTarget(
            actorID: PlayerID,
            cardID: String,
            tile: IndustryTile,
            state: GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog
        ) -> Bool {
            legalBuildTargets(
                actorID: actorID,
                cardID: cardID,
                tile: tile,
                state: state,
                catalog: verifiedCatalog,
                maximumCount: 1
            ).isEmpty == false
        }

        private static func legalBuildTargets(
            actorID: PlayerID,
            cardID: String,
            tile: IndustryTile,
            state: GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog,
            maximumCount: Int?
        ) -> [BuildTarget] {
            guard state.activePlayerID == actorID,
                  let player = state.players.first(where: { $0.id == actorID }),
                  let card = player.hand.first(where: { $0.id == cardID }),
                  let cardDefinition = verifiedCatalog.catalog.cards.first(where: {
                      $0.id == card.definitionID
                  }),
                  player.industryStacks.first(where: {
                      $0.industryDefinitionID == tile.industryDefinitionID
                  })?.tiles.first == tile,
                  let level = verifiedCatalog.catalog.industries.first(where: {
                      $0.id == tile.industryDefinitionID
                  })?.levels.first(where: { $0.level == tile.level })
            else { return [] }
            let requirements = Array(repeating: ResourceKind.coal, count: level.coalCost)
                + Array(repeating: .iron, count: level.ironCost)
                + Array(repeating: .beer, count: level.beerCost)
            var result: [BuildTarget] = []
            for location in verifiedCatalog.catalog.board.locations
                .filter({ location in
                    guard location.playerCounts.contains(state.playerCount),
                          location.industrySlots.contains(where: {
                              $0.contains(tile.industryDefinitionID)
                          })
                    else { return false }
                    switch cardDefinition.kind {
                    case .location:
                        return cardDefinition.targetIDs.contains(location.id)
                    case .industry:
                        return cardDefinition.targetIDs.contains(tile.industryDefinitionID)
                    case .wildLocation:
                        return location.kind != .breweryFarm
                    case .wildIndustry:
                        return true
                    }
                })
                .sorted(by: { $0.id < $1.id }) {
                for slotIndex in location.industrySlots.indices {
                    var sourceState = state
                    var sources: [ResourceSource] = []
                    var possible = true
                    for resource in requirements {
                        guard let source = GameRulesEngine.legalResourceSources(
                            resource: resource, consumerLocationID: location.id, context: .standard,
                            state: sourceState, catalog: verifiedCatalog
                        ).first else { possible = false; break }
                        sources.append(source)
                        consumeForEnumeration(resource: resource, source: source, state: &sourceState)
                    }
                    guard possible else { continue }
                    let intent = BuildIntent(
                        cardID: cardID, locationID: location.id,
                        industryDefinitionID: tile.industryDefinitionID,
                        slotIndex: slotIndex, resourceSources: sources
                    )
                    if (try? validate(intent, actorID: actorID, state: state, catalog: verifiedCatalog)) != nil {
                        result.append(.init(locationID: location.id, slotIndex: slotIndex))
                        if result.count == maximumCount { return result }
                    }
                }
            }
            return result.sorted { ($0.locationID, $0.slotIndex) < ($1.locationID, $1.slotIndex) }
        }

        private static func consumeForEnumeration(
            resource: ResourceKind, source: ResourceSource, state: inout GameState
        ) {
            switch source {
            case .industry(let id):
                if let index = state.boardIndustryPlacements.firstIndex(where: { $0.placementID == id }) {
                    state.boardIndustryPlacements[index].resourceCount -= 1
                    SupplyRules.returnToPublicSupply(resource, state: &state)
                }
            case .marketSlot(let kind, let index):
                if kind == .coal, state.coalMarket.slots.indices.contains(index) { state.coalMarket.slots[index].hasCube = false }
                if kind == .iron, state.ironMarket.slots.indices.contains(index) { state.ironMarket.slots[index].hasCube = false }
                if kind == .coal || kind == .iron {
                    SupplyRules.returnToPublicSupply(kind, state: &state)
                }
            case .merchantBeer(let id):
                if let index = state.merchants.firstIndex(where: { $0.slotID == id }) {
                    state.merchants[index].hasBeer = false
                    SupplyRules.returnToPublicSupply(.beer, state: &state)
                }
            case .unlimitedMarket:
                break
            }
        }

        private static func hasOwnNetwork(_ playerID: PlayerID, state: GameState) -> Bool {
            state.boardIndustryPlacements.contains { $0.ownerID == playerID }
                || state.placedLinks.contains { $0.ownerID == playerID }
        }

        private static func resourceExhausted(_ industryID: String, state: GameState) -> Bool {
            let boardEmpty = state.boardIndustryPlacements
                .filter { $0.tile.industryDefinitionID == industryID }
                .allSatisfy { $0.resourceCount == 0 }
            let market = industryID == "coal-mine" ? state.coalMarket : state.ironMarket
            return boardEmpty && market.slots.allSatisfy { $0.hasCube == false }
        }
    }
}
