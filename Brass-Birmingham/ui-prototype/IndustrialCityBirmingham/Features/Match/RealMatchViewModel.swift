import Foundation

nonisolated enum RealMatchViewModel {
    static func make(
        snapshot: GameCore.ViewSnapshot,
        hostPlayerID: GameCore.PlayerID,
        catalog: GameCore.VerifiedGameDataCatalog? = nil
    ) throws -> DemoMatchState {
        guard let match = snapshot.match else { throw Error.missingProjection }
        let board = try catalog?.catalog.board ?? bundledBoard()
        let merchantDefinitions = try catalog?.catalog.merchants ?? bundledMerchants()
        _ = try BoardPresentationCatalog.standard.validate(board: board)
        let merchantsByLocation = try projectedMerchantsByLocation(
            match.merchants,
            board: board,
            definitions: merchantDefinitions
        )
        let local = match.players.first(where: { $0.id == snapshot.recipient })
        return DemoMatchState(
            era: match.era == .canal ? "运河时代" : "铁路时代",
            round: match.roundNumber,
            roundCount: max(0, 12 - match.players.count),
            actionNumber: snapshot.actionNumber,
            deckRemaining: match.deckCount,
            money: local?.cash ?? 0,
            income: local?.incomeLevel ?? 0,
            victoryPoints: local?.victoryPoints ?? 0,
            players: match.players.enumerated().map { index, player in
                PlayerSummary(
                    id: player.id.rawValue,
                    name: player.name ?? player.id.rawValue,
                    color: color(player.color),
                    order: index + 1,
                    spent: player.spent,
                    isCurrent: snapshot.activePlayerID == player.id,
                    isHost: hostPlayerID == player.id,
                    isReady: true,
                    isConnected: true,
                    cash: player.cash,
                    incomeLevel: player.incomeLevel,
                    victoryPoints: player.victoryPoints
                )
            },
            industries: (local?.industryStacks ?? []).compactMap { stack in
                guard let tile = stack.tiles.first,
                      let kind = industryKind(stack.industryDefinitionID) else { return nil }
                guard let level = catalog?.catalog.industries.first(where: {
                    $0.id == stack.industryDefinitionID
                })?.levels.first(where: { $0.level == tile.level }) else { return nil }
                return IndustrySummary(
                    id: tile.id, kind: kind, level: tile.level,
                    cost: level.buildCost, coalCost: level.coalCost,
                    ironCost: level.ironCost, isAvailable: true,
                    remainingTotal: stack.tiles.count,
                    remainingLowest: stack.tiles.filter { $0.level == tile.level }.count,
                    victoryPoints: level.victoryPoints,
                    linkPoints: level.linkPoints
                )
            },
            coalMarket: market(match.coalMarket),
            ironMarket: market(match.ironMarket),
            hand: match.ownHand.map { card in
                HandCard(
                    id: card.id, title: cardTitle(card.definitionID),
                    kind: cardKind(card.definitionID),
                    allowedActions: Set((match.availableActionsByCardID?[card.id] ?? []).compactMap {
                        GameAction(rawValue: $0.rawValue)
                    })
                )
            },
            locations: BoardPresentationCatalog.standard.locations.map { location in
                var presented = location
                // 槽位层:来自权威地图数据,空槽可见"能修什么",占用按 slotIndex 对齐。
                if let boardLocation = board.locations.first(where: { $0.id == location.id }) {
                    presented.slots = boardLocation.industrySlots.enumerated().map { index, slot in
                        MapLocationSlot(index: index, allowedKinds: slot.compactMap { industryKind($0) })
                    }
                }
                presented.industryPlacements = match.boardIndustryPlacements
                    .filter { $0.locationID == location.id }
                    .compactMap { placement in
                        guard let kind = industryKind(placement.tile.industryDefinitionID),
                              let owner = match.players.first(where: { $0.id == placement.ownerID })
                        else { return nil }
                        // 翻面结算展示值:该板块等级的 VP 与路分(来自已校验目录)。
                        let levelInfo = catalog?.catalog.industries.first(where: {
                            $0.id == placement.tile.industryDefinitionID
                        })?.levels.first(where: { $0.level == placement.tile.level })
                        return .init(
                            placementID: placement.placementID,
                            ownerID: placement.ownerID.rawValue,
                            tileID: placement.tile.id,
                            kind: kind,
                            level: placement.tile.level,
                            resourceCount: placement.resourceCount,
                            isFlipped: placement.isFlipped,
                            ownerColor: color(owner.color),
                            slotIndex: placement.slotIndex,
                            victoryPoints: levelInfo?.victoryPoints ?? 0,
                            linkPoints: levelInfo?.linkPoints ?? 0
                        )
                    }
                presented.merchantPlacements = merchantsByLocation[location.id] ?? []
                return presented
            },
            routes: try BoardPresentationCatalog.standard.routes(for: board).map { route in
                var presented = route
                if let link = match.placedLinks.first(where: { $0.routeID == route.id }),
                   let owner = match.players.first(where: { $0.id == link.ownerID }) {
                    presented.placedLink = .init(
                        ownerID: link.ownerID.rawValue,
                        ownerColor: color(owner.color),
                        era: link.era == .canal ? .canal : .rail
                    )
                }
                return presented
            }
        )
    }

    private static func bundledBoard() throws -> GameCore.BoardDefinition {
        guard let url = Bundle.main.url(forResource: "map", withExtension: "json") else {
            throw Error.missingBoard
        }
        return try JSONDecoder().decode(GameCore.BoardDefinition.self, from: Data(contentsOf: url))
    }

    private static func bundledMerchants() throws -> [GameCore.MerchantDefinition] {
        guard let url = Bundle.main.url(forResource: "merchants", withExtension: "json") else {
            throw Error.missingMerchants
        }
        return try JSONDecoder().decode(
            [GameCore.MerchantDefinition].self,
            from: Data(contentsOf: url)
        )
    }

    static func projectedMerchantsByLocation(
        _ placements: [GameCore.MerchantPlacement],
        board: GameCore.BoardDefinition,
        definitions: [GameCore.MerchantDefinition]
    ) throws -> [String: [MapMerchantPlacement]] {
        let presentedLocationIDs = Set(BoardPresentationCatalog.standard.locations.map(\.id))
        var result: [String: [MapMerchantPlacement]] = [:]
        for placement in placements {
            guard let slot = board.merchantSlots.first(where: { $0.id == placement.slotID }) else {
                throw Error.unknownMerchantSlot(placement.slotID)
            }
            guard presentedLocationIDs.contains(slot.locationID) else {
                throw Error.unpresentedMerchantLocation(slot.locationID)
            }
            guard let definition = definitions.first(where: {
                $0.id == placement.merchantDefinitionID
            }) else {
                throw Error.unknownMerchantDefinition(placement.merchantDefinitionID)
            }
            let acceptedIndustries = try definition.acceptedIndustryIDs.map { id in
                guard let kind = merchantIndustryKind(id) else {
                    throw Error.unsupportedMerchantIndustry(id)
                }
                return kind
            }
            result[slot.locationID, default: []].append(.init(
                slotID: placement.slotID,
                acceptedIndustries: acceptedIndustries,
                hasBeer: placement.hasBeer,
                bonusKind: merchantBonusKind(slot.bonus.kind),
                bonusAmount: slot.bonus.amount
            ))
        }
        return result
    }

    private static func merchantIndustryKind(_ id: String) -> IndustryKind? {
        switch id {
        case "cotton-mill": .cotton
        case "manufacturer": .manufacturer
        case "pottery": .pottery
        default: nil
        }
    }

    private static func merchantBonusKind(
        _ kind: GameCore.BoardDefinition.MerchantSlot.Bonus.Kind
    ) -> MerchantBonusKind {
        switch kind {
        case .develop: .develop
        case .income: .income
        case .money: .money
        case .victoryPoints: .victoryPoints
        }
    }

    private static func market(_ market: GameCore.ResourceMarket) -> MarketSummary {
        // 阶梯展示整条价格轨(含空格):煤 £8、铁 £6 是"无限供应"格,
        // 空着也要显示出来;市场被买空后最低价回退到无限价,而不是 £0。
        // occupancy 记录每格真实占用:买走便宜格后,剩余方块向高价端(右)收缩。
        let unlimitedPrice: Int = market.resource == .coal ? 8 : 6
        let occupied = market.slots.filter(\.hasCube).map(\.price).sorted()
        return .init(
            remaining: occupied.count,
            cheapestPrice: occupied.first ?? unlimitedPrice,
            ladder: market.slots.map(\.price),
            occupancy: market.slots.map(\.hasCube)
        )
    }

    private static func color(_ value: GameCore.PlayerColor) -> PlayerColor {
        switch value {
        case .red: .crimson
        case .yellow: .amber
        case .blue: .teal
        case .purple: .violet
        }
    }

    static func industryTitle(_ id: String) -> String {
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

    private static func industryKind(_ id: String) -> IndustryKind? {
        switch id {
        case "cotton-mill": .cotton
        case "manufacturer": .manufacturer
        case "pottery": .pottery
        case "coal-mine": .coal
        case "iron-works": .iron
        case "brewery": .brewery
        default: nil
        }
    }

    private static func cardKind(_ definitionID: String) -> HandCardKind {
        if definitionID == "wild-location" { return .wildLocation }
        if definitionID == "wild-industry" { return .wildIndustry }
        if definitionID.hasPrefix("industry-") {
            let raw = String(definitionID.dropFirst("industry-".count))
            if raw.hasPrefix("brewery") { return .industry(.brewery) }
            if raw.hasPrefix("coal-mine") { return .industry(.coal) }
            if raw.hasPrefix("iron-works") { return .industry(.iron) }
            if raw.hasPrefix("pottery") { return .industry(.pottery) }
            if raw.hasPrefix("cotton-manufacturer") { return .industry(.cotton) }
        }
        return .location(definitionID)
    }

    static func cardTitle(_ definitionID: String) -> String {
        if definitionID == "wild-location" { return "地点万能牌" }
        if definitionID == "wild-industry" { return "产业万能牌" }
        if definitionID.hasPrefix("location-") {
            let raw = String(definitionID.dropFirst("location-".count))
            if let location = BoardPresentationCatalog.standard.locations
                .filter({ raw == $0.id || raw.hasPrefix("\($0.id)-") })
                .max(by: { $0.id.count < $1.id.count }) {
                return location.name + playerCountSuffix(raw.dropFirst(location.id.count))
            }
        }
        if definitionID.hasPrefix("industry-") {
            let raw = String(definitionID.dropFirst("industry-".count))
            let presentations: [(prefix: String, title: String)] = [
                ("cotton-manufacturer", "棉纺/制造厂"),
                ("coal-mine", "煤矿"),
                ("iron-works", "炼铁厂"),
                ("pottery", "陶瓷厂"),
                ("brewery", "啤酒厂"),
            ]
            if let presentation = presentations.first(where: {
                raw == $0.prefix || raw.hasPrefix("\($0.prefix)-")
            }) {
                return presentation.title + playerCountSuffix(raw.dropFirst(presentation.prefix.count))
            }
        }
        return "未知卡牌"
    }

    private static func playerCountSuffix(_ suffix: Substring) -> String {
        switch String(suffix) {
        case "": return ""
        case "-2-plus": return "（2人+）"
        case "-3-plus": return "（3人+）"
        case "-4": return "（4人）"
        default: return ""
        }
    }

    enum Error: Swift.Error, Equatable {
        case missingProjection
        case missingBoard
        case missingMerchants
        case unknownMerchantSlot(String)
        case unpresentedMerchantLocation(String)
        case unknownMerchantDefinition(String)
        case unsupportedMerchantIndustry(String)
    }
}
