import Foundation

extension GameCore {
    nonisolated enum GameRulesEngine {
        nonisolated struct Authority: Sendable {
            init() {}
        }
        private static let authority = Authority()
        nonisolated enum ReplayError: Error, Equatable, Sendable {
            case invalidEvent
        }
        nonisolated enum GameRulesInternalError: Error, Equatable, Sendable {
            case arithmeticOverflow
            case invalidAuthorityState
            case invariantViolation
        }
        nonisolated enum PassRuleError: Error, Equatable, Sendable {
            case notActivePlayer
            case missingDiscardCard
            case invalidState
        }

        static func replay(
            _ event: AuthoritativeGameEvent,
            expectedRoomID: RoomID,
            to state: inout GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog
        ) throws {
            let (expectedVersion, versionOverflow) = event.previousVersion.rawValue.addingReportingOverflow(1)
            let (expectedAction, actionOverflow) = state.actionNumber.addingReportingOverflow(1)
            guard !versionOverflow, !actionOverflow,
                  event.roomID == expectedRoomID,
                  event.previousVersion == state.authoritativeVersion,
                  event.version.rawValue == expectedVersion,
                  event.actionNumber == expectedAction,
                  event.actor == state.activePlayerID
            else { throw ReplayError.invalidEvent }
            var candidate = state
            let reproduced: AuthoritativeGameEvent
            do {
                switch event.payload {
                case .passed(let discardedCardID):
                    let target = try SimpleActionRules.validatePass(
                        .init(cardID: discardedCardID), actorID: event.actor,
                        state: candidate, catalog: verifiedCatalog
                    )
                    reproduced = try resolvePass(
                        target, roomID: expectedRoomID, state: &candidate,
                        catalog: verifiedCatalog
                    )
                case .built(let intent, _, _):
                    let target = try BuildRules.validate(
                        intent, actorID: event.actor, state: candidate, catalog: verifiedCatalog
                    )
                    reproduced = try resolveBuild(
                        target, roomID: expectedRoomID, state: &candidate, catalog: verifiedCatalog
                    )
                case .networkBuilt(let intent, _, _):
                    let target = try NetworkRules.validate(
                        intent, actorID: event.actor, state: candidate, catalog: verifiedCatalog
                    )
                    reproduced = try resolveNetwork(
                        target, roomID: expectedRoomID, state: &candidate, catalog: verifiedCatalog
                    )
                case .developed(let intent, _, _):
                    let target = try DevelopRules.validate(
                        intent, actorID: event.actor, state: candidate, catalog: verifiedCatalog
                    )
                    reproduced = try resolveDevelop(
                        target, roomID: expectedRoomID, state: &candidate, catalog: verifiedCatalog
                    )
                case .sold(let intent, _, _):
                    let target = try SellRules.validate(
                        intent, actorID: event.actor, state: candidate, catalog: verifiedCatalog
                    )
                    reproduced = try resolveSell(
                        target, roomID: expectedRoomID, state: &candidate, catalog: verifiedCatalog
                    )
                case .loanTaken(let intent, _, _):
                    let target = try SimpleActionRules.validateLoan(
                        intent, actorID: event.actor, state: candidate, catalog: verifiedCatalog
                    )
                    reproduced = try resolveLoan(
                        target, roomID: expectedRoomID, state: &candidate, catalog: verifiedCatalog
                    )
                case .scouted(let details):
                    guard let details else { throw ReplayError.invalidEvent }
                    let target = try SimpleActionRules.validateScout(
                        details.intent, actorID: event.actor,
                        state: candidate, catalog: verifiedCatalog
                    )
                    reproduced = try resolveScout(
                        target, roomID: expectedRoomID, state: &candidate, catalog: verifiedCatalog
                    )
                case .forcedSaleResolved(let intent):
                    reproduced = try resolveForcedSale(
                        intent, actorID: event.actor, roomID: expectedRoomID,
                        state: &candidate, catalog: verifiedCatalog
                    )
                }
            } catch {
                throw ReplayError.invalidEvent
            }
            guard reproduced == event else { throw ReplayError.invalidEvent }
            state = candidate
        }

        static func resolvePass(
            _ target: ValidatedPassTarget,
            roomID: RoomID,
            state: inout GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog
        ) throws -> AuthoritativeGameEvent {
            guard state.activePlayerID == target.actorID,
                  let playerIndex = state.players.firstIndex(where: { $0.id == target.actorID })
            else { throw PassRuleError.notActivePlayer }
            guard let cardIndex = state.players[playerIndex].hand.firstIndex(where: {
                $0 == target.card
            }) else { throw PassRuleError.missingDiscardCard }
            guard state.players.isEmpty == false else { throw GameRulesInternalError.invariantViolation }

            let previousVersion = state.authoritativeVersion
            var candidate = state
            let discardedCard = candidate.players[playerIndex].hand.remove(at: cardIndex)
            discard(discardedCard, from: &candidate, catalog: verifiedCatalog.catalog)
            let transitions = try finishAction(
                actorIndex: playerIndex, previousVersion: previousVersion,
                state: &candidate, catalog: verifiedCatalog
            )
            let event = AuthoritativeGameEvent(
                roomID: roomID,
                actor: target.actorID,
                previousVersion: previousVersion,
                version: candidate.authoritativeVersion,
                actionNumber: candidate.actionNumber,
                payload: .passed(discardedCardID: target.intent.cardID),
                transitions: transitions
            )
            state = candidate
            return event
        }

        static func resolveBuild(
            _ target: ValidatedBuildTarget,
            roomID: RoomID,
            state: inout GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog
        ) throws -> AuthoritativeGameEvent {
            let previous = state.authoritativeVersion
            var candidate = state
            guard candidate.activePlayerID == target.actorID,
                  let playerIndex = candidate.players.firstIndex(where: { $0.id == target.actorID }),
                  let cardIndex = candidate.players[playerIndex].hand.firstIndex(where: { $0.id == target.card.id }),
                  candidate.players[playerIndex].cash >= target.buildCost
            else { throw BuildRuleError.notActivePlayer }

            var resourceEffects = try ResourceRules.consumeResources(
                for: target, roomID: roomID, state: &candidate, catalog: verifiedCatalog,
                authority: authority
            )
            candidate.players[playerIndex].cash = try checkedSubtract(
                candidate.players[playerIndex].cash, target.buildCost
            )
            candidate.players[playerIndex].spent = try checkedAdd(
                candidate.players[playerIndex].spent, target.buildCost
            )
            candidate.players[playerIndex].spent = try checkedAdd(
                candidate.players[playerIndex].spent, try marketCost(in: resourceEffects)
            )

            if let placementID = target.overbuildPlacementID,
               let oldIndex = candidate.boardIndustryPlacements.firstIndex(where: { $0.placementID == placementID }) {
                let old = candidate.boardIndustryPlacements.remove(at: oldIndex)
                returnResourcesFromOverbuild(old, state: &candidate)
            }
            guard let stackIndex = candidate.players[playerIndex].industryStacks.firstIndex(where: {
                $0.industryDefinitionID == target.intent.industryDefinitionID
            }), candidate.players[playerIndex].industryStacks[stackIndex].tiles.first == target.tile
            else { throw BuildRuleError.wrongTile }
            candidate.players[playerIndex].industryStacks[stackIndex].tiles.removeFirst()

            let card = candidate.players[playerIndex].hand.remove(at: cardIndex)
            discard(card, from: &candidate, catalog: verifiedCatalog.catalog)
            let placement = BoardIndustryPlacement(
                locationID: target.intent.locationID,
                slotIndex: target.intent.slotIndex,
                ownerID: target.actorID,
                tile: target.tile,
                resourceCount: productionCount(for: target.tile, era: candidate.era, catalog: verifiedCatalog.catalog),
                marketDeliveryResolved: !["coal-mine", "iron-works"].contains(target.tile.industryDefinitionID)
            )
            takeProductionFromSupply(placement, state: &candidate)
            candidate.boardIndustryPlacements.append(placement)
            if ["coal-mine", "iron-works"].contains(target.tile.industryDefinitionID) {
                resourceEffects += try ResourceRules.settleBuiltIndustryMarket(
                    for: target, placementID: placement.placementID,
                    state: &candidate, catalog: verifiedCatalog, authority: authority
                )
            }
            guard let settledPlacement = candidate.boardIndustryPlacements.first(where: {
                $0.placementID == placement.placementID
            }) else { throw ResourceRuleError.unknownPlacement }
            let transitions = try finishAction(
                actorIndex: playerIndex, previousVersion: previous,
                state: &candidate, catalog: verifiedCatalog
            )
            state = candidate
            return AuthoritativeGameEvent(
                roomID: roomID, actor: target.actorID, previousVersion: previous,
                version: candidate.authoritativeVersion, actionNumber: candidate.actionNumber,
                payload: .built(intent: target.intent, placement: settledPlacement, resourceEffects: resourceEffects),
                transitions: transitions
            )
        }

        static func resolveNetwork(
            _ target: ValidatedNetworkTarget,
            roomID: RoomID,
            state: inout GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog
        ) throws -> AuthoritativeGameEvent {
            let previous = state.authoritativeVersion
            var candidate = state
            guard candidate.activePlayerID == target.actorID,
                  let playerIndex = candidate.players.firstIndex(where: { $0.id == target.actorID }),
                  let cardIndex = candidate.players[playerIndex].hand.firstIndex(where: { $0.id == target.card.id }),
                  candidate.players[playerIndex].cash >= target.cashCost,
                  candidate.players[playerIndex].linksRemaining >= target.intent.routeIDs.count
            else { throw NetworkRuleError.notActivePlayer }
            let links = target.intent.routeIDs.map {
                PlacedLink(routeID: $0, ownerID: target.actorID, era: candidate.era)
            }
            var effects: [ResourceEffect] = []
            var consumedRequestCount = 0
            if candidate.era == .rail {
                for link in links {
                    guard target.resourceRequests.indices.contains(consumedRequestCount),
                          target.resourceRequests[consumedRequestCount].resource == .coal
                    else { throw NetworkRuleError.illegalCoal }
                    candidate.placedLinks.append(link)
                    effects.append(contentsOf: try ResourceRules.consumeValidatedRequests(
                        [target.resourceRequests[consumedRequestCount]],
                        actorID: target.actorID, state: &candidate, catalog: verifiedCatalog
                    ))
                    consumedRequestCount += 1
                }
            } else {
                candidate.placedLinks.append(contentsOf: links)
            }
            effects.append(contentsOf: try ResourceRules.consumeValidatedRequests(
                Array(target.resourceRequests.dropFirst(consumedRequestCount)),
                actorID: target.actorID, state: &candidate, catalog: verifiedCatalog
            ))
            candidate.players[playerIndex].cash = try checkedSubtract(
                candidate.players[playerIndex].cash, target.cashCost
            )
            let networkCost = try checkedAdd(target.cashCost, try marketCost(in: effects))
            candidate.players[playerIndex].spent = try checkedAdd(
                candidate.players[playerIndex].spent, networkCost
            )
            candidate.players[playerIndex].linksRemaining = try checkedSubtract(
                candidate.players[playerIndex].linksRemaining, links.count
            )
            let card = candidate.players[playerIndex].hand.remove(at: cardIndex)
            discard(card, from: &candidate, catalog: verifiedCatalog.catalog)
            let transitions = try finishAction(
                actorIndex: playerIndex, previousVersion: previous,
                state: &candidate, catalog: verifiedCatalog
            )
            state = candidate
            return AuthoritativeGameEvent(
                roomID: roomID, actor: target.actorID, previousVersion: previous,
                version: candidate.authoritativeVersion, actionNumber: candidate.actionNumber,
                payload: .networkBuilt(intent: target.intent, links: links, resourceEffects: effects),
                transitions: transitions
            )
        }

        static func resolveDevelop(
            _ target: ValidatedDevelopTarget,
            roomID: RoomID,
            state: inout GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog
        ) throws -> AuthoritativeGameEvent {
            let previous = state.authoritativeVersion
            var candidate = state
            guard let playerIndex = candidate.players.firstIndex(where: { $0.id == target.actorID }),
                  let cardIndex = candidate.players[playerIndex].hand.firstIndex(where: { $0 == target.card })
            else { throw DevelopRuleError.missingCard }
            let effects = try DevelopRules.apply(target, state: &candidate, catalog: verifiedCatalog)
            candidate.players[playerIndex].spent = try checkedAdd(
                candidate.players[playerIndex].spent, try marketCost(in: effects)
            )
            let card = candidate.players[playerIndex].hand.remove(at: cardIndex)
            discard(card, from: &candidate, catalog: verifiedCatalog.catalog)
            let transitions = try finishAction(
                actorIndex: playerIndex, previousVersion: previous,
                state: &candidate, catalog: verifiedCatalog
            )
            let event = AuthoritativeGameEvent(
                roomID: roomID, actor: target.actorID, previousVersion: previous,
                version: candidate.authoritativeVersion, actionNumber: candidate.actionNumber,
                payload: .developed(intent: target.intent, tiles: target.tiles, resourceEffects: effects),
                transitions: transitions
            )
            state = candidate
            return event
        }

        static func resolveSell(
            _ target: ValidatedSellTarget,
            roomID: RoomID,
            state: inout GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog
        ) throws -> AuthoritativeGameEvent {
            let previous = state.authoritativeVersion
            var candidate = state
            guard let playerIndex = candidate.players.firstIndex(where: { $0.id == target.actorID }),
                  let cardIndex = candidate.players[playerIndex].hand.firstIndex(where: { $0 == target.card })
            else { throw SellRuleError.missingCard }
            let effects = try SellRules.apply(target, state: &candidate, catalog: verifiedCatalog)
            let card = candidate.players[playerIndex].hand.remove(at: cardIndex)
            discard(card, from: &candidate, catalog: verifiedCatalog.catalog)
            let transitions = try finishAction(
                actorIndex: playerIndex, previousVersion: previous,
                state: &candidate, catalog: verifiedCatalog
            )
            let event = AuthoritativeGameEvent(
                roomID: roomID, actor: target.actorID, previousVersion: previous,
                version: candidate.authoritativeVersion, actionNumber: candidate.actionNumber,
                payload: .sold(
                    intent: target.intent,
                    placementIDs: target.sales.map(\.placement.placementID),
                    resourceEffects: effects
                ),
                transitions: transitions
            )
            state = candidate
            return event
        }

        static func resolveLoan(
            _ target: ValidatedLoanTarget,
            roomID: RoomID,
            state: inout GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog
        ) throws -> AuthoritativeGameEvent {
            let previous = state.authoritativeVersion
            var candidate = state
            guard candidate.activePlayerID == target.actorID,
                  let playerIndex = candidate.players.firstIndex(where: { $0.id == target.actorID }),
                  let cardIndex = candidate.players[playerIndex].hand.firstIndex(where: { $0 == target.card })
            else { throw SimpleActionRuleError.missingCard }
            let oldIncome = candidate.players[playerIndex].incomePosition
            let (cash, overflow) = candidate.players[playerIndex].cash.addingReportingOverflow(30)
            guard overflow == false else { throw GameRulesInternalError.arithmeticOverflow }
            candidate.players[playerIndex].cash = cash
            candidate.players[playerIndex].incomePosition = target.incomePosition
            let card = candidate.players[playerIndex].hand.remove(at: cardIndex)
            discard(card, from: &candidate, catalog: verifiedCatalog.catalog)
            let transitions = try finishAction(
                actorIndex: playerIndex, previousVersion: previous,
                state: &candidate, catalog: verifiedCatalog
            )
            let event = AuthoritativeGameEvent(
                roomID: roomID, actor: target.actorID, previousVersion: previous,
                version: candidate.authoritativeVersion, actionNumber: candidate.actionNumber,
                payload: .loanTaken(
                    intent: target.intent,
                    previousIncomePosition: oldIncome,
                    incomePosition: target.incomePosition
                ),
                transitions: transitions
            )
            state = candidate
            return event
        }

        static func resolveScout(
            _ target: ValidatedScoutTarget,
            roomID: RoomID,
            state: inout GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog
        ) throws -> AuthoritativeGameEvent {
            let previous = state.authoritativeVersion
            var candidate = state
            guard candidate.activePlayerID == target.actorID,
                  let playerIndex = candidate.players.firstIndex(where: { $0.id == target.actorID }),
                  candidate.wildLocationPool.last == target.wildLocationCard,
                  candidate.wildIndustryPool.last == target.wildIndustryCard
            else { throw SimpleActionRuleError.wildPoolEmpty }
            for card in target.cards {
                guard let index = candidate.players[playerIndex].hand.firstIndex(of: card) else {
                    throw SimpleActionRuleError.missingCard
                }
                candidate.publicDiscard.append(candidate.players[playerIndex].hand.remove(at: index))
            }
            candidate.wildLocationPool.removeLast()
            candidate.wildIndustryPool.removeLast()
            candidate.players[playerIndex].hand.append(target.wildLocationCard)
            candidate.players[playerIndex].hand.append(target.wildIndustryCard)
            let transitions = try finishAction(
                actorIndex: playerIndex, previousVersion: previous,
                state: &candidate, catalog: verifiedCatalog
            )
            let event = AuthoritativeGameEvent(
                roomID: roomID, actor: target.actorID, previousVersion: previous,
                version: candidate.authoritativeVersion, actionNumber: candidate.actionNumber,
                payload: .scouted(.init(
                    intent: target.intent, discardedCards: target.cards,
                    wildLocationCard: target.wildLocationCard,
                    wildIndustryCard: target.wildIndustryCard
                )),
                transitions: transitions
            )
            state = candidate
            return event
        }

        static func legalResourceSources(
            resource: ResourceKind, consumerLocationID: String, context: ResourceContext,
            state: GameState, catalog: VerifiedGameDataCatalog
        ) -> [ResourceSource] {
            ResourceRules.legalResourceSources(
                resource: resource, consumerLocationID: consumerLocationID,
                context: context, state: state, catalog: catalog
            )
        }

        static func resolveRoundEnd(
            state: inout GameState,
            catalog: VerifiedGameDataCatalog
        ) throws -> [GameTransitionEvent] {
            var candidate = state
            let events = try TurnRules.resolveRoundEnd(state: &candidate, catalog: catalog)
            guard events.isEmpty == false else {
                throw GameRulesInternalError.invariantViolation
            }
            state = candidate
            return events
        }

        static func scoreEra(
            _ era: Era,
            state: inout GameState,
            catalog: VerifiedGameDataCatalog
        ) throws -> GameTransitionEvent {
            var candidate = state
            let event = try ScoringRules.scoreEra(era, state: &candidate, catalog: catalog)
            state = candidate
            return event
        }

        static func prepareRailEra(
            state: inout GameState,
            catalog: VerifiedGameDataCatalog
        ) throws -> GameTransitionEvent {
            var candidate = state
            let event = try ScoringRules.prepareRailEra(state: &candidate, catalog: catalog)
            state = candidate
            return event
        }

        static func resolveWinner(state: inout GameState) throws -> GameTransitionEvent {
            var candidate = state
            let event = ScoringRules.resolveWinner(state: &candidate)
            state = candidate
            return event
        }

        static func resolveForcedSale(
            _ intent: ForcedSaleIntent,
            actorID: PlayerID,
            roomID: RoomID,
            state: inout GameState,
            catalog: VerifiedGameDataCatalog
        ) throws -> AuthoritativeGameEvent {
            let previous = state.authoritativeVersion
            var candidate = state
            let transitions = try TurnRules.applyForcedSale(
                intent, actorID: actorID, state: &candidate, catalog: catalog
            )
            candidate.actionNumber = try checkedAdd(candidate.actionNumber, 1)
            candidate.authoritativeVersion = .init(rawValue: try checkedAdd(previous.rawValue, 1))
            let event = AuthoritativeGameEvent(
                roomID: roomID, actor: actorID, previousVersion: previous,
                version: candidate.authoritativeVersion,
                actionNumber: candidate.actionNumber,
                payload: .forcedSaleResolved(intent), transitions: transitions
            )
            state = candidate
            return event
        }

        static func replay(
            _ events: [GameTransitionEvent],
            to state: inout GameState,
            catalog: VerifiedGameDataCatalog
        ) throws {
            var candidate = state
            let reproduced: [GameTransitionEvent]
            do {
                reproduced = try TurnRules.resolveRoundEnd(state: &candidate, catalog: catalog)
            } catch {
                throw ReplayError.invalidEvent
            }
            guard reproduced.count == events.count,
                  zip(reproduced, events).allSatisfy(==)
            else { throw ReplayError.invalidEvent }
            state = candidate
        }

        static func advanceAction(
            actorIndex: Int,
            state: inout GameState,
            catalog: VerifiedGameDataCatalog
        ) throws -> [GameTransitionEvent] {
            let actorID = state.players[actorIndex].id
            state.actionNumber = try checkedAdd(state.actionNumber, 1)
            state.actionsRemaining = max(0, try checkedSubtract(state.actionsRemaining, 1))
            guard state.actionsRemaining == 0 else { return [] }
            TurnRules.refillHand(playerID: actorID, state: &state)
            state.turnsCompletedInRound = try checkedAdd(state.turnsCompletedInRound, 1)
            if state.turnsCompletedInRound == state.playerCount {
                return try TurnRules.resolveRoundEnd(state: &state, catalog: catalog)
            }
            state.activePlayerID = state.playerOrder[state.turnsCompletedInRound]
            state.actionsRemaining = TurnRules.actionsPerTurn(
                era: state.era, roundNumber: state.roundNumber
            )
            return []
        }

        /// Fixture-only compatibility path. Complete authoritative games always use
        /// the catalog-aware overload so round income and era transitions cannot be skipped.
        static func advanceAction(actorIndex: Int, state: inout GameState) throws {
            state.actionNumber = try checkedAdd(state.actionNumber, 1)
            state.actionsRemaining = max(0, try checkedSubtract(state.actionsRemaining, 1))
            guard state.actionsRemaining == 0 else { return }
            state.turnsCompletedInRound = try checkedAdd(state.turnsCompletedInRound, 1)
            if state.turnsCompletedInRound == state.playerCount {
                state.roundNumber = try checkedAdd(state.roundNumber, 1)
                state.turnsCompletedInRound = 0
            }
            state.activePlayerID = state.players[(actorIndex + 1) % state.players.count].id
            state.actionsRemaining = TurnRules.actionsPerTurn(
                era: state.era, roundNumber: state.roundNumber
            )
        }

        private static func marketCost(in effects: [ResourceEffect]) throws -> Int {
            try effects.reduce(0) { total, effect in
                if case .marketCostPaid(_, _, let amount) = effect {
                    return try checkedAdd(total, amount)
                }
                return total
            }
        }

        private static func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
            let (value, overflow) = lhs.addingReportingOverflow(rhs)
            guard !overflow else { throw GameRulesInternalError.arithmeticOverflow }
            return value
        }

        private static func checkedSubtract(_ lhs: Int, _ rhs: Int) throws -> Int {
            let (value, overflow) = lhs.subtractingReportingOverflow(rhs)
            guard !overflow else { throw GameRulesInternalError.arithmeticOverflow }
            return value
        }

        private static func finishAction(
            actorIndex: Int,
            previousVersion: AuthoritativeVersion,
            state: inout GameState,
            catalog: VerifiedGameDataCatalog
        ) throws -> [GameTransitionEvent] {
            let (nextVersion, overflow) = previousVersion.rawValue.addingReportingOverflow(1)
            guard overflow == false else { throw GameRulesInternalError.arithmeticOverflow }
            let transitions = try advanceAction(
                actorIndex: actorIndex, state: &state, catalog: catalog
            )
            state.authoritativeVersion = .init(rawValue: nextVersion)
            return transitions
        }

        private static func discard(_ card: CardInstance, from state: inout GameState, catalog: GameDataCatalog) {
            switch catalog.cards.first(where: { $0.id == card.definitionID })?.kind {
            case .wildLocation: state.wildLocationPool.append(card)
            case .wildIndustry: state.wildIndustryPool.append(card)
            default: state.publicDiscard.append(card)
            }
        }

        private static func productionCount(for tile: IndustryTile, era: Era, catalog: GameDataCatalog) -> Int {
            if tile.industryDefinitionID == "brewery" { return era == .canal ? 1 : 2 }
            guard let production = catalog.industries.first(where: { $0.id == tile.industryDefinitionID })?
                .levels.first(where: { $0.level == tile.level })?.production
            else { return 0 }
            return era == .canal ? production.canalCount : production.railCount
        }

        private static func takeProductionFromSupply(_ placement: BoardIndustryPlacement, state: inout GameState) {
            switch placement.tile.industryDefinitionID {
            case "coal-mine": state.publicSupply.coal = max(0, state.publicSupply.coal - placement.resourceCount)
            case "iron-works": state.publicSupply.iron = max(0, state.publicSupply.iron - placement.resourceCount)
            case "brewery": state.publicSupply.beer = max(0, state.publicSupply.beer - placement.resourceCount)
            default: break
            }
        }

        private static func returnResourcesFromOverbuild(_ placement: BoardIndustryPlacement, state: inout GameState) {
            switch placement.tile.industryDefinitionID {
            case "coal-mine": state.publicSupply.coal = min(30, state.publicSupply.coal + placement.resourceCount)
            case "iron-works": state.publicSupply.iron = min(18, state.publicSupply.iron + placement.resourceCount)
            case "brewery": state.publicSupply.beer = min(15, state.publicSupply.beer + placement.resourceCount)
            default: break
            }
        }
    }
}
