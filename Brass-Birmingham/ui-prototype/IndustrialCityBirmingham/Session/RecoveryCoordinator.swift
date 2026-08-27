import Foundation

nonisolated struct RecoveryRequest: Equatable, Sendable {
    let protocolVersion: Int
    let rulesetVersion: String
    let roomID: GameCore.RoomID
    let playerID: GameCore.PlayerID
    let reconnectToken: GameCore.ReconnectToken
    let hostPlayerID: GameCore.PlayerID
    let authenticatedRemotePlayerID: GameCore.PlayerID
    let fromVersion: GameCore.AuthoritativeVersion
}

nonisolated enum RecoveryResult: Equatable, Sendable {
    case events([SessionProtocol.SessionEnvelope])
    case snapshot(GameCore.ViewSnapshot)
}

nonisolated enum RecoveryError: Error, Equatable, Sendable {
    case authenticationFailed
    case wrongHost
    case unknownSeat
    case versionMismatch
    case invalidMaterial
    case returnToLobby(String)
}

nonisolated struct RestoredHostSession: Equatable, Sendable {
    let state: GameCore.AuthoritativeGameState
    let gameState: GameCore.GameState
    let hasCompleteGameState: Bool
    let eventWindows: [GameCore.PlayerID: [SessionProtocol.SessionEnvelope]]
    let peersNeedingRecovery: Set<GameCore.PlayerID>
    let commitSequence: UInt64

    init(
        state: GameCore.AuthoritativeGameState,
        gameState: GameCore.GameState? = nil,
        legacyRulesetVersion: String = "legacy-compatible",
        eventWindows: [GameCore.PlayerID: [SessionProtocol.SessionEnvelope]],
        peersNeedingRecovery: Set<GameCore.PlayerID>,
        commitSequence: UInt64
    ) {
        self.state = state
        self.gameState = gameState ?? .legacyCompatible(state, rulesetVersion: legacyRulesetVersion)
        self.hasCompleteGameState = gameState != nil
        self.eventWindows = eventWindows
        self.peersNeedingRecovery = peersNeedingRecovery
        self.commitSequence = commitSequence
    }
}

nonisolated protocol RecoveryMaterialCleaning: Sendable {
    func clearRecoveryMaterial(for reference: RoomTokenReference) async throws
}

nonisolated struct NoopRecoveryMaterialCleaner: RecoveryMaterialCleaning {
    func clearRecoveryMaterial(for reference: RoomTokenReference) async throws {}
}

actor RecoveryCoordinator {
    private let tokenStore: RoomTokenStore
    private let materialCleaner: any RecoveryMaterialCleaning
    private var failureCounts: [RoomTokenReference: Int] = [:]

    init(
        tokenStore: RoomTokenStore,
        materialCleaner: some RecoveryMaterialCleaning = NoopRecoveryMaterialCleaner()
    ) {
        self.tokenStore = tokenStore
        self.materialCleaner = materialCleaner
    }

    func recover(
        _ request: RecoveryRequest,
        from archive: SessionArchive,
        schemaVersion: Int,
        catalog verifiedCatalog: GameCore.VerifiedGameDataCatalog? = nil
    ) async throws -> RecoveryResult {
        guard request.authenticatedRemotePlayerID == request.hostPlayerID else {
            throw RecoveryError.wrongHost
        }
        guard case let .host(host) = archive.payload,
              host.authoritativeState.players.contains(where: { $0.id == request.playerID }) else {
            throw RecoveryError.unknownSeat
        }
        guard let credential = try await tokenStore.load(roomID: request.roomID, playerID: request.playerID),
              credential.reconnectToken == request.reconnectToken,
              host.authoritativeState.players.contains(where: { $0.id == request.playerID }) else {
            throw RecoveryError.authenticationFailed
        }
        guard request.fromVersion.rawValue <= archive.authoritativeVersion.rawValue else {
            throw RecoveryError.versionMismatch
        }

        let reference = RoomTokenReference(roomID: request.roomID, playerID: request.playerID)
        do {
            try validate(archive, request: request, host: host)
            let result = try await result(
                request: request, archive: archive, host: host,
                schemaVersion: schemaVersion, catalog: verifiedCatalog
            )
            failureCounts[reference] = nil
            return result
        } catch let error as RecoveryError {
            switch error {
            case .invalidMaterial:
                try await recordInvalidMaterialFailure(for: reference)
            default: break
            }
            throw error
        } catch {
            try await recordInvalidMaterialFailure(for: reference)
            throw RecoveryError.invalidMaterial
        }
    }

    private func recordInvalidMaterialFailure(for reference: RoomTokenReference) async throws {
        let previous = failureCounts[reference, default: 0]
        let count = previous >= 3 ? 3 : previous + 1
        failureCounts[reference] = count
        if count >= 3 {
            if previous < 3 {
                try await materialCleaner.clearRecoveryMaterial(for: reference)
            }
            throw RecoveryError.returnToLobby("recovery-material-invalid")
        }
    }

    func consecutiveFailureCount(roomID: GameCore.RoomID, playerID: GameCore.PlayerID) -> Int {
        failureCounts[.init(roomID: roomID, playerID: playerID), default: 0]
    }

    func restoreHost(
        archive: SessionArchive,
        expectedHostID: GameCore.PlayerID,
        catalog verifiedCatalog: GameCore.VerifiedGameDataCatalog
    ) async throws -> RestoredHostSession {
        try await restoreHostValidated(
            archive: archive, expectedHostID: expectedHostID, catalog: verifiedCatalog
        )
    }

#if DEBUG
    func restoreFixtureOnlyHost(
        archive: SessionArchive,
        expectedHostID: GameCore.PlayerID
    ) async throws -> RestoredHostSession {
        try await restoreHostValidated(archive: archive, expectedHostID: expectedHostID, catalog: nil)
    }
#endif

    private func restoreHostValidated(
        archive: SessionArchive,
        expectedHostID: GameCore.PlayerID,
        catalog verifiedCatalog: GameCore.VerifiedGameDataCatalog?
    ) async throws -> RestoredHostSession {
        guard archive.role == .host,
              archive.recipientID == expectedHostID,
              case let .host(host) = archive.payload,
              host.authoritativeState.players.contains(where: { $0.id == expectedHostID }) else {
            throw RecoveryError.invalidMaterial
        }
        if let verifiedCatalog {
            guard let gameState = host.gameState,
                  GameCore.GameStateAuthorityValidator.isValid(
                    gameState, catalog: verifiedCatalog
                  )
            else { throw RecoveryError.invalidMaterial }
        }
        var tokens: [GameCore.PlayerID: GameCore.ReconnectToken] = [:]
        for reference in host.tokenReferences {
            guard reference.roomID == archive.roomID,
                  let credential = try await tokenStore.load(
                    roomID: reference.roomID,
                    playerID: reference.playerID
                  ) else { throw RecoveryError.authenticationFailed }
            tokens[reference.playerID] = credential.reconnectToken
        }
        let persistedIDs = host.authoritativeState.players.map(\.id)
        guard Set(persistedIDs).count == persistedIDs.count,
              Set(tokens.keys) == Set(persistedIDs) else { throw RecoveryError.invalidMaterial }
        let players = try host.authoritativeState.players.map { player in
            guard let token = tokens[player.id] else { throw RecoveryError.authenticationFailed }
            return GameCore.AuthoritativePlayer(id: player.id, reconnectToken: token, hand: player.hand)
        }
        let restoredState = GameCore.AuthoritativeGameState(
                roomID: host.authoritativeState.roomID,
                players: players,
                activePlayerID: host.authoritativeState.activePlayerID,
                turn: host.authoritativeState.turn,
                actionNumber: host.authoritativeState.actionNumber,
                authoritativeVersion: host.authoritativeState.authoritativeVersion,
                discardPile: host.authoritativeState.discardPile
            )
        return RestoredHostSession(
            state: restoredState,
            gameState: host.gameState,
            legacyRulesetVersion: archive.rulesetVersion,
            eventWindows: host.eventWindows,
            peersNeedingRecovery: host.peersNeedingRecovery,
            commitSequence: archive.commitSequence
        )
    }

    private func validate(
        _ archive: SessionArchive,
        request: RecoveryRequest,
        host: HostSessionArchive
    ) throws {
        guard archive.role == .host,
              archive.protocolVersion == request.protocolVersion,
              archive.rulesetVersion == request.rulesetVersion,
              archive.roomID == request.roomID,
              archive.recipientID == request.hostPlayerID,
              host.authoritativeState.roomID == request.roomID,
              host.authoritativeState.authoritativeVersion == archive.authoritativeVersion,
              host.tokenReferences.contains(.init(roomID: request.roomID, playerID: request.playerID)) else {
            throw RecoveryError.invalidMaterial
        }
    }

    private func result(
        request: RecoveryRequest,
        archive: SessionArchive,
        host: HostSessionArchive,
        schemaVersion: Int,
        catalog verifiedCatalog: GameCore.VerifiedGameDataCatalog?
    ) async throws -> RecoveryResult {
        if request.fromVersion == archive.authoritativeVersion { return .events([]) }
        let candidates = (host.eventWindows[request.playerID] ?? []).filter {
            $0.authoritativeVersion.rawValue > request.fromVersion.rawValue
        }
        if isContinuous(
            candidates,
            from: request.fromVersion,
            through: archive.authoritativeVersion,
            request: request,
            roster: Set(host.authoritativeState.players.map(\.id))
        ) {
            return .events(candidates)
        }
        var players: [GameCore.AuthoritativePlayer] = []
        for player in host.authoritativeState.players {
            guard let credential = try? await tokenStore.load(roomID: request.roomID, playerID: player.id) else {
                throw RecoveryError.authenticationFailed
            }
            players.append(GameCore.AuthoritativePlayer(
                id: player.id,
                reconnectToken: credential.reconnectToken,
                hand: player.hand
            ))
        }
        let state = GameCore.AuthoritativeGameState(
            roomID: host.authoritativeState.roomID,
            players: players,
            activePlayerID: host.authoritativeState.activePlayerID,
            turn: host.authoritativeState.turn,
            actionNumber: host.authoritativeState.actionNumber,
            authoritativeVersion: host.authoritativeState.authoritativeVersion,
            discardPile: host.authoritativeState.discardPile
        )
        let reconnectTokens = Dictionary(uniqueKeysWithValues: players.map {
            ($0.id, $0.reconnectToken)
        })
        let engine: GameCore.HostEngine
        switch schemaVersion {
        case SnapshotEnvelope.currentSchemaVersion:
            guard let verifiedCatalog,
                  let gameState = host.gameState,
                  GameCore.GameStateAuthorityValidator.isValid(gameState, catalog: verifiedCatalog)
            else { throw RecoveryError.invalidMaterial }
            engine = try gameState.makeHostEngine(
                roomID: state.roomID,
                reconnectTokens: reconnectTokens,
                protocolVersion: archive.protocolVersion
            )
            guard PersistedAuthoritativeGameState(engine.state) == host.authoritativeState else {
                throw RecoveryError.invalidMaterial
            }
        case 2:
            engine = try GameCore.GameState.legacyCompatible(
                state, rulesetVersion: archive.rulesetVersion
            ).makeHostEngine(
                roomID: state.roomID,
                reconnectTokens: reconnectTokens,
                protocolVersion: archive.protocolVersion
            )
        default:
            throw RecoveryError.invalidMaterial
        }
        return .snapshot(try engine.snapshot(for: request.playerID))
    }

    private func isContinuous(
        _ events: [SessionProtocol.SessionEnvelope],
        from version: GameCore.AuthoritativeVersion,
        through latest: GameCore.AuthoritativeVersion,
        request: RecoveryRequest,
        roster: Set<GameCore.PlayerID>
    ) -> Bool {
        guard !events.isEmpty else { return false }
        var previous = version.rawValue
        for envelope in events {
            let (expected, overflow) = previous.addingReportingOverflow(1)
            guard !overflow else { return false }
            guard envelope.protocolVersion == request.protocolVersion,
                  envelope.rulesetVersion == request.rulesetVersion,
                  envelope.roomID == request.roomID,
                  envelope.senderID == request.hostPlayerID,
                  envelope.recipientID == request.playerID,
                  envelope.authoritativeVersion.rawValue == expected,
                  case let .clientEvent(event) = envelope.payload,
                  roster.contains(event.event.actor),
                  event.event.previousVersion.rawValue == previous,
                  event.event.version.rawValue == expected,
                  event.snapshot.roomID == request.roomID,
                  event.snapshot.recipient == request.playerID,
                  event.snapshot.authoritativeVersion.rawValue == expected,
                  event.snapshot.players.allSatisfy({
                      $0.id == request.playerID ? $0.hand != nil : $0.hand == nil
                  }) else { return false }
            if request.protocolVersion >= 2 {
                do {
                    try GameCore.RecipientSnapshotValidator.validate(
                        event.snapshot,
                        context: .init(
                            protocolVersion: request.protocolVersion,
                            rulesetVersion: request.rulesetVersion,
                            roomID: request.roomID,
                            recipient: request.playerID,
                            roster: roster,
                            authoritativeVersion: envelope.authoritativeVersion
                        )
                    )
                } catch { return false }
            } else {
                do {
                    guard event.snapshot.checksum == (try GameCore.snapshotChecksum(
                        roomID: event.snapshot.roomID,
                        recipient: event.snapshot.recipient,
                        players: event.snapshot.players,
                        activePlayerID: event.snapshot.activePlayerID,
                        turn: event.snapshot.turn,
                        actionNumber: event.snapshot.actionNumber,
                        authoritativeVersion: event.snapshot.authoritativeVersion,
                        discardPile: event.snapshot.discardPile,
                        forcedSale: event.snapshot.forcedSale,
                        match: event.snapshot.match
                    )) else { return false }
                } catch { return false }
            }
            previous = expected
        }
        return previous == latest.rawValue
    }
}
