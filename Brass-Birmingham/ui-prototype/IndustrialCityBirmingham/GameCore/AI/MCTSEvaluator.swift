import Foundation

extension GameCore {
    /// P2:MCTS 评估器协议——叶价值 + 动作先验的可替换来源(spec §7/§7.1)。
    /// 启发式实现=P1 行为;远程实现=推理服务(P2);CoreML=P3。
    nonisolated protocol MCTSEvaluator: Sendable {
        /// 叶节点价值:每玩家效用(0…1 排名效用口径)。
        func utilities(state: GameState, incomeTrack: [IncomeTrack.Entry]) throws -> [PlayerID: Double]
        /// 动作先验:与 payloads 同长、非负;权重只需相对可比
        /// (启发式=等权 1.0;远程=网络分布,状态条件化,故带 state/catalog)。
        func priors(
            for payloads: [PlayerIntent.Payload],
            state: GameState,
            catalog: VerifiedGameDataCatalog
        ) throws -> [Double]
    }

    /// P1 启发式的协议化封装:公式逐行来自 HeuristicEvaluator,行为不变。
    nonisolated struct HeuristicEvaluation: MCTSEvaluator {
        init() {}

        func utilities(
            state: GameState, incomeTrack: [IncomeTrack.Entry]
        ) throws -> [PlayerID: Double] {
            HeuristicEvaluator.utilities(state: state, incomeTrack: incomeTrack)
        }

        func priors(
            for payloads: [PlayerIntent.Payload],
            state: GameState,
            catalog: VerifiedGameDataCatalog
        ) throws -> [Double] {
            Array(repeating: 1.0, count: payloads.count)
        }
    }

    /// 远程评估:价值=网络 value 头;先验=softmax(A)[动作类型] × softmax(B)[卡牌定义]。
    /// 推理失败直接抛错(上层自博弈必须退出,绝不静默降级污染训练数据——计划 Review Focus 5)。
    /// 注意:非 Sendable-safe 的共享客户端;每个自博弈进程独占使用(MCTS 单线程内调用)。
    nonisolated final class RemoteEvaluation: MCTSEvaluator, @unchecked Sendable {
        private let client: InferenceClient
        private let catalog: VerifiedGameDataCatalog

        init(client: InferenceClient, catalog: VerifiedGameDataCatalog) {
            self.client = client
            self.catalog = catalog
        }

        func utilities(
            state: GameState, incomeTrack: [IncomeTrack.Entry]
        ) throws -> [PlayerID: Double] {
            // 终局叶:排名效用是精确已知的,不走网络(终审 I1——省一次推理且无噪声)。
            if state.turnPhase == .ended, let standings = state.finalStandings {
                return HeuristicEvaluator.standingsUtilities(
                    standings: standings, players: state.players
                )
            }
            let features = StateEncoder.encode(state: state, catalog: catalog)
            let result = try client.evaluateSingle(features)
            guard result.values.count == 1 else { throw InferenceError.truncatedResponse }
            // value 头按局内 players 座次序输出。
            var utilities: [PlayerID: Double] = [:]
            for (seat, player) in state.players.enumerated() {
                let index = min(seat, result.values[0].count - 1)
                utilities[player.id] = Double(result.values[0][index])
            }
            return utilities
        }

        func priors(
            for payloads: [PlayerIntent.Payload],
            state: GameState,
            catalog: VerifiedGameDataCatalog
        ) throws -> [Double] {
            let layout = StateEncoder.makeLayout(catalog: catalog)
            let features = StateEncoder.encode(state: state, catalog: catalog)
            let result = try client.evaluateSingle(features)
            guard result.logitsA.count == 1 else { throw InferenceError.truncatedResponse }
            let logitsA = result.logitsA[0]
            let logitsB = result.logitsB[0]
            let softA = Self.softmax(logitsA)
            let softB = Self.softmax(logitsB)
            // 动作类型序 = ActionKind.allCases(与自博弈策略目标的 A 维序一致)。
            let kinds = ActionKind.allCases
            var weights: [Double] = []
            weights.reserveCapacity(payloads.count)
            for payload in payloads {
                let kind = Self.kindIndex(of: payload, order: kinds)
                guard let kind else {
                    weights.append(0.0) // confirm/retract 类不产先验
                    continue
                }
                var weight = softA[kind]
                if let definitionID = Self.cardDefinition(of: payload, state: state) {
                    if let cardIndex = layout.cardIndex[definitionID] {
                        weight *= softB[cardIndex]
                    }
                }
                weights.append(weight)
            }
            // spec §7:先验在枚举出的合法动作集上归一(否则 ~1e-3 量级积使 U 项失效)。
            let total = weights.reduce(0, +)
            guard total > 0 else { return weights }
            return weights.map { $0 / total }
        }

        static func softmax(_ values: [Float]) -> [Double] {
            let maxLogit = values.max() ?? 0
            let exps = values.map { exp($0 - maxLogit) }
            let total = exps.reduce(0, +)
            guard total > 0 else { return Array(repeating: 0, count: values.count) }
            return exps.map { Double($0 / total) }
        }

        static func kindIndex(of payload: PlayerIntent.Payload, order: [ActionKind]) -> Int? {
            let kind: ActionKind?
            switch payload {
            case .pass: kind = .pass
            case .build: kind = .build
            case .network: kind = .network
            case .develop: kind = .develop
            case .sell: kind = .sell
            case .loan: kind = .loan
            case .scout: kind = .scout
            case .forcedSale: kind = .forcedSale
            case .confirmEraIntermission, .confirmTurnEnd, .retractTurnActions: kind = nil
            }
            guard let kind else { return nil }
            return order.firstIndex(of: kind)
        }

        /// 卡牌定义归属:意图携带卡实例 ID,经行动者手牌映射到 definitionID;
        /// scout 取首张(口径成文,spec §6);forcedSale/确认类无卡。
        static func cardDefinition(of payload: PlayerIntent.Payload, state: GameState) -> String? {
            let instanceID: String?
            switch payload {
            case .pass(let i): instanceID = i.cardID
            case .build(let i): instanceID = i.cardID
            case .network(let i): instanceID = i.cardID
            case .develop(let i): instanceID = i.cardID
            case .sell(let i): instanceID = i.cardID
            case .loan(let i): instanceID = i.cardID
            case .scout(let i): instanceID = i.cardIDs.first
            case .forcedSale, .confirmEraIntermission, .confirmTurnEnd, .retractTurnActions:
                instanceID = nil
            }
            guard let id = instanceID else { return nil }
            for player in state.players {
                if let card = player.hand.first(where: { $0.id == id }) {
                    return card.definitionID
                }
            }
            return nil
        }
    }
}
