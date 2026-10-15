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
            guard let coalOnBoard = resourceCount("coal-mine", state: state),
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
            let incomePositions = Set(catalog.incomeTrack.entries.map(\.position))
            guard state.authorityCompleteness == .complete,
                  state.rulesetVersion == catalog.rulesetVersion,
                  (2...4).contains(state.playerCount),
                  state.players.count == state.playerCount,
                  state.roundNumber > 0,
                  state.roundNumber <= (state.era == .canal ? state.canalRoundCapacity : state.railRoundCapacity),
                  validTurnPhase(state),
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
                          && (state.era == .canal || player.privateBottomDiscard == nil)
                          && validIndustryStacks(player.industryStacks, catalog: catalog)
                  }),
                  state.appliedResourceActionIDs != nil,
                  Set(state.appliedResourceActionIDs!).count == state.appliedResourceActionIDs!.count,
                  state.appliedResourceActionIDs!.allSatisfy({ $0.isEmpty == false }),
                  TopologyRules.validateTopologyState(state: state, board: catalog.board).isEmpty,
                  Set(state.boardIndustryPlacements.map(\.placementID)).count == state.boardIndustryPlacements.count,
                  Set(physicalSlots).count == physicalSlots.count,
                  Set(tileIDs).count == tileIDs.count,
                  Set(allTileIDs).count == allTileIDs.count,
                  state.boardIndustryPlacements.allSatisfy({ placement in
                      guard placement.placementID.isEmpty == false,
                            placement.tile.id.isEmpty == false,
                            placement.resourceCount >= 0,
                            placement.isFlipped == false || placement.resourceCount == 0,
                            state.players.contains(where: { $0.id == placement.ownerID }),
                            let location = activeLocations[placement.locationID],
                            location.industrySlots.indices.contains(placement.slotIndex),
                            location.industrySlots[placement.slotIndex].contains(placement.tile.industryDefinitionID),
                            let definition = industryDefinitions[placement.tile.industryDefinitionID],
                            let level = definition.levels.first(where: { $0.level == placement.tile.level })
                      else { return false }
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
                  // 官方市场:煤 14 可放格 = £1×2 + £2~£7×2(开局留空一个 £1),
                  // 铁 10 可放格 = £1×2 + £2~£5×2(开局两个 £1 空置);
                  // £8/£6 是无限供应标记价,不是格子。
                  state.coalMarket.slots.map(\.price) == (1...7).flatMap({ Array(repeating: $0, count: 2) }),
                  state.ironMarket.slots.map(\.price) == [1, 1] + (2...5).flatMap({ Array(repeating: $0, count: 2) }),
                  // 供应台账允许为负：负值 = 已投入使用的替代物数量（RULES.md §5.1.9），
                  // 下界为实体总数；守恒检查（coalTotal/ironTotal/beerTotal）继续拦截真实损坏。
                  state.publicSupply.coal >= -30,
                  state.publicSupply.coal <= 30,
                  state.publicSupply.iron >= -18,
                  state.publicSupply.iron <= 18,
                  state.publicSupply.beer >= -15,
                  state.publicSupply.beer <= 15,
                  coalTotal >= 30,
                  ironTotal >= 18,
                  beerTotal >= 15
            else { return false }
            if state.matchMode == .shortCanal {
                // 短局只打运河时代:不进铁路,也不进 eraIntermission(终局直接 .ended)。
                guard state.era == .canal else { return false }
                if case .eraIntermission = state.turnPhase { return false }
            }
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
            let merchantsOK = state.merchants.count == activeMerchantSlots.count
                && Set(state.merchants.map(\.slotID)) == Set(activeMerchantSlots.map(\.id))
                && actualMerchantCounts == expectedMerchantCounts
                && state.merchants.allSatisfy { placement in
                    guard slotsByID[placement.slotID] != nil,
                          let merchant = merchantsByID[placement.merchantDefinitionID]
                    else { return false }
                    return merchant.acceptedIndustryIDs.isEmpty == false || placement.hasBeer == false
                }
            return merchantsOK
        }

        private static func validTurnPhase(_ state: GameState) -> Bool {
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
            case .awaitingTurnEndConfirmation:
                // 待确认:行动玩家不变、行动额度已用尽、尚未补牌过轮。
                guard state.playerOrder.indices.contains(state.turnsCompletedInRound) else {
                    return false
                }
                return state.activePlayerID == state.playerOrder[state.turnsCompletedInRound]
                    && state.actionsRemaining == 0
                    && state.roundIncomeCursor == nil
            case .forcedSale(let pending):
                let ownedPlacementIDs = state.boardIndustryPlacements
                    .filter { $0.ownerID == pending.playerID }
                    .map(\.placementID)
                    .sorted()
                guard let cursor = state.roundIncomeCursor,
                      (1...state.playerCount).contains(cursor)
                else { return false }
                return state.actionsRemaining == 0
                    && state.turnsCompletedInRound == 0
                    && state.activePlayerID == pending.playerID
                    && pending.playerID == state.playerOrder[cursor - 1]
                    && pending.shortfall > 0
                    && pending.eligiblePlacementIDs.isEmpty == false
                    && pending.eligiblePlacementIDs == ownedPlacementIDs
            case .eraIntermission(let intermission):
                // 结算暂停:处于运河最后一轮收尾,等待全员确认。
                guard intermission.settledEra == .canal, state.era == .canal,
                      state.roundNumber == state.canalRoundCapacity,
                      Set(intermission.confirmedPlayerIDs).count == intermission.confirmedPlayerIDs.count,
                      intermission.confirmedPlayerIDs.allSatisfy({ confirmed in
                          state.players.contains(where: { $0.id == confirmed })
                      }),
                      intermission.awards.count == state.players.count,
                      Set(intermission.awards.map(\.playerID)) == Set(state.players.map(\.id))
                else { return false }
                return state.actionsRemaining == 0
                    && state.turnsCompletedInRound == 0
                    && state.roundIncomeCursor == nil
            case .ended:
                return state.actionsRemaining == 0
                    && state.turnsCompletedInRound == 0
                    && state.roundIncomeCursor == nil
            }
        }

        private static func validCards(_ state: GameState, catalog: GameDataCatalog) -> Bool {
            let definitions = catalog.cards.filter { $0.playerCounts.contains(state.playerCount) }
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
            return actual.allSatisfy { $0.id.isEmpty == false }
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
