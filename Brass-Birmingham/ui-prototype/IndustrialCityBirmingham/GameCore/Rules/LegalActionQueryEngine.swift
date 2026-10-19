import Foundation

extension GameCore {
    nonisolated enum LegalActionQueryError: String, Codable, Equatable, Error, Sendable {
        case staleVersion, notActivePlayer, invalidCard, invalidPrefix, malformedQuery
    }

    nonisolated enum LegalActionQueryEngine {
        static func respond(
            to query: LegalActionQuery,
            actorID: PlayerID,
            state: GameState,
            catalog: VerifiedGameDataCatalog,
            fastPath: Bool = false
        ) throws -> LegalActionResponse {
            if fastPath == false { try validateStructure(query) }
            guard query.baseVersion == state.authoritativeVersion else { throw LegalActionQueryError.staleVersion }
            guard state.activePlayerID == actorID,
                  let player = state.players.first(where: { $0.id == actorID })
            else { throw LegalActionQueryError.notActivePlayer }

            if query.draft.action == .forcedSale {
                let result = try forcedSale(query.draft, actorID: actorID, state: state, catalog: catalog)
                return .init(
                    requestID: query.requestID, baseVersion: query.baseVersion,
                    draftDigest: fastPath ? "" : (try query.draft.canonicalDigest()),
                    nextChoices: result.choices,
                    // fastPath(枚举器):跳过确认增量——每个完整 payload 都要二次
                    // 验证+整体 resolve 才能算出 delta,纯表现层数据,枚举不需要。
                    confirmation: fastPath ? nil : result.payload.flatMap {
                        confirmation(payload: $0, actorID: actorID, state: state, catalog: catalog)
                    }, completePayload: result.payload
                )
            }
            guard state.turnPhase == .active else { throw LegalActionQueryError.notActivePlayer }
            guard let cardID = query.draft.cardID,
                  player.hand.contains(where: { $0.id == cardID })
            else { throw LegalActionQueryError.invalidCard }
            var draft = query.draft
            draft.cardID = cardID

            let result: (choices: [LegalChoice], payload: PlayerIntent.Payload?)
            switch draft.action {
            case .build: result = try build(draft, actorID: actorID, state: state, catalog: catalog)
            case .network: result = try network(draft, actorID: actorID, state: state, catalog: catalog)
            case .develop: result = try develop(draft, actorID: actorID, state: state, catalog: catalog)
            case .sell: result = try sell(draft, actorID: actorID, state: state, catalog: catalog)
            case .loan:
                guard draft.selections.isEmpty else { throw LegalActionQueryError.invalidPrefix }
                result = try complete(.loan(.init(cardID: cardID)), actorID: actorID, state: state, catalog: catalog)
            case .pass:
                guard draft.selections.isEmpty else { throw LegalActionQueryError.invalidPrefix }
                result = try complete(.pass(.init(cardID: cardID)), actorID: actorID, state: state, catalog: catalog)
            case .scout: result = try scout(draft, actorID: actorID, state: state, catalog: catalog)
            case .forcedSale: throw LegalActionQueryError.invalidPrefix
            }
            let delta: ConfirmationDelta? = fastPath
                ? nil
                : result.payload.flatMap {
                    confirmation(payload: $0, actorID: actorID, state: state, catalog: catalog)
                }
            return .init(
                requestID: query.requestID, baseVersion: query.baseVersion,
                draftDigest: fastPath ? "" : (try query.draft.canonicalDigest()),
                nextChoices: result.choices, confirmation: delta,
                completePayload: result.payload
            )
        }

        private static func validateStructure(_ query: LegalActionQuery) throws {
            guard (1...128).contains(query.requestID.utf8.count),
                  // 出售可连续任意数量(RULES.md §7.4),上限只做 DoS 防护,配合 16KB JSON 界。
                  query.draft.selections.count <= 128,
                  query.draft.cardID.map({ (1...256).contains($0.utf8.count) }) ?? true,
                  query.draft.selections.allSatisfy(selectionIsBounded),
                  try JSONEncoder.canonical.encode(query).count <= 16_384
            else { throw LegalActionQueryError.malformedQuery }
        }

        private static func selectionIsBounded(_ value: LegalChoiceValue) -> Bool {
            func valid(_ id: String) -> Bool { (1...256).contains(id.utf8.count) }
            switch value {
            case .industryTile(let id), .route(let id), .industryPlacement(let id),
                 .merchant(let id), .card(let id):
                return valid(id)
            case .buildTarget(let locationID, let slotIndex):
                return valid(locationID) && slotIndex >= 0 && slotIndex < 64
            case .resourceSource(.industry(let placementID)):
                return valid(placementID)
            case .resourceSource(.merchantBeer(let slotID)):
                return valid(slotID)
            case .resourceSource(.marketSlot(_, let index)):
                return index >= 0 && index < 64
            case .resourceSource(.unlimitedMarket(_, let price)):
                return price >= 0 && price <= 1_000
            case .networkLinkCount(let count), .developTileCount(let count):
                return (1...2).contains(count)
            case .sellDisposition:
                return true
            }
        }

        private static func forcedSale(
            _ draft: LegalActionDraft, actorID: PlayerID,
            state: GameState, catalog: VerifiedGameDataCatalog
        ) throws -> (choices: [LegalChoice], payload: PlayerIntent.Payload?) {
            guard draft.cardID == nil,
                  case .forcedSale(let pending) = state.turnPhase,
                  pending.playerID == actorID
            else { throw LegalActionQueryError.invalidPrefix }
            let placementIDs = draft.selections.compactMap {
                if case .industryPlacement(let id) = $0 { id } else { nil }
            }
            guard placementIDs.count == draft.selections.count,
                  Set(placementIDs).count == placementIDs.count,
                  Set(placementIDs).isSubset(of: Set(pending.eligiblePlacementIDs))
            else { throw LegalActionQueryError.invalidPrefix }
            let total = try placementIDs.reduce(0) { partial, placementID in
                guard let placement = state.boardIndustryPlacements.first(where: {
                    $0.placementID == placementID && $0.ownerID == actorID
                }), let value = TurnRules.liquidationValue(of: placement, catalog: catalog.catalog)
                else { throw LegalActionQueryError.invalidPrefix }
                return partial + value
            }
            // 与 TurnRules.validateForcedSale 对齐："刚够即停"，或卖光全部 eligible
            // （ proceeds < shortfall 时差额转 VP 债，RULES.md §6.3）。
            let soldEverything = placementIDs.count == pending.eligiblePlacementIDs.count
            if total >= pending.shortfall || soldEverything {
                return try complete(
                    .forcedSale(.init(placementIDs: placementIDs)),
                    actorID: actorID, state: state, catalog: catalog
                )
            }
            let choices: [LegalChoice] = pending.eligiblePlacementIDs
                .filter { !placementIDs.contains($0) }.compactMap { id in
                guard let placement = state.boardIndustryPlacements.first(where: {
                    $0.placementID == id && $0.ownerID == actorID
                }), let value = TurnRules.liquidationValue(of: placement, catalog: catalog.catalog)
                else { return nil }
                return choice("forced-sale:\(id)", "\(industryLabel(placement.tile.industryDefinitionID)) L\(placement.tile.level) · £\(value)",
                              .industryPlacement(id: id))
            }
            guard !choices.isEmpty else { throw LegalActionQueryError.invalidPrefix }
            return (choices, nil)
        }

        private static func build(
            _ draft: LegalActionDraft, actorID: PlayerID,
            state: GameState, catalog: VerifiedGameDataCatalog
        ) throws -> ([LegalChoice], PlayerIntent.Payload?) {
            let cardID = try requiredCardID(in: draft)
            guard let player = state.players.first(where: { $0.id == actorID }) else {
                throw LegalActionQueryError.notActivePlayer
            }
            for (index, value) in draft.selections.enumerated() {
                switch (index, value) {
                case (0, .industryTile), (1, .buildTarget): break
                case (2..., .resourceSource): break
                default: throw LegalActionQueryError.invalidPrefix
                }
            }
            let tileIDs = draft.selections.compactMap { if case .industryTile(let id) = $0 { id } else { nil } }
            let targets = draft.selections.compactMap { value -> BuildTarget? in
                if case let .buildTarget(locationID, slotIndex) = value {
                    return .init(locationID: locationID, slotIndex: slotIndex)
                }
                return nil
            }
            let sources = draft.selections.compactMap { if case .resourceSource(let value) = $0 { value } else { nil } }
            guard tileIDs.count + targets.count + sources.count == draft.selections.count else {
                throw LegalActionQueryError.invalidPrefix
            }
            if tileIDs.isEmpty {
                let legalTiles = player.industryStacks.compactMap(\.tiles.first).filter { tile in
                    BuildRules.hasLegalBuildTarget(
                        actorID: actorID,
                        cardID: cardID,
                        tile: tile,
                        state: state,
                        catalog: catalog
                    )
                }
                return (legalTiles.map {
                    choice(
                        "tile:\($0.id)",
                        industryLabel($0.industryDefinitionID),
                        .industryTile(id: $0.id)
                    )
                }, nil)
            }
            guard tileIDs.count == 1,
                  let tile = player.industryStacks.compactMap(\.tiles.first).first(where: { $0.id == tileIDs[0] })
            else { throw LegalActionQueryError.invalidPrefix }
            if targets.isEmpty {
                return (BuildRules.legalBuildTargets(
                    actorID: actorID, cardID: cardID, tile: tile,
                    state: state, catalog: catalog
                ).map {
                    choice("build:\($0.locationID):\($0.slotIndex)", "\(locationLabel($0.locationID)) · 位置 \($0.slotIndex + 1)",
                           .buildTarget(locationID: $0.locationID, slotIndex: $0.slotIndex))
                }, nil)
            }
            guard targets.count == 1,
                  let level = catalog.catalog.industries.first(where: {
                      $0.id == tile.industryDefinitionID
                  })?.levels.first(where: { $0.level == tile.level })
            else { throw LegalActionQueryError.invalidPrefix }
            let requirements = Array(repeating: ResourceKind.coal, count: level.coalCost)
                + Array(repeating: .iron, count: level.ironCost)
            guard sources.count <= requirements.count else { throw LegalActionQueryError.invalidPrefix }
            var candidate = state
            for (resource, source) in zip(requirements, sources) {
                let request = ResourceRequest(
                    resource: resource, consumerLocationID: targets[0].locationID,
                    context: .standard, source: source
                )
                guard (try? ResourceRules.consumeValidatedRequests(
                    [request], actorID: actorID, state: &candidate, catalog: catalog
                )) != nil else { throw LegalActionQueryError.invalidPrefix }
            }
            if sources.count < requirements.count {
                let next = requirements[sources.count]
                return (GameRulesEngine.legalResourceSources(
                    resource: next, consumerLocationID: targets[0].locationID,
                    context: .standard, state: candidate, catalog: catalog
                ).map { sourceChoice(next, $0, actorID: actorID, state: candidate, catalog: catalog) }, nil)
            }
            let intent = BuildIntent(
                cardID: cardID, locationID: targets[0].locationID,
                industryDefinitionID: tile.industryDefinitionID,
                slotIndex: targets[0].slotIndex, resourceSources: sources
            )
            return try complete(.build(intent), actorID: actorID, state: state, catalog: catalog)
        }

        private static func network(
            _ draft: LegalActionDraft, actorID: PlayerID,
            state: GameState, catalog: VerifiedGameDataCatalog
        ) throws -> ([LegalChoice], PlayerIntent.Payload?) {
            let cardID = try requiredCardID(in: draft)
            if state.era == .canal {
                guard draft.selections.count <= 1,
                      draft.selections.allSatisfy({ if case .route = $0 { true } else { false } })
                else { throw LegalActionQueryError.invalidPrefix }
            } else if let first = draft.selections.first {
                guard case .networkLinkCount(let count) = first, [1, 2].contains(count) else {
                    throw LegalActionQueryError.invalidPrefix
                }
                let maximum = 1 + (count * 2) + (count == 2 ? 1 : 0)
                guard draft.selections.count <= maximum else { throw LegalActionQueryError.invalidPrefix }
                for (index, value) in draft.selections.dropFirst().enumerated() {
                    let expectsBeer = count == 2 && index == count * 2
                    if expectsBeer {
                        guard case .resourceSource = value else { throw LegalActionQueryError.invalidPrefix }
                    } else if index.isMultiple(of: 2) {
                        guard case .route = value else { throw LegalActionQueryError.invalidPrefix }
                    } else {
                        guard case .resourceSource = value else { throw LegalActionQueryError.invalidPrefix }
                    }
                }
            }
            let counts = draft.selections.compactMap { if case .networkLinkCount(let value) = $0 { value } else { nil } }
            let routes = draft.selections.compactMap { if case .route(let id) = $0 { id } else { nil } }
            let sources = draft.selections.compactMap { if case .resourceSource(let value) = $0 { value } else { nil } }
            guard counts.count + routes.count + sources.count == draft.selections.count else {
                throw LegalActionQueryError.invalidPrefix
            }
            let desiredCount: Int
            if state.era == .rail {
            if counts.isEmpty {
                guard routes.isEmpty, sources.isEmpty else { throw LegalActionQueryError.invalidPrefix }
                guard let player = state.players.first(where: { $0.id == actorID }) else {
                    throw LegalActionQueryError.notActivePlayer
                }
                // 双铁路前置可行性：£15 且消耗 2 个连接片（啤酒可达性由后续步骤校验）。
                var choices = [choice("network-count:1", "1 条铁路", .networkLinkCount(1))]
                if player.cash >= 15, player.linksRemaining >= 2 {
                    choices.append(choice("network-count:2", "2 条铁路", .networkLinkCount(2)))
                }
                guard choices.isEmpty == false else { throw LegalActionQueryError.invalidPrefix }
                return (choices, nil)
            }
                guard counts.count == 1, [1, 2].contains(counts[0]) else {
                    throw LegalActionQueryError.invalidPrefix
                }
                desiredCount = counts[0]
            } else {
                guard counts.isEmpty else { throw LegalActionQueryError.invalidPrefix }
                desiredCount = 1
            }
            guard routes.count <= desiredCount else { throw LegalActionQueryError.invalidPrefix }

            var candidate = state
            let coalSources = state.era == .rail ? Array(sources.prefix(routes.count)) : []
            guard state.era == .rail || sources.isEmpty else { throw LegalActionQueryError.invalidPrefix }
            let committedRouteCount = state.era == .rail ? coalSources.count : routes.count
            for index in 0..<committedRouteCount {
                let routeID = routes[index]
                guard TopologyRules.legalNetworkRoutes(
                    playerID: actorID, state: candidate, board: catalog.catalog.board
                ).contains(routeID) else { throw LegalActionQueryError.invalidPrefix }
                // 与 NetworkRules.validate 同序：先落线，再在新拓扑上找该线的煤源
                //（RULES.md §8.1“放置完成后必须连通煤源”）。
                candidate.placedLinks.append(.init(routeID: routeID, ownerID: actorID, era: state.era))
                guard state.era == .rail else { continue }
                guard let route = catalog.catalog.board.routes.first(where: { $0.id == routeID }),
                      let location = route.adjacentLocationIDs.first(where: {
                          GameRulesEngine.legalResourceSources(
                            resource: .coal, consumerLocationID: $0, context: .network,
                            state: candidate, catalog: catalog
                          ).contains(coalSources[index])
                      }) else { throw LegalActionQueryError.invalidPrefix }
                let request = ResourceRequest(
                    resource: .coal, consumerLocationID: location,
                    context: .network, source: coalSources[index]
                )
                guard (try? ResourceRules.consumeValidatedRequests(
                    [request], actorID: actorID, state: &candidate, catalog: catalog
                )) != nil else { throw LegalActionQueryError.invalidPrefix }
            }

            if state.era == .rail, coalSources.count < routes.count,
               coalSources.count + 1 == routes.count,
               let route = catalog.catalog.board.routes.first(where: { $0.id == routes.last }) {
                guard TopologyRules.legalNetworkRoutes(
                    playerID: actorID, state: candidate, board: catalog.catalog.board
                ).contains(route.id) else { throw LegalActionQueryError.invalidPrefix }
                // 待放线路先进入候选拓扑再找煤源，避免漏掉仅因这条线路才连通的来源。
                candidate.placedLinks.append(.init(routeID: route.id, ownerID: actorID, era: state.era))
                let options = uniqueSources(
                    .coal,
                    route.adjacentLocationIDs.flatMap {
                        GameRulesEngine.legalResourceSources(
                            resource: .coal, consumerLocationID: $0, context: .network,
                            state: candidate, catalog: catalog
                        )
                    },
                    actorID: actorID, state: candidate, catalog: catalog
                )
                guard options.isEmpty == false else { throw LegalActionQueryError.invalidPrefix }
                return (options, nil)
            }
            guard coalSources.count == routes.count || state.era == .canal else {
                throw LegalActionQueryError.invalidPrefix
            }
            if routes.count < desiredCount {
                let routeOptions = TopologyRules.legalNetworkRoutes(
                    playerID: actorID, state: candidate, board: catalog.catalog.board
                ).map { routeID -> GameCore.LegalChoice in
                    // 用起终点地名区分线路,避免按钮行出现无法分辨的同名选项。
                    let endpoints = catalog.catalog.board.routes
                        .first(where: { $0.id == routeID })?
                        .adjacentLocationIDs.map { locationLabel($0) } ?? []
                    let label = endpoints.isEmpty
                        ? "可建线路"
                        : "可建线路 · " + endpoints.joined(separator: "–")
                    return choice("route:\(routeID)", label, .route(id: routeID))
                }
                guard routeOptions.isEmpty == false else { throw LegalActionQueryError.invalidPrefix }
                return (routeOptions, nil)
            }
            if state.era == .canal || desiredCount == 1 {
                return try complete(.network(.init(
                    cardID: cardID, routeIDs: routes,
                    coalSources: state.era == .rail ? coalSources : [], beerSource: nil
                )), actorID: actorID, state: state, catalog: catalog)
            }
            let beerSources = Array(sources.dropFirst(desiredCount))
            if beerSources.isEmpty, let route = catalog.catalog.board.routes.first(where: { $0.id == routes[1] }) {
                let options = uniqueSources(
                    .beer,
                    route.adjacentLocationIDs.flatMap {
                        GameRulesEngine.legalResourceSources(
                            resource: .beer, consumerLocationID: $0, context: .network,
                            state: candidate, catalog: catalog
                        )
                    }.filter { if case .merchantBeer = $0 { false } else { true } },
                    actorID: actorID, state: candidate, catalog: catalog
                )
                guard options.isEmpty == false else { throw LegalActionQueryError.invalidPrefix }
                return (options, nil)
            }
            guard beerSources.count == 1 else { throw LegalActionQueryError.invalidPrefix }
            return try complete(.network(.init(
                cardID: cardID, routeIDs: routes,
                coalSources: coalSources, beerSource: beerSources[0]
            )), actorID: actorID, state: state, catalog: catalog)
        }

        private static func develop(
            _ draft: LegalActionDraft, actorID: PlayerID,
            state: GameState, catalog: VerifiedGameDataCatalog
        ) throws -> ([LegalChoice], PlayerIntent.Payload?) {
            let cardID = try requiredCardID(in: draft)
            if let first = draft.selections.first {
                guard case .developTileCount(let count) = first, [1, 2].contains(count),
                      draft.selections.count <= 1 + count * 2
                else { throw LegalActionQueryError.invalidPrefix }
                for (index, value) in draft.selections.dropFirst().enumerated() {
                    if index.isMultiple(of: 2) {
                        guard case .industryTile = value else { throw LegalActionQueryError.invalidPrefix }
                    } else {
                        guard case .resourceSource = value else { throw LegalActionQueryError.invalidPrefix }
                    }
                }
            }
            let counts = draft.selections.compactMap { if case .developTileCount(let value) = $0 { value } else { nil } }
            let tileIDs = draft.selections.compactMap { if case .industryTile(let id) = $0 { id } else { nil } }
            let sources = draft.selections.compactMap { if case .resourceSource(let value) = $0 { value } else { nil } }
            guard counts.count + tileIDs.count + sources.count == draft.selections.count else {
                throw LegalActionQueryError.invalidPrefix
            }
            if counts.isEmpty {
                guard tileIDs.isEmpty, sources.isEmpty else { throw LegalActionQueryError.invalidPrefix }
                return ([
                    choice("develop-count:1", "发展 1 块", .developTileCount(1)),
                    choice("develop-count:2", "发展 2 块", .developTileCount(2)),
                ], nil)
            }
            guard counts.count == 1, [1, 2].contains(counts[0]),
                  tileIDs.count <= counts[0], sources.count <= tileIDs.count else {
                throw LegalActionQueryError.invalidPrefix
            }
            let desiredCount = counts[0]
            var candidate = state
            for index in tileIDs.indices {
                guard let playerIndex = candidate.players.firstIndex(where: { $0.id == actorID }),
                      let stackIndex = candidate.players[playerIndex].industryStacks.firstIndex(where: {
                          $0.tiles.first?.id == tileIDs[index]
                      }),
                      let tile = candidate.players[playerIndex].industryStacks[stackIndex].tiles.first,
                      catalog.catalog.industries.first(where: { $0.id == tile.industryDefinitionID })?
                        .levels.first(where: { $0.level == tile.level })?.canDevelop == true
                else { throw LegalActionQueryError.invalidPrefix }
                guard index < sources.count else { break }
                let request = ResourceRequest(
                    resource: .iron, consumerLocationID: "",
                    context: .standard, source: sources[index]
                )
                guard (try? ResourceRules.consumeValidatedRequests(
                    [request], actorID: actorID, state: &candidate, catalog: catalog
                )) != nil else { throw LegalActionQueryError.invalidPrefix }
                candidate.players[playerIndex].industryStacks[stackIndex].tiles.removeFirst()
            }
            if sources.count < tileIDs.count {
                // 用 candidate 的现金:前一块付费铁已在 candidate 上扣除。
                guard let developingPlayer = candidate.players.first(where: { $0.id == actorID }) else {
                    throw LegalActionQueryError.notActivePlayer
                }
                // 铁来源选项按当前现金过滤，买不起的市场/无限供应来源不提供。
                let options = GameRulesEngine.legalResourceSources(
                    resource: .iron, consumerLocationID: "", context: .standard,
                    state: candidate, catalog: catalog
                ).filter { source in
                    switch source {
                    case .marketSlot(_, let index):
                        return candidate.ironMarket.slots.indices.contains(index)
                            && developingPlayer.cash >= candidate.ironMarket.slots[index].price
                    case .unlimitedMarket(_, let price):
                        return developingPlayer.cash >= price
                    case .industry, .merchantBeer:
                        return true
                    }
                }
                guard options.isEmpty == false else { throw LegalActionQueryError.invalidPrefix }
                return (options.map { sourceChoice(.iron, $0, actorID: actorID, state: candidate, catalog: catalog) }, nil)
            }
            if tileIDs.count < desiredCount {
                guard let current = candidate.players.first(where: { $0.id == actorID }) else {
                    throw LegalActionQueryError.notActivePlayer
                }
                return (current.industryStacks.compactMap(\.tiles.first).filter { tile in
                    catalog.catalog.industries.first(where: { $0.id == tile.industryDefinitionID })?
                        .levels.first(where: { $0.level == tile.level })?.canDevelop == true
                }.map { choice("tile:\($0.id)", industryLabel($0.industryDefinitionID), .industryTile(id: $0.id)) }, nil)
            }
            return try complete(.develop(.init(
                cardID: cardID, tileIDs: tileIDs, ironSources: sources
            )), actorID: actorID, state: state, catalog: catalog)
        }

        private static func sell(
            _ draft: LegalActionDraft, actorID: PlayerID,
            state: GameState, catalog: VerifiedGameDataCatalog
        ) throws -> ([LegalChoice], PlayerIntent.Payload?) {
            let cardID = try requiredCardID(in: draft)
            var cursor = 0
            var completedSales: [SellSelection] = []
            var candidate = state
            while true {
                guard cursor < draft.selections.count else {
                    return (sellablePlacements(actorID: actorID, state: candidate, catalog: catalog).map {
                        choice("placement:\($0.placementID)", "\(locationLabel($0.locationID)) · \(industryLabel($0.tile.industryDefinitionID))",
                               .industryPlacement(id: $0.placementID))
                    }, nil)
                }
                guard case .industryPlacement(let placementID) = draft.selections[cursor],
                      let placement = candidate.boardIndustryPlacements.first(where: {
                          $0.placementID == placementID && $0.ownerID == actorID && !$0.isFlipped
                      }),
                      sellablePlacements(actorID: actorID, state: candidate, catalog: catalog)
                        .contains(where: { $0.placementID == placementID })
                else { throw LegalActionQueryError.invalidPrefix }
                cursor += 1

                if cursor == draft.selections.count {
                    return (legalMerchants(for: placement, state: candidate, catalog: catalog).compactMap {
                        merchant in
                        guard let label = merchantLabel(merchant, catalog: catalog) else { return nil }
                        return choice(
                            "merchant:\(merchant.slotID)", label, .merchant(id: merchant.slotID)
                        )
                    }, nil)
                }
                guard case .merchant(let merchantID) = draft.selections[cursor],
                      legalMerchants(for: placement, state: candidate, catalog: catalog)
                        .contains(where: { $0.slotID == merchantID }),
                      let level = catalog.catalog.industries.first(where: {
                          $0.id == placement.tile.industryDefinitionID
                      })?.levels.first(where: { $0.level == placement.tile.level })
                else { throw LegalActionQueryError.invalidPrefix }
                cursor += 1

                var beerSources: [ResourceSource] = []
                var resourceCandidate = candidate
                while beerSources.count < level.beerCost {
                    if cursor == draft.selections.count {
                        let options = GameRulesEngine.legalResourceSources(
                            resource: .beer, consumerLocationID: placement.locationID,
                            context: .selling(merchantSlotID: merchantID),
                            state: resourceCandidate, catalog: catalog
                        ).map { sourceChoice(.beer, $0, actorID: actorID, state: resourceCandidate, catalog: catalog) }
                        guard options.isEmpty == false else { throw LegalActionQueryError.invalidPrefix }
                        return (options, nil)
                    }
                    guard case .resourceSource(let source) = draft.selections[cursor] else {
                        throw LegalActionQueryError.invalidPrefix
                    }
                    let request = ResourceRequest(
                        resource: .beer, consumerLocationID: placement.locationID,
                        context: .selling(merchantSlotID: merchantID), source: source
                    )
                    guard (try? ResourceRules.consumeValidatedRequests(
                        [request], actorID: actorID, state: &resourceCandidate, catalog: catalog
                    )) != nil else { throw LegalActionQueryError.invalidPrefix }
                    beerSources.append(source)
                    cursor += 1
                }

                let usedMerchantBeer = beerSources.contains {
                    if case .merchantBeer(let slotID) = $0 { slotID == merchantID } else { false }
                }
                let merchantBonus = catalog.catalog.board.merchantSlots.first(where: { $0.id == merchantID })?.bonus
                var bonusTileID: String?
                if usedMerchantBeer, merchantBonus?.kind == .develop {
                    if cursor == draft.selections.count {
                        guard let player = resourceCandidate.players.first(where: { $0.id == actorID }) else {
                            throw LegalActionQueryError.notActivePlayer
                        }
                        return (player.industryStacks.compactMap(\.tiles.first).filter { tile in
                            catalog.catalog.industries.first(where: { $0.id == tile.industryDefinitionID })?
                                .levels.first(where: { $0.level == tile.level })?.canDevelop == true
                        }.map { choice("bonus-tile:\($0.id)", industryLabel($0.industryDefinitionID),
                                       .industryTile(id: $0.id)) }, nil)
                    }
                    guard case .industryTile(let tileID) = draft.selections[cursor] else {
                        throw LegalActionQueryError.invalidPrefix
                    }
                    bonusTileID = tileID
                    cursor += 1
                }

                let sale = SellSelection(
                    industryPlacementID: placementID, merchantSlotID: merchantID,
                    beerSources: beerSources, bonusDevelopTileID: bonusTileID
                )
                let proposed = completedSales + [sale]
                guard let target = try? SellRules.validate(
                    .init(cardID: cardID, sales: proposed), actorID: actorID,
                    state: state, catalog: catalog
                ) else { throw LegalActionQueryError.invalidPrefix }

                if cursor == draft.selections.count {
                    var afterSale = state
                    guard (try? SellRules.apply(target, state: &afterSale, catalog: catalog)) != nil else {
                        throw LegalActionQueryError.invalidPrefix
                    }
                    let remaining = sellablePlacements(actorID: actorID, state: afterSale, catalog: catalog)
                    // 引导多笔出售:继续卖放首位并标明剩余可卖数,避免误以为只能卖一笔。
                    if remaining.isEmpty {
                        return ([choice("sell:finish", "结束出售（已选\(proposed.count)笔）",
                                        .sellDisposition(continueSelling: false))], nil)
                    }
                    return ([
                        choice("sell:continue", "继续出售（还可卖\(remaining.count)处）",
                               .sellDisposition(continueSelling: true)),
                        choice("sell:finish", "结束出售（已选\(proposed.count)笔）",
                               .sellDisposition(continueSelling: false)),
                    ], nil)
                }
                guard case .sellDisposition(let continueSelling) = draft.selections[cursor] else {
                    throw LegalActionQueryError.invalidPrefix
                }
                cursor += 1
                if continueSelling == false {
                    guard cursor == draft.selections.count else { throw LegalActionQueryError.invalidPrefix }
                    return try complete(.sell(.init(cardID: cardID, sales: proposed)),
                                        actorID: actorID, state: state, catalog: catalog)
                }
                completedSales = proposed
                candidate = state
                guard (try? SellRules.apply(target, state: &candidate, catalog: catalog)) != nil else {
                    throw LegalActionQueryError.invalidPrefix
                }
            }
        }

        private static func scout(
            _ draft: LegalActionDraft, actorID: PlayerID,
            state: GameState, catalog: VerifiedGameDataCatalog
        ) throws -> ([LegalChoice], PlayerIntent.Payload?) {
            let cardID = try requiredCardID(in: draft)
            guard let player = state.players.first(where: { $0.id == actorID }) else {
                throw LegalActionQueryError.notActivePlayer
            }
            // 手持任意万能牌时不能侦察(RULES.md §7.6),入口即拒绝而非走完选择再失败。
            let definitions = Dictionary(uniqueKeysWithValues: catalog.catalog.cards.map { ($0.id, $0) })
            if player.hand.contains(where: { card in
                let kind = definitions[card.definitionID]?.kind
                return kind == .wildLocation || kind == .wildIndustry
            }) {
                throw LegalActionQueryError.invalidPrefix
            }
            let selected = draft.selections.compactMap { if case .card(let id) = $0 { id } else { nil } }
            guard selected.count == draft.selections.count else { throw LegalActionQueryError.invalidPrefix }
            if selected.count < 2 {
                return (player.hand.filter { $0.id != cardID && !selected.contains($0.id) }.map {
                    choice("card:\($0.id)", cardLabel($0.definitionID), .card(id: $0.id))
                }, nil)
            }
            guard selected.count == 2 else { throw LegalActionQueryError.invalidPrefix }
            return try complete(.scout(.init(cardIDs: [cardID] + selected)),
                                actorID: actorID, state: state, catalog: catalog)
        }

        private static func requiredCardID(in draft: LegalActionDraft) throws -> String {
            guard let cardID = draft.cardID else { throw LegalActionQueryError.invalidCard }
            return cardID
        }

        private static func sellablePlacements(
            actorID: PlayerID, state: GameState, catalog: VerifiedGameDataCatalog
        ) -> [BoardIndustryPlacement] {
            state.boardIndustryPlacements.filter { placement in
                placement.ownerID == actorID && !placement.isFlipped
                    && ["cotton-mill", "manufacturer", "pottery"]
                        .contains(placement.tile.industryDefinitionID)
                    && legalMerchants(for: placement, state: state, catalog: catalog).isEmpty == false
            }
        }

        private static func legalMerchants(
            for placement: BoardIndustryPlacement,
            state: GameState,
            catalog: VerifiedGameDataCatalog
        ) -> [MerchantPlacement] {
            state.merchants.filter { merchant in
                guard let slot = catalog.catalog.board.merchantSlots.first(where: {
                          $0.id == merchant.slotID && $0.playerCounts.contains(state.playerCount)
                      }), let definition = catalog.catalog.merchants.first(where: {
                          $0.id == merchant.merchantDefinitionID && $0.playerCounts.contains(state.playerCount)
                      }), definition.acceptedIndustryIDs.contains(placement.tile.industryDefinitionID)
                else { return false }
                return TopologyRules.hasRoute(
                    from: placement.locationID, to: slot.locationID,
                    state: state, board: catalog.catalog.board
                )
            }
        }

        private static func complete(
            _ payload: PlayerIntent.Payload, actorID: PlayerID,
            state: GameState, catalog: VerifiedGameDataCatalog
        ) throws -> ([LegalChoice], PlayerIntent.Payload?) {
            // 注意:此处验证是承重的(如运河时代 network 分支组装后仅靠这里把关现金),
            // fastPath 也不可跳过;fastPath 只允许跳过纯派生数据(confirmation/摘要)。
            let valid: Bool = switch payload {
            case .build(let intent): (try? BuildRules.validate(intent, actorID: actorID, state: state, catalog: catalog)) != nil
            case .network(let intent): (try? NetworkRules.validate(intent, actorID: actorID, state: state, catalog: catalog)) != nil
            case .develop(let intent): (try? DevelopRules.validate(intent, actorID: actorID, state: state, catalog: catalog)) != nil
            case .sell(let intent): (try? SellRules.validate(intent, actorID: actorID, state: state, catalog: catalog)) != nil
            case .loan(let intent): (try? SimpleActionRules.validateLoan(intent, actorID: actorID, state: state, catalog: catalog)) != nil
            case .scout(let intent): (try? SimpleActionRules.validateScout(intent, actorID: actorID, state: state, catalog: catalog)) != nil
            case .pass(let intent): (try? SimpleActionRules.validatePass(intent, actorID: actorID, state: state, catalog: catalog)) != nil
            case .forcedSale(let intent):
                (try? TurnRules.validateForcedSale(
                    intent, actorID: actorID, state: state, catalog: catalog
                )) != nil
            case .confirmEraIntermission:
                (try? SimpleActionRules.validateEraConfirmation(
                    actorID: actorID, state: state, catalog: catalog
                )) != nil
            case .confirmTurnEnd:
                (try? SimpleActionRules.validateTurnEndConfirmation(
                    actorID: actorID, state: state, catalog: catalog
                )) != nil
            case .retractTurnActions:
                false
            }
            guard valid else { throw LegalActionQueryError.invalidPrefix }
            return ([], payload)
        }

        private static func confirmation(
            payload: PlayerIntent.Payload, actorID: PlayerID,
            state: GameState, catalog: VerifiedGameDataCatalog
        ) -> ConfirmationDelta? {
            guard let before = state.players.first(where: { $0.id == actorID }) else { return nil }
            var candidate = state
            let event: AuthoritativeGameEvent
            do {
                switch payload {
                case .build(let intent):
                    let target = try BuildRules.validate(intent, actorID: actorID, state: candidate, catalog: catalog)
                    event = try GameRulesEngine.resolveBuild(
                        target, roomID: .init(rawValue: "legal-query-dry-run"),
                        state: &candidate, catalog: catalog
                    )
                case .network(let intent):
                    let target = try NetworkRules.validate(intent, actorID: actorID, state: candidate, catalog: catalog)
                    event = try GameRulesEngine.resolveNetwork(
                        target, roomID: .init(rawValue: "legal-query-dry-run"),
                        state: &candidate, catalog: catalog
                    )
                case .develop(let intent):
                    let target = try DevelopRules.validate(intent, actorID: actorID, state: candidate, catalog: catalog)
                    event = try GameRulesEngine.resolveDevelop(
                        target, roomID: .init(rawValue: "legal-query-dry-run"),
                        state: &candidate, catalog: catalog
                    )
                case .sell(let intent):
                    let target = try SellRules.validate(intent, actorID: actorID, state: candidate, catalog: catalog)
                    event = try GameRulesEngine.resolveSell(
                        target, roomID: .init(rawValue: "legal-query-dry-run"),
                        state: &candidate, catalog: catalog
                    )
                case .loan(let intent):
                    let target = try SimpleActionRules.validateLoan(intent, actorID: actorID, state: candidate, catalog: catalog)
                    event = try GameRulesEngine.resolveLoan(
                        target, roomID: .init(rawValue: "legal-query-dry-run"),
                        state: &candidate, catalog: catalog
                    )
                case .scout(let intent):
                    let target = try SimpleActionRules.validateScout(intent, actorID: actorID, state: candidate, catalog: catalog)
                    event = try GameRulesEngine.resolveScout(
                        target, roomID: .init(rawValue: "legal-query-dry-run"),
                        state: &candidate, catalog: catalog
                    )
                case .pass(let intent):
                    let target = try SimpleActionRules.validatePass(intent, actorID: actorID, state: candidate, catalog: catalog)
                    event = try GameRulesEngine.resolvePass(
                        target, roomID: .init(rawValue: "legal-query-dry-run"),
                        state: &candidate, catalog: catalog
                    )
                case .forcedSale(let intent):
                    event = try GameRulesEngine.resolveForcedSale(
                        intent, actorID: actorID,
                        roomID: .init(rawValue: "legal-query-dry-run"),
                        state: &candidate, catalog: catalog
                    )
                case .confirmEraIntermission, .confirmTurnEnd, .retractTurnActions:
                    return nil
                }
            } catch { return nil }
            guard let after = candidate.players.first(where: { $0.id == actorID }) else { return nil }
            let effects: [ResourceEffect] = switch event.payload {
            case .built(_, _, let value), .networkBuilt(_, _, let value),
                 .developed(_, _, let value), .sold(_, _, let value): value
            case .passed, .loanTaken, .scouted, .forcedSaleResolved, .eraIntermissionConfirmed,
                 .turnEndConfirmed, .turnActionsRetracted: []
            }
            return .init(
                cashDelta: after.cash - before.cash,
                incomeDelta: after.incomePosition - before.incomePosition,
                victoryPointDelta: after.victoryPoints - before.victoryPoints,
                resourceEffects: effects
            )
        }

        private static func choice(_ id: String, _ label: String, _ value: LegalChoiceValue) -> LegalChoice {
            .init(id: id, label: label, value: value)
        }

        private static func sourceChoice(_ resource: ResourceKind, _ source: ResourceSource) -> LegalChoice {
            choice("source:\(resource.rawValue):\(stableSourceID(source))", stableSourceLabel(source), .resourceSource(source))
        }

        /// 带上下文的来源标签:标明自家/对手、产业类型与地名,
        /// 让“用自家酒厂/对手煤矿”这类选择一眼可辨。
        private static func sourceChoice(
            _ resource: ResourceKind,
            _ source: ResourceSource,
            actorID: PlayerID,
            state: GameState,
            catalog: VerifiedGameDataCatalog
        ) -> LegalChoice {
            choice(
                "source:\(resource.rawValue):\(stableSourceID(source))",
                detailedSourceLabel(source, actorID: actorID, state: state, catalog: catalog),
                .resourceSource(source)
            )
        }

        private static func detailedSourceLabel(
            _ source: ResourceSource,
            actorID: PlayerID,
            state: GameState,
            catalog: VerifiedGameDataCatalog
        ) -> String {
            switch source {
            case .industry(let placementID):
                guard let placement = state.boardIndustryPlacements.first(where: {
                    $0.placementID == placementID
                }) else { return stableSourceLabel(source) }
                let owner = placement.ownerID == actorID ? "自家" : "对手"
                return "\(owner)\(industryLabel(placement.tile.industryDefinitionID)) · \(locationLabel(placement.locationID))"
            case .merchantBeer(let slotID):
                let location = catalog.catalog.board.merchantSlots.first(where: { $0.id == slotID })?.locationID
                return "商人啤酒 · \(location.map { locationLabel($0) } ?? slotID)"
            default:
                return stableSourceLabel(source)
            }
        }

        private static func stableSourceID(_ source: ResourceSource) -> String {
            switch source {
            case .industry(let placementID): "industry:\(placementID)"
            case .marketSlot(let resource, let index): "market:\(resource.rawValue):\(index)"
            case .unlimitedMarket(let resource, let price): "unlimited:\(resource.rawValue):\(price)"
            case .merchantBeer(let slotID): "merchant-beer:\(slotID)"
            }
        }

        private static func stableSourceLabel(_ source: ResourceSource) -> String {
            switch source {
            case .industry: "地图产业资源"
            case .marketSlot(let resource, let index): "\(resourceLabel(resource))市场第 \(index + 1) 格"
            case .unlimitedMarket(let resource, let price): "\(resourceLabel(resource))市场 £\(price)"
            case .merchantBeer: "商人啤酒"
            }
        }

        private static func resourceLabel(_ resource: ResourceKind) -> String {
            switch resource { case .coal: "煤炭"; case .iron: "钢铁"; case .beer: "啤酒" }
        }

        private static func industryLabel(_ id: String) -> String {
            switch id {
            case "cotton-mill": "棉纺厂"
            case "manufacturer": "制造厂"
            case "pottery": "陶瓷厂"
            case "coal-mine": "煤矿"
            case "iron-works": "炼铁厂"
            case "brewery": "啤酒厂"
            default: "产业"
            }
        }

        private static func locationLabel(_ id: String) -> String {
            BoardPresentationCatalog.standard.locations.first(where: { $0.id == id })?.name ?? "地点"
        }

        private static func merchantLabel(
            _ merchant: MerchantPlacement,
            catalog: VerifiedGameDataCatalog
        ) -> String? {
            guard let slot = catalog.catalog.board.merchantSlots.first(where: {
                $0.id == merchant.slotID
            }), let definition = catalog.catalog.merchants.first(where: {
                $0.id == merchant.merchantDefinitionID
            }) else { return nil }
            let prefix = "\(locationLabel(slot.locationID)) · \(merchantAcceptanceLabel(definition.acceptedIndustryIDs))"
            let bonus = merchantBonusLabel(slot.bonus)
            if merchant.hasBeer {
                return "\(prefix) · \(bonus)"
            }
            return "\(prefix) · 啤酒已用尽 · \(bonus)（不可用）"
        }

        private static func merchantAcceptanceLabel(_ industryIDs: [String]) -> String {
            let accepted = Set(industryIDs)
            if accepted == ["cotton-mill", "manufacturer", "pottery"] {
                return "任意制成品"
            }
            if industryIDs.count == 1, let industryID = industryIDs.first {
                return industryLabel(industryID)
            }
            return industryIDs.isEmpty ? "空白" : industryIDs.map(industryLabel).joined(separator: "／")
        }

        private static func merchantBonusLabel(_ bonus: BoardDefinition.MerchantSlot.Bonus) -> String {
            switch bonus.kind {
            case .develop: "开发 \(bonus.amount)"
            case .income: "收入轨 +\(bonus.amount) 格"
            case .money: "£\(bonus.amount)"
            case .victoryPoints: "胜利点 +\(bonus.amount)"
            }
        }

        private static func cardLabel(_ definitionID: String) -> String {
            RealMatchViewModel.cardTitle(definitionID)
        }

        private static func uniqueSources(
            _ resource: ResourceKind,
            _ sources: [ResourceSource],
            actorID: PlayerID,
            state: GameState,
            catalog: VerifiedGameDataCatalog
        ) -> [LegalChoice] {
            var seen: Set<ResourceSource> = []
            return sources.filter { seen.insert($0).inserted }.map {
                sourceChoice(resource, $0, actorID: actorID, state: state, catalog: catalog)
            }
        }
    }
}
