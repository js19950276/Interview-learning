import Foundation

extension GameCore {
    nonisolated enum ScoringRuleError: Error, Equatable, Sendable {
        case missingDefinition
        case insufficientRailCards
    }

    nonisolated enum ScoringRules {
        static func scoreEra(
            _ era: Era,
            state: inout GameState,
            catalog: VerifiedGameDataCatalog
        ) throws -> GameTransitionEvent {
            let definitions = Dictionary(uniqueKeysWithValues: catalog.catalog.industries.map { ($0.id, $0) })
            let routes = Dictionary(uniqueKeysWithValues: catalog.catalog.board.routes.map { ($0.id, $0) })
            var linkPoints = Dictionary(uniqueKeysWithValues: state.players.map { ($0.id, 0) })
            var industryPoints = linkPoints
            let flipped = state.boardIndustryPlacements.filter(\.isFlipped)

            for placement in flipped {
                guard let level = definitions[placement.tile.industryDefinitionID]?
                    .levels.first(where: { $0.level == placement.tile.level })
                else { throw ScoringRuleError.missingDefinition }
                industryPoints[placement.ownerID] = try checkedAdd(
                    industryPoints[placement.ownerID, default: 0], level.victoryPoints
                )
            }

            let eraLinks = state.placedLinks.filter { $0.era == era }
            for link in eraLinks {
                guard let adjacent = routes[link.routeID]?.adjacentLocationIDs else {
                    throw ScoringRuleError.missingDefinition
                }
                for placement in flipped where adjacent.contains(placement.locationID) {
                    guard let points = definitions[placement.tile.industryDefinitionID]?
                        .levels.first(where: { $0.level == placement.tile.level })?.linkPoints
                    else { throw ScoringRuleError.missingDefinition }
                    linkPoints[link.ownerID] = try checkedAdd(linkPoints[link.ownerID, default: 0], points)
                }
            }

            let awards = try state.playerOrder.map { playerID in
                let links = linkPoints[playerID, default: 0]
                let industries = industryPoints[playerID, default: 0]
                guard let index = state.players.firstIndex(where: { $0.id == playerID }) else {
                    throw ScoringRuleError.missingDefinition
                }
                state.players[index].victoryPoints = try checkedAdd(
                    state.players[index].victoryPoints, try checkedAdd(links, industries)
                )
                return GameTransitionEvent.PlayerVPAward(
                    playerID: playerID, linkPoints: links, industryPoints: industries
                )
            }
            state.placedLinks.removeAll { $0.era == era }
            return .eraScored(.init(
                era: era, awards: awards, removedRouteIDs: eraLinks.map(\.routeID)
            ))
        }

        static func prepareRailEra(
            state: inout GameState,
            catalog: VerifiedGameDataCatalog
        ) throws -> GameTransitionEvent {
            let removed = state.boardIndustryPlacements.filter { $0.tile.level == 1 }
            for placement in removed {
                switch placement.tile.industryDefinitionID {
                case "coal-mine": SupplyRules.returnToPublicSupply(.coal, amount: placement.resourceCount, state: &state)
                case "iron-works": SupplyRules.returnToPublicSupply(.iron, amount: placement.resourceCount, state: &state)
                case "brewery": SupplyRules.returnToPublicSupply(.beer, amount: placement.resourceCount, state: &state)
                default: break
                }
            }
            let removedIDs = Set(removed.map(\.placementID))
            state.boardIndustryPlacements.removeAll { removedIDs.contains($0.placementID) }
            state.placedLinks.removeAll()

            let merchantDefinitions = Dictionary(uniqueKeysWithValues: catalog.catalog.merchants.map {
                ($0.id, $0)
            })
            for index in state.merchants.indices {
                guard state.merchants[index].hasBeer == false,
                      merchantDefinitions[state.merchants[index].merchantDefinitionID]?
                        .acceptedIndustryIDs.isEmpty == false
                else { continue }
                state.merchants[index].hasBeer = true
                if state.publicSupply.beer > 0 { state.publicSupply.beer -= 1 }
            }

            let legalDefinitions = Set(catalog.catalog.cards.filter {
                $0.playerCounts.contains(state.playerCount)
                    && $0.kind != .wildLocation && $0.kind != .wildIndustry
            }.map(\.id))
            var deck = state.players.flatMap(\.hand)
                + state.players.compactMap(\.privateBottomDiscard)
                + state.standardDrawDeck + state.publicDiscard
            guard deck.allSatisfy({ legalDefinitions.contains($0.definitionID) }) else {
                throw ScoringRuleError.missingDefinition
            }
            var generator = SeededGenerator(seed: state.seed ^ 0x5241_494C_4552_4102)
            generator.shuffle(&deck)
            guard deck.count >= state.playerCount * 8 else { throw ScoringRuleError.insufficientRailCards }
            for index in state.players.indices {
                state.players[index].hand.removeAll()
                state.players[index].privateBottomDiscard = nil
                state.players[index].linksRemaining = 14
            }
            state.publicDiscard.removeAll()
            for _ in 0..<8 {
                for playerID in state.playerOrder {
                    guard let playerIndex = state.players.firstIndex(where: { $0.id == playerID }) else {
                        throw ScoringRuleError.missingDefinition
                    }
                    state.players[playerIndex].hand.append(deck.removeFirst())
                }
            }
            state.standardDrawDeck = deck
            state.era = .rail
            state.roundNumber = 1
            state.actionsRemaining = 2
            state.turnsCompletedInRound = 0
            state.activePlayerID = state.playerOrder.first
            state.turnPhase = .active
            state.roundIncomeCursor = nil
            return .railPrepared(.init(
                removedPlacementIDs: removed.map(\.placementID),
                handCounts: Dictionary(uniqueKeysWithValues: state.players.map { ($0.id, $0.hand.count) })
            ))
        }

        static func resolveWinner(state: inout GameState) -> GameTransitionEvent {
            let playersByID = Dictionary(uniqueKeysWithValues: state.players.map { ($0.id, $0) })
            let previousIndex = Dictionary(uniqueKeysWithValues: state.playerOrder.enumerated().map {
                ($0.element, $0.offset)
            })
            let sorted = state.playerOrder.sorted { leftID, rightID in
                guard let left = playersByID[leftID], let right = playersByID[rightID] else { return false }
                let leftVP = left.victoryPoints - left.victoryPointDebt
                let rightVP = right.victoryPoints - right.victoryPointDebt
                if leftVP != rightVP { return leftVP > rightVP }
                if left.incomePosition != right.incomePosition { return left.incomePosition > right.incomePosition }
                if left.cash != right.cash { return left.cash > right.cash }
                return previousIndex[leftID, default: 0] < previousIndex[rightID, default: 0]
            }
            var standings: [[PlayerID]] = []
            for playerID in sorted {
                guard let player = playersByID[playerID] else { continue }
                if let lastID = standings.last?.first,
                   let last = playersByID[lastID],
                   player.victoryPoints - player.victoryPointDebt == last.victoryPoints - last.victoryPointDebt,
                   player.incomePosition == last.incomePosition,
                   player.cash == last.cash {
                    standings[standings.count - 1].append(playerID)
                } else {
                    standings.append([playerID])
                }
            }
            state.turnPhase = .ended
            state.actionsRemaining = 0
            state.roundIncomeCursor = nil
            state.activePlayerID = standings.first?.first ?? state.playerOrder.first
            return .gameEnded(.init(standings: standings))
        }

        private static func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
            let (value, overflow) = lhs.addingReportingOverflow(rhs)
            guard overflow == false else {
                throw GameRulesEngine.GameRulesInternalError.arithmeticOverflow
            }
            return value
        }
    }
}
