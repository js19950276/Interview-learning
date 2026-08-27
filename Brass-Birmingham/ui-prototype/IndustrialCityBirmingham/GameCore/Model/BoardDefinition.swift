import Foundation

extension GameCore {
    nonisolated struct BoardDefinition: Codable, Equatable, Sendable {
        enum Era: String, Codable, Equatable, Sendable {
            case canal
            case rail
        }

        struct Location: Codable, Equatable, Sendable {
            enum Kind: String, Codable, Equatable, Sendable {
                case city
                case breweryFarm
                case merchant
            }

            var id: String
            var kind: Kind
            var industrySlots: [[String]]
            var playerCounts: [Int]
        }

        struct Route: Codable, Equatable, Sendable {
            var id: String
            var endpoints: [String]
            var adjacentLocationIDs: [String]
            var eras: [Era]
            var playerCounts: [Int]
        }

        struct MerchantSlot: Codable, Equatable, Sendable {
            struct Bonus: Codable, Equatable, Sendable {
                enum Kind: String, Codable, Equatable, Sendable {
                    case develop
                    case income
                    case money
                    case victoryPoints
                }

                var kind: Kind
                var amount: Int
            }

            var id: String
            var locationID: String
            var playerCounts: [Int]
            var bonus: Bonus
        }

        var locations: [Location]
        var routes: [Route]
        var merchantSlots: [MerchantSlot]
    }
}
