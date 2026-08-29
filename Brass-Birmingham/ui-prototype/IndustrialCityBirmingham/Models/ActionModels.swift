import Foundation

nonisolated enum GameAction: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case build, network, develop, sell, loan, scout, pass
    var id: String { rawValue }
}

nonisolated struct SellOption: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let industryID: String
    let merchantName: String
    let beerSource: String
    let reward: Int
    let incomeIncrease: Int
}

#if DEBUG
nonisolated struct ActionFixture: Equatable, Codable, Sendable {
    let availableActions: [GameAction]
    let buildLocationIDs: [String]
    let networkRouteIDs: [String]
    let developIndustryIDs: [String]
    let sellOptions: [SellOption]
    let scoutCardIDs: [String]

    static let standard = ActionFixture(
        availableActions: GameAction.allCases,
        buildLocationIDs: ["birmingham", "coventry"],
        networkRouteIDs: ["birmingham-coventry", "birmingham-walsall", "walsall-cannock"],
        developIndustryIDs: ["industry-coal", "industry-iron"],
        sellOptions: [
            SellOption(
                id: "sell-cotton-oxford",
                industryID: "industry-cotton",
                merchantName: "Oxford",
                beerSource: "Your brewery",
                reward: 8,
                incomeIncrease: 1
            ),
            SellOption(
                id: "sell-manufacturer-warrington",
                industryID: "industry-manufacturer",
                merchantName: "Warrington",
                beerSource: "Merchant beer",
                reward: 6,
                incomeIncrease: 1
            )
        ],
        scoutCardIDs: ["card-walsall", "card-iron"]
    )
}
#endif
