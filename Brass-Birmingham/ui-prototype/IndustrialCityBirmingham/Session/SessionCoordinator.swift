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
    }

    struct Configuration: Sendable {
        let protocolVersion: Int
        let rulesetVersion: String
        let roomID: GameCore.RoomID
        let playerID: GameCore.PlayerID
        let reconnectToken: GameCore.ReconnectToken
        let hostPlayerID: GameCore.PlayerID
        let setupSeed: UInt64

        init(
            protocolVersion: Int,
            rulesetVersion: String,
            roomID: GameCore.RoomID,
            playerID: GameCore.PlayerID,
            reconnectToken: GameCore.ReconnectToken,
            hostPlayerID: GameCore.PlayerID,
            setupSeed: UInt64 = 1
        ) {
            self.protocolVersion = protocolVersion
            self.rulesetVersion = rulesetVersion
            self.roomID = roomID
            self.playerID = playerID
            self.reconnectToken = reconnectToken
            self.hostPlayerID = hostPlayerID
            self.setupSeed = setupSeed
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
    private let configuration: Configuration
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
    private var ready: Set<GameCore.PlayerID> = []
    private var replayCache = ReplayCache()
    private var invalidRecoveryReplayCache = InvalidRecoveryReplayCache()
    private var engine: GameCore.HostEngine?
    private var eventWindows: [GameCore.PlayerID: [SessionProtocol.SessionEnvelope]] = [:]
    private var joinOutcome: JoinOutcome = .pending
    private var startPhase: StartPhase = .notStarted
    private var stateContinuations: [UUID: AsyncStream<State>.Continuation] = [:]
    private(set) var snapshot: GameCore.ViewSnapshot?
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
        try await send(.hello(reconnectToken: configuration.reconnectToken), to: configuration.hostPlayerID)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            switch joinOutcome {
            case .accepted:
                publishState()
                print("INDUSTRIALCITY_LOCAL joined room=\(configuration.roomID.rawValue)")
                return
            case let .rejected(error): throw error
            case .pending: try await Task.sleep(for: .milliseconds(10))
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

    func startGame() async throws {
        guard isHost else { throw Error.hostOnly }
        guard startPhase == .notStarted else { throw Error.gameAlreadyStarted }
        guard tokens.count >= 2, ready == Set(tokens.keys) else { throw Error.notAllPlayersReady }
        startPhase = .starting
        let ordered = [configuration.hostPlayerID] + playerIDs.filter { $0 != configuration.hostPlayerID }
        if let verifiedCatalog {
            var setup = GameCore.SetupRules(seed: configuration.setupSeed)
            let game = try setup.makeGame(catalog: verifiedCatalog, playerIDs: ordered)
            engine = try game.state.makeHostEngine(
                roomID: configuration.roomID,
                reconnectTokens: tokens,
                protocolVersion: configuration.protocolVersion
            )
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

    func submit(_ payload: GameCore.PlayerIntent.Payload) async throws {
        guard persistenceError == nil else { throw Error.persistenceUnavailable }
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
        processingTask?.cancel()
        processingTask = nil
        for continuation in stateContinuations.values { continuation.finish() }
        stateContinuations.removeAll()
        await transport.disconnect()
    }

    func persistForBackground() async throws {
        await acquireResolveGate()
        do {
            if isHost {
                try await persistCommittedState()
            } else {
                try await persistGuestState(newEvent: nil)
            }
            releaseResolveGate()
        } catch {
            releaseResolveGate()
            throw error
        }
    }

    func retryPersistence() async throws {
        await acquireResolveGate()
        do {
            if isHost {
                try await persistCommittedState()
            } else {
                try await persistGuestState(newEvent: nil)
            }
            releaseResolveGate()
        } catch {
            releaseResolveGate()
            throw error
        }
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
            guard let envelope = try? JSONDecoder().decode(SessionProtocol.SessionEnvelope.self, from: data),
                  envelope.messageID.isValid else { return }
            if isHost { await handleAsHost(envelope, peer: peer) }
            else { await handleAsGuest(envelope, peer: peer) }
        case let .disconnected(peer, _):
            if !isHost, peer == configuration.hostPlayerID {
                pauseReason = .hostDisconnected
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
        guard envelope.protocolVersion == configuration.protocolVersion,
              envelope.rulesetVersion == configuration.rulesetVersion else {
            try? await send(.versionIncompatible, toTransportPeer: peer, recipient: envelope.senderID)
            return
        }
        switch envelope.payload {
        case let .hello(token):
            guard envelope.recipientID == configuration.playerID else { return }
            if let existing = tokens[envelope.senderID], existing != token {
                try? await send(.rejection(.init(reasonCode: .invalidReconnectToken,
                    recoverySuggestion: "Reauthenticate the seat with its reconnect token.")),
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
            tokens[envelope.senderID] = token
            peerByPlayer[envelope.senderID] = peer
            do {
                try await tokenStore?.save(.init(
                    roomID: configuration.roomID,
                    playerID: envelope.senderID,
                    reconnectToken: token
                ))
            } catch {
                tokens[envelope.senderID] = nil
                peerByPlayer[envelope.senderID] = nil
                try? await send(.rejection(.init(
                    reasonCode: .persistenceUnavailable,
                    recoverySuggestion: "Wait while the host safely saves the assigned seat, then retry."
                )), toTransportPeer: peer, recipient: envelope.senderID)
                return
            }
            publishState()
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
            if value { ready.insert(envelope.senderID) } else { ready.remove(envelope.senderID) }
            publishState()
            await broadcastLobbyState()
        case let .intent(intent):
            guard envelope.recipientID == configuration.playerID,
                  envelope.senderID == intent.senderID,
                  peerByPlayer[intent.senderID] == peer, tokens[intent.senderID] == intent.reconnectToken else { return }
            guard acceptUnique(envelope, peer: peer) else { return }
            if persistenceError != nil {
                try? await send(.rejection(.init(
                    reasonCode: .persistenceUnavailable,
                    recoverySuggestion: "Wait while the host safely saves the latest committed state, then retry."
                )), to: intent.senderID)
                return
            }
            do { try await resolve(intent) }
            catch Error.persistenceUnavailable { return }
            catch Error.sessionPaused { return }
            catch { recordDeliveryFailure(for: intent.senderID, error: error) }
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
            do { try await sendRecovery(to: envelope.senderID, fromVersion: fromVersion) }
            catch { recordDeliveryFailure(for: envelope.senderID, error: error) }
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
            joinOutcome = .accepted
            recoveryTargetVersion = envelope.authoritativeVersion
            pauseReason = recoveryIsComplete(at: snapshot?.authoritativeVersion) ? nil : .stateRecovery
            if pauseReason == nil { await guestRecoveryFailureHandler?.recoverySucceeded() }
            let fromVersion = snapshot?.authoritativeVersion ?? .init(rawValue: -1)
            try? await send(.catchUp(fromVersion: fromVersion), to: configuration.hostPlayerID, version: fromVersion)
        case .versionIncompatible:
            guard acceptUnique(envelope, peer: peer) else { return }
            joinOutcome = .rejected(.incompatiblePeer)
        case let .rejection(rejection):
            guard acceptUnique(envelope, peer: peer) else { return }
            if snapshot == nil {
                switch rejection.reasonCode {
                case .wrongRoom: joinOutcome = .rejected(.roomMismatch)
                case .invalidReconnectToken: joinOutcome = .rejected(.reconnectTokenMismatch)
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
            tokens = Dictionary(uniqueKeysWithValues: lobby.playerIDs.map { ($0, .init(rawValue: "host-authoritative-roster")) })
            ready = Set(lobby.readyPlayerIDs)
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
            eventWindows[configuration.playerID] = []
            lastClientEvent = nil
            lastLegalResponse = nil
            pauseReason = recoveryIsComplete(at: value.authoritativeVersion) ? nil : .stateRecovery
            if pauseReason == nil { await guestRecoveryFailureHandler?.recoverySucceeded() }
            recoveryError = nil
            lastIntentRejection = nil
            lastInternalFailure = nil
            publishState()
            do { try await persistGuestState(newEvent: nil) }
            catch { return }
        case .clientEvent:
            guard let current = snapshot else { return }
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
            lastClientEvent = value
            lastLegalResponse = nil
            pauseReason = recoveryIsComplete(at: value.snapshot.authoritativeVersion) ? nil : .stateRecovery
            if pauseReason == nil { await guestRecoveryFailureHandler?.recoverySucceeded() }
            recoveryError = nil
            lastIntentRejection = nil
            publishState()
            do { try await persistGuestState(newEvent: envelope) }
            catch { return }
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
        guard persistenceError == nil else { throw Error.persistenceUnavailable }
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
            var projections: [GameCore.PlayerID: GameCore.ClientEvent] = [:]
            for player in playerIDs {
                projections[player] = if let verifiedCatalog {
                    try candidateEngine.clientEvent(event, for: player, catalog: verifiedCatalog)
                } else {
                    try candidateEngine.clientEvent(event, for: player)
                }
            }
            var candidateEventWindows = eventWindows
            var outgoing: [GameCore.PlayerID: SessionProtocol.SessionEnvelope] = [:]
            for player in playerIDs {
                guard let clientEvent = projections[player] else { continue }
                let envelope = makeEnvelope(.clientEvent(clientEvent), recipient: player, version: event.version)
                var values = candidateEventWindows[player, default: []]
                values.append(envelope)
                candidateEventWindows[player] = Array(values.suffix(128))
                outgoing[player] = envelope
            }
            let remoteRecipients = Set(outgoing.keys.filter { $0 != configuration.playerID })
            let candidateRecovery = peersNeedingRecovery.union(remoteRecipients)

            if let persistence {
                guard authorityCompleteness == .complete else {
                    persistenceError = .saveFailed
                    publishState()
                    throw Error.persistenceUnavailable
                }
                let nextCommitSequence = try nextPersistenceCommitSequence()
                let archive = SessionArchive.host(
                    protocolVersion: configuration.protocolVersion,
                    rulesetVersion: configuration.rulesetVersion,
                    recipientID: configuration.hostPlayerID,
                    state: candidateEngine.state,
                    gameState: candidateEngine.gameState,
                    eventWindows: candidateEventWindows,
                    tokenReferences: playerIDs.map {
                        .init(roomID: configuration.roomID, playerID: $0)
                    },
                    peersNeedingRecovery: candidateRecovery,
                    commitSequence: nextCommitSequence
                )
                do {
                    try await persistence.save(archive)
                    persistenceCommitSequence = nextCommitSequence
                } catch {
                    persistenceError = .saveFailed
                    publishState()
                    if intent.senderID != configuration.playerID {
                        try? await send(.rejection(.init(
                            reasonCode: .persistenceUnavailable,
                            recoverySuggestion: "Wait while the host safely saves the latest committed state, then retry."
                        )), to: intent.senderID)
                    }
                    throw Error.persistenceUnavailable
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
            persistenceError = nil
            publishState()

            for player in playerIDs where remoteRecipients.contains(player) {
                guard let envelope = outgoing[player] else { continue }
                do {
                    try await send(envelope, to: player)
                    peersNeedingRecovery.remove(player)
                    do {
                        try await persistCommittedState()
                    } catch {
                        break
                    }
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

        for player in playerIDs where player != configuration.playerID {
            let value = if let verifiedCatalog {
                try engine.snapshot(for: player, catalog: verifiedCatalog)
            } else {
                try engine.snapshot(for: player)
            }
            do { try await send(.viewSnapshot(value), to: player) }
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
        let lobby = SessionProtocol.Payload.LobbyState(playerIDs: playerIDs, readyPlayerIDs: readyPlayerIDs)
        for player in playerIDs where player != configuration.playerID {
            do {
                try await send(.lobbyState(lobby), to: player)
                peersNeedingRecovery.remove(player)
                if peersNeedingRecovery.isEmpty { lastDeliveryError = nil }
                publishState()
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

    private func persistCommittedState() async throws {
        guard let persistence, let engine else { return }
        guard authorityCompleteness == .complete else {
            persistenceError = .saveFailed
            publishState()
            throw Error.persistenceUnavailable
        }
        let nextCommitSequence = try nextPersistenceCommitSequence()
        let archive = SessionArchive.host(
            protocolVersion: configuration.protocolVersion,
            rulesetVersion: configuration.rulesetVersion,
            recipientID: configuration.hostPlayerID,
            state: engine.state,
            gameState: engine.gameState,
            eventWindows: eventWindows,
            tokenReferences: playerIDs.map {
                .init(roomID: configuration.roomID, playerID: $0)
            },
            peersNeedingRecovery: peersNeedingRecovery,
            commitSequence: nextCommitSequence
        )
        do {
            try await persistence.save(archive)
            persistenceCommitSequence = nextCommitSequence
            persistenceError = nil
            publishState()
        } catch {
            persistenceError = .saveFailed
            publishState()
            throw Error.persistenceUnavailable
        }
    }

    private func persistGuestState(newEvent: SessionProtocol.SessionEnvelope?) async throws {
        guard let persistence, let snapshot else { return }
        if let newEvent { appendToEventWindow(newEvent, for: configuration.playerID) }
        let nextCommitSequence = try nextPersistenceCommitSequence()
        let archive = SessionArchive.guest(
            protocolVersion: configuration.protocolVersion,
            rulesetVersion: configuration.rulesetVersion,
            hostPlayerID: configuration.hostPlayerID,
            snapshot: snapshot,
            eventWindow: eventWindows[configuration.playerID] ?? [],
            tokenReference: .init(roomID: configuration.roomID, playerID: configuration.playerID),
            commitSequence: nextCommitSequence
        )
        do {
            try await persistence.save(archive)
            persistenceCommitSequence = nextCommitSequence
            persistenceError = nil
        } catch {
            persistenceError = .saveFailed
            publishState()
            throw Error.persistenceUnavailable
        }
        publishState()
    }

    private func nextPersistenceCommitSequence() throws -> UInt64 {
        let (next, overflow) = persistenceCommitSequence.addingReportingOverflow(1)
        guard !overflow else {
            persistenceError = .saveFailed
            publishState()
            throw Error.persistenceUnavailable
        }
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
            lastClientEvent: lastClientEvent
        )
    }

    private func publishState() {
        let state = currentState
        for continuation in stateContinuations.values { continuation.yield(state) }
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations[id] = nil
    }
}
