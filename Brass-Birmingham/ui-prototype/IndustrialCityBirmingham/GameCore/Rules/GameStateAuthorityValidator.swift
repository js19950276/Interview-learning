import Foundation

extension GameCore {
    nonisolated enum GameStateAuthorityValidator {
        static func isValid(
            _ state: GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog
        ) -> Bool {
            isValid(state, catalog: verifiedCatalog.catalog)
        }

        static func isValid(_ state: GameState, catalog: GameDataCatalog) -> Bool {
            let activeLocations = Dictionary(uniqueKeysWithValues: catalog.board.locations
                .filter { $0.playerCounts.contains(state.playerCount) }
                .map { ($0.id, $0) })
            let industryDefinitions = Dictionary(uniqueKeysWithValues: catalog.industries.map { ($0.id, $0) })
            let playerIDs = state.players.map(\.id)
            guard let canonicalTilesByOwner = canonicalIndustryTilesByOwner(
                state: state, catalog: catalog
            ),
                  let coalOnBoard = resourceCount("coal-mine", state: state),
                  let ironOnBoard = resourceCount("iron-works", state: state),
                  let beerOnBoard = resourceCount("brewery", state: state),
                  let coalTotal = resourceTotal(
                    board: coalOnBoard,
                    reserve: state.coalMarket.slots.filter(\.hasCube).count,
                    supply: state.publicSupply.coal
                  ),
                  let ironTotal = resourceTotal(
                    board: ironOnBoard,
                    reserve: state.ironMarket.slots.filter(\.hasCube).count,
                    supply: state.publicSupply.iron
                  ),
                  let beerTotal = resourceTotal(
                    board: beerOnBoard,
                    reserve: state.merchants.filter(\.hasBeer).count,
                    supply: state.publicSupply.beer
                  )
            else { return false }
            let physicalSlots = state.boardIndustryPlacements.map { "\($0.locationID)#\($0.slotIndex)" }
            let tileIDs = state.boardIndustryPlacements.map(\.tile.id)
            let allTileIDs = state.players.flatMap { player in
                player.industryStacks.flatMap(\.tiles).map(\.id)
            } + tileIDs
            let respectsCanalLocationLimit = state.era != .canal || state.players.allSatisfy { player in
                let ownedPlacements = state.boardIndustryPlacements.filter {
                    $0.ownerID == player.id
                }
                return Set(ownedPlacements.map(\.locationID)).count == ownedPlacements.count
            }
            let incomePositions = Set(catalog.incomeTrack.entries.map(\.position))
            guard state.authorityCompleteness == .complete,
                  state.resolvedGameVariant == .standard,
                  state.rulesetVersion == catalog.rulesetVersion,
                  (2...4).contains(state.playerCount),
                  state.players.count == state.playerCount,
                  state.roundNumber > 0,
                  state.roundNumber <= (state.era == .canal ? state.canalRoundCapacity : state.railRoundCapacity),
                  validTurnPhase(state, catalog: catalog),
                  validEraCardProgress(state),
                  validCards(state, catalog: catalog),
                  state.turnsCompletedInRound >= 0,
                  state.turnsCompletedInRound < state.playerCount,
                  state.actionNumber >= 0,
                  state.canalRoundCapacity == 12 - state.playerCount,
                  state.railRoundCapacity == 12 - state.playerCount,
                  state.authoritativeVersion.rawValue >= 0,
                  state.authoritativeVersion.rawValue < Int.max,
                  Set(playerIDs).count == playerIDs.count,
                  Set(state.playerOrder) == Set(playerIDs),
                  state.playerOrder.count == playerIDs.count,
                  state.activePlayerID.map(Set(playerIDs).contains) == true,
                  Set(state.players.map(\.color)).count == state.players.count,
                  state.players.allSatisfy({ player in
                      player.cash >= 0 && incomePositions.contains(player.incomePosition)
                          && player.victoryPoints >= 0 && player.victoryPointDebt >= 0 && player.spent >= 0
                          && (0...14).contains(player.linksRemaining)
                          && player.hand.count <= 8
                          && (state.era == .canal
                              ? player.privateBottomDiscard != nil
                              : player.privateBottomDiscard == nil)
                          && validIndustryStacks(player.industryStacks, catalog: catalog)
                          && player.industryStacks.flatMap(\.tiles).allSatisfy {
                              canonicalTilesByOwner[player.id]?[$0.id] == $0
                          }
                  }),
                  state.appliedResourceActionIDs != nil,
                  Set(state.appliedResourceActionIDs!).count == state.appliedResourceActionIDs!.count,
                  state.appliedResourceActionIDs!.allSatisfy({ $0.isEmpty == false }),
                  TopologyRules.validateTopologyState(state: state, board: catalog.board).isEmpty,
                  Set(state.boardIndustryPlacements.map(\.placementID)).count == state.boardIndustryPlacements.count,
                  Set(physicalSlots).count == physicalSlots.count,
                  Set(tileIDs).count == tileIDs.count,
                  Set(allTileIDs).count == allTileIDs.count,
                  respectsCanalLocationLimit,
                  state.boardIndustryPlacements.allSatisfy({ placement in
                      guard placement.placementID.isEmpty == false,
                            placement.tile.id.isEmpty == false,
                            placement.resourceCount >= 0,
                            placement.isFlipped == false || placement.resourceCount == 0,
                            state.players.contains(where: { $0.id == placement.ownerID }),
                            canonicalTilesByOwner[placement.ownerID]?[placement.tile.id]
                                == placement.tile,
                            let location = activeLocations[placement.locationID],
                            location.industrySlots.indices.contains(placement.slotIndex),
                            location.industrySlots[placement.slotIndex].contains(placement.tile.industryDefinitionID),
                            let definition = industryDefinitions[placement.tile.industryDefinitionID],
                            let level = definition.levels.first(where: { $0.level == placement.tile.level })
                      else { return false }
                      guard state.era == .canal ? level.canalEra : level.railEra else {
                          return false
                      }
                      guard placement.resourceCount > 0 else { return true }
                      let expected: IndustryDefinition.ResourceProduction.Resource
                      switch placement.tile.industryDefinitionID {
                      case "brewery": expected = .beer
                      case "coal-mine": expected = .coal
                      case "iron-works": expected = .iron
                      default: return false
                      }
                      guard let production = level.production, production.resource == expected else {
                          return false
                      }
                      let capacity = state.era == .canal ? production.canalCount : production.railCount
                      return placement.resourceCount <= capacity
                  }),
                  state.coalMarket.resource == .coal,
                  state.ironMarket.resource == .iron,
                  state.publicSupply.mayUseSubstitutes,
                  state.coalMarket.slots.map(\.price) == (1...7).flatMap({ Array(repeating: $0, count: 2) }),
                  state.ironMarket.slots.map(\.price) == ResourceMarket.officialIronPrices,
                  state.publicSupply.coal >= 0,
                  state.publicSupply.coal <= 30,
                  state.publicSupply.iron >= 0,
                  state.publicSupply.iron <= 18,
                  state.publicSupply.beer >= 0,
                  state.publicSupply.beer <= 15,
                  coalTotal >= 30,
                  ironTotal >= 18,
                  beerTotal >= 15
            else { return false }
            let activeMerchantSlots = catalog.board.merchantSlots.filter {
                $0.playerCounts.contains(state.playerCount) && activeLocations[$0.locationID] != nil
            }
            let slotsByID = Dictionary(uniqueKeysWithValues: activeMerchantSlots.map { ($0.id, $0) })
            let eligibleMerchants = catalog.merchants.filter { $0.playerCounts.contains(state.playerCount) }
            let merchantsByID = Dictionary(uniqueKeysWithValues: eligibleMerchants.map { ($0.id, $0) })
            let expectedMerchantCounts = Dictionary(uniqueKeysWithValues: eligibleMerchants.map {
                ($0.id, $0.count)
            })
            let actualMerchantCounts = state.merchants.reduce(into: [String: Int]()) {
                $0[$1.merchantDefinitionID, default: 0] += 1
            }
            let isUnstartedRailEra = state.era == .rail
                && state.roundNumber == 1
                && state.turnsCompletedInRound == 0
                && state.actionsRemaining == TurnRules.actionsPerTurn(era: .rail, roundNumber: 1)
            return state.merchants.count == activeMerchantSlots.count
                && Set(state.merchants.map(\.slotID)) == Set(activeMerchantSlots.map(\.id))
                && actualMerchantCounts == expectedMerchantCounts
                && state.merchants.allSatisfy { placement in
                    guard slotsByID[placement.slotID] != nil,
                          let merchant = merchantsByID[placement.merchantDefinitionID]
                    else { return false }
                    let isBlank = merchant.acceptedIndustryIDs.isEmpty
                    guard isBlank == false || placement.hasBeer == false else { return false }
                    return isUnstartedRailEra == false || isBlank || placement.hasBeer
                }
        }

        private static func validTurnPhase(
            _ state: GameState,
            catalog: GameDataCatalog
        ) -> Bool {
            switch state.turnPhase {
            case .active:
                guard state.playerOrder.indices.contains(state.turnsCompletedInRound) else {
                    return false
                }
                let actionBudget = TurnRules.actionsPerTurn(
                    era: state.era, roundNumber: state.roundNumber
                )
                return state.activePlayerID == state.playerOrder[state.turnsCompletedInRound]
                    && (1...actionBudget).contains(state.actionsRemaining)
                    && state.roundIncomeCursor == nil
                    && state.finalStandings == nil
            case .forcedSale(let pending):
                let ownedPlacementIDs = state.boardIndustryPlacements
                    .filter { $0.ownerID == pending.playerID }
                    .map(\.placementID)
                    .sorted()
                guard let cursor = state.roundIncomeCursor,
                      (1...state.playerCount).contains(cursor),
                      let debtor = state.players.first(where: { $0.id == pending.playerID }),
                      let income = catalog.incomeTrack.entries.first(where: {
                          $0.position == debtor.incomePosition
                      })?.income,
                      income < 0,
                      income != Int.min
                else { return false }
                return state.actionsRemaining == 0
                    && state.turnsCompletedInRound == 0
                    && state.activePlayerID == pending.playerID
                    && pending.playerID == state.playerOrder[cursor - 1]
                    && pending.shortfall > 0
                    && pending.shortfall <= -income
                    && debtor.cash == 0
                    && pending.eligiblePlacementIDs.isEmpty == false
                    && pending.eligiblePlacementIDs == ownedPlacementIDs
                    && state.finalStandings == nil
            case .ended:
                return state.actionsRemaining == 0
                    && state.turnsCompletedInRound == 0
                    && state.roundIncomeCursor == nil
                    && state.era == .rail
                    && state.roundNumber == state.railRoundCapacity
                    && validFinalStandings(state)
            }
        }

        private static func validFinalStandings(_ state: GameState) -> Bool {
            guard let standings = state.finalStandings,
                  standings.isEmpty == false,
                  standings.allSatisfy({ $0.isEmpty == false })
            else { return false }
            let ranked = standings.flatMap { $0 }
            return ranked.count == state.playerOrder.count
                && Set(ranked).count == ranked.count
                && Set(ranked) == Set(state.playerOrder)
                && standings == ScoringRules.standings(for: state)
        }

        private static func validCards(_ state: GameState, catalog: GameDataCatalog) -> Bool {
            let definitions = catalog.cards.filter { $0.playerCounts.contains(state.playerCount) }
            let definitionsByID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
            let expected = definitions.flatMap { definition in
                (1...definition.count).map {
                    CardInstance(id: "\(definition.id)-\($0)", definitionID: definition.id)
                }
            }
            let actual = state.players.flatMap(\.hand)
                + state.players.compactMap(\.privateBottomDiscard)
                + state.standardDrawDeck
                + state.wildLocationPool
                + state.wildIndustryPool
                + state.publicDiscard
            guard actual.count == expected.count,
                  Set(actual.map(\.id)).count == actual.count,
                  Set(actual) == Set(expected)
            else { return false }
            let isStandard: (CardInstance) -> Bool = { card in
                guard let kind = definitionsByID[card.definitionID]?.kind else { return false }
                return kind == .location || kind == .industry
            }
            guard actual.allSatisfy({ $0.id.isEmpty == false }),
                  state.standardDrawDeck.allSatisfy(isStandard),
                  state.publicDiscard.allSatisfy(isStandard),
                  state.players.compactMap(\.privateBottomDiscard).allSatisfy(isStandard),
                  state.wildLocationPool.allSatisfy({
                      definitionsByID[$0.definitionID]?.kind == .wildLocation
                  }),
                  state.wildIndustryPool.allSatisfy({
                      definitionsByID[$0.definitionID]?.kind == .wildIndustry
                  })
            else { return false }
            return requiresInitialCardSetupValidation(state) == false
                || validInitialCardSetup(state, catalog: catalog)
        }

        private static func requiresInitialCardSetupValidation(_ state: GameState) -> Bool {
            guard state.actionNumber == 0,
                  state.era == .canal,
                  state.roundNumber == 1,
                  state.actionsRemaining == 1,
                  state.turnsCompletedInRound == 0,
                  state.publicDiscard.isEmpty,
                  state.boardIndustryPlacements.isEmpty,
                  state.placedLinks.isEmpty,
                  state.finalStandings == nil,
                  case .active = state.turnPhase
            else { return false }
            return state.players.allSatisfy {
                $0.cash == 17
                    && $0.incomePosition == 10
                    && $0.victoryPoints == 0
                    && $0.victoryPointDebt == 0
                    && $0.spent == 0
                    && $0.linksRemaining == 14
            }
        }

        private static func validInitialCardSetup(
            _ state: GameState,
            catalog: GameDataCatalog
        ) -> Bool {
            guard state.era == .canal,
                  state.roundNumber == 1,
                  state.turnsCompletedInRound == 0,
                  state.actionsRemaining == 1,
                  state.publicDiscard.isEmpty,
                  state.players.allSatisfy({ $0.hand.count == 8 }),
                  Set(state.players.map(\.color))
                    == Set(PlayerColor.allCases.prefix(state.playerCount))
            else { return false }

            let standardDefinitions = catalog.cards.filter {
                $0.playerCounts.contains(state.playerCount)
                    && $0.kind != .wildLocation
                    && $0.kind != .wildIndustry
            }
            var deck = standardDefinitions.flatMap { definition in
                (1...definition.count).map {
                    CardInstance(id: "\(definition.id)-\($0)", definitionID: definition.id)
                }
            }
            var generator = SeededGenerator(seed: state.seed)
            generator.shuffle(&deck)

            let colorIndex = Dictionary(uniqueKeysWithValues: PlayerColor.allCases.enumerated().map {
                ($0.element, $0.offset)
            })
            var expectedOrder = state.players.sorted {
                colorIndex[$0.color, default: Int.max] < colorIndex[$1.color, default: Int.max]
            }.map(\.id)
            generator.shuffle(&expectedOrder)
            guard state.playerOrder == expectedOrder,
                  state.activePlayerID == expectedOrder.first,
                  deck.count >= state.playerCount * 9
            else { return false }

            var expectedHands = Dictionary(uniqueKeysWithValues: expectedOrder.map { ($0, [CardInstance]()) })
            for _ in 0..<8 {
                for playerID in expectedOrder {
                    expectedHands[playerID, default: []].append(deck.removeFirst())
                }
            }
            var expectedBottomCards: [PlayerID: CardInstance] = [:]
            for playerID in expectedOrder {
                expectedBottomCards[playerID] = deck.removeFirst()
            }
            let expectedWildLocations = catalog.cards.filter { $0.kind == .wildLocation }.flatMap {
                definition in (1...definition.count).map {
                    CardInstance(id: "\(definition.id)-\($0)", definitionID: definition.id)
                }
            }
            let expectedWildIndustries = catalog.cards.filter { $0.kind == .wildIndustry }.flatMap {
                definition in (1...definition.count).map {
                    CardInstance(id: "\(definition.id)-\($0)", definitionID: definition.id)
                }
            }
            return state.players.allSatisfy {
                $0.hand == expectedHands[$0.id]
                    && $0.privateBottomDiscard == expectedBottomCards[$0.id]
            }
                && state.standardDrawDeck == deck
                && state.wildLocationPool == expectedWildLocations
                && state.wildIndustryPool == expectedWildIndustries
        }

        private static func validEraCardProgress(_ state: GameState) -> Bool {
            let capacity = state.era == .canal
                ? state.canalRoundCapacity
                : state.railRoundCapacity
            guard (2...4).contains(state.playerCount),
                  capacity == 12 - state.playerCount,
                  (1...capacity).contains(state.roundNumber),
                  state.players.count == state.playerCount,
                  state.playerOrder.count == state.playerCount,
                  Set(state.players.map(\.id)).count == state.playerCount,
                  Set(state.playerOrder) == Set(state.players.map(\.id))
            else { return false }

            let actionSlots = state.era == .canal
                ? state.playerCount + (capacity - 1) * state.playerCount * 2
                : capacity * state.playerCount * 2
            let openingHandCount = state.playerCount * 8
            guard actionSlots >= openingHandCount else { return false }
            var expectedDeckCount = actionSlots - openingHandCount
            var expectedHands = Dictionary(uniqueKeysWithValues: state.players.map {
                ($0.id, 8)
            })

            func completeTurn(playerID: PlayerID, actionBudget: Int) -> Bool {
                guard let handCount = expectedHands[playerID], handCount >= actionBudget else {
                    return false
                }
                let afterActions = handCount - actionBudget
                let refillCount = min(8 - afterActions, expectedDeckCount)
                expectedHands[playerID] = afterActions + refillCount
                expectedDeckCount -= refillCount
                return true
            }

            if state.roundNumber > 1 {
                for round in 1..<state.roundNumber {
                    let actionBudget = TurnRules.actionsPerTurn(era: state.era, roundNumber: round)
                    for playerID in state.playerOrder {
                        guard completeTurn(playerID: playerID, actionBudget: actionBudget) else {
                            return false
                        }
                    }
                }
            }

            let currentActionBudget = TurnRules.actionsPerTurn(
                era: state.era, roundNumber: state.roundNumber
            )
            switch state.turnPhase {
            case .active:
                guard state.turnsCompletedInRound >= 0,
                      state.turnsCompletedInRound < state.playerCount,
                      (1...currentActionBudget).contains(state.actionsRemaining)
                else { return false }
                for seat in 0..<state.turnsCompletedInRound {
                    guard completeTurn(
                        playerID: state.playerOrder[seat], actionBudget: currentActionBudget
                    ) else { return false }
                }
                let activePlayerID = state.playerOrder[state.turnsCompletedInRound]
                let actionsTaken = currentActionBudget - state.actionsRemaining
                guard let activeHandCount = expectedHands[activePlayerID],
                      activeHandCount >= actionsTaken
                else { return false }
                expectedHands[activePlayerID] = activeHandCount - actionsTaken
            case .forcedSale:
                for playerID in state.playerOrder {
                    guard completeTurn(
                        playerID: playerID, actionBudget: currentActionBudget
                    ) else { return false }
                }
            case .ended:
                for playerID in state.playerOrder {
                    guard completeTurn(
                        playerID: playerID, actionBudget: currentActionBudget
                    ) else { return false }
                }
            }

            return state.standardDrawDeck.count == expectedDeckCount
                && state.players.allSatisfy { expectedHands[$0.id] == $0.hand.count }
        }

        private static func canonicalIndustryTilesByOwner(
            state: GameState,
            catalog: GameDataCatalog
        ) -> [PlayerID: [String: IndustryTile]]? {
            var result: [PlayerID: [String: IndustryTile]] = [:]
            for player in state.players {
                guard result[player.id] == nil else { return nil }
                var tiles: [String: IndustryTile] = [:]
                for definition in catalog.industries {
                    for level in definition.levels {
                        guard level.copiesPerColor > 0 else { return nil }
                        for copy in 1...level.copiesPerColor {
                            let tile = IndustryTile(
                                id: "\(player.color.rawValue)-\(definition.id)-\(level.level)-\(copy)",
                                industryDefinitionID: definition.id,
                                level: level.level
                            )
                            guard tiles.updateValue(tile, forKey: tile.id) == nil else {
                                return nil
                            }
                        }
                    }
                }
                result[player.id] = tiles
            }
            return result
        }

        private static func validIndustryStacks(
            _ stacks: [IndustryStack],
            catalog: GameDataCatalog
        ) -> Bool {
            guard stacks.count == catalog.industries.count,
                  Set(stacks.map(\.industryDefinitionID)) == Set(catalog.industries.map(\.id))
            else { return false }
            return stacks.allSatisfy { stack in
                let levels = Set(catalog.industries.first(where: {
                    $0.id == stack.industryDefinitionID
                })?.levels.map(\.level) ?? [])
                return stack.tiles.allSatisfy {
                    $0.industryDefinitionID == stack.industryDefinitionID
                        && $0.id.isEmpty == false
                        && levels.contains($0.level)
                } && stack.tiles.map(\.level) == stack.tiles.map(\.level).sorted()
            }
        }

        private static func resourceCount(_ industryID: String, state: GameState) -> Int? {
            var total = 0
            for placement in state.boardIndustryPlacements where placement.tile.industryDefinitionID == industryID {
                guard placement.resourceCount >= 0 else { return nil }
                let (next, overflow) = total.addingReportingOverflow(placement.resourceCount)
                guard overflow == false else { return nil }
                total = next
            }
            return total
        }

        private static func resourceTotal(board: Int, reserve: Int, supply: Int) -> Int? {
            let (partial, firstOverflow) = board.addingReportingOverflow(reserve)
            guard !firstOverflow else { return nil }
            let (total, secondOverflow) = partial.addingReportingOverflow(supply)
            return secondOverflow ? nil : total
        }
    }
}
