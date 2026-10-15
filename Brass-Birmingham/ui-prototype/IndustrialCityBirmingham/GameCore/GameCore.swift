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
            /// 时代结算界面的确认;全员确认后进入下一时代。
            case confirmEraIntermission
            /// 回合结束确认:两个行动落地后的"待确认"阶段,确认后才过轮
            ///(补牌/回合末结算/强卖/时代过渡都发生在此时)。
            case confirmTurnEnd
            /// 撤回当前行动玩家本回合已执行的全部操作,回到回合开始状态。
            case retractTurnActions
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
            /// 万能堆空时为 nil:侦察仍可执行,只是拿不到对应牌(官方规则)。
            let wildLocationCard: CardInstance?
            let wildIndustryCard: CardInstance?
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
            case eraIntermissionConfirmed(playerID: PlayerID)
            /// 回合结束确认:行动玩家在待确认阶段确认过轮,真正的换人/结算在此时发生。
            case turnEndConfirmed(playerID: PlayerID)
            /// 回合操作撤回:状态回到该玩家回合开始时的快照,版本链照常 +1 前进。
            case turnActionsRetracted(
                playerID: PlayerID,
                rewoundFromVersion: AuthoritativeVersion,
                actionCount: Int
            )
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
        }
        struct GameEndedDetails: Codable, Equatable, Sendable {
            let standings: [[PlayerID]]
        }
        struct ShortCanalPlayerScore: Codable, Equatable, Sendable {
            let playerID: PlayerID
            /// 刚才 eraScored 里该玩家的线分,按 playerOrder 回显;本事件不重加。
            let linkPoints: Int
            /// 刚才 eraScored 里该玩家的产业分,含已翻面一级;本事件不重加。
            let industryPoints: Int
            /// 已翻面且等级 ≥ 2 的板块 VP 之和;本事件之前已加入。
            let secondIndustryPoints: Int
            /// min(15, max(0, cash) / 4);已加入。
            let cashPoints: Int
            /// 收入等级本身,可为负;名义值,不是夹断后的实际加减量。
            let incomePoints: Int
            /// 夹断之后的最终 VP。
            let victoryPoints: Int
        }
        struct ShortCanalScoredDetails: Codable, Equatable, Sendable {
            let awards: [ShortCanalPlayerScore]
        }

        case forcedSaleRequired(PendingForcedSale)
        case forcedSaleRequiredMarker(PlayerID)
        case roundEnded(RoundEndedDetails)
        case eraScored(EraScoredDetails)
        case eraIntermissionConfirmed(playerID: PlayerID)
        case railPrepared(RailPreparedDetails)
        case gameEnded(GameEndedDetails)
        case shortCanalScored(ShortCanalScoredDetails)
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
        var name: String? = nil
    }

    struct ViewSnapshot: Codable, Equatable, Sendable {
        let roomID: RoomID
        let recipient: PlayerID
        let players: [VisiblePlayer]
        let activePlayerID: PlayerID
        let turn: Int
        let actionNumber: Int
        let authoritativeVersion: AuthoritativeVersion
        let discardPile: [String]
        let forcedSale: ForcedSaleProjection?
        let eraIntermission: EraIntermissionState?
        let gameEnded: GameTransitionEvent.GameEndedDetails?
        /// 回合结束待确认:行动玩家两个行动落地后需确认才过轮(自定义扩展)。
        /// 可选解码,旧存档缺省为 false。
        let awaitingTurnEndConfirmation: Bool
        let match: MatchProjection?
        let checksum: String

        init(
            roomID: RoomID, recipient: PlayerID, players: [VisiblePlayer],
            activePlayerID: PlayerID, turn: Int, actionNumber: Int,
            authoritativeVersion: AuthoritativeVersion, discardPile: [String],
            forcedSale: ForcedSaleProjection? = nil,
            eraIntermission: EraIntermissionState? = nil,
            gameEnded: GameTransitionEvent.GameEndedDetails? = nil,
            awaitingTurnEndConfirmation: Bool = false,
            match: MatchProjection? = nil,
            checksum: String
        ) {
            self.roomID = roomID
            self.recipient = recipient
            self.players = players
            self.activePlayerID = activePlayerID
            self.turn = turn
            self.actionNumber = actionNumber
            self.authoritativeVersion = authoritativeVersion
            self.discardPile = discardPile
            self.forcedSale = forcedSale
            self.eraIntermission = eraIntermission
            self.gameEnded = gameEnded
            self.awaitingTurnEndConfirmation = awaitingTurnEndConfirmation
            self.match = match
            self.checksum = checksum
        }

        private enum CodingKeys: String, CodingKey {
            case roomID, recipient, players, activePlayerID, turn, actionNumber
            case authoritativeVersion, discardPile, forcedSale, eraIntermission, gameEnded
            case awaitingTurnEndConfirmation, match, checksum
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            roomID = try values.decode(RoomID.self, forKey: .roomID)
            recipient = try values.decode(PlayerID.self, forKey: .recipient)
            players = try values.decode([VisiblePlayer].self, forKey: .players)
            activePlayerID = try values.decode(PlayerID.self, forKey: .activePlayerID)
            turn = try values.decode(Int.self, forKey: .turn)
            actionNumber = try values.decode(Int.self, forKey: .actionNumber)
            authoritativeVersion = try values.decode(AuthoritativeVersion.self, forKey: .authoritativeVersion)
            discardPile = try values.decode([String].self, forKey: .discardPile)
            forcedSale = try values.decodeIfPresent(ForcedSaleProjection.self, forKey: .forcedSale)
            eraIntermission = try values.decodeIfPresent(EraIntermissionState.self, forKey: .eraIntermission)
            gameEnded = try values.decodeIfPresent(GameTransitionEvent.GameEndedDetails.self, forKey: .gameEnded)
            awaitingTurnEndConfirmation = try values.decodeIfPresent(Bool.self, forKey: .awaitingTurnEndConfirmation) ?? false
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
    }

    struct HostEngine: Equatable, Sendable {
        /// 回合起点锚点:该玩家回合开始(上一个事件落地后)的权威状态。
        /// 撤回 = 恢复锚点状态并把版本/actionNumber 照常 +1,事件链保持严格递增。
        struct TurnAnchor: Equatable, Sendable {
            let playerID: PlayerID
            let version: AuthoritativeVersion
            let state: GameState
        }

        private(set) var gameState: GameState
        private(set) var turnAnchor: TurnAnchor?
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
            self.turnAnchor = TurnAnchor(
                playerID: activePlayerID,
                version: gameState.authoritativeVersion,
                state: self.gameState
            )
        }

        mutating func submit(
            _ intent: PlayerIntent,
            catalog: VerifiedGameDataCatalog
        ) -> SubmissionResult {
            let previousActiveID = gameState.activePlayerID
            let previousRoundNumber = gameState.roundNumber
            let result = submitResolved(intent, catalog: catalog)
            // 事件落地后若行动座位或回合切换,则新座位回合开始,锚点前移。
            if case .accepted = result,
               gameState.activePlayerID != previousActiveID || gameState.roundNumber != previousRoundNumber,
               let active = gameState.activePlayerID {
                turnAnchor = TurnAnchor(
                    playerID: active,
                    version: gameState.authoritativeVersion,
                    state: gameState
                )
            }
            return result
        }

        private mutating func submitResolved(
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
                case .confirmEraIntermission:
                    let target = try SimpleActionRules.validateEraConfirmation(
                        actorID: intent.senderID, state: gameState, catalog: catalog
                    )
                    event = try GameRulesEngine.resolveEraConfirmation(
                        target, roomID: roomID, state: &gameState, catalog: catalog
                    )
                case .confirmTurnEnd:
                    let target = try SimpleActionRules.validateTurnEndConfirmation(
                        actorID: intent.senderID, state: gameState, catalog: catalog
                    )
                    event = try GameRulesEngine.resolveTurnEndConfirmation(
                        actorID: target.actorID, roomID: roomID, state: &gameState,
                        catalog: catalog
                    )
                case .retractTurnActions:
                    guard let anchor = turnAnchor,
                          anchor.playerID == intent.senderID,
                          anchor.version.rawValue < gameState.authoritativeVersion.rawValue
                    else {
                        return .rejected(rejection(.invalidAction))
                    }
                    let previousVersion = gameState.authoritativeVersion
                    let (nextVersion, versionOverflow) = previousVersion.rawValue.addingReportingOverflow(1)
                    let (nextActionNumber, actionOverflow) = gameState.actionNumber.addingReportingOverflow(1)
                    guard versionOverflow == false, actionOverflow == false else {
                        return .internalFailure(.init(code: .arithmeticOverflow))
                    }
                    let retractedActionCount = gameState.actionNumber - anchor.state.actionNumber
                    var restored = anchor.state
                    restored.authoritativeVersion = .init(rawValue: nextVersion)
                    restored.actionNumber = nextActionNumber
                    event = AuthoritativeGameEvent(
                        roomID: roomID,
                        actor: intent.senderID,
                        previousVersion: previousVersion,
                        version: restored.authoritativeVersion,
                        actionNumber: nextActionNumber,
                        payload: .turnActionsRetracted(
                            playerID: intent.senderID,
                            rewoundFromVersion: previousVersion,
                            actionCount: retractedActionCount
                        ),
                        transitions: []
                    )
                    gameState = restored
                    turnAnchor = TurnAnchor(
                        playerID: intent.senderID,
                        version: restored.authoritativeVersion,
                        state: restored
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
            try snapshotImpl(for: recipient, catalog: nil, playerNames: nil)
        }

        func snapshot(
            for recipient: PlayerID,
            catalog: VerifiedGameDataCatalog
        ) throws -> ViewSnapshot {
            try snapshotImpl(for: recipient, catalog: Optional(catalog), playerNames: nil)
        }

        func snapshot(
            for recipient: PlayerID,
            catalog: VerifiedGameDataCatalog?,
            playerNames: [PlayerID: String]?
        ) throws -> ViewSnapshot {
            try snapshotImpl(for: recipient, catalog: catalog, playerNames: playerNames)
        }

        private func snapshotImpl(
            for recipient: PlayerID,
            catalog: VerifiedGameDataCatalog?,
            playerNames: [PlayerID: String]?
        ) throws -> ViewSnapshot {
            guard gameState.players.contains(where: { $0.id == recipient }) else {
                throw ProjectionError.unknownRecipient
            }

            let visiblePlayers = gameState.players.map { player in
                VisiblePlayer(
                    id: player.id,
                    handCount: player.hand.count,
                    hand: player.id == recipient ? player.hand.map(\.id) : nil,
                    name: playerNames?[player.id]
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
                    actionOptions: availability.trivialOptions,
                    playerNames: playerNames ?? [:],
                    incomeTrack: catalog?.catalog.incomeTrack.entries ?? []
                )
                projection.availableActions = availability.kinds
                projection.availableActionsByCardID = availability.byCardID
                // 本回合已落地操作数(供 UI 显示"撤回本回合操作"入口):
                // 活跃或待确认阶段且锚点属于当前行动玩家时,取事件序号差
                //(待确认阶段 = 两个行动都已落地,撤回入口保持可用)。
                projection.turnActionsTaken = if gameState.turnPhase == .active
                    || gameState.turnPhase == .awaitingTurnEndConfirmation,
                    let anchor = turnAnchor,
                    anchor.playerID == activePlayerID {
                    max(0, gameState.actionNumber - anchor.state.actionNumber)
                } else {
                    0
                }
                return projection
            }
            let checksum = try GameCore.snapshotChecksum(
                roomID: roomID,
                recipient: recipient,
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
                eraIntermission: {
                    if case .eraIntermission(let intermission) = gameState.turnPhase {
                        return intermission
                    }
                    return nil
                }(),
                gameEnded: gameState.finalStandings.map {
                    GameTransitionEvent.GameEndedDetails(standings: $0)
                },
                awaitingTurnEndConfirmation: gameState.turnPhase == .awaitingTurnEndConfirmation,
                match: match,
                checksum: checksum
            )
        }

        func clientEvent(
            _ event: AuthoritativeGameEvent,
            for recipient: PlayerID
        ) throws -> ClientEvent {
            try clientEvent(event, for: recipient, catalog: nil, playerNames: nil)
        }

        func clientEvent(
            _ event: AuthoritativeGameEvent,
            for recipient: PlayerID,
            catalog: VerifiedGameDataCatalog?,
            playerNames: [PlayerID: String]? = nil
        ) throws -> ClientEvent {
            try clientEventImpl(event, for: recipient, catalog: catalog, playerNames: playerNames)
        }

        private func clientEventImpl(
            _ event: AuthoritativeGameEvent,
            for recipient: PlayerID,
            catalog: VerifiedGameDataCatalog?,
            playerNames: [PlayerID: String]?
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
                try snapshotImpl(for: recipient, catalog: catalog, playerNames: playerNames)
            } else {
                try snapshotImpl(for: recipient, catalog: nil, playerNames: playerNames)
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
            // 时代结算确认:任何座位都可以确认,不受当前行动座位限制。
            if case .confirmEraIntermission = intent.payload {
                if case .eraIntermission = gameState.turnPhase {
                    return nil
                }
                return rejection(.invalidAction)
            }
            // 结算暂停期间拒绝一切普通行动:此时 advanceAction 会破坏
            // intermission 不变量,导致之后所有行动(含确认)永久被拒。
            if case .eraIntermission = gameState.turnPhase {
                return rejection(.invalidAction)
            }
            // 回合结束待确认:只接受"确认过轮"与"整回合撤回",第三个行动不允许。
            if case .awaitingTurnEndConfirmation = gameState.turnPhase {
                switch intent.payload {
                case .confirmTurnEnd, .retractTurnActions:
                    break
                default:
                    return rejection(.invalidAction)
                }
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
            case .confirmEraIntermission:
                // 时代确认无持牌要求;阶段合法性由校验规则把关。
                break
            case .confirmTurnEnd:
                // 过轮确认无持牌要求;阶段与行动座位合法性由校验规则把关。
                break
            case .retractTurnActions:
                // 仅当前行动玩家、活跃或待确认阶段、本回合确有已落地操作时可撤回;
                // 其余阶段(结算暂停/强卖/终局)一律拒绝。
                guard gameState.turnPhase == .active
                    || gameState.turnPhase == .awaitingTurnEndConfirmation,
                      let anchor = turnAnchor,
                      anchor.playerID == intent.senderID,
                      anchor.version.rawValue < gameState.authoritativeVersion.rawValue
                else { return rejection(.invalidAction) }
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
            roomID: roomID, recipient: recipient, players: players,
            activePlayerID: activePlayerID, turn: turn, actionNumber: actionNumber,
            authoritativeVersion: authoritativeVersion, discardPile: discardPile,
            forcedSale: forcedSale, match: match
        ))
    }
}
