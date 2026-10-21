import Foundation
import Combine
import PokerEngine

@MainActor
final class GameViewModel: ObservableObject {
    @Published private(set) var state: GameState
    private(set) var lastResult: HandResult?
    private let bots: [Int: any PokerAI]
    private let thinkNanos: UInt64

    init(config: GameConfig, seed: UInt64,
         bots: [Int: any PokerAI]? = nil, thinkMilliseconds: Int = 700) {
        state = .start(config: config, seed: seed)
        let defaults: [Int: any PokerAI] = Dictionary(uniqueKeysWithValues:
            (0..<config.playerCount).filter { $0 != config.humanSeat }
                .map { ($0, HeuristicAI(aggression: 0.5) as any PokerAI) })
        self.bots = bots ?? defaults
        thinkNanos = UInt64(max(1, thinkMilliseconds)) * 1_000_000
    }

    var humanLegal: LegalActions? {
        guard state.actorSeat == state.config.humanSeat,
              [.preflop, .flop, .turn, .river].contains(state.street) else { return nil }
        return legalActions(state)
    }

    var isHandOver: Bool { state.street == .handOver }
    var isSessionOver: Bool { state.tournamentOver }

    /// 人类行动，然后驱动机器人直到再次轮到人类或本手结束。
    func act(_ action: PlayerAction) async {
        guard state.actorSeat == state.config.humanSeat else { return }
        state.apply(action)
        await driveBots()
    }

    func nextHand() async {
        guard state.street == .handOver, !state.tournamentOver else { return }
        lastResult = state.handResult
        state.nextHand()
        await driveBots()
    }

    /// 驱动机器人直到回到人类或本手结束。UI 需在 .task {} 调用一次（机器人先手的开局）。
    func driveBots() async {
        while let seat = state.actorSeat,
              seat != state.config.humanSeat,
              let bot = bots[seat] {
            let snapshot = state
            let decision = await Task.detached(priority: .userInitiated) {
                bot.decide(snapshot, seat: seat)
            }.value
            try? await Task.sleep(nanoseconds: thinkNanos)
            guard state.actorSeat == seat else { return }   // 防竞态：状态未变才应用
            state.apply(decision)
        }
    }
}
