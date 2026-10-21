extension GameState {
    /// 唯一的行动入口：作用于当前 actorSeat。
    public mutating func apply(_ action: PlayerAction) {
        guard let seat = actorSeat,
              [.preflop, .flop, .turn, .river].contains(street) else { return }
        let legal = legalActions(self)
        var act = action
        if !isLegal(act, in: legal) {
            assert(false, "illegal action \(action) for seat \(seat); treated as fold")
            act = .fold
        }
        actions.append(SeatAction(seat: seat, action: act))
        var p = players[seat]

        switch act {
        case .fold:
            p.status = .folded
        case .check:
            p.hasActed = true
        case .call:
            let pay = min(max(0, currentBet - p.streetContribution), p.stack)
            p.stack -= pay
            p.streetContribution += pay
            p.handContribution += pay
            p.hasActed = true
            if p.stack == 0 { p.status = .allIn }
        case .bet(let target), .raiseTo(let target):
            let t = min(target, p.streetContribution + p.stack)   // 全下封顶
            let add = t - p.streetContribution
            precondition(add > 0, "aggressive action must exceed current contribution")
            let raiseSize = t - currentBet
            let isFull = currentBet == 0 ? t >= minRaiseIncrement : raiseSize >= minRaiseIncrement
            p.stack -= add
            p.streetContribution = t
            p.handContribution += add
            p.hasActed = true
            if p.stack == 0 { p.status = .allIn }
            if isFull {
                if raiseSize > 0 { minRaiseIncrement = raiseSize }
                lastAggressionFullRaise = true
                for i in players.indices where players[i].status == .active && i != seat {
                    players[i].hasActed = false
                }
            } else {
                lastAggressionFullRaise = false             // 不足额 all-in：不重开
            }
            currentBet = t
        }
        players[seat] = p

        let unfolded = players.filter { $0.status != .folded && $0.status != .eliminated }
        if unfolded.count <= 1 {
            settleUncontested(winner: unfolded.first?.seat ?? seat)
            return
        }
        if bettingRoundComplete() { closeBettingRound() }
        else { actorSeat = nextToAct(after: seat) }
    }

    func bettingRoundComplete() -> Bool {
        let contenders = players.filter { $0.status == .active }
        if contenders.isEmpty { return true }
        return contenders.allSatisfy { $0.hasActed && $0.streetContribution == currentBet }
    }

    func nextToAct(after from: Int) -> Int? {
        var s = (from + 1) % players.count
        for _ in 0..<players.count {
            let p = players[s]
            if p.status == .active && (!p.hasActed || p.streetContribution < currentBet) { return s }
            s = (s + 1) % players.count
        }
        return nil
    }

    mutating func closeBettingRound() {
        guard street != .river else { showdown(); return }
        dealNextStreet()
        let contenders = players.filter { $0.status == .active }
        if contenders.count <= 1 {
            // runout：直接发完剩余公共牌
            while street != .river { dealNextStreet() }
            showdown()
            return
        }
        // 新街道重置下注状态
        for i in players.indices { players[i].streetContribution = 0; players[i].hasActed = false }
        currentBet = 0
        let (_, bb) = currentBlinds(for: config.format, handNumber: handNumber)
        minRaiseIncrement = bb
        lastAggressionFullRaise = true
        // 翻后首行动者 = 按钮顺时针下一位 active 玩家（nextToAct 从 from+1 起扫，单挑即非按钮方）
        actorSeat = nextToAct(after: buttonSeat)
    }

    mutating func dealNextStreet() {
        switch street {
        case .preflop:
            board += [deck.draw(), deck.draw(), deck.draw()]; street = .flop
        case .flop:
            board.append(deck.draw()); street = .turn
        case .turn:
            board.append(deck.draw()); street = .river
        default: break
        }
    }

    /// 只剩一人未弃牌：直接收池（未跟注部分自然返还）。
    mutating func settleUncontested(winner: Int) {
        let amount = potTotal
        pots = [PotLayer(amount: amount, eligibleSeats: [winner])]
        players[winner].stack += amount
        handResult = HandResult(awards: [PotAward(potIndex: 0, amount: amount, winners: [winner],
                                                  perWinner: amount, oddChipSeat: nil, ranks: [:])])
        street = .handOver
        actorSeat = nil
    }

    // Task 7 原地填充：摊牌与边池
    mutating func showdown() {}
}
