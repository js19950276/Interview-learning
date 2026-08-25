import Foundation

nonisolated enum ConnectionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case online
    case nearby
    var id: String { rawValue }
}

nonisolated enum PlayerColor: String, CaseIterable, Codable, Sendable {
    case amber, crimson, teal, violet
    var symbol: String {
        switch self {
        case .amber: "diamond.fill"
        case .crimson: "triangle.fill"
        case .teal: "circle.fill"
        case .violet: "square.fill"
        }
    }
}

nonisolated struct PlayerSummary: Identifiable, Equatable, Codable, Sendable {
    let id: String
    var name: String
    var color: PlayerColor
    var order: Int
    var spent: Int
    var isCurrent: Bool
    var isHost: Bool
    var isReady: Bool
    var isConnected: Bool
}

nonisolated enum IndustryKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case cotton, manufacturer, pottery, coal, iron, brewery
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .cotton: "square.grid.3x3.fill"
        case .manufacturer: "shippingbox.fill"
        case .pottery: "cup.and.saucer.fill"
        case .coal: "seal.fill"
        case .iron: "cube.fill"
        case .brewery: "waterbottle.fill"
        }
    }
}

nonisolated struct IndustrySummary: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let kind: IndustryKind
    var level: Int
    var cost: Int
    var coalCost: Int
    var ironCost: Int
    var isAvailable: Bool
}

nonisolated struct MarketSummary: Equatable, Codable, Sendable {
    var remaining: Int
    var cheapestPrice: Int
    var ladder: [Int]
}

nonisolated enum HandCardKind: Equatable, Codable, Sendable {
    case location(String)
    case industry(IndustryKind)
    case wildLocation
    case wildIndustry
}

nonisolated struct HandCard: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let title: String
    let kind: HandCardKind
    let allowedActions: Set<GameAction>
}

nonisolated struct MapLocation: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let name: String
    let x: Double
    let y: Double
    var industryPlacements: [MapIndustryPlacement] = []
}

nonisolated struct MapIndustryPlacement: Identifiable, Equatable, Codable, Sendable {
    var id: String { placementID }
    let placementID: String
    let ownerID: String
    let tileID: String
    let kind: IndustryKind
    let level: Int
    let resourceCount: Int
    let isFlipped: Bool
    let ownerColor: PlayerColor
}

nonisolated struct MapPlacedLink: Equatable, Codable, Sendable {
    enum Era: String, CaseIterable, Codable, Equatable, Sendable { case canal, rail }
    let ownerID: String
    let ownerColor: PlayerColor
    let era: Era
}

nonisolated struct MapRoute: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let fromLocationID: String
    let toLocationID: String
    let availableEras: [MapPlacedLink.Era]
    var placedLink: MapPlacedLink?

    init(
        id: String,
        fromLocationID: String,
        toLocationID: String,
        availableEras: [MapPlacedLink.Era] = [.canal, .rail],
        placedLink: MapPlacedLink? = nil
    ) {
        self.id = id
        self.fromLocationID = fromLocationID
        self.toLocationID = toLocationID
        self.availableEras = availableEras
        self.placedLink = placedLink
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        fromLocationID = try container.decode(String.self, forKey: .fromLocationID)
        toLocationID = try container.decode(String.self, forKey: .toLocationID)
        if container.contains(.availableEras) {
            availableEras = try container.decode([MapPlacedLink.Era].self, forKey: .availableEras)
        } else {
            availableEras = [.canal, .rail]
        }
        placedLink = try container.decodeIfPresent(MapPlacedLink.self, forKey: .placedLink)
    }
}

nonisolated struct LobbyState: Equatable, Codable, Sendable {
    let mode: ConnectionMode
    var roomCode: String
    var players: [PlayerSummary]
}

nonisolated struct DemoMatchState: Equatable, Codable, Sendable {
    var era: String
    var round: Int
    var roundCount: Int
    var actionNumber: Int
    var deckRemaining: Int
    var money: Int
    var income: Int
    var victoryPoints: Int
    var players: [PlayerSummary]
    var industries: [IndustrySummary]
    var coalMarket: MarketSummary
    var ironMarket: MarketSummary
    var hand: [HandCard]
    var locations: [MapLocation]
    var routes: [MapRoute]
}
