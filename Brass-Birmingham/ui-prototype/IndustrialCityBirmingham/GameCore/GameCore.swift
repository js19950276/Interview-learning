import CryptoKit
import Foundation

nonisolated enum GameCore {
    struct PlayerID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
        let rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    struct RoomID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
        let rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    struct ReconnectToken: RawRepresentable, Codable, Equatable, Hashable, Sendable {
        let rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    struct AuthoritativeVersion: RawRepresentable, Codable, Equatable, Hashable, Sendable {
        let rawValue: Int

        init(rawValue: Int) {
            self.rawValue = rawValue
        }
    }

    struct PlayerIntent: Codable, Equatable, Sendable {
        enum Payload: Codable, Equatable, Sendable {
            case pass(PassIntent)
            case build(BuildIntent)
            case network(NetworkIntent)
            case develop(DevelopIntent)
            case sell(SellIntent)
            case loan(LoanIntent)
            case scout(ScoutIntent)
            case forcedSale(ForcedSaleIntent)
        }

        let protocolVersion: Int
        let rulesetVersion: String
        let roomID: RoomID
        let senderID: PlayerID
        let reconnectToken: ReconnectToken
        let baseVersion: AuthoritativeVersion
        let payload: Payload

        init(
            protocolVersion: Int,
            rulesetVersion: String,
            roomID: RoomID,
            senderID: PlayerID,
            reconnectToken: ReconnectToken,
            baseVersion: AuthoritativeVersion,
            payload: Payload
        ) {
            self.protocolVersion = protocolVersion
            self.rulesetVersion = rulesetVersion
            self.roomID = roomID
            self.senderID = senderID
            self.reconnectToken = reconnectToken
            self.baseVersion = baseVersion
            self.payload = payload
        }
    }

    struct AuthoritativePlayer: Codable, Equatable, Sendable {
        let id: PlayerID
        let reconnectToken: ReconnectToken
        var hand: [String]

        init(id: PlayerID, reconnectToken: ReconnectToken, hand: [String]) {
            self.id = id
            self.reconnectToken = reconnectToken
            self.hand = hand
        }
    }

    struct AuthoritativeGameState: Codable, Equatable, Sendable {
        let roomID: RoomID
        var players: [AuthoritativePlayer]
        var activePlayerID: PlayerID
        var turn: Int
        var actionNumber: Int
        var authoritativeVersion: AuthoritativeVersion
        var discardPile: [String]

        init(
            roomID: RoomID,
            players: [AuthoritativePlayer],
            activePlayerID: PlayerID,
            turn: Int,
            actionNumber: Int,
            authoritativeVersion: AuthoritativeVersion,
            discardPile: [String]
        ) {
            self.roomID = roomID
            self.players = players
            self.activePlayerID = activePlayerID
            self.turn = turn
            self.actionNumber = actionNumber
            self.authoritativeVersion = authoritativeVersion
            self.discardPile = discardPile
        }
    }

    struct AuthoritativeGameEvent: Codable, Equatable, Sendable {
        struct ScoutDetails: Codable, Equatable, Sendable {
            let intent: ScoutIntent
            let discardedCards: [CardInstance]
            let wildLocationCard: CardInstance
            let wildIndustryCard: CardInstance
        }

        enum Payload: Codable, Equatable, Sendable {
            case passed(discardedCardID: String)
            case built(
                intent: BuildIntent,
                placement: BoardIndustryPlacement,
                resourceEffects: [ResourceEffect]
            )
            case networkBuilt(
                intent: NetworkIntent,
                links: [PlacedLink],
                resourceEffects: [ResourceEffect]
            )
            case developed(
                intent: DevelopIntent,
                tiles: [IndustryTile],
                resourceEffects: [ResourceEffect]
            )
            case sold(
                intent: SellIntent,
                placementIDs: [String],
                resourceEffects: [ResourceEffect]
            )
            case loanTaken(intent: LoanIntent, previousIncomePosition: Int, incomePosition: Int)
            case scouted(ScoutDetails?)
            case forcedSaleResolved(ForcedSaleIntent)
        }

        let roomID: RoomID
        let actor: PlayerID
        let previousVersion: AuthoritativeVersion
        let version: AuthoritativeVersion
        let actionNumber: Int
        let payload: Payload
        let transitions: [GameTransitionEvent]

        init(
            roomID: RoomID, actor: PlayerID,
            previousVersion: AuthoritativeVersion, version: AuthoritativeVersion,
            actionNumber: Int, payload: Payload,
            transitions: [GameTransitionEvent] = []
        ) {
            self.roomID = roomID
            self.actor = actor
            self.previousVersion = previousVersion
            self.version = version
            self.actionNumber = actionNumber
            self.payload = payload
            self.transitions = transitions
        }

        private enum CodingKeys: String, CodingKey {
            case roomID, actor, previousVersion, version, actionNumber, payload, transitions
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            roomID = try values.decode(RoomID.self, forKey: .roomID)
            actor = try values.decode(PlayerID.self, forKey: .actor)
            previousVersion = try values.decode(AuthoritativeVersion.self, forKey: .previousVersion)
            version = try values.decode(AuthoritativeVersion.self, forKey: .version)
            actionNumber = try values.decode(Int.self, forKey: .actionNumber)
            payload = try values.decode(Payload.self, forKey: .payload)
            transitions = try values.decodeIfPresent([GameTransitionEvent].self, forKey: .transitions) ?? []
        }
    }

    struct ForcedSaleIntent: Codable, Equatable, Sendable {
        let placementIDs: [String]
        init(placementIDs: [String]) { self.placementIDs = placementIDs }
    }

    struct ForcedSaleProjection: Codable, Equatable, Sendable {
        struct Option: Codable, Equatable, Sendable {
            let placementID: String
            let liquidationValue: Int
        }

        let shortfall: Int
        let eligiblePlacementIDs: [String]
        let options: [Option]

        init(shortfall: Int, eligiblePlacementIDs: [String], options: [Option] = []) {
            self.shortfall = shortfall
            self.eligiblePlacementIDs = eligiblePlacementIDs
            self.options = options
        }

        private enum CodingKeys: String, CodingKey { case shortfall, eligiblePlacementIDs, options }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            shortfall = try values.decode(Int.self, forKey: .shortfall)
            eligiblePlacementIDs = try values.decode([String].self, forKey: .eligiblePlacementIDs)
            options = try values.decodeIfPresent([Option].self, forKey: .options) ?? []
        }
    }

    enum GameTransitionEvent: Codable, Equatable, Sendable {
        struct RoundEndedDetails: Codable, Equatable, Sendable {
            let completedRoundNumber: Int
            let playerOrder: [PlayerID]
        }
        struct PlayerVPAward: Codable, Equatable, Sendable {
            let playerID: PlayerID
            let linkPoints: Int
            let industryPoints: Int
        }
        struct EraScoredDetails: Codable, Equatable, Sendable {
            let era: Era
            let awards: [PlayerVPAward]
            let removedRouteIDs: [String]
        }
        struct RailPreparedDetails: Codable, Equatable, Sendable {
            let removedPlacementIDs: [String]
            let handCounts: [PlayerID: Int]

            private enum CodingKeys: String, CodingKey {
                case removedPlacementIDs
                case handCounts
            }

            init(removedPlacementIDs: [String], handCounts: [PlayerID: Int]) {
                self.removedPlacementIDs = removedPlacementIDs
                self.handCounts = handCounts
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                removedPlacementIDs = try container.decode([String].self, forKey: .removedPlacementIDs)
                handCounts = try container.decode([PlayerID: Int].self, forKey: .handCounts)
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(removedPlacementIDs, forKey: .removedPlacementIDs)
                var handCountsContainer = container.nestedUnkeyedContainer(forKey: .handCounts)
                for (playerID, handCount) in handCounts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                    try handCountsContainer.encode(playerID)
                    try handCountsContainer.encode(handCount)
                }
            }
        }
        struct GameEndedDetails: Codable, Equatable, Sendable {
            let standings: [[PlayerID]]
        }

        case forcedSaleRequired(PendingForcedSale)
        case forcedSaleRequiredMarker(PlayerID)
        case roundEnded(RoundEndedDetails)
        case eraScored(EraScoredDetails)
        case railPrepared(RailPreparedDetails)
        case gameEnded(GameEndedDetails)
    }

    struct RejectedIntent: Codable, Equatable, Error, Sendable {
        enum ReasonCode: String, Codable, Equatable, Sendable {
            case wrongRoom
            case protocolVersionMismatch
            case rulesetVersionMismatch
            case staleAuthoritativeVersion
            case unknownSender
            case invalidReconnectToken
            case notActivePlayer
            case missingDiscardCard
            case invalidAction
            case internalFailure
            case persistenceUnavailable
        }

        let reasonCode: ReasonCode
        let recoverySuggestion: String
    }

    struct InternalFailure: Codable, Equatable, Error, Sendable {
        enum Code: String, Codable, Equatable, Sendable {
            case arithmeticOverflow
            case invalidAuthorityState
            case invariantViolation
        }

        let code: Code
    }

    enum SubmissionResult: Codable, Equatable, Sendable {
        case accepted(AuthoritativeGameEvent)
        case rejected(RejectedIntent)
        case internalFailure(InternalFailure)
    }

    struct VisiblePlayer: Codable, Equatable, Sendable {
        let id: PlayerID
        let handCount: Int
        let hand: [String]?
    }

    struct ViewSnapshot: Codable, Equatable, Sendable {
        let roomID: RoomID
        let recipient: PlayerID
        /// Missing means a legacy standard-game snapshot.
        let gameVariant: GameVariant?
        let players: [VisiblePlayer]
        let activePlayerID: PlayerID
        let turn: Int
        let actionNumber: Int
        let authoritativeVersion: AuthoritativeVersion
        let discardPile: [String]
        let forcedSale: ForcedSaleProjection?
        let match: MatchProjection?
        let checksum: String

        init(
            roomID: RoomID, recipient: PlayerID, players: [VisiblePlayer],
            activePlayerID: PlayerID, turn: Int, actionNumber: Int,
            authoritativeVersion: AuthoritativeVersion, discardPile: [String],
            forcedSale: ForcedSaleProjection? = nil,
            match: MatchProjection? = nil,
            gameVariant: GameVariant? = .standard,
            checksum: String
        ) {
            self.roomID = roomID
            self.recipient = recipient
            self.gameVariant = gameVariant
            self.players = players
            self.activePlayerID = activePlayerID
            self.turn = turn
            self.actionNumber = actionNumber
            self.authoritativeVersion = authoritativeVersion
            self.discardPile = discardPile
            self.forcedSale = forcedSale
            self.match = match
            self.checksum = checksum
        }

        private enum CodingKeys: String, CodingKey {
            case roomID, recipient, players, activePlayerID, turn, actionNumber
            case authoritativeVersion, discardPile, forcedSale, match, gameVariant, checksum
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            roomID = try values.decode(RoomID.self, forKey: .roomID)
            recipient = try values.decode(PlayerID.self, forKey: .recipient)
            gameVariant = try values.decodeIfPresent(GameVariant.self, forKey: .gameVariant)
            players = try values.decode([VisiblePlayer].self, forKey: .players)
            activePlayerID = try values.decode(PlayerID.self, forKey: .activePlayerID)
            turn = try values.decode(Int.self, forKey: .turn)
            actionNumber = try values.decode(Int.self, forKey: .actionNumber)
            authoritativeVersion = try values.decode(AuthoritativeVersion.self, forKey: .authoritativeVersion)
            discardPile = try values.decode([String].self, forKey: .discardPile)
            forcedSale = try values.decodeIfPresent(ForcedSaleProjection.self, forKey: .forcedSale)
            match = try values.decodeIfPresent(MatchProjection.self, forKey: .match)
            checksum = try values.decode(String.self, forKey: .checksum)
        }
    }

    struct ClientEvent: Codable, Equatable, Sendable {
        let event: AuthoritativeGameEvent
        let snapshot: ViewSnapshot
    }

    enum ProjectionError: Error, Equatable, Sendable {
        case unknownRecipient
        case invalidPlayerOrder
    }

    struct HostEngine: Equatable, Sendable {
        private(set) var gameState: GameState
        private let roomID: RoomID
        private let reconnectTokens: [PlayerID: ReconnectToken]
        let protocolVersion: Int
        var rulesetVersion: String { gameState.rulesetVersion }

        var state: AuthoritativeGameState {
            AuthoritativeGameState(
                roomID: roomID,
                players: gameState.players.map { player in
                    AuthoritativePlayer(
                        id: player.id,
                        reconnectToken: reconnectTokens[player.id] ?? .init(rawValue: ""),
                        hand: player.hand.map(\.id)
                    )
                },
                activePlayerID: gameState.activePlayerID ?? gameState.playerOrder[0],
                turn: gameState.roundNumber,
                actionNumber: gameState.actionNumber,
                authoritativeVersion: gameState.authoritativeVersion,
                discardPile: gameState.publicDiscard.map(\.id)
            )
        }

        init(
            gameState: GameState,
            roomID: RoomID,
            reconnectTokens: [PlayerID: ReconnectToken],
            protocolVersion: Int,
            activePlayerID: PlayerID
        ) {
            self.gameState = gameState
            self.gameState.activePlayerID = activePlayerID
            self.roomID = roomID
            self.reconnectTokens = reconnectTokens
            self.protocolVersion = protocolVersion
        }

        mutating func submit(
            _ intent: PlayerIntent,
            catalog: VerifiedGameDataCatalog
        ) -> SubmissionResult {
            if let rejection = validate(intent) { return .rejected(rejection) }
            guard GameStateAuthorityValidator.isValid(gameState, catalog: catalog) else {
                return .internalFailure(.init(code: .invalidAuthorityState))
            }
            do {
                let event: AuthoritativeGameEvent
                switch intent.payload {
                case .pass(let passIntent):
                    let target = try SimpleActionRules.validatePass(
                        passIntent, actorID: intent.senderID,
                        state: gameState, catalog: catalog
                    )
                    event = try GameRulesEngine.resolvePass(
                        target, roomID: roomID, state: &gameState, catalog: catalog
                    )
                case .build(let buildIntent):
                    let target = try BuildRules.validate(
                        buildIntent, actorID: intent.senderID,
                        state: gameState, catalog: catalog
                    )
                    event = try GameRulesEngine.resolveBuild(
                        target, roomID: roomID, state: &gameState, catalog: catalog
                    )
                case .network(let networkIntent):
                    let target = try NetworkRules.validate(
                        networkIntent, actorID: intent.senderID,
                        state: gameState, catalog: catalog
                    )
                    event = try GameRulesEngine.resolveNetwork(
                        target, roomID: roomID, state: &gameState, catalog: catalog
                    )
                case .develop(let developIntent):
                    let target = try DevelopRules.validate(
                        developIntent, actorID: intent.senderID,
                        state: gameState, catalog: catalog
                    )
                    event = try GameRulesEngine.resolveDevelop(
                        target, roomID: roomID, state: &gameState, catalog: catalog
                    )
                case .sell(let sellIntent):
                    let target = try SellRules.validate(
                        sellIntent, actorID: intent.senderID,
                        state: gameState, catalog: catalog
                    )
                    event = try GameRulesEngine.resolveSell(
                        target, roomID: roomID, state: &gameState, catalog: catalog
                    )
                case .loan(let loanIntent):
                    let target = try SimpleActionRules.validateLoan(
                        loanIntent, actorID: intent.senderID,
                        state: gameState, catalog: catalog
                    )
                    event = try GameRulesEngine.resolveLoan(
                        target, roomID: roomID, state: &gameState, catalog: catalog
                    )
                case .scout(let scoutIntent):
                    let target = try SimpleActionRules.validateScout(
                        scoutIntent, actorID: intent.senderID,
                        state: gameState, catalog: catalog
                    )
                    event = try GameRulesEngine.resolveScout(
                        target, roomID: roomID, state: &gameState, catalog: catalog
                    )
                case .forcedSale(let forcedSaleIntent):
                    event = try GameRulesEngine.resolveForcedSale(
                        forcedSaleIntent, actorID: intent.senderID,
                        roomID: roomID, state: &gameState, catalog: catalog
                    )
                }
                return .accepted(event)
            } catch let error as GameRulesEngine.GameRulesInternalError {
                switch error {
                case .arithmeticOverflow:
                    return .internalFailure(.init(code: .arithmeticOverflow))
                case .invalidAuthorityState:
                    return .internalFailure(.init(code: .invalidAuthorityState))
                case .invariantViolation:
                    return .internalFailure(.init(code: .invariantViolation))
                }
            } catch let error where error is BuildRuleError
                || error is NetworkRuleError
                || error is DevelopRuleError
                || error is SellRuleError
                || error is SimpleActionRuleError
                || error is ResourceRuleError
                || error is ForcedSaleRuleError {
                return .rejected(rejection(.invalidAction))
            } catch {
                return .internalFailure(.init(code: .invariantViolation))
            }
        }

        func snapshot(for recipient: PlayerID) throws -> ViewSnapshot {
            try snapshot(for: recipient, catalog: nil)
        }

        func snapshot(
            for recipient: PlayerID,
            catalog: VerifiedGameDataCatalog
        ) throws -> ViewSnapshot {
            try snapshot(for: recipient, catalog: Optional(catalog))
        }

        private func snapshot(
            for recipient: PlayerID,
            catalog: VerifiedGameDataCatalog?
        ) throws -> ViewSnapshot {
            guard gameState.players.contains(where: { $0.id == recipient }) else {
                throw ProjectionError.unknownRecipient
            }

            let visiblePlayers = gameState.players.map { player in
                VisiblePlayer(
                    id: player.id,
                    handCount: player.hand.count,
                    hand: player.id == recipient ? player.hand.map(\.id) : nil
                )
            }
            guard let activePlayerID = gameState.activePlayerID else {
                throw ProjectionError.unknownRecipient
            }
            let forcedSale: ForcedSaleProjection?
            if case .forcedSale(let pending) = gameState.turnPhase, pending.playerID == recipient {
                forcedSale = .init(
                    shortfall: pending.shortfall,
                    eligiblePlacementIDs: pending.eligiblePlacementIDs.sorted(),
                    options: catalog.map { verified in
                        pending.eligiblePlacementIDs.sorted().compactMap { placementID in
                            guard let placement = gameState.boardIndustryPlacements.first(where: {
                                $0.placementID == placementID && $0.ownerID == recipient
                            }), let value = TurnRules.liquidationValue(
                                of: placement, catalog: verified.catalog
                            ) else { return nil }
                            return .init(placementID: placementID, liquidationValue: value)
                        }
                    } ?? []
                )
            } else {
                forcedSale = nil
            }
            let match = try catalog.map {
                let availability = try SnapshotActionAvailability.make(
                    state: gameState, recipient: recipient, catalog: $0
                )
                var projection = try MatchProjection.make(
                    state: gameState, recipient: recipient,
                    actionOptions: availability.trivialOptions
                )
                projection.availableActions = availability.kinds
                projection.availableActionsByCardID = availability.byCardID
                return projection
            }
            let checksum = try GameCore.snapshotChecksum(
                roomID: roomID,
                recipient: recipient,
                gameVariant: gameState.resolvedGameVariant,
                players: visiblePlayers,
                activePlayerID: activePlayerID,
                turn: gameState.roundNumber,
                actionNumber: gameState.actionNumber,
                authoritativeVersion: gameState.authoritativeVersion,
                discardPile: gameState.publicDiscard.map(\.id),
                forcedSale: forcedSale,
                match: match
            )

            return ViewSnapshot(
                roomID: roomID,
                recipient: recipient,
                players: visiblePlayers,
                activePlayerID: activePlayerID,
                turn: gameState.roundNumber,
                actionNumber: gameState.actionNumber,
                authoritativeVersion: gameState.authoritativeVersion,
                discardPile: gameState.publicDiscard.map(\.id),
                forcedSale: forcedSale,
                match: match,
                gameVariant: gameState.resolvedGameVariant,
                checksum: checksum
            )
        }

        func clientEvent(
            _ event: AuthoritativeGameEvent,
            for recipient: PlayerID
        ) throws -> ClientEvent {
            try clientEvent(event, for: recipient, catalog: nil)
        }

        func clientEvent(
            _ event: AuthoritativeGameEvent,
            for recipient: PlayerID,
            catalog: VerifiedGameDataCatalog
        ) throws -> ClientEvent {
            try clientEvent(event, for: recipient, catalog: Optional(catalog))
        }

        private func clientEvent(
            _ event: AuthoritativeGameEvent,
            for recipient: PlayerID,
            catalog: VerifiedGameDataCatalog?
        ) throws -> ClientEvent {
            let payload: AuthoritativeGameEvent.Payload = if recipient != event.actor, case .scouted = event.payload {
                .scouted(nil)
            } else { event.payload }
            let transitions = event.transitions.map { transition in
                if case .forcedSaleRequired(let pending) = transition,
                   pending.playerID != recipient {
                    return GameTransitionEvent.forcedSaleRequiredMarker(pending.playerID)
                }
                return transition
            }
            let projectedEvent = AuthoritativeGameEvent(
                roomID: event.roomID, actor: event.actor,
                previousVersion: event.previousVersion, version: event.version,
                actionNumber: event.actionNumber, payload: payload,
                transitions: transitions
            )
            let projectedSnapshot = if let catalog {
                try snapshot(for: recipient, catalog: catalog)
            } else {
                try snapshot(for: recipient)
            }
            return ClientEvent(event: projectedEvent, snapshot: projectedSnapshot)
        }

        private func validate(_ intent: PlayerIntent) -> RejectedIntent? {
            guard intent.roomID == roomID else {
                return rejection(.wrongRoom)
            }
            guard intent.protocolVersion == protocolVersion else {
                return rejection(.protocolVersionMismatch)
            }
            guard intent.rulesetVersion == rulesetVersion else {
                return rejection(.rulesetVersionMismatch)
            }
            guard intent.baseVersion == gameState.authoritativeVersion else {
                return rejection(.staleAuthoritativeVersion)
            }
            guard let player = gameState.players.first(where: { $0.id == intent.senderID }) else {
                return rejection(.unknownSender)
            }
            guard reconnectTokens[player.id] == intent.reconnectToken else {
                return rejection(.invalidReconnectToken)
            }
            guard intent.senderID == gameState.activePlayerID else {
                return rejection(.notActivePlayer)
            }
            if gameState.turnPhase == .ended {
                return rejection(.invalidAction)
            }
            if case .forcedSale(let pending) = gameState.turnPhase {
                guard pending.playerID == intent.senderID,
                      case .forcedSale = intent.payload
                else { return rejection(.invalidAction) }
            } else if case .forcedSale = intent.payload {
                return rejection(.invalidAction)
            }
            switch intent.payload {
            case let .pass(passIntent):
                guard player.hand.contains(where: { $0.id == passIntent.cardID }) else {
                    return rejection(.missingDiscardCard)
                }
            case .build(let buildIntent):
                guard player.hand.contains(where: { $0.id == buildIntent.cardID }) else {
                    return rejection(.missingDiscardCard)
                }
            case .network(let networkIntent):
                guard player.hand.contains(where: { $0.id == networkIntent.cardID }) else {
                    return rejection(.missingDiscardCard)
                }
            case .develop(let developIntent):
                guard player.hand.contains(where: { $0.id == developIntent.cardID }) else {
                    return rejection(.missingDiscardCard)
                }
            case .sell(let sellIntent):
                guard player.hand.contains(where: { $0.id == sellIntent.cardID }) else {
                    return rejection(.missingDiscardCard)
                }
            case .loan(let loanIntent):
                guard player.hand.contains(where: { $0.id == loanIntent.cardID }) else {
                    return rejection(.missingDiscardCard)
                }
            case .scout(let scoutIntent):
                guard scoutIntent.cardIDs.allSatisfy({ cardID in
                    player.hand.contains(where: { $0.id == cardID })
                }) else { return rejection(.missingDiscardCard) }
            case .forcedSale:
                break
            }
            return nil
        }

        private func actionsPerTurn(era: Era, roundNumber: Int) -> Int {
            era == .canal && roundNumber == 1 ? 1 : 2
        }

        private func nextPlayer(after index: Int) -> SetupPlayer {
            gameState.players[(index + 1) % gameState.players.count]
        }

        private func rejection(_ reasonCode: RejectedIntent.ReasonCode) -> RejectedIntent {
            let suggestion: String
            switch reasonCode {
            case .wrongRoom:
                suggestion = "Return to the lobby and join the authoritative room."
            case .protocolVersionMismatch:
                suggestion = "Update the app so all peers use the host protocol version."
            case .rulesetVersionMismatch:
                suggestion = "Reload the room using the host ruleset version."
            case .staleAuthoritativeVersion:
                suggestion = "Request a fresh recipient snapshot and retry from that version."
            case .unknownSender:
                suggestion = "Rejoin the room to restore the assigned player identity."
            case .invalidReconnectToken:
                suggestion = "Reauthenticate the seat with its reconnect token."
            case .notActivePlayer:
                suggestion = "Wait until the authoritative state names this player as active."
            case .missingDiscardCard:
                suggestion = "Refresh the private hand and choose a card it contains."
            case .invalidAction:
                suggestion = "Refresh the authoritative state and choose a legal action target."
            case .internalFailure:
                suggestion = "The host paused on an internal authority failure. Recover from a trusted snapshot."
            case .persistenceUnavailable:
                suggestion = "Wait while the host safely saves the latest committed state, then retry."
            }
            return RejectedIntent(reasonCode: reasonCode, recoverySuggestion: suggestion)
        }
    }

    static func snapshotChecksum(
        roomID: RoomID,
        recipient: PlayerID,
        gameVariant: GameVariant? = .standard,
        players: [VisiblePlayer],
        activePlayerID: PlayerID,
        turn: Int,
        actionNumber: Int,
        authoritativeVersion: AuthoritativeVersion,
        discardPile: [String],
        forcedSale: ForcedSaleProjection? = nil,
        match: MatchProjection? = nil
    ) throws -> String {
        struct Material: Encodable {
            var roomID: RoomID
            var recipient: PlayerID
            var gameVariant: GameVariant?
            var players: [VisiblePlayer]
            var activePlayerID: PlayerID
            var turn: Int
            var actionNumber: Int
            var authoritativeVersion: AuthoritativeVersion
            var discardPile: [String]
            var forcedSale: ForcedSaleProjection?
            var match: MatchProjection?
        }
        return try CanonicalChecksum.sha256(Material(
            roomID: roomID, recipient: recipient, gameVariant: gameVariant, players: players,
            activePlayerID: activePlayerID, turn: turn, actionNumber: actionNumber,
            authoritativeVersion: authoritativeVersion, discardPile: discardPile,
            forcedSale: forcedSale, match: match
        ))
    }
}
