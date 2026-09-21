import Foundation

extension GameCore {
    nonisolated struct MerchantDefinition: Codable, Equatable, Sendable {
        var id: String
        var acceptedIndustryIDs: [String]
        var count: Int
        var playerCounts: [Int]
        /// 贸易商板块角标的连接图标数，时代计分时计入相邻连接片（RULES.md §10.1）。
        var linkPoints: Int
    }
}
