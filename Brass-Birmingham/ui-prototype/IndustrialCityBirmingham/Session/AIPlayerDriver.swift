import Foundation

/// 宿主侧 AI 驱动器(spec §10.3):监听权威状态流,AI 座位行动时搜索并经
/// submitAs 提交;确认类阶段自动处理;人类撤回/新事件到达即取消在途搜索。
/// 搜索计算跑在后台线程(detached Task),绝不阻塞主 actor。
@MainActor
final class AIPlayerDriver {
    struct SeatAssignment: Sendable {
        let seat: GameCore.PlayerID
        let difficulty: GameCore.AIDifficulty
        /// 缺省为难度档预设;测试可注入小预算。
        let configuration: GameCore.MCTSConfiguration

        init(
            seat: GameCore.PlayerID,
            difficulty: GameCore.AIDifficulty,
            configuration: GameCore.MCTSConfiguration? = nil
        ) {
            self.seat = seat
            self.difficulty = difficulty
            self.configuration = configuration ?? .preset(difficulty)
        }
    }

    private let coordinator: SessionCoordinator
    private let seats: [GameCore.PlayerID: SeatAssignment]
    private let minimumThinkNanos: UInt64
    private var observeTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    /// 最近一次各座位决策(调试面板数据源)。
    private(set) var lastDiagnostics: [GameCore.PlayerID: GameCore.MonteCarloTreeSearch.Decision] = [:]
    /// 测试观测钩子:每次驱动器发起提交时回调(座位 + payload)。
    var onSubmission: (@Sendable (GameCore.PlayerID, GameCore.PlayerIntent.Payload) -> Void)?

    init(
        coordinator: SessionCoordinator,
        seats: [SeatAssignment],
        minimumThinkMs: UInt64 = 800
    ) {
        self.coordinator = coordinator
        self.seats = Dictionary(uniqueKeysWithValues: seats.map { ($0.seat, $0) })
        self.minimumThinkNanos = minimumThinkMs * 1_000_000
    }

    func start() {
        guard observeTask == nil else { return }
        observeTask = Task { [weak self] in
            guard let stream = await self?.coordinator.stateUpdates() else { return }
            for await state in stream {
                guard let self, !Task.isCancelled else { return }
                self.handle(state)
            }
        }
    }

    func stop() {
        observeTask?.cancel()
        observeTask = nil
        searchTask?.cancel()
        searchTask = nil
    }

    private func handle(_ state: SessionCoordinator.State) {
        // 新状态到达:在途搜索立即作废(版本可能已过期/人类撤回/回合切换)。
        searchTask?.cancel()
        searchTask = nil
        guard let snapshot = state.snapshot else { return }
        if snapshot.gameEnded != nil { stop(); return }

        if let intermission = snapshot.eraIntermission {
            // 时代结算:为每个未确认的 AI 座位依次提交确认(单任务,整体可取消)。
            let pending = seats.keys
                .filter { intermission.confirmedPlayerIDs.contains($0) == false }
                .sorted { $0.rawValue < $1.rawValue }
            guard pending.isEmpty == false else { return }
            searchTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.minimumThinkNanos ?? 0)
                for seat in pending {
                    guard let self, !Task.isCancelled else { return }
                    self.onSubmission?(seat, .confirmEraIntermission)
                    try? await self.coordinator.submitAs(seat: seat, .confirmEraIntermission)
                }
            }
            return
        }

        let active = snapshot.activePlayerID
        guard seats[active] != nil else { return }

        if snapshot.awaitingTurnEndConfirmation {
            // AI 自己的回合结束确认。
            searchTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.minimumThinkNanos ?? 0)
                guard let self, !Task.isCancelled else { return }
                self.onSubmission?(active, .confirmTurnEnd)
                try? await self.coordinator.submitAs(seat: active, .confirmTurnEnd)
            }
            return
        }

        // active/forcedSale:搜索 → 最短思考延迟 → 提交(拒绝时按最新状态重试 ≤3)。
        let assignment = seats[active]!
        searchTask = Task { [weak self] in
            for _ in 0..<3 {
                guard let self, !Task.isCancelled else { return }
                guard let state = await self.coordinator.authoritativeStateForAI,
                      let catalog = await self.coordinator.verifiedCatalogForAI,
                      state.activePlayerID == active
                else { return }
                let configuration = assignment.configuration
                let decision = await Task.detached(priority: .userInitiated) {
                    try? GameCore.MonteCarloTreeSearch.chooseAction(
                        state: state, actorID: active, catalog: catalog, configuration: configuration
                    )
                }.value
                guard let decision, !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: self.minimumThinkNanos)
                guard !Task.isCancelled else { return }
                self.lastDiagnostics[active] = decision
                self.onSubmission?(active, decision.payload)
                do {
                    try await self.coordinator.submitAs(seat: active, decision.payload)
                    return
                } catch {
                    continue // staleVersion 等:取最新状态重试
                }
            }
        }
    }
}
