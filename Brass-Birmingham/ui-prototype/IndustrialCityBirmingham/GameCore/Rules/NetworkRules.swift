import Foundation

extension GameCore {
    nonisolated struct NetworkIntent: Codable, Equatable, Sendable {
        var cardID: String
        var routeIDs: [String]
        var coalSources: [ResourceSource]
        var beerSource: ResourceSource?
    }

    nonisolated struct ValidatedNetworkTarget: Equatable, Sendable {
        let actorID: PlayerID
        let intent: NetworkIntent
        let card: CardInstance
        let cashCost: Int
        let resourceRequests: [ResourceRequest]

        fileprivate init(
            actorID: PlayerID,
            intent: NetworkIntent,
            card: CardInstance,
            cashCost: Int,
            resourceRequests: [ResourceRequest]
        ) {
            self.actorID = actorID
            self.intent = intent
            self.card = card
            self.cashCost = cashCost
            self.resourceRequests = resourceRequests
        }
    }

    nonisolated enum NetworkRuleError: String, Codable, Equatable, Error, Sendable {
        case notActivePlayer, missingCard, invalidCard, invalidRouteCount, duplicateRoute
        case occupiedRoute, disconnectedRoute, wrongEra, unavailableRoute, insufficientLinks
        case insufficientCash, illegalCoal, illegalBeer
    }

    nonisolated enum NetworkRules {
        static func validate(
            _ intent: NetworkIntent,
            actorID: PlayerID,
            state: GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog
        ) throws -> ValidatedNetworkTarget {
            guard state.activePlayerID == actorID,
                  let player = state.players.first(where: { $0.id == actorID })
            else { throw NetworkRuleError.notActivePlayer }
            guard let card = player.hand.first(where: { $0.id == intent.cardID })
            else { throw NetworkRuleError.missingCard }
            guard verifiedCatalog.catalog.cards.contains(where: { $0.id == card.definitionID })
            else { throw NetworkRuleError.invalidCard }

            let requiredCount: ClosedRange<Int> = state.era == .canal ? 1...1 : 1...2
            guard requiredCount.contains(intent.routeIDs.count) else { throw NetworkRuleError.invalidRouteCount }
            guard Set(intent.routeIDs).count == intent.routeIDs.count else { throw NetworkRuleError.duplicateRoute }
            guard player.linksRemaining >= intent.routeIDs.count else { throw NetworkRuleError.insufficientLinks }
            let cashCost = state.era == .canal ? 3 : (intent.routeIDs.count == 1 ? 5 : 15)
            guard player.cash >= cashCost else { throw NetworkRuleError.insufficientCash }
            if state.era == .rail {
                guard intent.coalSources.count == intent.routeIDs.count else { throw NetworkRuleError.illegalCoal }
            } else if intent.coalSources.isEmpty == false {
                throw NetworkRuleError.illegalCoal
            }
            if state.era == .rail && intent.routeIDs.count == 2 {
                guard let beer = intent.beerSource else { throw NetworkRuleError.illegalBeer }
                if case .merchantBeer = beer { throw NetworkRuleError.illegalBeer }
            } else if intent.beerSource != nil {
                throw NetworkRuleError.illegalBeer
            }

            var candidate = state
            var requests: [ResourceRequest] = []
            for (index, routeID) in intent.routeIDs.enumerated() {
                guard let route = verifiedCatalog.catalog.board.routes.first(where: { $0.id == routeID })
                else { throw NetworkRuleError.unavailableRoute }
                guard route.playerCounts.contains(state.playerCount) else { throw NetworkRuleError.unavailableRoute }
                let expectedEra: BoardDefinition.Era = state.era == .canal ? .canal : .rail
                guard route.eras.contains(expectedEra) else { throw NetworkRuleError.wrongEra }
                guard candidate.placedLinks.contains(where: { $0.routeID == routeID }) == false
                else { throw NetworkRuleError.occupiedRoute }
                guard TopologyRules.legalNetworkRoutes(
                    playerID: actorID, state: candidate, board: verifiedCatalog.catalog.board
                ).contains(routeID) else { throw NetworkRuleError.disconnectedRoute }
                candidate.placedLinks.append(.init(routeID: routeID, ownerID: actorID, era: state.era))

                if state.era == .rail {
                    let source = intent.coalSources[index]
                    guard let consumer = route.adjacentLocationIDs.first(where: { locationID in
                        GameRulesEngine.legalResourceSources(
                            resource: .coal, consumerLocationID: locationID, context: .network,
                            state: candidate, catalog: verifiedCatalog
                        ).contains(source)
                    }) else { throw NetworkRuleError.illegalCoal }
                    requests.append(.init(resource: .coal, consumerLocationID: consumer, context: .network, source: source))
                    simulateConsumption(resource: .coal, source: source, state: &candidate)
                }
            }
            if let beer = intent.beerSource {
                guard let secondRouteID = intent.routeIDs.last,
                      let route = verifiedCatalog.catalog.board.routes.first(where: { $0.id == secondRouteID }),
                      let consumer = route.adjacentLocationIDs.first(where: { locationID in
                          GameRulesEngine.legalResourceSources(
                              resource: .beer, consumerLocationID: locationID, context: .network,
                              state: candidate, catalog: verifiedCatalog
                          ).contains(beer)
                      }) else { throw NetworkRuleError.illegalBeer }
                requests.append(.init(resource: .beer, consumerLocationID: consumer, context: .network, source: beer))
            }
            return ValidatedNetworkTarget(
                actorID: actorID, intent: intent, card: card,
                cashCost: cashCost, resourceRequests: requests
            )
        }

        private static func simulateConsumption(
            resource: ResourceKind,
            source: ResourceSource,
            state: inout GameState
        ) {
            switch source {
            case .industry(let placementID):
                guard let index = state.boardIndustryPlacements.firstIndex(where: {
                    $0.placementID == placementID
                }) else { return }
                state.boardIndustryPlacements[index].resourceCount -= 1
                if resource == .coal { state.publicSupply.coal = min(30, state.publicSupply.coal + 1) }
                if resource == .iron { state.publicSupply.iron = min(18, state.publicSupply.iron + 1) }
            case .marketSlot(let kind, let index):
                if kind == .coal, state.coalMarket.slots.indices.contains(index) {
                    state.coalMarket.slots[index].hasCube = false
                    state.publicSupply.coal = min(30, state.publicSupply.coal + 1)
                } else if kind == .iron, state.ironMarket.slots.indices.contains(index) {
                    state.ironMarket.slots[index].hasCube = false
                    state.publicSupply.iron = min(18, state.publicSupply.iron + 1)
                }
            case .unlimitedMarket, .merchantBeer:
                break
            }
        }
    }
}
