import Foundation

extension GameCore {
    nonisolated struct CardDefinition: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Equatable, Sendable {
            case location
            case industry
            case wildLocation
            case wildIndustry
        }

        var id: String
        var kind: Kind
        var targetIDs: [String]
        var count: Int
        var playerCounts: [Int]
    }
}
