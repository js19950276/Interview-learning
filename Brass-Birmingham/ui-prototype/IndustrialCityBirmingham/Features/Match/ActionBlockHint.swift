import Foundation

/// 选卡后"建造"不可用时的原因诊断(设计稿 §8.4:非法操作须给原因与出路)。
/// 只依赖 ViewSnapshot 投影出的 DemoMatchState,不需要权威 GameState。
@MainActor
enum ActionBlockHint {
    static func buildReason(
        state: DemoMatchState,
        cardID: String,
        localPlayerID: String
    ) -> String? {
        guard let hand = state.hand.first(where: { $0.id == cardID }) else { return nil }
        let isRail = state.era.contains("铁路")

        // 玩家自己的网络:自己的产业所在城 + 自己连接片两端
        let ownLocations = Set(state.locations.filter { location in
            location.industryPlacements.contains { $0.ownerID == localPlayerID }
        }.map(\.id))
        let ownLinkCities = Set(state.routes.filter { $0.placedLink?.ownerID == localPlayerID }
            .flatMap { [$0.fromLocationID, $0.toLocationID] })
        let hasNetwork = !ownLocations.isEmpty || !ownLinkCities.isEmpty

        // 已连通性:沿任意玩家已铺线路 BFS
        func reachable(from sourceID: String) -> Set<String> {
            var seen: Set<String> = [sourceID]
            var frontier = [sourceID]
            while !frontier.isEmpty {
                var next: Set<String> = []
                for city in frontier {
                    for route in state.routes where route.placedLink != nil {
                        if route.fromLocationID == city, !seen.contains(route.toLocationID) {
                            seen.insert(route.toLocationID)
                            next.insert(route.toLocationID)
                        }
                        if route.toLocationID == city, !seen.contains(route.fromLocationID) {
                            seen.insert(route.fromLocationID)
                            next.insert(route.fromLocationID)
                        }
                    }
                }
                if next.isEmpty { break }
                frontier.append(contentsOf: next)
            }
            return seen
        }

        func connected(_ locationID: String, to targets: Set<String>) -> Bool {
            targets.contains(locationID)
                || !reachable(from: locationID).intersection(targets).isEmpty
        }

        let merchantCities = Set(state.locations.filter { !$0.merchantPlacements.isEmpty }.map(\.id))

        // 资源来源 cheapest:免费地图来源优先(煤需连通、铁任意,§8.1/§8.2),
        // 其次市场(煤需连通贸易商位置),市场空时无限供应。
        func cheapestSource(_ kind: IndustryKind, consumer: String) -> Int? {
            if kind == .coal {
                let freeCoal = state.locations.contains { location in
                    location.industryPlacements.contains {
                        $0.kind == .coal && $0.isFlipped == false && $0.resourceCount > 0
                    } && connected(consumer, to: [location.id])
                }
                if freeCoal { return 0 }
            } else {
                let freeIron = state.locations.contains { location in
                    location.industryPlacements.contains {
                        $0.kind == .iron && $0.isFlipped == false && $0.resourceCount > 0
                    }
                }
                if freeIron { return 0 }
            }
            let market = kind == .coal ? state.coalMarket : state.ironMarket
            if market.remaining > 0 {
                guard kind == .iron || connected(consumer, to: merchantCities) else { return nil }
                return market.cheapestPrice
            }
            if kind == .iron { return 6 }
            if kind == .coal, connected(consumer, to: merchantCities) { return 8 }
            return nil
        }

        // 单城单产业探测:返回不可建原因,nil = 可建
        func probe(kind: IndustryKind, tile: IndustrySummary, in location: MapLocation) -> String? {
            let emptySlots = location.slots.filter { slot in
                slot.allowedKinds.contains(kind)
                    && !location.industryPlacements.contains { $0.slotIndex == slot.index }
            }
            guard emptySlots.isEmpty == false else { return "没有可用的空槽位" }
            var cash = tile.cost
            for (resource, count) in [(IndustryKind.coal, tile.coalCost), (.iron, tile.ironCost)] {
                for _ in 0..<count {
                    guard let price = cheapestSource(resource, consumer: location.id) else {
                        return resource == .coal
                            ? "缺煤:需经连接片连通煤矿,或连通贸易商位置后从煤市场购买"
                            : "缺铁:场上没有可取的铁,市场也已售空"
                    }
                    cash += price
                }
            }
            if state.money < cash { return "现金不足(至少 £\(cash))" }
            return nil
        }

        var buildAvailable = false
        var best: (priority: Int, text: String)?
        func record(_ priority: Int, _ text: String) {
            if best == nil || priority < best!.priority { best = (priority, text) }
        }
        func priorityFor(_ text: String) -> Int {
            if text.hasPrefix("缺") { return 0 }
            if text.contains("槽位") { return 1 }
            if text.hasPrefix("现金") { return 2 }
            return 3
        }
        func probeIndustry(_ kind: IndustryKind, tile: IndustrySummary, candidates: [MapLocation]) {
            for location in candidates {
                if buildAvailable { return }
                if isRail == false, state.era.contains("运河") {
                    // §9.1 运河时代一城一产业;伯明翰例外允许 2 个。
                    let limit = location.id == "birmingham" ? 2 : 1
                    let mine = location.industryPlacements.filter { $0.ownerID == localPlayerID }.count
                    if mine >= limit {
                        continue
                    }
                }
                if let reason = probe(kind: kind, tile: tile, in: location) {
                    record(priorityFor(reason), reason)
                } else {
                    buildAvailable = true
                    return
                }
            }
        }

        let stack = state.industries
        switch hand.kind {
        case .location(let definitionID):
            let cityID = definitionID.hasPrefix("location-")
                ? String(definitionID.dropFirst("location-".count))
                : definitionID
            guard let city = state.locations.first(where: { $0.id == cityID }) else {
                return "这张地点牌对应的城市不在当前地图上"
            }
            for summary in stack where city.slots.contains(where: { $0.allowedKinds.contains(summary.kind) }) {
                probeIndustry(summary.kind, tile: summary, candidates: [city])
                if buildAvailable { break }
            }
        case .industry(let kind):
            if let summary = state.industries.first(where: { $0.kind == kind }) {
                let candidates = state.locations.filter { location in
                    location.slots.contains { $0.allowedKinds.contains(kind) }
                        && (hasNetwork == false
                            || ownLocations.contains(location.id)
                            || ownLinkCities.contains(location.id))
                }
                probeIndustry(kind, tile: summary, candidates: candidates)
            }
        case .wildLocation:
            let cities = state.locations.filter { !$0.name.contains("乡村酒桶") }
            for summary in stack {
                probeIndustry(summary.kind, tile: summary, candidates: cities)
                if buildAvailable { break }
            }
        case .wildIndustry:
            let cities = state.locations.filter { location in
                location.slots.contains { $0.allowedKinds.isEmpty == false }
            }
            for summary in stack {
                probeIndustry(summary.kind, tile: summary, candidates: cities)
                if buildAvailable { break }
            }
        }

        if buildAvailable { return nil }
        return best?.text
    }
}
