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
            let merchantDefinitions = Dictionary(uniqueKeysWithValues: catalog.catalog.merchants.map { ($0.id, $0) })
            let merchantLinkPoints = state.merchants.reduce(into: [String: Int]()) { totals, merchant in
                guard let slot = catalog.catalog.board.merchantSlots.first(where: { $0.id == merchant.slotID }),
                      let definition = merchantDefinitions[merchant.merchantDefinitionID] else { return }
                totals[slot.locationID, default: 0] += definition.linkPoints
            }

            for placement in flipped {
                guard let level = definitions[placement.tile.industryDefinitionID]?
                    .levels.first(where: { $0.level == placement.tile.level })
                else { throw ScoringRuleError.missingDefinition }
                industryPoints[placement.ownerID] = try checkedAdd(
                    industryPoints[placement.ownerID, default: 0], level.victoryPoints
                )
            }

            // 官方规则:每个时代结束时,自己的"所有"连线各计一次分。
            // 本函数只加 VP、不撤线:运河线留在地图上,待全员确认后的
            // prepareRailEra 退回主人;铁路线由终局调用方退回。两种线都不计第二次分。
            let eraLinks = state.placedLinks
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
                // 贸易商板块的连接图标同样计入相邻连接片（RULES.md §10.1）。
                let merchantPoints = adjacent.reduce(0) { $0 + (merchantLinkPoints[$1] ?? 0) }
                if merchantPoints > 0 {
                    linkPoints[link.ownerID] = try checkedAdd(linkPoints[link.ownerID, default: 0], merchantPoints)
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
            // 撤线不在本函数:见上方注释;removedRouteIDs 恒为空。
            return .eraScored(.init(
                era: era, awards: awards, removedRouteIDs: []
            ))
        }

        /// 已计分的连接片全部撤下,退回各自主人(余量+1);不加 VP、不发事件。
        /// 缺主人的孤儿线抛 missingDefinition 且一条余量都不改。
        static func returnScoredLinks(state: inout GameState) throws {
            var ownerIndexes: [Int] = []
            ownerIndexes.reserveCapacity(state.placedLinks.count)
            for link in state.placedLinks {
                guard let index = state.players.firstIndex(where: { $0.id == link.ownerID }) else {
                    throw ScoringRuleError.missingDefinition
                }
                ownerIndexes.append(index)
            }
            for index in ownerIndexes {
                state.players[index].linksRemaining += 1
            }
            state.placedLinks.removeAll()
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
            // 官方规则(End of Canal Era 步骤 3):一级板块从板上移除并退回游戏盒,
            // 不回玩家垫板、铁路时代不可重建(垫板上未建的一级板块不受影响)。

            // 官方规则(End of Era 步骤 1):连接片计分后全部从板上撤下,
            // 连线片(双面:运河面/铁路面)退回各自主人,铁路时代可再次使用。
            try returnScoredLinks(state: &state)

            let merchantDefinitions = Dictionary(uniqueKeysWithValues: catalog.catalog.merchants.map {
                ($0.id, $0)
            })
            for index in state.merchants.indices {
                guard state.merchants[index].hasBeer == false,
                      merchantDefinitions[state.merchants[index].merchantDefinitionID]?
                        .acceptedIndustryIDs.isEmpty == false
                else { continue }
                state.merchants[index].hasBeer = true
                // 无条件扣减：库存不足时以替代物顶上，保持资源守恒（RULES.md §5.1.9）。
                state.publicSupply.beer -= 1
            }

            let legalDefinitions = Set(catalog.catalog.cards.filter {
                $0.playerCounts.contains(state.playerCount)
                    && $0.kind != .wildLocation && $0.kind != .wildIndustry
            }.map(\.id))
            // 手牌中的万能牌是可复用组件:回到各自奖池供铁路时代再次侦察,
            // 不进入重组后的铁路牌库(官方规则:铁路抽牌堆不含万能牌)。
            let cardKinds = Dictionary(uniqueKeysWithValues: catalog.catalog.cards.map { ($0.id, $0.kind) })
            for index in state.players.indices {
                var retained: [CardInstance] = []
                for card in state.players[index].hand {
                    switch cardKinds[card.definitionID] {
                    case .wildLocation: state.wildLocationPool.append(card)
                    case .wildIndustry: state.wildIndustryPool.append(card)
                    default: retained.append(card)
                    }
                }
                state.players[index].hand = retained
            }
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
                // 债务在发生时已即时扣减(上限为当期 VP),排名直接比较 VP。
                let leftVP = left.victoryPoints
                let rightVP = right.victoryPoints
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
                   player.victoryPoints == last.victoryPoints,
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
            state.turnsCompletedInRound = 0
            state.finalStandings = standings
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
