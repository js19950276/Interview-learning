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
    case hell = "地狱"
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
        case .hell: pimc = PIMCAI.hell
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
    /// 观战快进的替身决策：搜索型 AI 即使零停顿，纯计算也有 0.3~2.5s/决策的预算，
    /// 人类弃牌后整手会累计十几秒不可见等待——观战期间一律换启发式替身。
    private let spectatorBots: [Int: any PokerAI]
    private let thinkNanos: UInt64
    private let streetPauseNanos: UInt64

    init(config: GameConfig, seed: UInt64,
         bots: [Int: any PokerAI]? = nil, thinkMilliseconds: Int = 1500,
         streetPauseMilliseconds: Int = 1000,
         ai: AIDifficulty = .baseline) {
        state = .start(config: config, seed: seed)
        let defaults: [Int: any PokerAI] = Dictionary(uniqueKeysWithValues:
            (0..<config.playerCount).filter { $0 != config.humanSeat }
                .map { ($0, HeuristicAI(aggression: 0.5) as any PokerAI) })
        self.bots = bots ?? ai.bots(humanSeat: config.humanSeat, playerCount: config.playerCount) ?? defaults
        spectatorBots = Dictionary(uniqueKeysWithValues:
            self.bots.keys.map { ($0, HeuristicAI(aggression: 0.5) as any PokerAI) })
        thinkNanos = UInt64(max(1, thinkMilliseconds)) * 1_000_000
        streetPauseNanos = UInt64(max(1, streetPauseMilliseconds)) * 1_000_000
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
        await applyPaced(action)
        await driveBots()
    }

    func nextHand() async {
        guard state.street == .handOver, !state.tournamentOver else { return }
        lastResult = state.handResult
        state.nextHand()
        await driveBots()
    }

    /// 驱动机器人直到回到人类或本手结束。UI 需在 .task {} 调用一次（机器人先手的开局）。
    /// 人类已弃牌/被淘汰时快进：跳过全部节奏停顿，且换启发式替身决策（搜索型 AI 的计算时间也不等）。
    func driveBots() async {
        while let seat = state.actorSeat,
              seat != state.config.humanSeat,
              let bot = bots[seat] {
            let human = state.players[state.config.humanSeat]
            let paced = human.status != .folded && human.status != .eliminated
            let brain: any PokerAI = paced ? bot : (spectatorBots[seat] ?? bot)
            let snapshot = state
            let decision = await Task.detached(priority: .userInitiated) {
                brain.decide(snapshot, seat: seat)
            }.value
            if paced { try? await Task.sleep(nanoseconds: thinkNanos) }
            guard state.actorSeat == seat else { return }   // 防竞态：状态未变才应用
            await applyPaced(decision, paced: paced)
        }
    }

    /// 应用动作；若该动作刚发出新街道（翻牌/转牌/河牌）且下一位行动者仍是机器人，
    /// 先停一拍再继续，给玩家看清新牌面的准备时间（手牌结束或轮到人类则不停）。
    private func applyPaced(_ action: PlayerAction, paced: Bool = true) async {
        let streetBefore = state.street
        state.apply(action)
        if paced, state.street != streetBefore, state.street != .handOver,
           state.actorSeat != state.config.humanSeat {
            try? await Task.sleep(nanoseconds: streetPauseNanos)
        }
    }
}
