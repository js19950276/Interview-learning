import Foundation

extension GameCore {
    nonisolated struct MerchantDefinition: Codable, Equatable, Sendable {
        var id: String
        var acceptedIndustryIDs: [String]
        var count: Int
        var playerCounts: [Int]
    }
}
