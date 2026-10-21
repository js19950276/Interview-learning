/// 花色。原始值即 Card 整数编码的低 2 位。
public enum Suit: Int, CaseIterable, Sendable, Hashable, Comparable, Codable {
    case spade = 0, heart = 1, diamond = 2, club = 3
    public static func < (lhs: Suit, rhs: Suit) -> Bool { lhs.rawValue < rhs.rawValue }
    var symbol: String { ["♠", "♥", "♦", "♣"][rawValue] }
}

/// 点数。2…14，A=14（轮子顺中另按 1 处理，见 HandEvaluator）。
public enum Rank: Int, CaseIterable, Sendable, Hashable, Comparable, Codable {
    case two = 2, three, four, five, six, seven, eight, nine, ten, jack, queen, king, ace
    public static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.rawValue < rhs.rawValue }
    var symbol: String {
        switch self {
        case .ace: return "A"; case .king: return "K"; case .queen: return "Q"
        case .jack: return "J"; case .ten: return "T"
        default: return String(rawValue)
        }
    }
}

/// 一张牌，0-51 整数编码（(rank.rawValue-2)*4+suit，suit 占低 2 位）。
public struct Card: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rank: Rank
    public let suit: Suit
    public var code: Int { (rank.rawValue - 2) * 4 + suit.rawValue }
    public init(code: Int) {
        precondition((0..<52).contains(code), "card code out of range")
        rank = Rank(rawValue: code / 4 + 2)!
        suit = Suit(rawValue: code % 4)!
    }
    public init(rank: Rank, suit: Suit) { self.rank = rank; self.suit = suit }
    public var description: String { rank.symbol + suit.symbol }
}
