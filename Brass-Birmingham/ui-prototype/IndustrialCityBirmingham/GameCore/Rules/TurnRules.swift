import Foundation

extension GameCore {
    nonisolated enum ForcedSaleRuleError: Error, Equatable, Sendable {
        case noPendingSale
        case wrongPlayer
        case invalidSelection
    }

    nonisolated enum TurnRules {
        static func actionsPerTurn(era: Era, roundNumber: Int) -> Int {
            era == .canal && roundNumber == 1 ? 1 : 2
        }

        static func refillHand(playerID: PlayerID, state: inout GameState) {
            guard let index = state.players.firstIndex(where: { $0.id == playerID }) else { return }
            while state.players[index].hand.count < 8, state.standardDrawDeck.isEmpty == false {
                state.players[index].hand.append(state.standardDrawDeck.removeFirst())
            }
        }

        static func resolveRoundEnd(
            state: inout GameState,
            catalog: VerifiedGameDataCatalog
        ) throws -> [GameTransitionEvent] {
            guard state.turnPhase == .active else { throw ForcedSaleRuleError.noPendingSale }
            let oldIndex = Dictionary(uniqueKeysWithValues: state.playerOrder.enumerated().map {
                ($0.element, $0.offset)
            })
            let spent = Dictionary(uniqueKeysWithValues: state.players.map { ($0.id, $0.spent) })
            state.playerOrder.sort {
                let left = spent[$0, default: 0]
                let right = spent[$1, default: 0]
                return left == right ? oldIndex[$0, default: 0] < oldIndex[$1, default: 0] : left < right
            }
            for index in state.players.indices { state.players[index].spent = 0 }
            state.turnsCompletedInRound = 0
            state.actionsRemaining = 0
            state.activePlayerID = state.playerOrder.first
            state.roundIncomeCursor = 0

            if state.era == .rail && state.roundNumber >= state.railRoundCapacity {
                return try completeRound(state: &state, catalog: catalog)
            }
            return try resolveIncomeFromCursor(state: &state, catalog: catalog)
        }

        static func validateForcedSale(
            _ intent: ForcedSaleIntent,
            actorID: PlayerID,
            state: GameState,
            catalog: VerifiedGameDataCatalog
        ) throws -> Int {
            guard case .forcedSale(let pending) = state.turnPhase else {
                throw ForcedSaleRuleError.noPendingSale
            }
            guard pending.playerID == actorID else { throw ForcedSaleRuleError.wrongPlayer }
            guard intent.placementIDs.isEmpty == false,
                  Set(intent.placementIDs).count == intent.placementIDs.count,
                  intent.placementIDs.allSatisfy(pending.eligiblePlacementIDs.contains)
            else { throw ForcedSaleRuleError.invalidSelection }

            var proceeds = 0
            for (index, placementID) in intent.placementIDs.enumerated() {
                guard let placement = state.boardIndustryPlacements.first(where: {
                    $0.placementID == placementID && $0.ownerID == actorID
                }), let value = liquidationValue(of: placement, catalog: catalog.catalog)
                else { throw ForcedSaleRuleError.invalidSelection }
                if index > 0, proceeds >= pending.shortfall {
                    throw ForcedSaleRuleError.invalidSelection
                }
                proceeds = try checkedAdd(proceeds, value)
            }
            let soldEverything = Set(intent.placementIDs) == Set(pending.eligiblePlacementIDs)
            guard proceeds >= pending.shortfall || soldEverything else {
                throw ForcedSaleRuleError.invalidSelection
            }
            return proceeds
        }

        static func applyForcedSale(
            _ intent: ForcedSaleIntent,
            actorID: PlayerID,
            state: inout GameState,
            catalog: VerifiedGameDataCatalog
        ) throws -> [GameTransitionEvent] {
            guard case .forcedSale(let pending) = state.turnPhase,
                  let playerIndex = state.players.firstIndex(where: { $0.id == actorID })
            else { throw ForcedSaleRuleError.noPendingSale }
            let proceeds = try validateForcedSale(intent, actorID: actorID, state: state, catalog: catalog)
            let selected = Set(intent.placementIDs)
            let removed = state.boardIndustryPlacements.filter { selected.contains($0.placementID) }
            for placement in removed {
                switch placement.tile.industryDefinitionID {
                case "coal-mine": SupplyRules.returnToPublicSupply(.coal, amount: placement.resourceCount, state: &state)
                case "iron-works": SupplyRules.returnToPublicSupply(.iron, amount: placement.resourceCount, state: &state)
                case "brewery": SupplyRules.returnToPublicSupply(.beer, amount: placement.resourceCount, state: &state)
                default: break
                }
            }
            state.boardIndustryPlacements.removeAll { selected.contains($0.placementID) }
            if proceeds >= pending.shortfall {
                state.players[playerIndex].cash = try checkedAdd(
                    state.players[playerIndex].cash, proceeds - pending.shortfall
                )
            } else {
                state.players[playerIndex].victoryPointDebt = try checkedAdd(
                    state.players[playerIndex].victoryPointDebt, pending.shortfall - proceeds
                )
            }
            state.turnPhase = .active
            return try resolveIncomeFromCursor(state: &state, catalog: catalog)
        }

        private static func resolveIncomeFromCursor(
            state: inout GameState,
            catalog: VerifiedGameDataCatalog
        ) throws -> [GameTransitionEvent] {
            var cursor = state.roundIncomeCursor ?? 0
            while cursor < state.playerOrder.count {
                let playerID = state.playerOrder[cursor]
                guard let playerIndex = state.players.firstIndex(where: { $0.id == playerID }),
                      let income = catalog.catalog.incomeTrack.entries.first(where: {
                          $0.position == state.players[playerIndex].incomePosition
                      })?.income
                else { throw ForcedSaleRuleError.invalidSelection }
                state.roundIncomeCursor = cursor + 1
                if income >= 0 {
                    state.players[playerIndex].cash = try checkedAdd(state.players[playerIndex].cash, income)
                } else {
                    let payment = -income
                    if state.players[playerIndex].cash >= payment {
                        state.players[playerIndex].cash -= payment
                    } else {
                        let shortfall = payment - state.players[playerIndex].cash
                        state.players[playerIndex].cash = 0
                        let eligible = state.boardIndustryPlacements
                            .filter { $0.ownerID == playerID }
                            .map(\.placementID)
                            .sorted()
                        if eligible.isEmpty {
                            state.players[playerIndex].victoryPointDebt = try checkedAdd(
                                state.players[playerIndex].victoryPointDebt, shortfall
                            )
                        } else {
                            let pending = PendingForcedSale(
                                playerID: playerID, shortfall: shortfall,
                                eligiblePlacementIDs: eligible
                            )
                            state.turnPhase = .forcedSale(pending)
                            state.activePlayerID = playerID
                            return [.forcedSaleRequired(pending)]
                        }
                    }
                }
                cursor += 1
            }
            return try completeRound(state: &state, catalog: catalog)
        }

        private static func completeRound(
            state: inout GameState,
            catalog: VerifiedGameDataCatalog
        ) throws -> [GameTransitionEvent] {
            let completedRound = state.roundNumber
            state.roundIncomeCursor = nil
            var events: [GameTransitionEvent] = [
                .roundEnded(.init(
                    completedRoundNumber: completedRound,
                    playerOrder: state.playerOrder
                )),
            ]
            let capacity = state.era == .canal ? state.canalRoundCapacity : state.railRoundCapacity
            if completedRound < capacity {
                state.roundNumber += 1
                state.actionsRemaining = actionsPerTurn(era: state.era, roundNumber: state.roundNumber)
                state.activePlayerID = state.playerOrder.first
                return events
            }
            let scoring = try ScoringRules.scoreEra(state.era, state: &state, catalog: catalog)
            events.append(scoring)
            if state.era == .canal {
                events.append(try ScoringRules.prepareRailEra(state: &state, catalog: catalog))
            } else {
                events.append(ScoringRules.resolveWinner(state: &state))
            }
            return events
        }

        static func liquidationValue(
            of placement: BoardIndustryPlacement,
            catalog: GameDataCatalog
        ) -> Int? {
            catalog.industries.first(where: { $0.id == placement.tile.industryDefinitionID })?
                .levels.first(where: { $0.level == placement.tile.level })?
                .buildCost.quotientAndRemainder(dividingBy: 2).quotient
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
