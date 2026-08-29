#if DEBUG
nonisolated enum DemoFixture {
    static func players(count: Int) -> [PlayerSummary] {
        precondition((2...4).contains(count))
        return Array(allPlayers.prefix(count))
    }

    static func match(playerCount: Int, era: String = "运河时代") -> DemoMatchState {
        DemoMatchState(
            era: era, round: 1,
            roundCount: playerCount == 4 ? 8 : playerCount == 3 ? 9 : 10,
            actionNumber: 1, deckRemaining: 26, money: 17, income: 0, victoryPoints: 0,
            players: players(count: playerCount), industries: industries,
            coalMarket: MarketSummary(remaining: 7, cheapestPrice: 2, ladder: [1, 2, 3, 4, 5, 6, 7, 8]),
            ironMarket: MarketSummary(remaining: 5, cheapestPrice: 3, ladder: [1, 2, 3, 4, 5, 6]),
            hand: hand, locations: locations, routes: routes
        )
    }

    private static let allPlayers = [
        PlayerSummary(id: "player-amber", name: "Owen", color: .amber, order: 1, spent: 0, isCurrent: true, isHost: true, isReady: true, isConnected: true),
        PlayerSummary(id: "player-crimson", name: "Bessemer", color: .crimson, order: 2, spent: 5, isCurrent: false, isHost: false, isReady: true, isConnected: true),
        PlayerSummary(id: "player-teal", name: "Coade", color: .teal, order: 3, spent: 8, isCurrent: false, isHost: false, isReady: true, isConnected: true),
        PlayerSummary(id: "player-violet", name: "Cadbury-Langname", color: .violet, order: 4, spent: 12, isCurrent: false, isHost: false, isReady: true, isConnected: true)
    ]

    private static let industries = [
        IndustrySummary(id: "industry-cotton", kind: .cotton, level: 1, cost: 12, coalCost: 0, ironCost: 0, isAvailable: true),
        IndustrySummary(id: "industry-manufacturer", kind: .manufacturer, level: 1, cost: 8, coalCost: 1, ironCost: 0, isAvailable: true),
        IndustrySummary(id: "industry-pottery", kind: .pottery, level: 1, cost: 17, coalCost: 1, ironCost: 0, isAvailable: false),
        IndustrySummary(id: "industry-coal", kind: .coal, level: 1, cost: 5, coalCost: 0, ironCost: 0, isAvailable: true),
        IndustrySummary(id: "industry-iron", kind: .iron, level: 1, cost: 5, coalCost: 1, ironCost: 0, isAvailable: true),
        IndustrySummary(id: "industry-brewery", kind: .brewery, level: 1, cost: 5, coalCost: 0, ironCost: 1, isAvailable: true)
    ]

    private static let hand: [HandCard] = [
        HandCard(id: "card-birmingham", title: "Birmingham", kind: .location("Birmingham"), allowedActions: Set(GameAction.allCases)),
        HandCard(id: "card-coventry", title: "Coventry", kind: .location("Coventry"), allowedActions: Set(GameAction.allCases)),
        HandCard(id: "card-walsall", title: "Walsall", kind: .location("Walsall"), allowedActions: Set(GameAction.allCases)),
        HandCard(id: "card-iron", title: "Iron Works", kind: .industry(.iron), allowedActions: Set(GameAction.allCases)),
        HandCard(id: "card-coal", title: "Coal Mine", kind: .industry(.coal), allowedActions: Set(GameAction.allCases)),
        HandCard(id: "card-brewery", title: "Brewery", kind: .industry(.brewery), allowedActions: Set(GameAction.allCases)),
        HandCard(id: "card-wild-location", title: "Wild Location", kind: .wildLocation, allowedActions: Set(GameAction.allCases)),
        HandCard(id: "card-wild-industry", title: "Wild Industry", kind: .wildIndustry, allowedActions: Set(GameAction.allCases))
    ]

    private static let locations = [
        MapLocation(id: "birmingham", name: "Birmingham", x: 0.50, y: 0.54),
        MapLocation(id: "coventry", name: "Coventry", x: 0.70, y: 0.60),
        MapLocation(id: "walsall", name: "Walsall", x: 0.45, y: 0.34),
        MapLocation(id: "cannock", name: "Cannock", x: 0.35, y: 0.20),
        MapLocation(id: "worcester", name: "Worcester", x: 0.35, y: 0.78),
        MapLocation(id: "oxford", name: "Oxford", x: 0.80, y: 0.82),
        MapLocation(id: "gloucester", name: "Gloucester", x: 0.56, y: 0.90),
        MapLocation(id: "burton", name: "Burton", x: 0.70, y: 0.22)
    ]

    private static let routes = [
        MapRoute(id: "birmingham-coventry", fromLocationID: "birmingham", toLocationID: "coventry"),
        MapRoute(id: "birmingham-walsall", fromLocationID: "birmingham", toLocationID: "walsall"),
        MapRoute(id: "walsall-cannock", fromLocationID: "walsall", toLocationID: "cannock"),
        MapRoute(id: "birmingham-worcester", fromLocationID: "birmingham", toLocationID: "worcester"),
        MapRoute(id: "coventry-oxford", fromLocationID: "coventry", toLocationID: "oxford"),
        MapRoute(id: "worcester-gloucester", fromLocationID: "worcester", toLocationID: "gloucester"),
        MapRoute(id: "walsall-burton", fromLocationID: "walsall", toLocationID: "burton")
    ]
}
#endif
