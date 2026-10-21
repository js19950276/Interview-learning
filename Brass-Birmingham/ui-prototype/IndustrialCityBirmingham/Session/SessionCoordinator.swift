import Foundation

nonisolated struct InvalidRecoveryReplayCache: Sendable {
    private let capacity: Int
    private var idsByHost: [GameCore.PlayerID: [SessionProtocol.MessageID]] = [:]

    init(capacity: Int = 128) {
        self.capacity = max(1, capacity)
    }

    mutating func insert(
        _ id: SessionProtocol.MessageID,
        authenticatedHostID: GameCore.PlayerID
    ) -> Bool {
        guard id.isValid else { return false }
        var ids = idsByHost[authenticatedHostID, default: []]
        guard !ids.contains(id) else { return false }
        ids.append(id)
        if ids.count > capacity { ids.removeFirst(ids.count - capacity) }
        idsByHost[authenticatedHostID] = ids
        return true
    }

    var count: Int { idsByHost.values.reduce(0) { $0 + $1.count } }
}

actor SessionCoordinator {
    enum RulesMode: Sendable {
        case verified(GameCore.VerifiedGameDataCatalog)
#if DEBUG
        case fixtureOnlyLegacy
#endif
    }

    private enum AuthorityCompleteness: Sendable {
        case complete
        case incompleteLegacy
    }

    struct State: Equatable, Sendable {
        let roomID: GameCore.RoomID
        let playerID: GameCore.PlayerID
        let hostPlayerID: GameCore.PlayerID
        let playerIDs: [GameCore.PlayerID]
        let readyPlayerIDs: [GameCore.PlayerID]
        let snapshot: GameCore.ViewSnapshot?
        let forcedSale: GameCore.ForcedSaleProjection?
        let peersNeedingRecovery: Set<GameCore.PlayerID>
        let lastDeliveryError: TransportError?
        let lastIntentRejection: GameCore.RejectedIntent?
        let lastInternalFailure: GameCore.InternalFailure?
        let persistenceError: SessionPersistenceError?
        let pauseReason: SessionProtocol.PauseReason?
        let recoveryError: RecoveryError?
        let lastLegalResponse: GameCore.LegalActionResponse?
        let lastClientEvent: GameCore.ClientEvent?
        let playerNames: [GameCore.PlayerID: String]
        let actionLog: [MatchActionLogEntry]
        let playerColors: [GameCore.PlayerID: GameCore.PlayerColor]
        /// 对局模式;客机值来自主机的大厅广播。
        let matchMode: GameCore.MatchMode
    }

    struct Configuration: Sendable {
        /// 会话协议;短局房间由主机在协议 2/3 之间切换(存档/信封都抄这个值)。
        var protocolVersion: Int
        let rulesetVersion: String
        let roomID: GameCore.RoomID
        let playerID: GameCore.PlayerID
        let reconnectToken: GameCore.ReconnectToken
        var displayName: String? = nil
        let hostPlayerID: GameCore.PlayerID
        let setupSeed: UInt64

        init(
            protocolVersion: Int,
            rulesetVersion: String,
            roomID: GameCore.RoomID,
            playerID: GameCore.PlayerID,
            reconnectToken: GameCore.ReconnectToken,
            hostPlayerID: GameCore.PlayerID,
            setupSeed: UInt64 = 1,
            displayName: String? = nil
        ) {
            self.protocolVersion = protocolVersion
            self.rulesetVersion = rulesetVersion
            self.roomID = roomID
            self.playerID = playerID
            self.reconnectToken = reconnectToken
            self.hostPlayerID = hostPlayerID
            self.setupSeed = setupSeed
            self.displayName = displayName
        }
    }

    enum Error: String, Swift.Error, Equatable, Sendable {
        case hostOnly
        case roomNotCreated
        case roomFull
        case incompatiblePeer
        case roomMismatch
        case reconnectTokenMismatch
        case notAllPlayersReady
        case gameNotStarted
        case joinTimedOut
        case harnessPhaseTimedOut
        case persistenceUnavailable
        case dataUnavailable
        case sessionPaused
        case restoredProjectionInvalid
        case gameAlreadyStarted
    }

    private struct ReplayScope: Hashable, Sendable {
        let sender: GameCore.PlayerID
    }

    private struct ReplayCache: Sendable {
        private var idsByScope: [ReplayScope: [SessionProtocol.MessageID]] = [:]

        mutating func insert(_ id: SessionProtocol.MessageID, scope: ReplayScope) -> Bool {
            guard id.isValid else { return false }
            var ids = idsByScope[scope, default: []]
            guard !ids.contains(id) else { return false }
            ids.append(id)
            if ids.count > 128 { ids.removeFirst(ids.count - 128) }
            idsByScope[scope] = ids
            return true
        }

        var scopeCount: Int { idsByScope.count }
    }

    private enum JoinOutcome { case pending, accepted, rejected(Error) }
    private enum StartPhase { case notStarted, starting, started }
    // 协议字段可变:短局房间把被档案/信封/PlayerIntent 抄走的这个数升到 3,
    // 全部拷贝点都读 configuration.protocolVersion,不另立第二套数字。
    private var configuration: Configuration
    private let transport: any Transport
    private let persistence: (any SessionArchivePersisting)?
    private let tokenStore: RoomTokenStore?
    private let guestRecoveryFailureHandler: (any GuestRecoveryFailureHandling)?
    private let rulesMode: RulesMode
    private let verifiedCatalog: GameCore.VerifiedGameDataCatalog?
    nonisolated let presentationCatalog: GameCore.VerifiedGameDataCatalog?
    private var processingTask: Task<Void, Never>?
    private var peerByPlayer: [GameCore.PlayerID: GameCore.PlayerID] = [:]
    private var tokens: [GameCore.PlayerID: GameCore.ReconnectToken] = [:]
    /// AI 接管的座位(host 侧生成,无传输对端;单机模式)。
    private(set) var aiSeatIDs: Set<GameCore.PlayerID> = []
    private var ready: Set<GameCore.PlayerID> = []
    private var replayCache = ReplayCache()
    private var invalidRecoveryReplayCache = InvalidRecoveryReplayCache()
    private var engine: GameCore.HostEngine?
    private var eventWindows: [GameCore.PlayerID: [SessionProtocol.SessionEnvelope]] = [:]
    private var joinOutcome: JoinOutcome = .pending
    /// 玩家显示名(含房主),随大厅广播与投影下发。
    private var playerNames: [GameCore.PlayerID: String] = [:]
    private var startPhase: StartPhase = .notStarted
    /// 对局模式(主机权威);开局时传给 makeGame,大厅广播随名册下发。
    private(set) var matchMode: GameCore.MatchMode = .standard
    /// 协议切换期间需要按新协议重新 hello 的座位;发送返回后仍带标记者移出名册。
    private var needsProtocolRehello: Set<GameCore.PlayerID> = []
    /// 客机跟随协议后的待确认标记:翻转后的 hello 再被拒即停,不在 2/3 之间震荡。
    private var awaitingProtocolFollowAck = false
    private var stateContinuations: [UUID: AsyncStream<State>.Continuation] = [:]
    private(set) var snapshot: GameCore.ViewSnapshot?
    /// 缺初始快照时只发一次恢复请求,防止每个到达的事件都触发 catchUp。
    private var didRequestInitialRecovery = false
    private(set) var processedMessageCount = 0
    private(set) var peersNeedingRecovery: Set<GameCore.PlayerID> = []
    private(set) var lastDeliveryError: TransportError?
    private(set) var lastIntentRejection: GameCore.RejectedIntent?
    private(set) var lastInternalFailure: GameCore.InternalFailure?
    private(set) var persistenceError: SessionPersistenceError?
    private(set) var pauseReason: SessionProtocol.PauseReason?
    private(set) var recoveryError: RecoveryError?
    private(set) var lastLegalResponse: GameCore.LegalActionResponse?
    private(set) var lastClientEvent: GameCore.ClientEvent?
    private var recoveryTargetVersion: GameCore.AuthoritativeVersion?
    private var persistenceCommitSequence: UInt64 = 0
    private var authorityCompleteness = AuthorityCompleteness.complete
    private var isResolving = false
    private var resolveWaiters: [CheckedContinuation<Void, Never>] = []

    var playerIDs: [GameCore.PlayerID] { tokens.keys.sorted { $0.rawValue < $1.rawValue } }
    var readyPlayerIDs: [GameCore.PlayerID] { ready.sorted { $0.rawValue < $1.rawValue } }
    var replayScopeCount: Int { replayCache.scopeCount }
    var stateSubscriberCount: Int { stateContinuations.count }
    var isProcessing: Bool { processingTask != nil }
    var forcedSale: GameCore.ForcedSaleProjection? { snapshot?.forcedSale }

    init(
        configuration: Configuration,
        transport: some Transport,
        persistence: (any SessionArchivePersisting)? = nil,
        tokenStore: RoomTokenStore? = nil,
        guestRecoveryFailureHandler: (any GuestRecoveryFailureHandling)? = nil,
        rulesMode: RulesMode
    ) {
        self.configuration = configuration
        self.transport = transport
        self.persistence = persistence
        self.tokenStore = tokenStore
        self.guestRecoveryFailureHandler = guestRecoveryFailureHandler
        self.rulesMode = rulesMode
        if case .verified(let catalog) = rulesMode {
            verifiedCatalog = catalog
            presentationCatalog = catalog
        } else {
            verifiedCatalog = nil
            presentationCatalog = nil
        }
    }

    init(
        configuration: Configuration,
        restored: RestoredHostSession,
        transport: some Transport,
        persistence: (any SessionArchivePersisting)? = nil,
        tokenStore: RoomTokenStore? = nil,
        guestRecoveryFailureHandler: (any GuestRecoveryFailureHandling)? = nil,
        rulesMode: RulesMode
    ) throws {
        self.configuration = configuration
        self.transport = transport
        self.persistence = persistence
        self.tokenStore = tokenStore
        self.guestRecoveryFailureHandler = guestRecoveryFailureHandler
        self.rulesMode = rulesMode
        if case .verified(let catalog) = rulesMode {
            verifiedCatalog = catalog
            presentationCatalog = catalog
        } else {
            verifiedCatalog = nil
            presentationCatalog = nil
        }
        tokens = Dictionary(uniqueKeysWithValues: restored.state.players.map {
            ($0.id, $0.reconnectToken)
        })
        if restored.hasCompleteGameState {
            engine = try restored.gameState.makeHostEngine(
                roomID: configuration.roomID,
                reconnectTokens: tokens,
                protocolVersion: configuration.protocolVersion
            )
        } else {
            engine = try GameCore.GameState.legacyCompatible(
                restored.state, rulesetVersion: configuration.rulesetVersion
            ).makeHostEngine(
                roomID: configuration.roomID,
                reconnectTokens: tokens,
                protocolVersion: configuration.protocolVersion
            )
        }
        peerByPlayer[configuration.playerID] = configuration.playerID
        eventWindows = restored.eventWindows.mapValues { Array($0.suffix(128)) }
        peersNeedingRecovery = restored.peersNeedingRecovery
        persistenceCommitSequence = restored.commitSequence
        authorityCompleteness = restored.hasCompleteGameState ? .complete : .incompleteLegacy
        guard let engine else { throw Error.restoredProjectionInvalid }
        if let verifiedCatalog {
            snapshot = try engine.snapshot(for: configuration.playerID, catalog: verifiedCatalog)
        } else {
            snapshot = try engine.snapshot(for: configuration.playerID)
        }
        startPhase = .started
    }

    init(
        configuration: Configuration,
        restoredGuest: GuestSessionArchive,
        restoredCommitSequence: UInt64 = 0,
        transport: some Transport,
        persistence: (any SessionArchivePersisting)? = nil,
        tokenStore: RoomTokenStore? = nil,
        guestRecoveryFailureHandler: (any GuestRecoveryFailureHandling)? = nil,
        rulesMode: RulesMode
    ) {
        self.configuration = configuration
        self.transport = transport
        self.persistence = persistence
        self.tokenStore = tokenStore
        self.guestRecoveryFailureHandler = guestRecoveryFailureHandler
        self.rulesMode = rulesMode
        if case .verified(let catalog) = rulesMode {
            verifiedCatalog = catalog
            presentationCatalog = catalog
        } else {
            verifiedCatalog = nil
            presentationCatalog = nil
        }
        snapshot = restoredGuest.snapshot
        eventWindows[configuration.playerID] = Array(restoredGuest.eventWindow.suffix(128))
        persistenceCommitSequence = restoredCommitSequence
    }

    func stateUpdates() -> AsyncStream<State> {
        let id = UUID()
        return AsyncStream { continuation in
            stateContinuations[id] = continuation
            continuation.yield(currentState)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateContinuation(id) }
            }
        }
    }

    func createRoom(port: UInt16? = nil) async throws {
        guard isHost else { throw Error.hostOnly }
        startProcessingIfNeeded()
        tokens[configuration.playerID] = configuration.reconnectToken
        peerByPlayer[configuration.playerID] = configuration.playerID
        if let ownName = configuration.displayName, ownName.isEmpty == false {
            playerNames[configuration.playerID] = String(ownName.prefix(12))
        }
        playerColors[configuration.playerID] = lowestFreeColor()
        try await tokenStore?.save(.init(
            roomID: configuration.roomID,
            playerID: configuration.playerID,
            reconnectToken: configuration.reconnectToken
        ))
        publishState()
        try await transport.startHosting(roomID: configuration.roomID, port: port)
        print("INDUSTRIALCITY_LOCAL host room=\(configuration.roomID.rawValue)")
    }

    func joinRoom() async throws {
        guard !isHost else { throw Error.hostOnly }
        startProcessingIfNeeded()
        try await transport.browse()
        try await transport.connect(to: configuration.hostPlayerID)
        // 复位上一次加入的结论,避免同实例二次加入立即假成功。
        joinOutcome = .pending
        try await send(.hello(reconnectToken: configuration.reconnectToken, displayName: configuration.displayName), to: configuration.hostPlayerID)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            switch joinOutcome {
            case .accepted:
                publishState()
                print("INDUSTRIALCITY_LOCAL joined room=\(configuration.roomID.rawValue)")
                return
            case let .rejected(error): throw error
            case .pending: try await Task.sleep(for: .milliseconds(50))
            }
        }
        throw Error.joinTimedOut
    }

    func setReady(_ value: Bool) async throws {
        if isHost {
            if value { ready.insert(configuration.playerID) } else { ready.remove(configuration.playerID) }
            publishState()
            await broadcastLobbyState()
        } else {
            try await send(.ready(value), to: configuration.hostPlayerID)
        }
    }

    /// 主机选择对局模式(仅大厅阶段、棋盘未写出)。切换协议时:
    /// 先写新协议并标记全部客机座位,发 versionIncompatible 期间按新协议
    /// hello 回来的座位保留;发送返回后仍带标记者移出名册,再广播缩小后的名册。
    func setMatchMode(_ mode: GameCore.MatchMode) async throws {
        guard isHost else { throw Error.hostOnly }
        guard startPhase == .notStarted, engine == nil, snapshot == nil else {
            throw Error.gameAlreadyStarted
        }
        let target = mode == .shortCanal ? 3 : 2
        let changed = matchMode != mode
        matchMode = mode
        guard changed, target != configuration.protocolVersion else {
            await broadcastLobbyState()
            return
        }
        // 1) 先写新协议:发通知期间按新协议 hello 的客机能对上协议检查。
        configuration.protocolVersion = target
        needsProtocolRehello = Set(playerIDs.filter { $0 != configuration.playerID })
        for player in needsProtocolRehello { ready.remove(player) }   // tokens 先不动
        // 2) 发 versionIncompatible;.hello 处理会把按新协议回来的人移出标记。
        for player in playerIDs where player != configuration.playerID {
            try? await send(.versionIncompatible, to: player)
        }
        // 3) 发送全部返回:仍带标记的座位移出名册(断线/旧构建都不会重新 hello)。
        //    恢复名册与连接映射一并清掉,否则幽灵座位会把主机永久卡在 recovering。
        for player in needsProtocolRehello {
            tokens[player] = nil
            ready.remove(player)
            peersNeedingRecovery.remove(player)
            peerByPlayer[player] = nil
        }
        needsProtocolRehello = []
        // 4) 广播缩小后的名册;startGame 只给剩下的 tokens 发牌。
        await broadcastLobbyState()
    }

    func startGame() async throws {
        guard isHost else { throw Error.hostOnly }
        guard startPhase == .notStarted else { throw Error.gameAlreadyStarted }
        guard tokens.count >= 2, ready == Set(tokens.keys) else { throw Error.notAllPlayersReady }
        startPhase = .starting
        let ordered = [configuration.hostPlayerID] + playerIDs.filter { $0 != configuration.hostPlayerID }
        // 座位颜色:房主与未入座的座位用默认分配兜底。
        var seatColors = playerColors
        if seatColors[configuration.playerID] == nil {
            seatColors[configuration.playerID] = lowestFreeColor()
        }
        if let verifiedCatalog {
            do {
                var setup = GameCore.SetupRules(seed: configuration.setupSeed)
                let game = try setup.makeGame(
                    catalog: verifiedCatalog, playerIDs: ordered, colors: seatColors, mode: matchMode
                )
                engine = try game.state.makeHostEngine(
                    roomID: configuration.roomID,
                    reconnectTokens: tokens,
                    protocolVersion: configuration.protocolVersion
                )
            } catch {
                // 开局失败回滚到未开始,否则重试永远 gameAlreadyStarted 且新座位被拒。
                startPhase = .notStarted
                engine = nil
                throw error
            }
            authorityCompleteness = .complete
            startPhase = .started
            try await distributeInitialSnapshots()
            publishState()
#if DEBUG
            print("INDUSTRIALCITY_LOCAL started room=\(configuration.roomID.rawValue)")
#endif
            return
        }
#if DEBUG
        let players = ordered.enumerated().map { index, id in
            GameCore.AuthoritativePlayer(id: id, reconnectToken: tokens[id]!, hand: ["card-\(index)-a", "card-\(index)-b"])
        }
        let legacyState = GameCore.AuthoritativeGameState(
            roomID: configuration.roomID, players: players, activePlayerID: ordered[0], turn: 1,
            actionNumber: 0, authoritativeVersion: .init(rawValue: 0), discardPile: []
        )
        engine = try GameCore.GameState.legacyCompatible(
            legacyState, rulesetVersion: configuration.rulesetVersion
        ).makeHostEngine(
            roomID: configuration.roomID,
            reconnectTokens: tokens,
            protocolVersion: configuration.protocolVersion
        )
        startPhase = .started
        try await distributeInitialSnapshots()
        publishState()
        print("INDUSTRIALCITY_LOCAL started room=\(configuration.roomID.rawValue)")
#else
        throw Error.dataUnavailable
#endif
    }

    func pass(discardCardID: String) async throws {
        try await submit(.pass(.init(cardID: discardCardID)))
    }

    /// 单机模式:房主 + N 个 AI 座位直接开局。不进大厅名册广播、不给 AI 发快照、
    /// 不写 tokenStore(AI 不重连);座位进入 tokens/ready/颜色/名册后复用 startGame 主体。
    func startSinglePlayerGame(aiDifficulties: [GameCore.AIDifficulty]) async throws {
        guard isHost else { throw Error.hostOnly }
        guard startPhase == .notStarted, engine == nil else { throw Error.gameAlreadyStarted }
        guard let verifiedCatalog else { throw Error.dataUnavailable }
        tokens[configuration.playerID] = configuration.reconnectToken
        ready.insert(configuration.playerID)
        playerColors[configuration.playerID] = playerColors[configuration.playerID] ?? lowestFreeColor()
        for (index, difficulty) in aiDifficulties.enumerated() {
            let seat = GameCore.PlayerID(rawValue: "ai-\(index + 1)")
            tokens[seat] = GameCore.ReconnectToken(rawValue: UUID().uuidString)
            ready.insert(seat)
            aiSeatIDs.insert(seat)
            playerNames[seat] = "AI·\(difficulty.displayName)"
            playerColors[seat] = lowestFreeColor()
        }
        try await startGame()
    }

    /// 仅限 AI 座位:以该座位身份过宿主权威门(串行化/日志/事件落地全复用)。
    func submitAs(seat: GameCore.PlayerID, _ payload: GameCore.PlayerIntent.Payload) async throws {
        guard isHost, aiSeatIDs.contains(seat) else { throw Error.hostOnly }
        guard let engine else { throw Error.gameNotStarted }
        let intent = GameCore.PlayerIntent(
            protocolVersion: configuration.protocolVersion,
            rulesetVersion: configuration.rulesetVersion,
            roomID: configuration.roomID,
            senderID: seat,
            reconnectToken: tokens[seat] ?? configuration.reconnectToken,
            baseVersion: engine.gameState.authoritativeVersion,
            payload: payload
        )
        try await resolve(intent)
    }

    /// AIPlayerDriver 只读支持面(宿主侧;AI 的手牌等隐藏信息只有宿主引擎可见)。
    var authoritativeStateForAI: GameCore.GameState? { engine?.gameState }
    var verifiedCatalogForAI: GameCore.VerifiedGameDataCatalog? { verifiedCatalog }

    func submit(_ payload: GameCore.PlayerIntent.Payload) async throws {
        if !isHost, pauseReason != nil { throw Error.sessionPaused }
        guard let snapshot else { throw Error.gameNotStarted }
        let intent = GameCore.PlayerIntent(
            protocolVersion: configuration.protocolVersion, rulesetVersion: configuration.rulesetVersion,
            roomID: configuration.roomID, senderID: configuration.playerID,
            reconnectToken: configuration.reconnectToken, baseVersion: snapshot.authoritativeVersion,
            payload: payload
        )
        if isHost { try await resolve(intent) }
        else {
            try await send(.intent(intent), to: configuration.hostPlayerID, version: snapshot.authoritativeVersion)
            print("INDUSTRIALCITY_LOCAL intent-sent version=\(snapshot.authoritativeVersion.rawValue)")
        }
    }

    func requestLegalOptions(
        requestID: String,
        draft: GameCore.LegalActionDraft
    ) async throws {
        guard let snapshot else { throw Error.gameNotStarted }
        lastIntentRejection = nil
        let query = GameCore.LegalActionQuery(
            requestID: requestID,
            baseVersion: snapshot.authoritativeVersion,
            draft: draft
        )
        if isHost {
            guard let engine, let verifiedCatalog else { throw Error.dataUnavailable }
            lastLegalResponse = try GameCore.LegalActionQueryEngine.respond(
                to: query, actorID: configuration.playerID,
                state: engine.gameState, catalog: verifiedCatalog
            )
            publishState()
        } else {
            try await send(.legalQuery(query), to: configuration.hostPlayerID, version: snapshot.authoritativeVersion)
        }
    }

    func disconnect() async {
        hostReconnectTask?.cancel()
        hostReconnectTask = nil
        processingTask?.cancel()
        processingTask = nil
        for continuation in stateContinuations.values { continuation.finish() }
        stateContinuations.removeAll()
        await transport.disconnect()
    }

    // MARK: - 断线自愈(切出 app 后回来直接继续)

    private var hostReconnectTask: Task<Void, Never>?

    /// 前台自愈入口:客机对断链/paused 状态立即重试重连;房主确保监听器
    /// 在挂起后仍可被发现。由 SessionViewStore.handleScenePhase(.active) 调用。
    func applicationDidBecomeActive() async {
        if isHost {
            await transport.reviveHostingIfNeeded()
            return
        }
        var linkAlive = pauseReason == nil
        if linkAlive {
            linkAlive = await transport.isConnected(to: configuration.hostPlayerID)
        }
        if linkAlive == false {
            hostReconnectTask?.cancel()
            hostReconnectTask = nil
            beginHostReconnectLoop()
        }
    }

    /// 客机自动重拨房主:重放 joinRoom 的 connect+hello 握手,座位凭
    /// reconnect token 重新绑定,再由既有 createRoom→catchUp 流程补齐状态。
    private func beginHostReconnectLoop() {
        guard hostReconnectTask == nil else { return }
        hostReconnectTask = Task { [weak self] in
            await self?.runHostReconnectLoop()
        }
    }

    private func runHostReconnectLoop() async {
        var delay: Duration = .milliseconds(500)
        while Task.isCancelled == false {
            if await attemptHostReconnect() { break }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(5))
        }
        hostReconnectTask = nil
    }

    /// 单次重连尝试。返回 true 表示停止循环(恢复成功,或座位被拒重试无意义)。
    private func attemptHostReconnect() async -> Bool {
        do {
            try await transport.connect(to: configuration.hostPlayerID)
            joinOutcome = .pending
            try await send(
                .hello(reconnectToken: configuration.reconnectToken, displayName: configuration.displayName),
                to: configuration.hostPlayerID
            )
        } catch {
            return false
        }
        SessionDiagnostics.log("HOST-RECONNECT seat=\(configuration.playerID.rawValue) dialed")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return true }
            if pauseReason == nil { return true }
            if case .accepted = joinOutcome { return true }
            if case .rejected(let reason) = joinOutcome {
                // 令牌不符/房间不符/协议不符:座位已不可用,停止重试。
                switch reason {
                case .reconnectTokenMismatch, .roomMismatch, .incompatiblePeer: return true
                default: return false
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// 更新自己的显示名:房主本地登记并重播大厅;客人发送 rename 给房主。
    func updateDisplayName(_ name: String) async {
        let trimmed = String(name.prefix(12))
        guard trimmed.isEmpty == false else { return }
        if isHost {
            playerNames[configuration.playerID] = trimmed
            publishState()
            await broadcastLobbyState()
        } else {
            do {
                try await send(
                    .rename(displayName: trimmed),
                    to: configuration.hostPlayerID,
                    version: snapshot?.authoritativeVersion ?? .init(rawValue: 0)
                )
            } catch {
                recordDeliveryFailure(for: configuration.playerID, error: error)
            }
        }
    }

    /// 切后台时尽力同步刷盘一次。存盘失败不抛错、不阻断对局——
    /// 后台循环会持续重试,回来时对局照常继续。
    func persistForBackground() async {
        await acquireResolveGate()
        // 有失败积压时优先重试最新积压档案,否则按当前状态落盘。
        if let pending = latestPendingArchive {
            await persistArchiveNow(pending)
        } else {
            await persistCurrentStateNow()
        }
        releaseResolveGate()
        await waitForPendingPersistenceToDrain(timeout: .seconds(2))
    }

    /// 手动触发一次同步刷盘(诊断兜底);同样不抛错。
    func retryPersistence() async {
        await persistForBackground()
    }

    private var isHost: Bool { configuration.playerID == configuration.hostPlayerID }

    private func startProcessingIfNeeded() {
        guard processingTask == nil else { return }
        processingTask = Task { [weak self, transport] in
            let events = await transport.events
            for await event in events {
                guard !Task.isCancelled else { break }
                await self?.handle(event)
            }
        }
    }

    private func handle(_ event: TransportEvent) async {
        switch event {
        case let .received(data, peer):
            if let envelope = try? JSONDecoder().decode(SessionProtocol.SessionEnvelope.self, from: data),
               envelope.messageID.isValid {
                if isHost { await handleAsHost(envelope, peer: peer) }
                else { await handleAsGuest(envelope, peer: peer) }
            } else {
                print("INDUSTRIALCITY_LOCAL discarded undecodable frame peer=\(peer.rawValue)")
            }
        case let .disconnected(peer, _):
            if !isHost, peer == configuration.hostPlayerID {
                pauseReason = .hostDisconnected
                // 切出 app/网络抖动导致的断链由客机自动重拨,不需要玩家手动重进。
                beginHostReconnectLoop()
                publishState()
            } else if isHost, let player = peerByPlayer.first(where: { $0.value == peer })?.key {
                peersNeedingRecovery.insert(player)
                publishState()
            }
        case .connected, .discovered:
            break
        }
    }

    private func handleAsHost(_ envelope: SessionProtocol.SessionEnvelope, peer: GameCore.PlayerID) async {
        guard envelope.roomID == configuration.roomID else {
            try? await send(.rejection(.init(reasonCode: .wrongRoom,
                recoverySuggestion: "Return to the lobby and join the authoritative room.")),
                toTransportPeer: peer, recipient: envelope.senderID, envelopeRoomID: envelope.roomID)
            return
        }
        guard envelope.protocolVersion == configuration.protocolVersion else {
            try? await send(.versionIncompatible, toTransportPeer: peer, recipient: envelope.senderID)
            return
        }
        guard envelope.rulesetVersion == configuration.rulesetVersion else {
            // 规则集不符是可解释的拒绝,不是协议不兼容;客机硬失败,不翻转协议。
            try? await send(.rejection(.init(
                reasonCode: .rulesetVersionMismatch,
                recoverySuggestion: "Update to the same ruleset version to join this room."
            )), toTransportPeer: peer, recipient: envelope.senderID)
            return
        }
        switch envelope.payload {
        case let .hello(token, displayName):
            guard envelope.recipientID == configuration.playerID else { return }
            // 协议切换期间:按当前(新)协议回来的 hello 把座位移出待重连名册。
            needsProtocolRehello.remove(envelope.senderID)
            if let existing = tokens[envelope.senderID], existing != token {
                try? await send(.rejection(.init(reasonCode: .invalidReconnectToken,
                    recoverySuggestion: "Reauthenticate the seat with its reconnect token.")),
                    toTransportPeer: peer, recipient: envelope.senderID)
                return
            }
            // 对局已开始后拒绝新座位：权威引擎的玩家集合已固定，新座位会让
            // finishResolution 的投影对未知接收者抛错，卡死之后所有行动。
            if tokens[envelope.senderID] == nil, startPhase != .notStarted {
                try? await send(.rejection(.init(reasonCode: .unknownSender,
                    recoverySuggestion: "The match has already started; the room accepts no new seats.")),
                    toTransportPeer: peer, recipient: envelope.senderID)
                return
            }
            // 一条连接只能绑定一个座位，防止同一设备声明多个身份。
            if let bound = peerByPlayer.first(where: { $0.value == peer })?.key, bound != envelope.senderID {
                try? await send(.rejection(.init(reasonCode: .invalidReconnectToken,
                    recoverySuggestion: "This connection is already bound to another seat.")),
                    toTransportPeer: peer, recipient: envelope.senderID)
                return
            }
            guard tokens[envelope.senderID] != nil || tokens.count < 4 else {
                try? await send(.rejection(.init(reasonCode: .unknownSender,
                    recoverySuggestion: "The room already has four assigned seats.")),
                    toTransportPeer: peer, recipient: envelope.senderID)
                return
            }
            guard acceptUnique(envelope, peer: peer) else { return }
            let previousToken = tokens[envelope.senderID]
            tokens[envelope.senderID] = token
            peerByPlayer[envelope.senderID] = peer
            if let name = displayName, name.isEmpty == false {
                playerNames[envelope.senderID] = String(name.prefix(12))
            } else if playerNames[envelope.senderID] == nil {
                playerNames[envelope.senderID] = "玩家-\(String(envelope.senderID.rawValue.suffix(4)))"
            }
            if playerColors[envelope.senderID] == nil {
                playerColors[envelope.senderID] = lowestFreeColor()
            }
            do {
                try await tokenStore?.save(.init(
                    roomID: configuration.roomID,
                    playerID: envelope.senderID,
                    reconnectToken: token
                ))
            } catch {
                // 回滚恢复原值而非抹除:已知座位不能因 keychain 瞬时失败永久失联。
                tokens[envelope.senderID] = previousToken
                peerByPlayer[envelope.senderID] = nil
                try? await send(.rejection(.init(
                    reasonCode: .persistenceUnavailable,
                    recoverySuggestion: "Wait while the host safely saves the assigned seat, then retry."
                )), toTransportPeer: peer, recipient: envelope.senderID)
                return
            }
            publishState()
            if startPhase == .notStarted {
                // 大厅阶段座位重新归队即视为已同步:恢复标记只对已开局的对局有意义。
                peersNeedingRecovery.remove(envelope.senderID)
                if peersNeedingRecovery.isEmpty { lastDeliveryError = nil }
            }
            do {
                try await send(
                    .createRoom,
                    to: envelope.senderID,
                    version: engine?.state.authoritativeVersion ?? .init(rawValue: 0)
                )
                await broadcastLobbyState()
            } catch {
                recordDeliveryFailure(for: envelope.senderID, error: error)
            }
        case let .ready(value):
            guard envelope.recipientID == configuration.playerID,
                  tokens[envelope.senderID] != nil, peerByPlayer[envelope.senderID] == peer else { return }
            guard acceptUnique(envelope, peer: peer) else { return }
            // 开局后的准备状态没有意义,忽略以避免改写对局中的名册。
            guard startPhase == .notStarted else { return }
            if value { ready.insert(envelope.senderID) } else { ready.remove(envelope.senderID) }
            publishState()
            await broadcastLobbyState()
        case let .intent(intent):
            guard envelope.recipientID == configuration.playerID,
                  envelope.senderID == intent.senderID,
                  peerByPlayer[intent.senderID] == peer, tokens[intent.senderID] == intent.reconnectToken else { return }
            guard acceptUnique(envelope, peer: peer) else { return }
            do { try await resolve(intent) }
            catch Error.sessionPaused { return }
            catch {
                // 规则/状态级失败不是投递失败:回 rejected 而不是把发送者
                // 标记为需要恢复(那会让房主 UI 无端进入恢复态)。
                try? await send(.rejection(.init(
                    reasonCode: .invalidAction,
                    recoverySuggestion: "Refresh the authoritative state and choose a legal action target."
                )), to: intent.senderID)
            }
        case let .rename(displayName):
            guard envelope.recipientID == configuration.playerID,
                  tokens[envelope.senderID] != nil,
                  peerByPlayer[envelope.senderID] == peer,
                  acceptUnique(envelope, peer: peer, countsAsProcessedMessage: false) else { return }
            let trimmed = String(displayName.prefix(12))
            guard trimmed.isEmpty == false else { return }
            playerNames[envelope.senderID] = trimmed
            publishState()
            await broadcastLobbyState()
        case let .chooseColor(color):
            guard envelope.recipientID == configuration.playerID,
                  tokens[envelope.senderID] != nil,
                  peerByPlayer[envelope.senderID] == peer,
                  acceptUnique(envelope, peer: peer, countsAsProcessedMessage: false) else { return }
            guard startPhase == .notStarted else { return }
            if assignColor(color, to: envelope.senderID) {
                publishState()
                await broadcastLobbyState()
            } else {
                try? await send(.rejection(.init(
                    reasonCode: .invalidAction,
                    recoverySuggestion: "That color is already taken by another player."
                )), toTransportPeer: peer, recipient: envelope.senderID)
            }
        case let .legalQuery(query):
            guard envelope.recipientID == configuration.playerID,
                  peerByPlayer[envelope.senderID] == peer,
                  let engine, let verifiedCatalog,
                  acceptUnique(envelope, peer: peer, countsAsProcessedMessage: false)
            else { return }
            let response: GameCore.LegalActionResponse
            do {
                response = try GameCore.LegalActionQueryEngine.respond(
                    to: query, actorID: envelope.senderID,
                    state: engine.gameState, catalog: verifiedCatalog
                )
            } catch let error as GameCore.LegalActionQueryError {
                let digest: String
                do { digest = try query.draft.canonicalDigest() }
                catch { return }
                response = .init(
                    requestID: query.requestID, baseVersion: query.baseVersion,
                    draftDigest: digest,
                    nextChoices: [], confirmation: nil, completePayload: nil,
                    error: error
                )
            } catch {
                response = .init(
                    requestID: query.requestID, baseVersion: query.baseVersion,
                    nextChoices: [], confirmation: nil, completePayload: nil,
                    error: .malformedQuery
                )
            }
            do {
                try await send(
                    .legalResponse(response), to: envelope.senderID,
                    version: response.baseVersion
                )
            } catch { recordDeliveryFailure(for: envelope.senderID, error: error) }
        case let .catchUp(fromVersion):
            guard envelope.recipientID == configuration.playerID,
                  tokens[envelope.senderID] != nil, peerByPlayer[envelope.senderID] == peer else { return }
            guard acceptUnique(envelope, peer: peer, countsAsProcessedMessage: false) else { return }
            // 恢复重放与行动扇出串行：避免窗口补发与新事件在同一条连接上交错，
            // 否则 guest 端会把"版本超前"的合法消息误判为无效恢复材料并累计 strike。
            await acquireResolveGate()
            do {
                try await sendRecovery(to: envelope.senderID, fromVersion: fromVersion)
                releaseResolveGate()
            } catch {
                releaseResolveGate()
                recordDeliveryFailure(for: envelope.senderID, error: error)
            }
        default: break
        }
    }

    private func handleAsGuest(_ envelope: SessionProtocol.SessionEnvelope, peer: GameCore.PlayerID) async {
        guard envelope.roomID == configuration.roomID,
              peer == configuration.hostPlayerID,
              envelope.senderID == configuration.hostPlayerID,
              envelope.recipientID == configuration.playerID else { return }
        switch envelope.payload {
        case .createRoom:
            guard acceptUnique(envelope, peer: peer) else { return }
            awaitingProtocolFollowAck = false
            joinOutcome = .accepted
            recoveryTargetVersion = envelope.authoritativeVersion
            // 跨生命周期防御:本地存档版本高于新房间的权威版本,说明是上一局残留,
            // 弃用旧快照与事件窗,重新走完整的恢复流程。
            if let current = snapshot,
               current.authoritativeVersion.rawValue > envelope.authoritativeVersion.rawValue {
                snapshot = nil
                eventWindows[configuration.playerID] = nil
                lastClientEvent = nil
            }
            pauseReason = recoveryIsComplete(at: snapshot?.authoritativeVersion) ? nil : .stateRecovery
            if pauseReason == nil { await guestRecoveryFailureHandler?.recoverySucceeded() }
            let fromVersion = snapshot?.authoritativeVersion ?? .init(rawValue: -1)
            try? await send(.catchUp(fromVersion: fromVersion), to: configuration.hostPlayerID, version: fromVersion)
        case .versionIncompatible:
            guard acceptUnique(envelope, peer: peer) else { return }
            if awaitingProtocolFollowAck {
                // 翻转后的 hello 仍被拒:停止,不在 2/3 之间震荡。
                awaitingProtocolFollowAck = false
                joinOutcome = .rejected(.incompatiblePeer)
                return
            }
            // 跟随主机:2→3、3→2,立刻用改过的存储值重新 hello 一次。
            // 旧构建没有这条分支,收到即在上面的拒绝路径停下,不会 hello。
            configuration.protocolVersion = configuration.protocolVersion == 3 ? 2 : 3
            awaitingProtocolFollowAck = true
            try? await send(
                .hello(reconnectToken: configuration.reconnectToken, displayName: configuration.displayName),
                to: configuration.hostPlayerID
            )
        case let .rejection(rejection):
            guard acceptUnique(envelope, peer: peer) else { return }
            if snapshot == nil {
                switch rejection.reasonCode {
                case .wrongRoom: joinOutcome = .rejected(.roomMismatch)
                case .invalidReconnectToken: joinOutcome = .rejected(.reconnectTokenMismatch)
                case .rulesetVersionMismatch: joinOutcome = .rejected(.incompatiblePeer)
                default: joinOutcome = .rejected(.roomFull)
                }
            } else {
                lastIntentRejection = rejection
                publishState()
            }
        case let .lobbyState(lobby):
            guard envelope.protocolVersion == configuration.protocolVersion,
                  envelope.rulesetVersion == configuration.rulesetVersion,
                  validatedLobbyState(lobby), acceptUnique(envelope, peer: peer) else { return }
            // 名册同步成功:协议跟随的待确认标记清零(主机再改模式可以再翻转一次)。
            awaitingProtocolFollowAck = false
            // 模式由主机权威决定:客机跟随广播。
            matchMode = lobby.matchMode
            tokens = Dictionary(uniqueKeysWithValues: lobby.playerIDs.map { ($0, .init(rawValue: "host-authoritative-roster")) })
            ready = Set(lobby.readyPlayerIDs)
            for (rawName, name) in lobby.names {
                playerNames[GameCore.PlayerID(rawValue: rawName)] = name
            }
            playerColors = Dictionary(uniqueKeysWithValues: lobby.colors.compactMap { rawID, rawColor in
                guard let color = GameCore.PlayerColor(rawValue: rawColor) else { return nil }
                return (GameCore.PlayerID(rawValue: rawID), color)
            })
            publishState()
        case let .legalResponse(response):
            guard let current = snapshot else { return }
            let context = SessionProtocol.SessionContext(
                protocolVersion: configuration.protocolVersion,
                rulesetVersion: configuration.rulesetVersion,
                roomID: configuration.roomID,
                localPlayerID: configuration.playerID,
                authenticatedRemotePlayerID: configuration.hostPlayerID,
                hostPlayerID: configuration.hostPlayerID,
                roomPlayerIDs: Set(current.players.map(\.id)),
                authoritativeVersion: current.authoritativeVersion,
                actionNumber: current.actionNumber,
                reconnectTokens: [configuration.hostPlayerID: .init(rawValue: "transport-authenticated-host")]
            )
            guard case .legalResponse = try? SessionProtocol.EnvelopeValidator().validate(
                envelope, against: context
            ), response.baseVersion == current.authoritativeVersion,
                  acceptUnique(envelope, peer: peer, countsAsProcessedMessage: false)
            else { return }
            lastLegalResponse = response
            lastIntentRejection = nil
            publishState()
        case let .viewSnapshot(value):
            guard envelope.protocolVersion == configuration.protocolVersion,
                  envelope.rulesetVersion == configuration.rulesetVersion,
                  validatedRecoverySnapshot(value, envelope: envelope) else {
                if invalidRecoveryReplayCache.insert(
                    envelope.messageID,
                    authenticatedHostID: configuration.hostPlayerID
                ) {
                    await recordInvalidGuestRecoveryMessage()
                }
                return
            }
            guard acceptUnique(envelope, peer: peer) else { return }
            snapshot = value
            didRequestInitialRecovery = false
            eventWindows[configuration.playerID] = []
            lastClientEvent = nil
            lastLegalResponse = nil
            pauseReason = recoveryIsComplete(at: value.authoritativeVersion) ? nil : .stateRecovery
            if pauseReason == nil { await guestRecoveryFailureHandler?.recoverySucceeded() }
            recoveryError = nil
            lastIntentRejection = nil
            lastInternalFailure = nil
            publishState()
            await persistGuestArchive(newEvent: nil)
        case .clientEvent:
            guard let current = snapshot else {
                // 缺初始快照时无法应用增量事件:向房主请求一次完整恢复,
                // 而不是静默丢弃后续所有事件。
                if !didRequestInitialRecovery {
                    didRequestInitialRecovery = true
                    try? await send(
                        .catchUp(fromVersion: .init(rawValue: -1)),
                        to: configuration.hostPlayerID,
                        version: .init(rawValue: -1)
                    )
                }
                return
            }
            let playerIDs = Set(current.players.map(\.id))
            let context = SessionProtocol.SessionContext(
                protocolVersion: configuration.protocolVersion, rulesetVersion: configuration.rulesetVersion,
                roomID: configuration.roomID, localPlayerID: configuration.playerID,
                authenticatedRemotePlayerID: configuration.hostPlayerID, hostPlayerID: configuration.hostPlayerID,
                roomPlayerIDs: playerIDs, authoritativeVersion: current.authoritativeVersion,
                actionNumber: current.actionNumber,
                reconnectTokens: [configuration.hostPlayerID: .init(rawValue: "transport-authenticated-host")]
            )
            guard case let .clientEvent(value) = try? SessionProtocol.EnvelopeValidator().validate(envelope, against: context) else {
                // 持久诊断:被拒的合法事件曾让客机静默丢弃、对局冻结(2026-10-11),
                // 落盘一行便于事后从设备拉日志定位。
                do { _ = try SessionProtocol.EnvelopeValidator().validate(envelope, against: context) }
                catch {
                    SessionDiagnostics.log(
                        "CLIENT-EVENT-REJECTED seat=\(configuration.playerID.rawValue)"
                        + " v=\(envelope.authoritativeVersion.rawValue) err=\(error)"
                    )
                }
                if invalidRecoveryReplayCache.insert(
                    envelope.messageID,
                    authenticatedHostID: configuration.hostPlayerID
                ) {
                    await recordInvalidGuestRecoveryMessage()
                }
                return
            }
            guard acceptUnique(envelope, peer: peer) else { return }
            snapshot = value.snapshot
            SessionDiagnostics.log("EVENT-APPLIED seat=\(configuration.playerID.rawValue) v\(value.event.version.rawValue) actor=\(value.event.actor.rawValue) \(SessionDiagnostics.describe(value.event.payload))")
            lastClientEvent = value
            lastLegalResponse = nil
            pauseReason = recoveryIsComplete(at: value.snapshot.authoritativeVersion) ? nil : .stateRecovery
            if pauseReason == nil { await guestRecoveryFailureHandler?.recoverySucceeded() }
            recoveryError = nil
            lastIntentRejection = nil
            // 恢复重放会按版本序重发历史事件,去重后正好重建完整行动日志。
            if let match = value.snapshot.match {
                appendActionLog(
                    event: value.event,
                    era: match.era,
                    roundNumber: match.roundNumber
                )
            }
            publishState()
            await persistGuestArchive(newEvent: envelope)
            print("INDUSTRIALCITY_LOCAL converged version=\(value.event.version.rawValue) actor=\(value.event.actor.rawValue)")
        default: break
        }
    }

    private func resolve(_ intent: GameCore.PlayerIntent) async throws {
        await acquireResolveGate()
        do {
            try await resolveSerially(intent)
            releaseResolveGate()
        } catch {
            releaseResolveGate()
            throw error
        }
    }

    private func acquireResolveGate() async {
        guard isResolving else {
            isResolving = true
            return
        }
        await withCheckedContinuation { continuation in
            resolveWaiters.append(continuation)
        }
    }

    private func releaseResolveGate() {
        guard !resolveWaiters.isEmpty else {
            isResolving = false
            return
        }
        resolveWaiters.removeFirst().resume()
    }

    private func resolveSerially(_ intent: GameCore.PlayerIntent) async throws {
        SessionDiagnostics.log("INTENT seat=\(configuration.playerID.rawValue) sender=\(intent.senderID.rawValue) base=v\(intent.baseVersion.rawValue) \(SessionDiagnostics.describe(intent.payload))")
        guard pauseReason == nil else {
            if intent.senderID != configuration.playerID {
                try? await send(.rejection(.init(
                    reasonCode: .internalFailure,
                    recoverySuggestion: "The host session is paused pending authoritative recovery."
                )), to: intent.senderID)
            }
            throw Error.sessionPaused
        }
        guard var candidateEngine = engine else { throw Error.gameNotStarted }
        let result: GameCore.SubmissionResult
        switch rulesMode {
        case .verified(let catalog):
            result = candidateEngine.submit(intent, catalog: catalog)
#if DEBUG
        case .fixtureOnlyLegacy:
            result = try submitFixtureOnly(intent, engine: &candidateEngine)
#endif
        }
        try await finishResolution(result, intent: intent, candidateEngine: candidateEngine)
    }

#if DEBUG
    private func submitFixtureOnly(
        _ intent: GameCore.PlayerIntent,
        engine: inout GameCore.HostEngine
    ) throws -> GameCore.SubmissionResult {
        guard case .fixtureOnlyLegacy = rulesMode,
              case .pass(let passIntent) = intent.payload
        else {
            return .rejected(.init(
                reasonCode: .invalidAction,
                recoverySuggestion: "The fixture-only session accepts pass actions only."
            ))
        }
        guard var activePlayerID = engine.gameState.activePlayerID,
              activePlayerID == intent.senderID
        else {
            return .rejected(.init(
                reasonCode: .notActivePlayer,
                recoverySuggestion: "Wait until the fixture state names this player as active."
            ))
        }
        guard
              let playerIndex = engine.gameState.players.firstIndex(where: { $0.id == activePlayerID }),
              let cardIndex = engine.gameState.players[playerIndex].hand.firstIndex(where: {
                  $0.id == passIntent.cardID
              })
        else {
            return .rejected(.init(
                reasonCode: .missingDiscardCard,
                recoverySuggestion: "Choose a card held by the fixture player."
            ))
        }
        let previous = engine.gameState.authoritativeVersion
        let (nextVersion, overflow) = previous.rawValue.addingReportingOverflow(1)
        guard overflow == false else { return .rejected(.init(
            reasonCode: .invalidAction, recoverySuggestion: "The fixture state cannot advance."
        )) }
        var state = engine.gameState
        let card = state.players[playerIndex].hand.remove(at: cardIndex)
        state.publicDiscard.append(card)
        try GameCore.GameRulesEngine.advanceAction(actorIndex: playerIndex, state: &state)
        state.authoritativeVersion = .init(rawValue: nextVersion)
        activePlayerID = state.activePlayerID ?? activePlayerID
        engine = try state.makeHostEngine(
            roomID: configuration.roomID, reconnectTokens: tokens,
            protocolVersion: configuration.protocolVersion
        )
        return .accepted(.init(
            roomID: configuration.roomID, actor: intent.senderID,
            previousVersion: previous, version: state.authoritativeVersion,
            actionNumber: state.actionNumber,
            payload: .passed(discardedCardID: passIntent.cardID)
        ))
    }
#endif

    private func finishResolution(
        _ result: GameCore.SubmissionResult,
        intent: GameCore.PlayerIntent,
        candidateEngine: GameCore.HostEngine
    ) async throws {
        let candidateEngine = candidateEngine
        switch result {
        case let .accepted(event):
            SessionDiagnostics.log("EVENT-ACCEPTED v\(event.version.rawValue) actor=\(event.actor.rawValue) \(SessionDiagnostics.describe(event.payload))")
        case let .rejected(rejection):
            SessionDiagnostics.log("EVENT-REJECTED sender=\(intent.senderID.rawValue) \(SessionDiagnostics.describe(intent.payload)) reason=\(rejection.reasonCode)")
        case let .internalFailure(failure):
            SessionDiagnostics.log("EVENT-INTERNAL-FAILURE sender=\(intent.senderID.rawValue) \(SessionDiagnostics.describe(intent.payload)) code=\(failure.code)")
        }
        switch result {
        case let .accepted(event):
            var projections: [GameCore.PlayerID: GameCore.ClientEvent] = [:]
            // 只为权威引擎已知的座位投影；容错防御任何未知座位混入 tokens 的路径。
            let enginePlayerIDs = Set(candidateEngine.gameState.players.map(\.id))
            let recipients = playerIDs.filter { enginePlayerIDs.contains($0) && aiSeatIDs.contains($0) == false }
            for player in recipients {
                projections[player] = if let verifiedCatalog {
                    try candidateEngine.clientEvent(event, for: player, catalog: verifiedCatalog, playerNames: playerNames)
                } else {
                    try candidateEngine.clientEvent(event, for: player, catalog: nil, playerNames: playerNames)
                }
            }
            var candidateEventWindows = eventWindows
            var outgoing: [GameCore.PlayerID: SessionProtocol.SessionEnvelope] = [:]
            for player in recipients {
                guard let clientEvent = projections[player] else { continue }
                let envelope = makeEnvelope(.clientEvent(clientEvent), recipient: player, version: event.version)
                var values = candidateEventWindows[player, default: []]
                values.append(envelope)
                candidateEventWindows[player] = Array(values.suffix(128))
                outgoing[player] = envelope
            }
            let remoteRecipients = Set(outgoing.keys.filter { $0 != configuration.playerID })
            let candidateRecovery = peersNeedingRecovery.union(remoteRecipients)

            if persistence != nil, authorityCompleteness == .complete {
                // 扇出前尽力落盘保守恢复证据(崩溃安全:事件发出前对局可恢复)。
                // 存盘失败不再丢弃行动、不再冻结对局——交给后台循环自动重试。
                if let conservative = try? buildHostArchive(
                    state: candidateEngine.state,
                    gameState: candidateEngine.gameState,
                    eventWindows: candidateEventWindows,
                    peersNeedingRecovery: candidateRecovery
                ) {
                    await persistArchiveNow(conservative)
                }
            }

            engine = candidateEngine
            snapshot = projections[configuration.playerID]?.snapshot
            lastClientEvent = projections[configuration.playerID]
            lastLegalResponse = nil
            eventWindows = candidateEventWindows
            peersNeedingRecovery = candidateRecovery
            lastIntentRejection = nil
            lastDeliveryError = nil
            appendActionLog(
                event: event,
                era: candidateEngine.gameState.era,
                roundNumber: candidateEngine.gameState.roundNumber
            )
            publishState()

            for player in recipients where remoteRecipients.contains(player) {
                guard let envelope = outgoing[player] else { continue }
                do {
                    try await send(envelope, to: player)
                    peersNeedingRecovery.remove(player)
                    // 投递成功后落盘"已送达"状态(尽力而为,失败后台重试)。
                    await persistCurrentStateNow()
                } catch {
                    recordDeliveryFailure(for: player, error: error)
                }
            }
            publishState()
            print("INDUSTRIALCITY_LOCAL converged version=\(event.version.rawValue) actor=\(event.actor.rawValue)")
        case let .rejected(rejection):
            if intent.senderID != configuration.playerID {
                try await send(.rejection(rejection), to: intent.senderID)
            } else {
                lastIntentRejection = rejection
                publishState()
            }
        case let .internalFailure(failure):
            lastInternalFailure = failure
            pauseReason = .stateRecovery
            recoveryError = .invalidMaterial
            if intent.senderID != configuration.playerID {
                try? await send(.rejection(.init(
                    reasonCode: .internalFailure,
                    recoverySuggestion: "The host paused on internal failure \(failure.code.rawValue)."
                )), to: intent.senderID)
            }
            publishState()
        }
    }

    private func distributeInitialSnapshots() async throws {
        guard let engine else { return }
        let local = if let verifiedCatalog {
            try engine.snapshot(for: configuration.playerID, catalog: verifiedCatalog)
        } else {
            try engine.snapshot(for: configuration.playerID)
        }
        snapshot = local
        publishState()

        for player in playerIDs
        where player != configuration.playerID && aiSeatIDs.contains(player) == false {
            guard Set(engine.gameState.players.map(\.id)).contains(player) else { continue }
            let value = if let verifiedCatalog {
                try engine.snapshot(for: player, catalog: verifiedCatalog, playerNames: playerNames)
            } else {
                try engine.snapshot(for: player)
            }
            do { try await send(.viewSnapshot(value), to: player, version: value.authoritativeVersion) }
            catch { recordDeliveryFailure(for: player, error: error) }
        }
    }

    private func validatedRecoverySnapshot(_ value: GameCore.ViewSnapshot, envelope: SessionProtocol.SessionEnvelope) -> Bool {
        let isMonotonic = snapshot.map {
            value.authoritativeVersion.rawValue >= $0.authoritativeVersion.rawValue
                && value.actionNumber >= $0.actionNumber
        } ?? true
        guard isMonotonic else { return false }
        if configuration.protocolVersion >= 2 {
            do {
                try GameCore.RecipientSnapshotValidator.validate(
                    value,
                    context: .init(
                        protocolVersion: configuration.protocolVersion,
                        rulesetVersion: configuration.rulesetVersion,
                        roomID: configuration.roomID,
                        recipient: configuration.playerID,
                        roster: Set(playerIDs),
                        authoritativeVersion: envelope.authoritativeVersion
                    )
                )
                return true
            } catch { return false }
        }
        let ids = value.players.map(\.id)
        guard value.recipient == configuration.playerID && value.roomID == configuration.roomID
            && value.authoritativeVersion == envelope.authoritativeVersion
            && Set(ids).count == ids.count && ids.contains(configuration.playerID)
            && value.players.allSatisfy({ $0.id == configuration.playerID ? $0.hand != nil : $0.hand == nil })
        else { return false }
        do {
            return value.checksum == (try GameCore.snapshotChecksum(
                roomID: value.roomID, recipient: value.recipient,
                players: value.players, activePlayerID: value.activePlayerID, turn: value.turn,
                actionNumber: value.actionNumber, authoritativeVersion: value.authoritativeVersion,
                discardPile: value.discardPile, forcedSale: value.forcedSale, match: value.match
            ))
        } catch { return false }
    }

    private func recoveryIsComplete(at version: GameCore.AuthoritativeVersion?) -> Bool {
        guard let recoveryTargetVersion else { return true }
        guard let version, version.rawValue >= recoveryTargetVersion.rawValue else { return false }
        self.recoveryTargetVersion = nil
        return true
    }

    private func recordInvalidGuestRecoveryMessage() async {
        do {
            try await guestRecoveryFailureHandler?.recordInvalidAuthenticatedMessage()
        } catch let error as RecoveryError {
            recoveryError = error
            pauseReason = .stateRecovery
            publishState()
        } catch {
            recoveryError = .returnToLobby("recovery-material-invalid")
            pauseReason = .stateRecovery
            publishState()
        }
    }

    private func acceptUnique(
        _ envelope: SessionProtocol.SessionEnvelope,
        peer: GameCore.PlayerID,
        countsAsProcessedMessage: Bool = true
    ) -> Bool {
        let inserted = replayCache.insert(envelope.messageID, scope: .init(sender: envelope.senderID))
        if inserted && countsAsProcessedMessage {
            let (next, overflow) = processedMessageCount.addingReportingOverflow(1)
            processedMessageCount = overflow ? Int.max : next
        }
        return inserted
    }

    private func recordDeliveryFailure(for player: GameCore.PlayerID, error: any Swift.Error) {
        peersNeedingRecovery.insert(player)
        lastDeliveryError = error as? TransportError ?? .connectionFailed
        publishState()
    }

    private func sendRecoverySnapshot(to player: GameCore.PlayerID) async throws {
        guard let engine else { return }
        let value = if let verifiedCatalog {
            try engine.snapshot(for: player, catalog: verifiedCatalog)
        } else {
            try engine.snapshot(for: player)
        }
        try await send(.viewSnapshot(value), to: player, version: value.authoritativeVersion)
        peersNeedingRecovery.remove(player)
        if peersNeedingRecovery.isEmpty { lastDeliveryError = nil }
        publishState()
    }

    private func sendRecovery(
        to player: GameCore.PlayerID,
        fromVersion: GameCore.AuthoritativeVersion
    ) async throws {
        guard let engine else { return }
        if fromVersion.rawValue >= 0 {
            var window = SessionProtocol.EventWindow(expectedRoster: Set(playerIDs))
            do {
                for envelope in eventWindows[player] ?? [] { try window.append(envelope) }
                if let events = window.events(after: fromVersion),
                   fromVersion == engine.state.authoritativeVersion
                    || events.last?.authoritativeVersion == engine.state.authoritativeVersion {
                    for envelope in events { try await send(envelope, to: player) }
                    peersNeedingRecovery.remove(player)
                    if peersNeedingRecovery.isEmpty { lastDeliveryError = nil }
                    publishState()
                    return
                }
            } catch {
                // Corrupt, recipient-mismatched, or gapped windows fall back to
                // a freshly projected snapshot for only this authenticated seat.
            }
        }
        try await sendRecoverySnapshot(to: player)
    }

    private func broadcastLobbyState() async {
        let lobby = SessionProtocol.Payload.LobbyState(
            playerIDs: playerIDs, readyPlayerIDs: readyPlayerIDs,
            names: Dictionary(uniqueKeysWithValues: playerNames.map { ($0.key.rawValue, $0.value) }),
            colors: Dictionary(uniqueKeysWithValues: playerColors.map { ($0.key.rawValue, $0.value.rawValue) }),
            matchMode: matchMode
        )
        for player in playerIDs
        where player != configuration.playerID && aiSeatIDs.contains(player) == false {
            do {
                try await send(.lobbyState(lobby), to: player)
                // 大厅名册是幂等全量状态:投递成功即代表该座位已同步。
                // 开局后 ready/hello 广播已被守卫,不会误清对局中的恢复标记。
                if startPhase == .notStarted {
                    peersNeedingRecovery.remove(player)
                    if peersNeedingRecovery.isEmpty { lastDeliveryError = nil }
                    publishState()
                }
            }
            catch { recordDeliveryFailure(for: player, error: error) }
        }
    }

    private func validatedLobbyState(_ lobby: SessionProtocol.Payload.LobbyState) -> Bool {
        let players = Set(lobby.playerIDs)
        return (2...4).contains(lobby.playerIDs.count)
            && players.count == lobby.playerIDs.count
            && players.contains(configuration.playerID)
            && players.contains(configuration.hostPlayerID)
            && Set(lobby.readyPlayerIDs).isSubset(of: players)
            && Set(lobby.readyPlayerIDs).count == lobby.readyPlayerIDs.count
    }

    private func send(_ payload: SessionProtocol.Payload, to player: GameCore.PlayerID,
                      version: GameCore.AuthoritativeVersion = .init(rawValue: 0)) async throws {
        guard let peer = peerByPlayer[player] ?? (player == configuration.hostPlayerID ? player : nil) else {
            throw TransportError.notConnected
        }
        try await send(payload, toTransportPeer: peer, recipient: player, version: version)
    }

    private func send(_ envelope: SessionProtocol.SessionEnvelope, to player: GameCore.PlayerID) async throws {
        guard let peer = peerByPlayer[player] else { throw TransportError.notConnected }
        try await transport.send(JSONEncoder().encode(envelope), to: peer)
    }

    private func send(_ payload: SessionProtocol.Payload, toTransportPeer peer: GameCore.PlayerID,
                      recipient: GameCore.PlayerID,
                      version: GameCore.AuthoritativeVersion = .init(rawValue: 0),
                      envelopeRoomID: GameCore.RoomID? = nil) async throws {
        let envelope = makeEnvelope(
            payload,
            recipient: recipient,
            version: version,
            roomID: envelopeRoomID
        )
        try await transport.send(JSONEncoder().encode(envelope), to: peer)
    }

    private func makeEnvelope(
        _ payload: SessionProtocol.Payload,
        recipient: GameCore.PlayerID,
        version: GameCore.AuthoritativeVersion = .init(rawValue: 0),
        roomID: GameCore.RoomID? = nil
    ) -> SessionProtocol.SessionEnvelope {
        SessionProtocol.SessionEnvelope(
            protocolVersion: configuration.protocolVersion, rulesetVersion: configuration.rulesetVersion,
            roomID: roomID ?? configuration.roomID, messageID: .init(rawValue: UUID().uuidString),
            senderID: configuration.playerID, recipientID: recipient,
            authoritativeVersion: version, payload: payload
        )
    }

    private func appendToEventWindow(
        _ envelope: SessionProtocol.SessionEnvelope,
        for player: GameCore.PlayerID
    ) {
        var values = eventWindows[player, default: []]
        values.append(envelope)
        if values.count > 128 { values.removeFirst(values.count - 128) }
        eventWindows[player] = values
    }

    // MARK: - 持久化(尽力而为:先于扇出尝试落盘,失败自动后台重试,从不阻断对局)

    private var latestPendingArchive: SessionArchive?
    private var persistenceWorker: Task<Void, Never>?
    private var persistenceGeneration = 0
    private var highestPersistedSequence: UInt64 = 0

    /// 同步尽力落盘一次(扇出前/客机应用事件后/切后台刷盘共用)。
    /// 成功即权威;失败交给后台重试循环——行动从不因存盘失败被丢弃或冻结。
    private func persistArchiveNow(_ archive: SessionArchive) async {
        guard let persistence else { return }
        do {
            try await persistence.save(archive)
            highestPersistedSequence = max(highestPersistedSequence, archive.commitSequence)
            if latestPendingArchive?.commitSequence ?? 0 <= archive.commitSequence {
                latestPendingArchive = nil
            }
            if persistenceError != nil {
                persistenceError = nil
                publishState()
            }
        } catch {
            if persistenceError == nil {
                persistenceError = .saveFailed
                publishState()
            }
            SessionDiagnostics.log(
                "PERSIST-SAVE-FAILED seat=\(configuration.playerID.rawValue) seq=\(archive.commitSequence)"
            )
            enqueueForRetry(archive)
        }
    }

    /// 把失败档案交给后台重试:只保留最新(全量快照),新档案入队立即唤醒退避循环。
    private func enqueueForRetry(_ archive: SessionArchive) {
        guard persistence != nil else { return }
        persistenceGeneration += 1
        if (latestPendingArchive?.commitSequence ?? 0) < archive.commitSequence {
            latestPendingArchive = archive
        }
        guard persistenceWorker == nil else { return }
        persistenceWorker = Task { [weak self] in
            await self?.drainPersistenceQueue()
        }
    }

    private func drainPersistenceQueue() async {
        guard let persistence else {
            persistenceWorker = nil
            return
        }
        var backoff: Duration = .milliseconds(500)
        while Task.isCancelled == false {
            guard let archive = latestPendingArchive else { break }
            do {
                try await persistence.save(archive)
                highestPersistedSequence = max(highestPersistedSequence, archive.commitSequence)
                if latestPendingArchive?.commitSequence == archive.commitSequence {
                    latestPendingArchive = nil
                }
                if persistenceError != nil {
                    persistenceError = nil
                    publishState()
                }
                backoff = .milliseconds(500)
            } catch {
                if archive.commitSequence < highestPersistedSequence {
                    // 迟到的过期档案:已被更新提交覆盖,直接丢弃,不算失败。
                    if latestPendingArchive?.commitSequence == archive.commitSequence {
                        latestPendingArchive = nil
                    }
                    continue
                }
                if persistenceError == nil {
                    persistenceError = .saveFailed
                    publishState()
                }
                SessionDiagnostics.log(
                    "PERSIST-SAVE-RETRY seat=\(configuration.playerID.rawValue) seq=\(archive.commitSequence)"
                )
                // 分片退避:新档案入队(代际变化)立即唤醒,退避封顶 2 秒。
                let generation = persistenceGeneration
                var waited: Duration = .zero
                while waited < backoff, persistenceGeneration == generation, Task.isCancelled == false {
                    try? await Task.sleep(for: .milliseconds(100))
                    waited += .milliseconds(100)
                }
                backoff = min(backoff * 2, .seconds(2))
            }
        }
        persistenceWorker = nil
    }

    /// 按当前最新状态构造并同步尝试落盘一份档案(主机完整权威态/客机私有投影)。
    private func persistCurrentStateNow() async {
        if isHost {
            guard let engine, authorityCompleteness == .complete else { return }
            try? await persistArchiveNow(try buildHostArchive(
                state: engine.state,
                gameState: engine.gameState,
                eventWindows: eventWindows,
                peersNeedingRecovery: peersNeedingRecovery
            ))
        } else {
            guard let snapshot else { return }
            try? await persistArchiveNow(try buildGuestArchive(
                snapshot: snapshot,
                eventWindow: eventWindows[configuration.playerID] ?? []
            ))
        }
    }

    private func buildHostArchive(
        state: GameCore.AuthoritativeGameState,
        gameState: GameCore.GameState,
        eventWindows: [GameCore.PlayerID: [SessionProtocol.SessionEnvelope]],
        peersNeedingRecovery: Set<GameCore.PlayerID>
    ) throws -> SessionArchive {
        SessionArchive.host(
            protocolVersion: configuration.protocolVersion,
            rulesetVersion: configuration.rulesetVersion,
            recipientID: configuration.hostPlayerID,
            state: state,
            gameState: gameState,
            eventWindows: eventWindows,
            tokenReferences: playerIDs.map {
                .init(roomID: configuration.roomID, playerID: $0)
            },
            peersNeedingRecovery: peersNeedingRecovery,
            commitSequence: try nextPersistenceCommitSequence()
        )
    }

    private func buildGuestArchive(
        snapshot: GameCore.ViewSnapshot,
        eventWindow: [SessionProtocol.SessionEnvelope]
    ) throws -> SessionArchive {
        SessionArchive.guest(
            protocolVersion: configuration.protocolVersion,
            rulesetVersion: configuration.rulesetVersion,
            hostPlayerID: configuration.hostPlayerID,
            snapshot: snapshot,
            eventWindow: eventWindow,
            tokenReference: .init(roomID: configuration.roomID, playerID: configuration.playerID),
            commitSequence: try nextPersistenceCommitSequence()
        )
    }

    /// 等待排队档案落盘(有界);供切后台/手动重试的同步语义,超时交给后台循环。
    private func waitForPendingPersistenceToDrain(timeout: Duration) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if latestPendingArchive == nil { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 客机私有投影存档:先并入事件窗,再同步尝试落盘;失败由后台循环重试。
    private func persistGuestArchive(newEvent: SessionProtocol.SessionEnvelope?) async {
        guard persistence != nil, let snapshot else { return }
        if let newEvent { appendToEventWindow(newEvent, for: configuration.playerID) }
        try? await persistArchiveNow(try buildGuestArchive(
            snapshot: snapshot,
            eventWindow: eventWindows[configuration.playerID] ?? []
        ))
    }

    private func nextPersistenceCommitSequence() throws -> UInt64 {
        let (next, overflow) = persistenceCommitSequence.addingReportingOverflow(1)
        guard !overflow else {
            throw Error.persistenceUnavailable
        }
        persistenceCommitSequence = next
        return next
    }

    private var currentState: State {
        State(
            roomID: configuration.roomID,
            playerID: configuration.playerID,
            hostPlayerID: configuration.hostPlayerID,
            playerIDs: playerIDs,
            readyPlayerIDs: readyPlayerIDs,
            snapshot: snapshot,
            forcedSale: snapshot?.forcedSale,
            peersNeedingRecovery: peersNeedingRecovery,
            lastDeliveryError: lastDeliveryError,
            lastIntentRejection: lastIntentRejection,
            lastInternalFailure: lastInternalFailure,
            persistenceError: persistenceError,
            pauseReason: pauseReason,
            recoveryError: recoveryError,
            lastLegalResponse: lastLegalResponse,
            lastClientEvent: lastClientEvent,
            playerNames: playerNames,
            actionLog: matchActionLog,
            playerColors: playerColors,
            matchMode: matchMode
        )
    }

    // MARK: - 座位代表色

    private var playerColors: [GameCore.PlayerID: GameCore.PlayerColor] = [:]

    /// 尚未被任何座位占用的最低顺位颜色。
    private func lowestFreeColor() -> GameCore.PlayerColor {
        GameCore.PlayerColor.allCases.first(where: { color in
            playerColors.values.contains(color) == false
        }) ?? .red
    }

    /// 大厅内选择代表色:房主本地登记,客人发送 chooseColor 给房主。
    /// 颜色被其他座位占用时房主会拒绝,UI 也会禁用被占颜色。
    func chooseColor(_ color: GameCore.PlayerColor) async {
        if isHost {
            assignColor(color, to: configuration.playerID)
            publishState()
            await broadcastLobbyState()
        } else {
            do {
                try await send(
                    .chooseColor(color),
                    to: configuration.hostPlayerID,
                    version: snapshot?.authoritativeVersion ?? .init(rawValue: 0)
                )
            } catch {
                recordDeliveryFailure(for: configuration.playerID, error: error)
            }
        }
    }

    /// 房主侧登记:占用校验失败返回 false(不改动现有颜色)。
    @discardableResult
    private func assignColor(_ color: GameCore.PlayerColor, to playerID: GameCore.PlayerID) -> Bool {
        if let owner = playerColors.first(where: { $0.value == color })?.key, owner != playerID {
            return false
        }
        playerColors[playerID] = color
        return true
    }

    // MARK: - 行动日志

    private var matchActionLog: [MatchActionLogEntry] = []
    private var loggedActionVersions: Set<Int> = []

    /// 追加一条行动日志;按事件版本去重(恢复重放会重发历史事件),
    /// 上限 500 条避免长局内存增长。
    private func appendActionLog(
        event: GameCore.AuthoritativeGameEvent,
        era: GameCore.Era,
        roundNumber: Int
    ) {
        guard loggedActionVersions.insert(event.version.rawValue).inserted else { return }
        matchActionLog.append(
            MatchActionLog.makeEntry(
                event: event, era: era, roundNumber: roundNumber,
                playerNames: playerNames
            )
        )
        if matchActionLog.count > 500 {
            matchActionLog.removeFirst(matchActionLog.count - 500)
        }
    }

    private func publishState() {
        let state = currentState
        for continuation in stateContinuations.values { continuation.yield(state) }
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations[id] = nil
    }
}
