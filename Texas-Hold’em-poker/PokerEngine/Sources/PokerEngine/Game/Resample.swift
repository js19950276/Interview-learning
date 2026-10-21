extension GameState {
    /// 从 seat 视角构造平行世界（spec 阶段 2a §4.1）：
    /// 保留 seat 底牌、board 与全部公开状态；对手（凡有底牌者——含已弃牌与终局手淘汰未清牌）
    /// 从未见池均匀重发 2 张；剩余未见牌构成新 deck。产出仅供搜索内部使用，不进 HandHistory。
    public func resampled(from seat: Int, using rng: inout SeededGenerator) -> GameState {
        var world = self
        let visible = Set(players[seat].holeCards).union(board)
        var unseen = (0..<52).map(Card.init(code:)).filter { !visible.contains($0) }
        for i in stride(from: unseen.count - 1, through: 1, by: -1) {
            unseen.swapAt(i, Int(rng.next() % UInt64(i + 1)))
        }
        var idx = 0
        for i in players.indices {
            guard i != seat, !players[i].holeCards.isEmpty else { continue }
            world.players[i].holeCards = [unseen[idx], unseen[idx + 1]]
            idx += 2
        }
        world.deck = Deck(cards: Array(unseen[idx...]))
        return world
    }
}
