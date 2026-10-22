import Foundation

extension GameCore {
    /// 难度档(spec §10.3):模拟数初值按 macOS -O 实测展开成本(~123ms/新节点)定;
    /// 深档数值待 P1 剖析(Task 3)后可调。
    nonisolated enum AIDifficulty: String, CaseIterable, Codable, Sendable {
        case light, standard, deep
        var simulations: Int {
            switch self {
            case .light: return 8
            case .standard: return 24
            case .deep: return 48
            }
        }
        var displayName: String {
            switch self {
            case .light: return "轻量"
            case .standard: return "标准"
            case .deep: return "深思"
            }
        }
    }

    nonisolated struct MCTSConfiguration: Sendable {
        var simulations: Int = 24
        /// PUCT 探索常数 c(spec §7)。
        var explorationConstant: Double = 1.25
        /// 到点立即返回当前最多访问的动作;nil 表示不限时(测试用)。
        var timeLimitMs: Int? = 4_000
        /// 同 seed 同状态 → 同决策(枚举序稳定 + 平手取发现序)。
        var seed: UInt64 = 0
        /// P2:可替换评估来源;nil = 启发式(P1 行为逐位不变)。
        var evaluator: (any MCTSEvaluator)? = nil

        static func preset(_ difficulty: AIDifficulty) -> MCTSConfiguration {
            .init(simulations: difficulty.simulations, explorationConstant: 1.25, timeLimitMs: 4_000, seed: 0)
        }
    }

    nonisolated enum MCTSError: Error, Equatable, Sendable {
        case noActionsAvailable
        /// 远程评估失败:自博弈必须整体退出,绝不静默降级(Review Focus 5)。
        case inferenceFailed(underlying: String?)
    }

    /// PUCT 树搜索 + MaxN 多人备份(spec §7)。
    /// 动作生成 = 完备枚举(作者 2026-10-19 决策);节点惰性展开(首次访问时枚举一次);
    /// 状态不落树,每次模拟从根沿路径用 SimulationRunner 重放。
    nonisolated enum MonteCarloTreeSearch {
        struct Decision: Equatable, Sendable {
            var payload: PlayerIntent.Payload
            var totalVisits: Int
            var elapsedMs: Double
            var expandedNodes: Int
            /// 调试面板用:根子女按访问数降序前 5(动作类型 + 访问数 + 行动方平均效用)。
            var topCandidates: [String]
        }

        /// 树内节点(单线程使用,不跨并发域)。
        final class Node {
            let payload: PlayerIntent.Payload?
            /// 合成确认动作的指定行动者(普通动作在 apply 时取当前 activePlayerID)。
            let actor: PlayerID?
            var children: [Node] = []
            /// nil=未枚举;空=已枚举但无动作(死叶/终局)。
            var pending: [(payload: PlayerIntent.Payload, prior: Double, actor: PlayerID?)]? = nil
            var visits = 0
            var valueSum: [PlayerID: Double] = [:]
            var prior: Double = 1.0

            init(payload: PlayerIntent.Payload? = nil, prior: Double = 1.0, actor: PlayerID? = nil) {
                self.payload = payload
                self.prior = prior
                self.actor = actor
            }
        }

        static func chooseAction(
            state: GameState,
            actorID: PlayerID,
            catalog: VerifiedGameDataCatalog,
            configuration: MCTSConfiguration
        ) throws -> Decision {
            let evaluator = configuration.evaluator
            let start = DispatchTime.now()
            let deadlineNs: UInt64? = configuration.timeLimitMs.map {
                start.uptimeNanoseconds + UInt64($0) * 1_000_000
            }
            let incomeTrack = catalog.catalog.incomeTrack.entries
            let roomID = RoomID(rawValue: "mcts-sim")
            let seed = configuration.seed == 0
                ? UInt64(bitPattern: Int64(state.actionNumber)) &+ 0x5EED_5EED
                : configuration.seed
            var rng = SplitMix64Seed(seed: seed)

            let root = Node()
            try enumeratePending(node: root, state: state, actorID: actorID, catalog: catalog, deadlineNs: deadlineNs, evaluator: evaluator)
            if root.pending?.isEmpty != false {
                // 死区兜底:根枚举被截止阀门截空或确实无动作时,无截止重枚举一次——
                // 活性优先于预算(宁可单步超时,不可座位死锁)。
                try enumeratePending(node: root, state: state, actorID: actorID, catalog: catalog, deadlineNs: nil, evaluator: evaluator)
            }
            guard let rootPending = root.pending, rootPending.isEmpty == false else {
                throw MCTSError.noActionsAvailable
            }
            applyRootNoise(root, using: &rng)

            var expandedNodes = 0
            simulationLoop: for simulationIndex in 0..<max(configuration.simulations, 1) {
                // 首模拟不受限时约束:根枚举本身可能接近预算(重状态/争抢),
                // 必须保证至少一次展开,否则无决策可返回(预算死区 bug,CLI 实测捕获)。
                if simulationIndex > 0, let deadlineNs,
                   DispatchTime.now().uptimeNanoseconds > deadlineNs { break }

                var work = state
                var node = root
                var path: [Node] = [root]

                descent: while true {
                    // 首访非根节点:在此节点的状态上完备枚举一次(受同一搜索截止时间约束)。
                    if node !== root, node.pending == nil {
                        // 枚举/先验失败硬传播;仅 SimulationRunner.apply 的失败按死分支弃模拟。
                        try enumeratePending(
                            node: node, state: work, actorID: work.activePlayerID,
                            catalog: catalog, deadlineNs: deadlineNs, evaluator: evaluator
                        )
                    }
                    if var pending = node.pending, pending.isEmpty == false {
                        // 展开一个未展开动作为新叶(合成确认动作用其指定行动者)。
                        let entry = pending.removeLast()
                        node.pending = pending
                        let child = Node(payload: entry.payload, prior: entry.prior, actor: entry.actor)
                        node.children.append(child)
                        let actor = entry.actor ?? work.activePlayerID
                        guard let actor else { break descent }
                        do {
                            try SimulationRunner.apply(
                                entry.payload, actorID: actor, roomID: roomID, to: &work, catalog: catalog
                            )
                        } catch is Error {
                            break descent // 应用失败=死分支,弃本次模拟(枚举合法性由宿主对拍保障)
                        }
                        node = child
                        path.append(child)
                        expandedNodes += 1
                        break descent
                    }
                    if work.turnPhase == .ended { break descent } // 终局叶
                    if node.children.isEmpty { break descent } // 无动作死叶,直接评估
                    guard let selectingActor = work.activePlayerID,
                          let next = selectPUCT(node, actor: selectingActor, c: configuration.explorationConstant),
                          let payload = next.payload
                    else { break descent }
                    let actor = next.actor ?? work.activePlayerID
                    guard let actor else { break descent }
                    do {
                        try SimulationRunner.apply(
                            payload, actorID: actor, roomID: roomID, to: &work, catalog: catalog
                        )
                    } catch {
                        break descent
                    }
                    node = next
                    path.append(next)
                }

                // 叶评估:终局走 finalStandings,否则评估器(缺省启发式);
                // 远程失败硬传播(绝不静默降级)。
                let leafUtility: [PlayerID: Double]
                do {
                    leafUtility = try configuration.evaluator?.utilities(state: work, incomeTrack: incomeTrack)
                        ?? HeuristicEvaluator.utilities(state: work, incomeTrack: incomeTrack)
                } catch {
                    throw MCTSError.inferenceFailed(underlying: String(describing: error))
                }
                // MaxN 备份:路径上每节点累计每玩家效用(轮到谁最大化谁是选择层的事)。
                for nodeOnPath in path {
                    nodeOnPath.visits += 1
                    for (player, value) in leafUtility {
                        nodeOnPath.valueSum[player, default: 0] += value
                    }
                }
            }

            // 决策:访问数降序;平手(浅层星形树下每叶仅 1 访问)按行动方平均效用择优,
            // 再平手取发现序——小预算下等效"抽样动作的即时评估择优"。
            let ranked = root.children.enumerated().sorted { lhs, rhs in
                if lhs.element.visits != rhs.element.visits { return lhs.element.visits > rhs.element.visits }
                let lq = lhs.element.valueSum[actorID].map { $0 / Double(max(lhs.element.visits, 1)) } ?? 0
                let rq = rhs.element.valueSum[actorID].map { $0 / Double(max(rhs.element.visits, 1)) } ?? 0
                if lq != rq { return lq > rq }
                return lhs.offset < rhs.offset
            }
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            guard let best = ranked.first, let bestPayload = best.element.payload else {
                // 兜底:极端情况(零模拟完成)下取枚举出的任一动作,绝不抛无动作。
                guard let fallback = root.pending?.last?.payload else {
                    throw MCTSError.noActionsAvailable
                }
                return Decision(
                    payload: fallback, totalVisits: root.visits, elapsedMs: elapsedMs,
                    expandedNodes: expandedNodes, topCandidates: []
                )
            }
            let top = ranked.prefix(5).map { entry in
                let child = entry.element
                let utility = child.valueSum[actorID].map { $0 / Double(max(child.visits, 1)) } ?? 0
                return "\(describeKind(child.payload)) visits=\(child.visits) util=\(String(format: "%.2f", utility))"
            }
            return Decision(
                payload: bestPayload,
                totalVisits: root.visits,
                elapsedMs: elapsedMs,
                expandedNodes: expandedNodes,
                topCandidates: Array(top)
            )
        }

        /// 节点首访时枚举该状态全部动作:active/forcedSale 走完备枚举器;
        /// 确认阶段合成唯一动作,让树能跨回合/时代边界继续深入(否则路径永远
        /// 止于当前行动者,MaxN 多人备份结构性不可达——终审 Important-3)。
        private static func enumeratePending(
            node: Node,
            state: GameState,
            actorID: PlayerID?,
            catalog: VerifiedGameDataCatalog,
            deadlineNs: UInt64?,
            evaluator: (any MCTSEvaluator)?
        ) throws {
            switch state.turnPhase {
            case .awaitingTurnEndConfirmation:
                if let active = state.activePlayerID {
                    node.pending = [(.confirmTurnEnd, 1.0, active)]
                } else {
                    node.pending = []
                }
                return
            case .eraIntermission(let intermission):
                if let confirmer = state.players.map(\.id)
                    .first(where: { intermission.confirmedPlayerIDs.contains($0) == false }) {
                    node.pending = [(.confirmEraIntermission, 1.0, confirmer)]
                } else {
                    node.pending = []
                }
                return
            case .active, .forcedSale, .ended:
                break
            }
            guard let actorID else {
                node.pending = []
                return
            }
            let payloads = (try? FastActionEnumerator.enumerate(
                state: state, actorID: actorID, catalog: catalog, deadlineNs: deadlineNs
            ))?.payloads ?? []
            // 先验:评估器给权重(远程=网络分布),缺省等权 1.0(P1 数值行为);
            // 远程失败硬传播。
            let weights: [Double]
            do {
                weights = try evaluator?.priors(for: payloads, state: state, catalog: catalog)
                    ?? Array(repeating: 1.0, count: payloads.count)
            } catch {
                throw MCTSError.inferenceFailed(underlying: String(describing: error))
            }
            node.pending = payloads.enumerated().map { ($0.element, weights[$0.offset], nil) }
        }

        /// PUCT:a* = argmax Q(s,a) + c·P(s,a)·√N/(1+N(a));
        /// Q 取"当前行动玩家"的均值(MaxN:轮到谁就最大化谁,Review Focus 1)。
        static func selectPUCT(_ node: Node, actor: PlayerID, c: Double) -> Node? {
            guard node.children.isEmpty == false else { return nil }
            let sqrtN = sqrt(Double(max(node.visits, 1)))
            var best: Node?
            var bestScore = -Double.infinity
            for child in node.children {
                let q = child.valueSum[actor].map { $0 / Double(max(child.visits, 1)) } ?? 0
                let score = q + c * child.prior * sqrtN / Double(1 + child.visits)
                if score > bestScore {
                    bestScore = score
                    best = child
                }
            }
            return best
        }

        /// 根先验噪声:均匀混合(0.75 + 0.5·U)近似 spec 的 Dirichlet(α=0.3, 权重 0.25);
        /// V1 无网络先验,仅用于自博弈多样性;seed 确定 → 结果仍可复现。
        private static func applyRootNoise(_ root: Node, using rng: inout SplitMix64Seed) {
            guard let pending = root.pending, pending.count > 1 else { return }
            for index in pending.indices {
                let unit = Double(rng.next() % 1_000) / 1_000
                root.pending?[index].prior = 0.75 + 0.5 * unit
            }
        }

        static func describeKind(_ payload: PlayerIntent.Payload?) -> String {
            guard let payload else { return "root" }
            switch payload {
            case .pass: return "pass"
            case .build(let i): return "build:\(i.locationID)"
            case .network: return "network"
            case .develop: return "develop"
            case .sell: return "sell"
            case .loan: return "loan"
            case .scout: return "scout"
            case .forcedSale: return "forcedSale"
            case .confirmEraIntermission: return "confirmEra"
            case .confirmTurnEnd: return "confirmTurnEnd"
            case .retractTurnActions: return "retract"
            }
        }
    }
}

/// MCTS 内部确定性 RNG(与测试侧 SplitMix64 同族;仅 AI 模块使用)。
nonisolated struct SplitMix64Seed: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
