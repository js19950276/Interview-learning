import Foundation

extension GameCore {
    nonisolated struct IndustryDefinition: Codable, Equatable, Sendable {
        struct ResourceProduction: Codable, Equatable, Sendable {
            enum Resource: String, Codable, Equatable, Sendable {
                case beer
                case coal
                case iron
            }

            var resource: Resource
            var canalCount: Int
            var railCount: Int
        }

        struct Level: Codable, Equatable, Sendable {
            var level: Int
            var copiesPerColor: Int
            var buildCost: Int
            var coalCost: Int
            var ironCost: Int
            var beerCost: Int
            var incomeReward: Int
            var victoryPoints: Int
            var linkPoints: Int
            var canalEra: Bool
            var railEra: Bool
            var canDevelop: Bool
            var production: ResourceProduction?
        }

        var id: String
        var levels: [Level]
    }
}
