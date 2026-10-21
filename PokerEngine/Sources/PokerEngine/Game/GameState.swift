public enum Street: Equatable, Sendable, Codable, CaseIterable {
    case preflop, flop, turn, river, showdown, handOver
}

public enum PlayerStatus: Equatable, Sendable, Codable {
    case active, folded, allIn, eliminated
}

public struct PlayerState: Equatable, Sendable {
    public var seat: Int
    public var name: String
    public var isBot: Bool
    public var stack: Int
    public var holeCards: [Card]
    public var streetContribution: Int
    public var handContribution: Int
    public var status: PlayerStatus
    public var hasActed: Bool
    public var stackAtHandStart: Int
    public var finishPlace: Int?

    public init(seat: Int, name: String, isBot: Bool, stack: Int,
                status: PlayerStatus = .active, finishPlace: Int? = nil) {
        self.seat = seat; self.name = name; self.isBot = isBot; self.stack = stack
        self.status = status; self.finishPlace = finishPlace
        holeCards = []; streetContribution = 0; handContribution = 0
        hasActed = false; stackAtHandStart = stack
    }
}

public struct PotLayer: Equatable, Sendable {
    public var amount: Int
    public var eligibleSeats: [Int]
    public init(amount: Int, eligibleSeats: [Int]) { self.amount = amount; self.eligibleSeats = eligibleSeats }
}

public struct PotAward: Equatable, Sendable {
    public var potIndex: Int
    public var amount: Int
    public var winners: [Int]
    public var perWinner: Int
    public var oddChipSeat: Int?
    public var ranks: [Int: HandRank]
    public init(potIndex: Int, amount: Int, winners: [Int], perWinner: Int,
                oddChipSeat: Int?, ranks: [Int: HandRank]) {
        self.potIndex = potIndex; self.amount = amount; self.winners = winners
        self.perWinner = perWinner; self.oddChipSeat = oddChipSeat; self.ranks = ranks
    }
}

public struct HandResult: Equatable, Sendable {
    public var awards: [PotAward]
    public init(awards: [PotAward]) { self.awards = awards }
}

public struct TournamentPayout: Equatable, Sendable {
    public let seat: Int, place: Int, amount: Int
    public init(seat: Int, place: Int, amount: Int) { self.seat = seat; self.place = place; self.amount = amount }
}

/// 游戏的全部状态：值类型，唯一推进方式是 apply / nextHand。
public struct GameState: Equatable, Sendable {
    public var config: GameConfig
    public let seed: UInt64
    public private(set) var rng: SeededGenerator
    // T6 编译强制：Reducer.swift（跨文件 extension）需写这些存储属性，private(set) 仅限本文件，
    // 故改为 internal(set)——模块外（App）仍只读，引擎内唯一推进入口仍为 apply/nextHand。
    public internal(set) var deck: Deck
    public private(set) var handNumber: Int
    public private(set) var buttonSeat: Int
    public internal(set) var street: Street
    public internal(set) var board: [Card]
    public internal(set) var players: [PlayerState]    // 下标即 seat
    public internal(set) var pots: [PotLayer]
    public internal(set) var currentBet: Int
    public internal(set) var minRaiseIncrement: Int
    public internal(set) var actorSeat: Int?
    public internal(set) var actions: [SeatAction]
    public internal(set) var handResult: HandResult?
    public private(set) var tournamentOver: Bool
    public private(set) var tournamentPayouts: [TournamentPayout]
    /// 最近一次激进动作（bet/raise）是否足额（决定是否重开加注轮）。
    public internal(set) var lastAggressionFullRaise: Bool

    public var potTotal: Int { players.reduce(0) { $0 + $1.handContribution } }

    /// 开一局。stacks/buttonSeat/handNumber 供重放（HandHistory）使用。
    public static func start(config: GameConfig, seed: UInt64,
                             stacks: [Int]? = nil, buttonSeat: Int? = nil,
                             handNumber: Int = 0) -> GameState {
        precondition((2...9).contains(config.playerCount))
        precondition(config.effectiveStack > 0)
        // T3 评审裁决：引擎入口强制校验 SNG 配置
        if case .sng(let sng) = config.format { _ = SNGConfig.validated(sng) }
        var rng = SeededGenerator(seed: seed)
        var s = GameState(
            config: config, seed: seed, rng: rng, deck: Deck(rng: &rng),
            handNumber: handNumber,
            buttonSeat: 0,          // 占位，下方按需覆写
            street: .preflop, board: [], players: [],
            pots: [], currentBet: 0, minRaiseIncrement: 0, actorSeat: nil,
            actions: [], handResult: nil, tournamentOver: false,
            tournamentPayouts: [], lastAggressionFullRaise: true)
        let stack0 = stacks ?? Array(repeating: config.effectiveStack, count: config.playerCount)
        precondition(stack0.count == config.playerCount)
        for seat in 0..<config.playerCount {
            s.players.append(PlayerState(seat: seat, name: "座位 \(seat + 1)",
                                          isBot: seat != config.humanSeat, stack: stack0[seat]))
        }
        s.buttonSeat = buttonSeat ?? Int(rng.next() % UInt64(config.playerCount))
        // 重置 rng：按钮选择不再影响发牌序列（重放传显式按钮时同样成立）
        rng = SeededGenerator(seed: seed)
        s.rng = rng
        s.dealNewHand()
        return s
    }

    /// 发一手新牌（含盲注）。start 与 nextHand 共用。
    mutating func dealNewHand() {
        let (sb, bb) = currentBlinds(for: config.format, handNumber: handNumber)
        var rng = self.rng
        deck = Deck(rng: &rng)
        self.rng = rng
        board = []; pots = []; actions = []; handResult = nil
        currentBet = bb; minRaiseIncrement = bb; lastAggressionFullRaise = true
        for i in players.indices {
            players[i].holeCards = []
            players[i].streetContribution = 0
            players[i].handContribution = 0
            players[i].hasActed = false
            players[i].stackAtHandStart = players[i].stack
            if players[i].status == .folded || players[i].status == .allIn {
                players[i].status = .active
            }
        }
        // 从按钮下一位开始每人两张（两轮各一张）
        let dealOrder = liveSeatsClockwise(from: buttonSeat)
        for _ in 0..<2 {
            for seat in dealOrder {
                players[seat].holeCards.append(deck.draw())
            }
        }
        // 盲注：单挑按钮=SB；否则按钮+1=SB
        let n = players.count
        let sbSeat = n == 2 ? buttonSeat : nextSeat(after: buttonSeat)
        let bbSeat = nextSeat(after: sbSeat)
        postBlind(amount: sb, seat: sbSeat)
        postBlind(amount: bb, seat: bbSeat)
        street = .preflop
        actorSeat = n == 2 ? buttonSeat : nextSeat(after: bbSeat)
    }

    private mutating func postBlind(amount: Int, seat: Int) {
        let pay = min(amount, players[seat].stack)
        players[seat].stack -= pay
        players[seat].streetContribution += pay
        players[seat].handContribution += pay
        if players[seat].stack == 0 { players[seat].status = .allIn }
    }

    /// 从 from 下一位起顺时针第一个未淘汰座位。
    func nextSeat(after from: Int) -> Int {
        var s = (from + 1) % players.count
        while players[s].status == .eliminated { s = (s + 1) % players.count }
        return s
    }

    /// 从 from 下一位起顺时针所有未淘汰座位（发牌顺序）。
    func liveSeatsClockwise(from: Int) -> [Int] {
        let total = players.filter { $0.status != .eliminated }.count
        var seats: [Int] = []
        var s = nextSeat(after: from)
        seats.append(s)
        while seats.count < total {
            s = nextSeat(after: s)
            seats.append(s)
        }
        return seats
    }

    /// 忽略 rng 内部状态的状态等价（重放测试的基础）。
    public static func == (lhs: GameState, rhs: GameState) -> Bool {
        lhs.config == rhs.config && lhs.seed == rhs.seed && lhs.deck == rhs.deck
            && lhs.handNumber == rhs.handNumber && lhs.buttonSeat == rhs.buttonSeat
            && lhs.street == rhs.street && lhs.board == rhs.board
            && lhs.players == rhs.players && lhs.pots == rhs.pots
            && lhs.currentBet == rhs.currentBet
            && lhs.minRaiseIncrement == rhs.minRaiseIncrement
            && lhs.actorSeat == rhs.actorSeat && lhs.actions == rhs.actions
            && lhs.handResult == rhs.handResult
            && lhs.tournamentOver == rhs.tournamentOver
            && lhs.tournamentPayouts == rhs.tournamentPayouts
            && lhs.lastAggressionFullRaise == rhs.lastAggressionFullRaise
    }
}
