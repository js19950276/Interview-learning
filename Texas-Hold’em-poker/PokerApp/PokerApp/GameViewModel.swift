import Foundation
import Combine
import PokerEngine

/// AI 难度档：baseline 沿用 VM 默认（全员 HeuristicAI），其余档位全机器人换 PIMCAI 预设；
/// master 单挑局用蓝图查表 AI（Bundle 资源），非单挑/加载失败回退普通档。
enum AIDifficulty: String, CaseIterable, Identifiable {
    case baseline = "基线（启发式）"
    case easy = "轻松"
    case normal = "普通"
    case hard = "困难"
    case master = "大师（蓝图）"
    var id: String { rawValue }

    /// nil → 沿用 VM 默认（全员 HeuristicAI）
    func bots(humanSeat: Int, playerCount: Int) -> [Int: any PokerAI]? {
        let pimc: PIMCAI?
        switch self {
        case .baseline: return nil
        case .easy: pimc = PIMCAI.easy
        case .normal: pimc = PIMCAI.normal
        case .hard: pimc = PIMCAI.hard
        case .master:
            // 蓝图仅单挑训练（spec §1）：多人局或加载失败一律回退普通档，App 不崩
            let normal = Dictionary(uniqueKeysWithValues:
                (0..<playerCount).filter { $0 != humanSeat }.map { ($0, PIMCAI.normal as any PokerAI) })
            guard playerCount == 2,
                  let url = Bundle.main.url(forResource: "blueprint-hu", withExtension: "json"),
                  let bp = try? Blueprint.load(from: url) else {
                print("警告：大师档不可用（非单挑或蓝图加载失败），回退普通档")
                return normal
            }
            return Dictionary(uniqueKeysWithValues:
                (0..<playerCount).filter { $0 != humanSeat }.map { ($0, BlueprintAI(blueprint: bp) as any PokerAI) })
        }
        guard let ai = pimc else { return nil }
        return Dictionary(uniqueKeysWithValues:
            (0..<playerCount).filter { $0 != humanSeat }.map { ($0, ai as any PokerAI) })
    }
}

@MainActor
final class GameViewModel: ObservableObject {
    @Published private(set) var state: GameState
    private(set) var lastResult: HandResult?
    private let bots: [Int: any PokerAI]
    private let thinkNanos: UInt64

    init(config: GameConfig, seed: UInt64,
         bots: [Int: any PokerAI]? = nil, thinkMilliseconds: Int = 700,
         ai: AIDifficulty = .baseline) {
        state = .start(config: config, seed: seed)
        let defaults: [Int: any PokerAI] = Dictionary(uniqueKeysWithValues:
            (0..<config.playerCount).filter { $0 != config.humanSeat }
                .map { ($0, HeuristicAI(aggression: 0.5) as any PokerAI) })
        self.bots = bots ?? ai.bots(humanSeat: config.humanSeat, playerCount: config.playerCount) ?? defaults
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
