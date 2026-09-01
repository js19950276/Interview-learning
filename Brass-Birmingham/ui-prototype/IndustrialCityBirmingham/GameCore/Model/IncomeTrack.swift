import Foundation

extension GameCore {
    nonisolated struct IncomeTrack: Codable, Equatable, Sendable {
        struct Entry: Codable, Equatable, Sendable {
            var position: Int
            var income: Int
        }

        var entries: [Entry]

        func income(at position: Int) -> Int? {
            entries.first(where: { $0.position == position })?.income
        }
    }
}
