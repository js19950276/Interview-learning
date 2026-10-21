/// 平分层的奇数筹码分配：按钮顺时针下一位方向的最近赢家拿大份。
/// 距离从按钮下一位起算（-1）：按钮本人在"按钮之后顺时针"次序中排最后；
/// 若从按钮本人起算（+0），按钮会排第一并优先拿走奇数筹码，与该规则相悖。
/// 模块级 internal 自由函数而非 GameState 方法：不依赖任何对局状态，
/// 可脱离实例直接单测（@testable 可见），摊牌逻辑调用它时同样无需状态。
func splitOddChip(amount: Int, winners: [Int], buttonSeat: Int, playerCount: Int) -> [(seat: Int, amount: Int)] {
    let n = winners.count
    let per = amount / n
    let odd = amount % n
    let ordered = winners.sorted {
        (($0 - buttonSeat - 1 + playerCount) % playerCount) < (($1 - buttonSeat - 1 + playerCount) % playerCount)
    }
    return ordered.enumerated().map { i, seat in (seat, per + (i == 0 && odd > 0 ? odd : 0)) }
}

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

    // MARK: - Task 7：摊牌与边池

    mutating func showdown() {
        let contenders = players.filter { $0.status != .folded && $0.status != .eliminated }
        precondition(contenders.count >= 2)
        let ranks: [Int: HandRank] = Dictionary(uniqueKeysWithValues:
            contenders.map { ($0.seat, HandEvaluator.evaluate($0.holeCards + board)) })

        // 分层：未弃牌玩家的投入上限升序
        let caps = Array(Set(contenders.map(\.handContribution))).sorted()
        var layers: [PotLayer] = []
        var prev = 0
        for cap in caps {
            let amount = players.reduce(0) { sum, p in
                sum + max(0, min(p.handContribution, cap) - prev)
            }
            let eligible = contenders.filter { $0.handContribution >= cap }.map(\.seat)
            if amount > 0 { layers.append(PotLayer(amount: amount, eligibleSeats: eligible)) }
            prev = cap
        }
        // 顶层兜底：任何玩家投入超过最高摊牌线（未跟注超额/弃牌死钱）的部分并入顶层，保证筹码守恒
        if let topCap = caps.last, !layers.isEmpty {
            layers[layers.count - 1].amount += players.reduce(0) { $0 + max(0, $1.handContribution - topCap) }
        }
        pots = layers

        var awards: [PotAward] = []
        for (i, layer) in layers.enumerated() {
            let best = layer.eligibleSeats.map { ranks[$0]! }.max()!
            let winners = layer.eligibleSeats.filter { ranks[$0]! == best }
            let split = splitOddChip(amount: layer.amount, winners: winners,
                                     buttonSeat: buttonSeat, playerCount: players.count)
            for (seat, amount) in split { players[seat].stack += amount }
            awards.append(PotAward(potIndex: i, amount: layer.amount, winners: winners,
                                   perWinner: layer.amount / winners.count,
                                   oddChipSeat: layer.amount % winners.count > 0 ? split[0].seat : nil,
                                   ranks: ranks))
        }
        handResult = HandResult(awards: awards)
        street = .handOver
        actorSeat = nil
    }

    // MARK: - Task 8：局间逻辑

    /// 结束当前手之后开下一手；或结束锦标赛。
    public mutating func nextHand() {
        guard street == .handOver, !tournamentOver else { return }

        // 1) 淘汰结算：从最差名次起分配；手初筹码低者名次差，同筹码时座位大者名次差
        var remaining = players.filter { $0.status != .eliminated }.count
        let busted = players
            .filter { $0.status != .eliminated && $0.stack == 0 }
            .sorted {
                if $0.stackAtHandStart != $1.stackAtHandStart { return $0.stackAtHandStart < $1.stackAtHandStart }
                return $0.seat > $1.seat
            }
        for p in busted {
            players[p.seat].status = .eliminated
            players[p.seat].finishPlace = remaining
            remaining -= 1
        }

        // 2) 只剩一人 → 终局 + 奖金（SNG）；现金局会话结束无奖金
        if remaining <= 1 {
            let champ = players.first { $0.status != .eliminated }!
            players[champ.seat].finishPlace = 1
            tournamentOver = true
            if case .sng(let cfg) = config.format {
                let pool = cfg.buyIn * config.playerCount
                let floorTotal = cfg.payouts.reduce(0) { $0 + Int(Double(pool) * $1) }
                var entries: [TournamentPayout] = []
                for (i, rate) in cfg.payouts.enumerated() {
                    let place = i + 1
                    let seat = players.first { $0.finishPlace == place }?.seat ?? -1
                    var amount = Int(Double(pool) * rate)
                    if i == 0 { amount += pool - floorTotal }   // 余数归第 1 名
                    entries.append(TournamentPayout(seat: seat, place: place, amount: amount))
                }
                tournamentPayouts = entries
            }
            return
        }

        // 3) 下一手
        handNumber += 1
        buttonSeat = nextSeat(after: buttonSeat)
        dealNewHand()
    }
}
