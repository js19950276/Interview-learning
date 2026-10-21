/// 洗好的 52 张牌堆，从顶部摸牌。
public struct Deck: Equatable, Sendable {
    public private(set) var cards: [Card]
    public var count: Int { cards.count }

    public init<R: RandomNumberGenerator>(rng: inout R) {
        cards = (0..<52).map(Card.init(code:))
        // Fisher-Yates，从尾部往前换
        for i in stride(from: 51, through: 1, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            cards.swapAt(i, j)
        }
    }

    /// 直接持有给定牌（顶部 = 末尾）。供视角重采样重建牌堆，不走洗牌路径。
    init(cards: [Card]) {
        self.cards = cards
    }

    public mutating func draw() -> Card {
        precondition(!cards.isEmpty, "deck is empty")
        return cards.removeLast()
    }

    /// 仅供测试偷看顶牌。
    public func peekTop() -> Card? { cards.last }
}
