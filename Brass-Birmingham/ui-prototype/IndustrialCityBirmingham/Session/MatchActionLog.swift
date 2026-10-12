import Foundation

/// 一条玩家行动日志。摘要文本在追加时生成;
/// 玩家名不在条目里,由展示层按当前昵称解析(支持改名后日志同步更新)。
nonisolated struct MatchActionLogEntry: Equatable, Sendable, Identifiable {
    /// 权威事件版本号,单调唯一,同时作为去重键。
    let version: Int
    var id: Int { version }
    let actorID: GameCore.PlayerID
    let roundNumber: Int
    let eraLabel: String
    let actionNumber: Int
    let summary: String
}

nonisolated enum MatchActionLog {
    static func makeEntry(
        event: GameCore.AuthoritativeGameEvent,
        era: GameCore.Era,
        roundNumber: Int,
        playerNames: [GameCore.PlayerID: String] = [:]
    ) -> MatchActionLogEntry {
        // 事件效果按 payload 类型挂载:建造/修路/开发/出售携带资源效果。
        let effects: [GameCore.ResourceEffect] = switch event.payload {
        case .built(_, _, let value), .networkBuilt(_, _, let value),
             .developed(_, _, let value), .sold(_, _, let value):
            value
        default:
            []
        }
        return MatchActionLogEntry(
            version: event.version.rawValue,
            actorID: event.actor,
            roundNumber: roundNumber,
            eraLabel: era == .canal ? "运河时代" : "铁路时代",
            actionNumber: event.actionNumber,
            summary: detailedSummary(
                for: event.payload,
                effects: effects,
                transitions: event.transitions,
                actorID: event.actor,
                playerNames: playerNames
            )
        )
    }

    private static func resourceLabel(_ resource: GameCore.ResourceKind) -> String {
        switch resource {
        case .coal: "煤"
        case .iron: "铁"
        case .beer: "啤酒"
        }
    }

    // MARK: - 详细摘要

    private static func detailedSummary(
        for payload: GameCore.AuthoritativeGameEvent.Payload,
        effects: [GameCore.ResourceEffect],
        transitions: [GameCore.GameTransitionEvent],
        actorID: GameCore.PlayerID,
        playerNames: [GameCore.PlayerID: String]
    ) -> String {
        var lines: [String] = []
        switch payload {
        case .built(_, let placement, _):
            var line = "在\(locationName(placement.locationID))建造\(industryName(placement.tile.industryDefinitionID)) L\(placement.tile.level)"
            if let cost = buildCost(placement.tile.industryDefinitionID, placement.tile.level) {
                line += "（花费 £\(cost)）"
            }
            lines.append(line)
            appendConsumed(&lines, effects: effects, actorID: actorID)
            appendDelivery(&lines, effects: effects, actorID: actorID)
            appendIncome(&lines, effects: effects, actorID: actorID)
            if effects.contains(where: {
                if case .industryFlipped(let id) = $0 { return id == placement.placementID }
                return false
            }) {
                if let vp = victoryPoints(placement.tile.industryDefinitionID, placement.tile.level) {
                    lines.append("资源采空立即翻面（时代结算 +\(vp) VP）")
                } else {
                    lines.append("板块翻面")
                }
            }
        case .networkBuilt(_, let links, _):
            let names = links.map { routeName($0.routeID) }
            lines.append(names.isEmpty
                ? "铺设铁路"
                : "铺设铁路：" + names.joined(separator: "、"))
            appendConsumed(&lines, effects: effects, actorID: actorID)
            appendBeer(&lines, effects: effects)
        case .developed(_, let tiles, _):
            let names = tiles.map { industryName($0.industryDefinitionID) }
            lines.append(names.isEmpty
                ? "开发（未移除板块）"
                : "开发：移除 " + names.joined(separator: "、"))
            appendConsumed(&lines, effects: effects, actorID: actorID)
        case .sold(let intent, _, _):
            let merchants = intent.sales.map { merchantLocationName($0.merchantSlotID) }
            lines.append(merchants.isEmpty
                ? "出售产业×\(intent.sales.count)"
                : "出售 \(intent.sales.count) 处产业 → " + merchants.joined(separator: "、"))
            appendIncome(&lines, effects: effects, actorID: actorID)
            appendBeer(&lines, effects: effects)
            appendBonuses(&lines, effects: effects, actorID: actorID)
            let flips = effects.filter {
                if case .industryFlipped = $0 { return true }
                return false
            }.count
            if flips > 0 { lines.append("板块翻面 ×\(flips)（时代结算计 VP）") }
        case .loanTaken(_, let previous, let current):
            let before = incomeLevel(previous).map { "£\($0)" } ?? "£?"
            let after = incomeLevel(current).map { "£\($0)" } ?? "£?"
            lines.append("贷款 £30 · 收入等级 \(before) → \(after)（后退 3 级）")
        case .scouted:
            lines.append("侦察：弃 3 张换 2 张万能牌")
        case .passed(let cardID):
            lines.append("跳过行动（弃 \(cardName(cardID))）")
        case .forcedSaleResolved(let intent):
            lines.append("强制出售 \(intent.placementIDs.count) 处产业补足欠款")
        case .eraIntermissionConfirmed(let playerID):
            let name = playerNames[playerID] ?? playerID.rawValue
            lines.append("确认了时代结算（\(name)）")
        case .turnEndConfirmed(let playerID):
            let name = playerNames[playerID] ?? playerID.rawValue
            lines.append("\(name) 确认结束回合，交给下一位")
        case .turnActionsRetracted(let playerID, _, let actionCount):
            let name = playerNames[playerID] ?? playerID.rawValue
            lines.append("\(name) 撤回了本回合的操作 ×\(actionCount)，回到回合开始")
        }

        for transition in transitions {
            switch transition {
            case .eraScored(let details):
                let parts = details.awards.map { award -> String in
                    let name = playerNames[award.playerID] ?? award.playerID.rawValue
                    return "\(name) +\(award.linkPoints + award.industryPoints)"
                }
                lines.append("\(details.era == .canal ? "运河" : "铁路")时代结算：" + parts.joined(separator: "、"))
            case .railPrepared(let details):
                lines.append("全员确认，进入铁路时代（撤下运河连线 · 移除一级产业 \(details.removedPlacementIDs.count) 处 · 重发手牌 · 商人补酒）")
            case .gameEnded(let details):
                let winner = details.standings.first?.first.flatMap { playerNames[$0] }
                if let winner {
                    lines.append("游戏结束，\(winner) 获胜 🏆")
                } else {
                    lines.append("游戏结束")
                }
            default:
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 消耗的材料:按资源统计数量,并汇总市场购入花费。
    private static func appendConsumed(
        _ lines: inout [String],
        effects: [GameCore.ResourceEffect],
        actorID: GameCore.PlayerID
    ) {
        var counts: [GameCore.ResourceKind: Int] = [:]
        var paid: [GameCore.ResourceKind: Int] = [:]
        for effect in effects {
            switch effect {
            case .resourceRemoved(let resource, _, _):
                counts[resource, default: 0] += 1
            case .marketCostPaid(let playerID, let resource, let amount) where playerID == actorID:
                paid[resource, default: 0] += amount
            default:
                break
            }
        }
        guard counts.isEmpty == false else { return }
        let parts = counts.keys.sorted { $0.rawValue < $1.rawValue }.map { resource -> String in
            let label = resourceLabel(resource)
            if let amount = paid[resource], amount > 0 {
                return "\(label)×\(counts[resource]!)（市场 £\(amount)）"
            }
            return "\(label)×\(counts[resource]!)"
        }
        lines.append("消耗：" + parts.joined(separator: " · "))
    }

    /// 用酒来源(出售/双铁路)。
    private static func appendBeer(
        _ lines: inout [String],
        effects: [GameCore.ResourceEffect]
    ) {
        let beers = effects.compactMap { effect -> String? in
            guard case .resourceRemoved(let resource, let source, _) = effect,
                  resource == .beer
            else { return nil }
            switch source {
            case .merchantBeer(let slotID):
                return "商人啤酒·\(merchantLocationName(slotID))"
            case .industry(let placementID):
                return "啤酒厂·\(placementLocationName(placementID))"
            default:
                return nil
            }
        }
        if beers.isEmpty == false {
            lines.append("用酒：" + beers.joined(separator: "、"))
        }
    }

    /// 建造煤矿/炼铁厂时的市场交付:交付数量与回收金额。
    private static func appendDelivery(
        _ lines: inout [String],
        effects: [GameCore.ResourceEffect],
        actorID: GameCore.PlayerID
    ) {
        var count = 0
        var earned = 0
        var resource: GameCore.ResourceKind?
        for effect in effects {
            guard case .marketDelivered(_, let delivered, _, let price) = effect else { continue }
            count += 1
            earned += price
            resource = delivered
        }
        guard count > 0 else { return }
        let name = resource.map(resourceLabel) ?? "方块"
        lines.append("交付市场：\(name)×\(count)，回收 £\(earned)")
    }

    /// 收入轨前进:格数 + 折算金额。
    private static func appendIncome(
        _ lines: inout [String],
        effects: [GameCore.ResourceEffect],
        actorID: GameCore.PlayerID
    ) {
        for effect in effects {
            guard case .incomeAdvanced(let ownerID, let from, let to) = effect,
                  ownerID == actorID, to != from
            else { continue }
            let before = incomeLevel(from).map { "£\($0)" } ?? "?"
            let after = incomeLevel(to).map { "£\($0)" } ?? "?"
            lines.append("收入轨 +\(to - from) 格（\(before) → \(after)）")
        }
    }

    /// 商人奖励(现金/收入/VP)。
    private static func appendBonuses(
        _ lines: inout [String],
        effects: [GameCore.ResourceEffect],
        actorID: GameCore.PlayerID
    ) {
        for effect in effects {
            switch effect {
            case .cashReceived(let playerID, let amount) where playerID == actorID:
                lines.append("商人奖励：£\(amount)")
            case .victoryPointsReceived(let playerID, let amount) where playerID == actorID:
                lines.append("商人奖励：+\(amount) VP")
            default:
                break
            }
        }
    }

    // MARK: - 静态展示数据(捆绑目录)

    private static func locationName(_ id: String) -> String {
        BoardPresentationCatalog.standard.locations.first(where: { $0.id == id })?.name ?? id
    }

    private static func industryName(_ id: String) -> String {
        RealMatchViewModel.industryTitle(id)
    }

    private static func cardName(_ cardID: String) -> String {
        // 卡牌实例 ID 形如 location-birmingham-1,截取定义名展示。
        let definitionID = cardID.dropLast(1)
        let kind = definitionID.hasPrefix("location") ? "地点" : "产业"
        return "\(kind)牌"
    }

    private static func routeName(_ routeID: String) -> String {
        guard let route = boardData?.routes.first(where: { $0.id == routeID }) else { return routeID }
        let names = route.adjacentLocationIDs.map(locationName)
        return names.count == 2 ? "\(names[0])–\(names[1])" : routeID
    }

    private static func merchantLocationName(_ slotID: String) -> String {
        guard let slot = boardData?.merchantSlots.first(where: { $0.id == slotID }) else { return slotID }
        return locationName(slot.locationID)
    }

    private static func placementLocationName(_ placementID: String) -> String {
        let locationID = placementID.split(separator: "#").first.map(String.init) ?? placementID
        return locationName(locationID)
    }

    private static func incomeLevel(_ position: Int) -> Int? {
        incomeByPosition[position]
    }

    private static func buildCost(_ industryID: String, _ level: Int) -> Int? {
        industryLevel(industryID, level)?.buildCost
    }

    private static func victoryPoints(_ industryID: String, _ level: Int) -> Int? {
        industryLevel(industryID, level)?.victoryPoints
    }

    private static func industryLevel(_ industryID: String, _ level: Int) -> GameCore.IndustryDefinition.Level? {
        industries.first(where: { $0.id == industryID })?.levels.first(where: { $0.level == level })
    }

    /// 捆绑静态数据:地图/产业/收入轨,加载失败时退回原始 ID。
    private static let boardData: GameCore.BoardDefinition? = {
        guard let url = Bundle.main.url(forResource: "map", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let board = try? JSONDecoder().decode(GameCore.BoardDefinition.self, from: data)
        else { return nil }
        return board
    }()

    private static let industries: [GameCore.IndustryDefinition] = {
        guard let url = Bundle.main.url(forResource: "industries", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([GameCore.IndustryDefinition].self, from: data)
        else { return [] }
        return list
    }()

    private static let incomeByPosition: [Int: Int] = {
        guard let url = Bundle.main.url(forResource: "income-track", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let track = try? JSONDecoder().decode(GameCore.IncomeTrack.self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: track.entries.map { ($0.position, $0.income) })
    }()
}
