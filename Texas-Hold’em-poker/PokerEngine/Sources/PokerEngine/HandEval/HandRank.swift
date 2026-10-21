public enum HandCategory: Int, CaseIterable, Sendable, Comparable, Codable {
    case highCard = 0, onePair, twoPair, threeOfAKind, straight, flush, fullHouse, fourOfAKind, straightFlush
    public static func < (lhs: HandCategory, rhs: HandCategory) -> Bool { lhs.rawValue < rhs.rawValue }
    var name: String {
        ["高牌", "一对", "两对", "三条", "顺子", "同花", "葫芦", "四条", "同花顺"][rawValue]
    }
}

/// 可整体比较的牌力：类别 + 恒定 5 个降序踢脚，编码成单个 Int。
public struct HandRank: Comparable, Equatable, Sendable, Codable, CustomStringConvertible {
    public let category: HandCategory
    public let tiebreakers: [Int]   // 恒 5 个，降序，缺位补 0
    public var value: Int {
        var v = category.rawValue
        for t in tiebreakers { v = (v << 4) | min(t, 14) }
        return v
    }
    public init(_ category: HandCategory, _ tiebreakers: [Int]) {
        self.category = category
        var t = Array(tiebreakers.prefix(5))
        while t.count < 5 { t.append(0) }
        self.tiebreakers = t
    }
    public static func < (lhs: HandRank, rhs: HandRank) -> Bool { lhs.value < rhs.value }
    public var description: String {
        let cards = tiebreakers.filter { $0 > 0 }.map { Rank(rawValue: $0)!.symbol }
        return category.name + " " + cards.joined(separator: "-")
    }
}
