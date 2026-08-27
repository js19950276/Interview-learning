import Foundation

extension GameCore {
    nonisolated enum ResourceContext: Codable, Equatable, Sendable {
        case standard
        case network
        case selling(merchantSlotID: String)
    }

    nonisolated enum ResourceSource: Codable, Equatable, Hashable, Sendable {
        case industry(placementID: String)
        case marketSlot(resource: ResourceKind, index: Int)
        case unlimitedMarket(resource: ResourceKind, price: Int)
        case merchantBeer(slotID: String)
    }

    nonisolated struct ResourceRequest: Equatable, Sendable {
        var resource: ResourceKind
        var consumerLocationID: String
        var context: ResourceContext
        var source: ResourceSource
    }

    nonisolated enum ResourceActionTarget: Codable, Equatable, Sendable {
        case build(locationID: String, slotIndex: Int, industryDefinitionID: String, level: Int)
        case network(routeIDs: [String], consumerLocationID: String)
        case develop(tileIDs: [String])
        case sell(industryPlacementID: String, merchantSlotID: String)
    }

    nonisolated struct ResourceActionContext: Codable, Equatable, Sendable {
        var roomID: RoomID
        var actionID: String
        var actorID: PlayerID
        var target: ResourceActionTarget
    }

    /// An untrusted proposal. Deliberately not Codable and never accepted by authoritative apply.
    nonisolated struct ResourcePlan: Equatable, Sendable {
        var context: ResourceActionContext
        var baseVersion: AuthoritativeVersion
        var requests: [ResourceRequest]

        init(context: ResourceActionContext, baseVersion: AuthoritativeVersion, requests: [ResourceRequest]) {
            self.context = context
            self.baseVersion = baseVersion
            self.requests = requests
        }

    }

    nonisolated enum ResourceEffect: Codable, Equatable, Sendable {
        case resourceRemoved(resource: ResourceKind, source: ResourceSource, consumerLocationID: String)
        case industryFlipped(placementID: String)
        case incomeAdvanced(playerID: PlayerID, from: Int, to: Int)
        case marketCostPaid(playerID: PlayerID, resource: ResourceKind, amount: Int)
        case marketDelivered(placementID: String, resource: ResourceKind, slotIndex: Int, price: Int)
        case marketDeliveryResolved(placementID: String)
        case cashReceived(playerID: PlayerID, amount: Int)
        case industryDeveloped(playerID: PlayerID, tile: IndustryTile)
        case victoryPointsReceived(playerID: PlayerID, amount: Int)
    }

    nonisolated enum ResourceTransactionPurpose: Codable, Equatable, Sendable {
        case consumption
        case marketDelivery(placementID: String)
    }

    nonisolated struct AuthoritativeResourceTransactionEvent: Codable, Equatable, Sendable {
        var rulesetVersion: String
        var context: ResourceActionContext
        var purpose: ResourceTransactionPurpose
        var previousVersion: AuthoritativeVersion
        var version: AuthoritativeVersion
        var effects: [ResourceEffect]

        var actionID: String { context.actionID }
        var actorID: PlayerID { context.actorID }
        var roomID: RoomID { context.roomID }
    }

    nonisolated struct ValidatedResourceTransaction: Equatable, Sendable {
        fileprivate var context: ResourceActionContext
        fileprivate var purpose: ResourceTransactionPurpose
        fileprivate var baseVersion: AuthoritativeVersion
        fileprivate var stateDigest: String
        fileprivate var requests: [ResourceRequest]

        fileprivate init(
            context: ResourceActionContext,
            purpose: ResourceTransactionPurpose,
            baseVersion: AuthoritativeVersion,
            stateDigest: String,
            requests: [ResourceRequest]
        ) {
            self.context = context
            self.purpose = purpose
            self.baseVersion = baseVersion
            self.stateDigest = stateDigest
            self.requests = requests
        }
    }

    nonisolated enum ResourceRuleError: Error, Codable, Equatable, Sendable {
        case staleAuthoritativeVersion
        case unknownActor
        case notActivePlayer
        case invalidState
        case illegalSource
        case insufficientCash
        case unknownPlacement
        case marketDeliveryAlreadyResolved
        case unsupportedIndustry
    }

    nonisolated enum ResourceRules {
        static func consumeValidatedRequests(
            _ requests: [ResourceRequest],
            actorID: PlayerID,
            state: inout GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog
        ) throws -> [ResourceEffect] {
            var effects: [ResourceEffect] = []
            for request in requests {
                let legal = legalResourceSources(
                    resource: request.resource,
                    consumerLocationID: request.consumerLocationID,
                    context: request.context,
                    state: state,
                    catalog: verifiedCatalog
                )
                guard legal.contains(request.source) else { throw ResourceRuleError.illegalSource }
                try consume(
                    request, actorID: actorID, state: &state,
                    catalog: verifiedCatalog.catalog, effects: &effects
                )
            }
            return effects
        }

        static func consumeResources(
            for target: ValidatedBuildTarget,
            roomID: RoomID,
            state: inout GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog,
            authority: GameRulesEngine.Authority
        ) throws -> [ResourceEffect] {
            var effects: [ResourceEffect] = []
            let actionNumber = try nextActionNumber(state.actionNumber)
            try executeRequests(
                target.resourceRequests,
                context: .init(
                    roomID: roomID,
                    actionID: "build-\(state.authoritativeVersion.rawValue)-\(actionNumber)",
                    actorID: target.actorID,
                    target: .build(
                        locationID: target.intent.locationID,
                        slotIndex: target.intent.slotIndex,
                        industryDefinitionID: target.intent.industryDefinitionID,
                        level: target.tile.level
                    )
                ),
                state: &state,
                catalog: verifiedCatalog,
                effects: &effects
            )
            return effects
        }

        static func consumeResources(
            for target: ValidatedNetworkTarget,
            roomID: RoomID,
            state: inout GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog,
            authority: GameRulesEngine.Authority
        ) throws -> [ResourceEffect] {
            var effects: [ResourceEffect] = []
            let actionNumber = try nextActionNumber(state.actionNumber)
            try executeRequests(
                target.resourceRequests,
                context: .init(
                    roomID: roomID,
                    actionID: "network-\(state.authoritativeVersion.rawValue)-\(actionNumber)",
                    actorID: target.actorID,
                    target: .network(
                        routeIDs: target.intent.routeIDs,
                        consumerLocationID: target.resourceRequests.first?.consumerLocationID ?? ""
                    )
                ),
                state: &state,
                catalog: verifiedCatalog,
                effects: &effects
            )
            return effects
        }

        static func settleBuiltIndustryMarket(
            for target: ValidatedBuildTarget,
            placementID: String,
            state: inout GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog,
            authority: GameRulesEngine.Authority
        ) throws -> [ResourceEffect] {
            var effects: [ResourceEffect] = []
            try executeDelivery(
                placementID: placementID,
                state: &state,
                catalog: verifiedCatalog.catalog,
                effects: &effects
            )
            return effects
        }

        static func legalResourceSources(
            resource: ResourceKind,
            consumerLocationID: String,
            context: ResourceContext,
            state: GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog
        ) -> [ResourceSource] {
            let catalog = verifiedCatalog.catalog
            guard GameStateAuthorityValidator.isValid(state, catalog: catalog) else { return [] }
            switch resource {
            case .coal:
                guard catalog.board.locations.contains(where: {
                    $0.id == consumerLocationID && $0.playerCounts.contains(state.playerCount)
                }) else { return [] }
                let candidates = resourceIndustries(.coal, state: state)
                    .compactMap { placement -> (BoardIndustryPlacement, Int)? in
                        guard let distance = TopologyRules.routeDistance(
                            from: consumerLocationID,
                            to: placement.locationID,
                            state: state,
                            board: catalog.board
                        ) else { return nil }
                        return (placement, distance)
                    }
                if let minimum = candidates.map(\.1).min() {
                    return candidates.filter { $0.1 == minimum }
                        .map { .industry(placementID: $0.0.placementID) }
                        .sorted(by: sourceOrder)
                }
                guard connectedToMerchantLocation(
                    consumerLocationID,
                    state: state,
                    board: catalog.board
                ) else { return [] }
                return marketSource(for: .coal, market: state.coalMarket, unlimitedPrice: 8)

            case .iron:
                let candidates = resourceIndustries(.iron, state: state)
                if candidates.isEmpty == false {
                    return candidates.map { .industry(placementID: $0.placementID) }.sorted(by: sourceOrder)
                }
                return marketSource(for: .iron, market: state.ironMarket, unlimitedPrice: 6)

            case .beer:
                var sources = resourceIndustries(.beer, state: state).compactMap { placement -> ResourceSource? in
                    if placement.ownerID == state.activePlayerID {
                        return .industry(placementID: placement.placementID)
                    }
                    return TopologyRules.hasRoute(
                        from: consumerLocationID,
                        to: placement.locationID,
                        state: state,
                        board: catalog.board
                    ) ? .industry(placementID: placement.placementID) : nil
                }
                if case .selling(let selectedSlotID) = context,
                   state.merchants.contains(where: { $0.slotID == selectedSlotID && $0.hasBeer }),
                   let slot = catalog.board.merchantSlots.first(where: {
                       $0.id == selectedSlotID && $0.playerCounts.contains(state.playerCount)
                   }),
                   TopologyRules.hasRoute(
                       from: consumerLocationID,
                       to: slot.locationID,
                       state: state,
                       board: catalog.board
                   ) {
                    sources.append(.merchantBeer(slotID: selectedSlotID))
                }
                return sources.sorted(by: sourceOrder)
            }
        }

        static func prepare(
            _ plan: ResourcePlan,
            expectedRoomID: RoomID,
            state: GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog,
            authority: GameRulesEngine.Authority
        ) throws -> ValidatedResourceTransaction {
            guard plan.baseVersion == state.authoritativeVersion else {
                throw ResourceRuleError.staleAuthoritativeVersion
            }
            let context = plan.context
            guard context.roomID == expectedRoomID else { throw ResourceRuleError.invalidState }
            guard state.players.contains(where: { $0.id == context.actorID }) else {
                throw ResourceRuleError.unknownActor
            }
            guard state.activePlayerID == context.actorID else {
                throw ResourceRuleError.notActivePlayer
            }
            let catalog = verifiedCatalog.catalog
            guard GameStateAuthorityValidator.isValid(state, catalog: catalog) else { throw ResourceRuleError.invalidState }
            guard validActionBinding(plan, state: state, catalog: catalog) else { throw ResourceRuleError.illegalSource }

            var candidate = state
            var effects: [ResourceEffect] = []
            try executeRequests(plan.requests, context: context, state: &candidate, catalog: verifiedCatalog, effects: &effects)
            guard let digest = try? state.canonicalHash() else { throw ResourceRuleError.invalidState }
            return ValidatedResourceTransaction(
                context: context,
                purpose: .consumption,
                baseVersion: plan.baseVersion,
                stateDigest: digest,
                requests: plan.requests
            )
        }

        static func apply(
            _ transaction: ValidatedResourceTransaction,
            expectedRoomID: RoomID,
            to state: inout GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog,
            authority: GameRulesEngine.Authority
        ) throws -> AuthoritativeResourceTransactionEvent {
            let catalog = verifiedCatalog.catalog
            guard GameStateAuthorityValidator.isValid(state, catalog: catalog) else { throw ResourceRuleError.invalidState }
            guard transaction.baseVersion == state.authoritativeVersion else {
                throw ResourceRuleError.staleAuthoritativeVersion
            }
            guard transaction.context.roomID == expectedRoomID,
                  (try? state.canonicalHash()) == transaction.stateDigest,
                  state.appliedResourceActionIDs?.contains(transaction.context.actionID) == false
            else { throw ResourceRuleError.invalidState }

            var candidate = state
            var effects: [ResourceEffect] = []
            switch transaction.purpose {
            case .consumption:
                try executeRequests(
                    transaction.requests,
                    context: transaction.context,
                    state: &candidate,
                    catalog: verifiedCatalog,
                    effects: &effects
                )
            case .marketDelivery(let placementID):
                try executeDelivery(
                    placementID: placementID,
                    state: &candidate,
                    catalog: catalog,
                    effects: &effects
                )
            }
            let previous = state.authoritativeVersion
            guard let next = safeIncrement(previous.rawValue) else { throw ResourceRuleError.invalidState }
            candidate.authoritativeVersion = .init(rawValue: next)
            guard var applied = candidate.appliedResourceActionIDs else { throw ResourceRuleError.invalidState }
            applied.append(transaction.context.actionID)
            candidate.appliedResourceActionIDs = applied
            let event = AuthoritativeResourceTransactionEvent(
                rulesetVersion: state.rulesetVersion,
                context: transaction.context,
                purpose: transaction.purpose,
                previousVersion: previous,
                version: candidate.authoritativeVersion,
                effects: effects
            )
            state = candidate
            return event
        }

        /// Authority-only seam for the future build resolver; proposals cannot construct the result.
        static func prepareMarketDelivery(
            context: ResourceActionContext,
            placementID: String,
            baseVersion: AuthoritativeVersion,
            expectedRoomID: RoomID,
            state: GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog,
            authority: GameRulesEngine.Authority
        ) throws -> ValidatedResourceTransaction {
            guard baseVersion == state.authoritativeVersion else {
                throw ResourceRuleError.staleAuthoritativeVersion
            }
            guard GameStateAuthorityValidator.isValid(state, catalog: verifiedCatalog) else {
                throw ResourceRuleError.invalidState
            }
            guard let placement = state.boardIndustryPlacements.first(where: { $0.placementID == placementID })
            else { throw ResourceRuleError.unknownPlacement }
            guard placement.marketDeliveryResolved == false else {
                throw ResourceRuleError.marketDeliveryAlreadyResolved
            }
            guard context.roomID == expectedRoomID,
                  context.actionID.isEmpty == false,
                  context.actorID == state.activePlayerID,
                  context.actorID == placement.ownerID,
                  state.appliedResourceActionIDs?.contains(context.actionID) == false,
                  let digest = try? state.canonicalHash()
            else { throw ResourceRuleError.illegalSource }
            guard case let .build(locationID, slotIndex, industryDefinitionID, level) = context.target,
                  locationID == placement.locationID,
                  slotIndex == placement.slotIndex,
                  industryDefinitionID == placement.tile.industryDefinitionID,
                  level == placement.tile.level
            else { throw ResourceRuleError.illegalSource }
            return ValidatedResourceTransaction(
                context: context,
                purpose: .marketDelivery(placementID: placementID),
                baseVersion: baseVersion,
                stateDigest: digest,
                requests: []
            )
        }

        private static func executeDelivery(
            placementID: String,
            state candidate: inout GameState,
            catalog: GameDataCatalog,
            effects: inout [ResourceEffect]
        ) throws {
            guard let originalIndex = candidate.boardIndustryPlacements.firstIndex(where: { $0.placementID == placementID })
            else { throw ResourceRuleError.unknownPlacement }
            let placement = candidate.boardIndustryPlacements[originalIndex]
            guard placement.marketDeliveryResolved == false else {
                throw ResourceRuleError.marketDeliveryAlreadyResolved
            }
            let resource: ResourceKind
            let marketKeyPath: WritableKeyPath<GameState, ResourceMarket>
            var mayDeliver = true
            switch placement.tile.industryDefinitionID {
            case "coal-mine":
                mayDeliver = connectedToMerchantLocation(
                    placement.locationID,
                    state: candidate,
                    board: catalog.board
                )
                resource = .coal
                marketKeyPath = \.coalMarket
            case "iron-works":
                resource = .iron
                marketKeyPath = \.ironMarket
            default:
                throw ResourceRuleError.unsupportedIndustry
            }

            while mayDeliver,
                  candidate.boardIndustryPlacements[originalIndex].resourceCount > 0,
                  let slotIndex = highestPriceEmptySlot(candidate[keyPath: marketKeyPath]) {
                let price = candidate[keyPath: marketKeyPath].slots[slotIndex].price
                candidate.boardIndustryPlacements[originalIndex].resourceCount -= 1
                candidate[keyPath: marketKeyPath].slots[slotIndex].hasCube = true
                guard let playerIndex = candidate.players.firstIndex(where: { $0.id == placement.ownerID })
                else { throw ResourceRuleError.invalidState }
                let (cash, overflow) = candidate.players[playerIndex].cash.addingReportingOverflow(price)
                guard overflow == false else {
                    throw GameRulesEngine.GameRulesInternalError.arithmeticOverflow
                }
                candidate.players[playerIndex].cash = cash
                effects.append(.resourceRemoved(
                    resource: resource,
                    source: .industry(placementID: placementID),
                    consumerLocationID: placement.locationID
                ))
                effects.append(.marketDelivered(placementID: placementID, resource: resource, slotIndex: slotIndex, price: price))
                effects.append(.cashReceived(playerID: placement.ownerID, amount: price))
            }
            candidate.boardIndustryPlacements[originalIndex].marketDeliveryResolved = true
            effects.append(.marketDeliveryResolved(placementID: placementID))
            try flipIfEmpty(index: originalIndex, state: &candidate, catalog: catalog, effects: &effects)
        }

        private static func consume(
            _ request: ResourceRequest,
            actorID: PlayerID,
            state: inout GameState,
            catalog: GameDataCatalog,
            effects: inout [ResourceEffect]
        ) throws {
            switch request.source {
            case .industry(let placementID):
                guard let index = state.boardIndustryPlacements.firstIndex(where: { $0.placementID == placementID }),
                      state.boardIndustryPlacements[index].resourceCount > 0
                else { throw ResourceRuleError.illegalSource }
                state.boardIndustryPlacements[index].resourceCount -= 1
                SupplyRules.returnToPublicSupply(request.resource, state: &state)
                effects.append(.resourceRemoved(resource: request.resource, source: request.source, consumerLocationID: request.consumerLocationID))
                try flipIfEmpty(index: index, state: &state, catalog: catalog, effects: &effects)

            case .marketSlot(let resource, let index):
                guard resource == request.resource,
                      let marketPath = marketPath(for: resource),
                      state[keyPath: marketPath].slots.indices.contains(index),
                      state[keyPath: marketPath].slots[index].hasCube
                else { throw ResourceRuleError.illegalSource }
                let price = state[keyPath: marketPath].slots[index].price
                guard let playerIndex = state.players.firstIndex(where: { $0.id == actorID }),
                      state.players[playerIndex].cash >= price
                else { throw ResourceRuleError.insufficientCash }
                state.players[playerIndex].cash -= price
                state[keyPath: marketPath].slots[index].hasCube = false
                SupplyRules.returnToPublicSupply(resource, state: &state)
                effects.append(.resourceRemoved(resource: resource, source: request.source, consumerLocationID: request.consumerLocationID))
                effects.append(.marketCostPaid(playerID: actorID, resource: resource, amount: price))

            case .unlimitedMarket(let resource, let price):
                guard resource == request.resource else { throw ResourceRuleError.illegalSource }
                guard let playerIndex = state.players.firstIndex(where: { $0.id == actorID }),
                      state.players[playerIndex].cash >= price
                else { throw ResourceRuleError.insufficientCash }
                state.players[playerIndex].cash -= price
                effects.append(.resourceRemoved(resource: resource, source: request.source, consumerLocationID: request.consumerLocationID))
                effects.append(.marketCostPaid(playerID: actorID, resource: resource, amount: price))

            case .merchantBeer(let slotID):
                guard request.resource == .beer,
                      let index = state.merchants.firstIndex(where: { $0.slotID == slotID && $0.hasBeer })
                else { throw ResourceRuleError.illegalSource }
                state.merchants[index].hasBeer = false
                SupplyRules.returnToPublicSupply(.beer, state: &state)
                effects.append(.resourceRemoved(resource: .beer, source: request.source, consumerLocationID: request.consumerLocationID))
            }
        }

        private static func executeRequests(
            _ requests: [ResourceRequest],
            context: ResourceActionContext,
            state: inout GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog,
            effects: inout [ResourceEffect]
        ) throws {
            for request in requests {
                let legal = legalResourceSources(
                    resource: request.resource,
                    consumerLocationID: request.consumerLocationID,
                    context: request.context,
                    state: state,
                    catalog: verifiedCatalog
                )
                guard legal.contains(request.source) else { throw ResourceRuleError.illegalSource }
                try consume(
                    request,
                    actorID: context.actorID,
                    state: &state,
                    catalog: verifiedCatalog.catalog,
                    effects: &effects
                )
            }
        }

        private static func flipIfEmpty(
            index: Int,
            state: inout GameState,
            catalog: GameDataCatalog,
            effects: inout [ResourceEffect]
        ) throws {
            let placement = state.boardIndustryPlacements[index]
            guard placement.resourceCount == 0, placement.isFlipped == false,
                  let reward = catalog.industries.first(where: { $0.id == placement.tile.industryDefinitionID })?
                    .levels.first(where: { $0.level == placement.tile.level })?.incomeReward,
                  let playerIndex = state.players.firstIndex(where: { $0.id == placement.ownerID })
            else { return }
            state.boardIndustryPlacements[index].isFlipped = true
            effects.append(.industryFlipped(placementID: placement.placementID))
            let old = state.players[playerIndex].incomePosition
            let cap = catalog.incomeTrack.entries.map(\.position).max() ?? old
            let (advanced, overflow) = old.addingReportingOverflow(reward)
            guard overflow == false else {
                throw GameRulesEngine.GameRulesInternalError.arithmeticOverflow
            }
            let new = min(cap, advanced)
            state.players[playerIndex].incomePosition = new
            effects.append(.incomeAdvanced(playerID: placement.ownerID, from: old, to: new))
        }

        private static func nextActionNumber(_ current: Int) throws -> Int {
            let (next, overflow) = current.addingReportingOverflow(1)
            guard !overflow else {
                throw GameRulesEngine.GameRulesInternalError.arithmeticOverflow
            }
            return next
        }

        private static func resourceIndustries(_ resource: ResourceKind, state: GameState) -> [BoardIndustryPlacement] {
            let industryID: String
            switch resource {
            case .beer: industryID = "brewery"
            case .coal: industryID = "coal-mine"
            case .iron: industryID = "iron-works"
            }
            return state.boardIndustryPlacements.filter {
                $0.tile.industryDefinitionID == industryID && $0.resourceCount > 0 && $0.isFlipped == false
            }
        }

        private static func marketSource(for resource: ResourceKind, market: ResourceMarket, unlimitedPrice: Int) -> [ResourceSource] {
            let filled = market.slots.enumerated().filter(\.element.hasCube)
            guard let cheapest = filled.map(\.element.price).min() else {
                return [.unlimitedMarket(resource: resource, price: unlimitedPrice)]
            }
            guard let index = filled.filter({ $0.element.price == cheapest }).map(\.offset).min() else { return [] }
            return [.marketSlot(resource: resource, index: index)]
        }

        private static func connectedToMerchantLocation(_ locationID: String, state: GameState, board: BoardDefinition) -> Bool {
            board.locations.filter { $0.kind == .merchant && $0.playerCounts.contains(state.playerCount) }
                .contains { TopologyRules.hasRoute(from: locationID, to: $0.id, state: state, board: board) }
        }

        private static func highestPriceEmptySlot(_ market: ResourceMarket) -> Int? {
            market.slots.enumerated().filter { $0.element.hasCube == false }
                .sorted { ($0.element.price, -$0.offset) > ($1.element.price, -$1.offset) }.first?.offset
        }

        private static func marketPath(for resource: ResourceKind) -> WritableKeyPath<GameState, ResourceMarket>? {
            switch resource {
            case .coal: return \.coalMarket
            case .iron: return \.ironMarket
            case .beer: return nil
            }
        }

        static func replay(
            _ event: AuthoritativeResourceTransactionEvent,
            expectedRoomID: RoomID,
            to state: inout GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog,
            authority: GameRulesEngine.Authority
        ) throws {
            guard let expectedVersion = safeIncrement(event.previousVersion.rawValue),
                  event.context.roomID == expectedRoomID,
                  event.rulesetVersion == state.rulesetVersion,
                  event.rulesetVersion == verifiedCatalog.catalog.rulesetVersion,
                  event.previousVersion == state.authoritativeVersion,
                  event.version.rawValue == expectedVersion,
                  event.context.actionID.isEmpty == false,
                  state.appliedResourceActionIDs?.contains(event.context.actionID) == false
            else { throw ResourceRuleError.invalidState }

            var candidate = state
            let transaction: ValidatedResourceTransaction
            switch event.purpose {
            case .consumption:
                guard let binding = actionBinding(event.context, state: state, catalog: verifiedCatalog.catalog)
                else { throw ResourceRuleError.invalidState }
                let requests = event.effects.compactMap { effect -> ResourceRequest? in
                    guard case let .resourceRemoved(resource, source, consumerLocationID) = effect else { return nil }
                    return .init(resource: resource, consumerLocationID: consumerLocationID, context: binding.requestContext, source: source)
                }
                let proposal = ResourcePlan(context: event.context, baseVersion: event.previousVersion, requests: requests)
                transaction = try prepare(
                    proposal, expectedRoomID: expectedRoomID, state: state,
                    catalog: verifiedCatalog, authority: authority
                )
            case .marketDelivery(let placementID):
                transaction = try prepareMarketDelivery(
                    context: event.context,
                    placementID: placementID,
                    baseVersion: event.previousVersion,
                    expectedRoomID: expectedRoomID,
                    state: state,
                    catalog: verifiedCatalog,
                    authority: authority
                )
            }
            let reproduced = try apply(
                transaction, expectedRoomID: expectedRoomID, to: &candidate,
                catalog: verifiedCatalog, authority: authority
            )
            guard reproduced == event else { throw ResourceRuleError.invalidState }
            state = candidate
        }

        private struct ActionBinding {
            var consumerLocationID: String
            var requestContext: ResourceContext
            var requirements: [ResourceKind: Int]
        }

        private static func validActionBinding(
            _ plan: ResourcePlan,
            state: GameState,
            catalog: GameDataCatalog
        ) -> Bool {
            let context = plan.context
            guard let binding = actionBinding(context, state: state, catalog: catalog) else { return false }
            guard context.actionID.isEmpty == false,
                  context.actorID == state.activePlayerID,
                  state.appliedResourceActionIDs?.contains(context.actionID) == false,
                  binding.requirements.isEmpty == false,
                  plan.requests.allSatisfy({
                      $0.consumerLocationID == binding.consumerLocationID
                          && $0.context == binding.requestContext
                  })
            else { return false }

            let actual = Dictionary(grouping: plan.requests, by: \ResourceRequest.resource).mapValues(\.count)
            guard actual == binding.requirements else { return false }
            if case .selling(let merchantSlotID) = binding.requestContext {
                return plan.requests.allSatisfy {
                    if case .merchantBeer(let sourceSlotID) = $0.source { return sourceSlotID == merchantSlotID }
                    return true
                }
            }
            return plan.requests.allSatisfy {
                if case .merchantBeer = $0.source { return false }
                return true
            }
        }

        private static func actionBinding(
            _ context: ResourceActionContext,
            state: GameState,
            catalog: GameDataCatalog
        ) -> ActionBinding? {
            func requirements(coal: Int, iron: Int, beer: Int) -> [ResourceKind: Int] {
                var result: [ResourceKind: Int] = [:]
                if coal > 0 { result[.coal] = coal }
                if iron > 0 { result[.iron] = iron }
                if beer > 0 { result[.beer] = beer }
                return result
            }

            switch context.target {
            case let .build(locationID, slotIndex, industryDefinitionID, levelNumber):
                guard let location = catalog.board.locations.first(where: {
                    $0.id == locationID && $0.playerCounts.contains(state.playerCount)
                }),
                    location.industrySlots.indices.contains(slotIndex),
                    location.industrySlots[slotIndex].contains(industryDefinitionID),
                    let level = catalog.industries.first(where: { $0.id == industryDefinitionID })?
                        .levels.first(where: { $0.level == levelNumber })
                else { return nil }
                return .init(
                    consumerLocationID: locationID,
                    requestContext: .standard,
                    requirements: requirements(coal: level.coalCost, iron: level.ironCost, beer: level.beerCost)
                )

            case let .network(routeIDs, consumerLocationID):
                guard (1...2).contains(routeIDs.count),
                      Set(routeIDs).count == routeIDs.count,
                      catalog.board.locations.contains(where: {
                          $0.id == consumerLocationID && $0.playerCounts.contains(state.playerCount)
                      })
                else { return nil }
                let routes = routeIDs.compactMap { routeID in
                    catalog.board.routes.first(where: {
                        $0.id == routeID
                            && $0.playerCounts.contains(state.playerCount)
                            && $0.eras.contains(state.era == .canal ? .canal : .rail)
                    })
                }
                guard routes.count == routeIDs.count,
                      routes.first.map({ ($0.endpoints + $0.adjacentLocationIDs).contains(consumerLocationID) }) == true
                else { return nil }
                let coal = state.era == .rail ? routeIDs.count : 0
                let beer = state.era == .rail && routeIDs.count == 2 ? 1 : 0
                return .init(
                    consumerLocationID: consumerLocationID,
                    requestContext: .network,
                    requirements: requirements(coal: coal, iron: 0, beer: beer)
                )

            case let .develop(tileIDs):
                guard (1...2).contains(tileIDs.count), Set(tileIDs).count == tileIDs.count,
                      let player = state.players.first(where: { $0.id == context.actorID })
                else { return nil }
                let ownedTileIDs = Set(player.industryStacks.flatMap(\.tiles).map(\.id))
                guard tileIDs.allSatisfy(ownedTileIDs.contains) else { return nil }
                return .init(
                    consumerLocationID: "",
                    requestContext: .standard,
                    requirements: requirements(coal: 0, iron: tileIDs.count, beer: 0)
                )

            case let .sell(industryPlacementID, merchantSlotID):
                guard let placement = state.boardIndustryPlacements.first(where: {
                    $0.placementID == industryPlacementID && $0.ownerID == context.actorID
                }),
                    let level = catalog.industries.first(where: { $0.id == placement.tile.industryDefinitionID })?
                        .levels.first(where: { $0.level == placement.tile.level }),
                    level.beerCost > 0,
                    state.merchants.contains(where: { $0.slotID == merchantSlotID }),
                    catalog.board.merchantSlots.contains(where: {
                        $0.id == merchantSlotID && $0.playerCounts.contains(state.playerCount)
                    })
                else { return nil }
                return .init(
                    consumerLocationID: placement.locationID,
                    requestContext: .selling(merchantSlotID: merchantSlotID),
                    requirements: requirements(coal: 0, iron: 0, beer: level.beerCost)
                )
            }
        }

        private static func sourceOrder(_ lhs: ResourceSource, _ rhs: ResourceSource) -> Bool {
            sourceKey(lhs) < sourceKey(rhs)
        }

        private static func sourceKey(_ source: ResourceSource) -> String {
            switch source {
            case .industry(let id): return "0:\(id)"
            case .marketSlot(let resource, let index): return "1:\(resource.rawValue):\(index)"
            case .unlimitedMarket(let resource, let price): return "2:\(resource.rawValue):\(price)"
            case .merchantBeer(let id): return "3:\(id)"
            }
        }

        private static func safeIncrement(_ value: Int) -> Int? {
            let (result, overflow) = value.addingReportingOverflow(1)
            return overflow ? nil : result
        }
    }
}
