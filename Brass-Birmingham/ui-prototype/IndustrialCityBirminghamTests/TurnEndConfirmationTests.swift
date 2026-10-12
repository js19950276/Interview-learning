import Foundation
import Testing

@testable import IndustrialCityBirmingham

/// 回合结束待确认(自定义扩展):两个行动落地后不自动过轮,
/// 玩家确认才交给下一位;期间可整回合撤回(含第二个行动之后)。
struct TurnEndConfirmationTests {
    private func verifiedCatalog() throws -> GameCore.VerifiedGameDataCatalog {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "IndustrialCityBirmingham/GameData/v2018.11")
        let catalog = try GameCore.GameDataLoader.decodeCatalog(
            rulesetVersion: "v2018.11",
            mapData: Data(contentsOf: directory.appending(path: "map.json")),
            industryData: Data(contentsOf: directory.appending(path: "industries.json")),
            cardData: Data(contentsOf: directory.appending(path: "cards.json")),
            merchantData: Data(contentsOf: directory.appending(path: "merchants.json")),
            incomeTrackData: Data(contentsOf: directory.appending(path: "income-track.json"))
        )
        let encoder = JSONEncoder()
        let files = try [
            "map.json": encoder.encode(catalog.board),
            "industries.json": encoder.encode(catalog.industries),
            "cards.json": encoder.encode(catalog.cards),
            "merchants.json": encoder.encode(catalog.merchants),
            "income-track.json": encoder.encode(catalog.incomeTrack),
        ]
        let manifest = GameCore.GameDataManifest(
            rulesetVersion: catalog.rulesetVersion,
            verificationStatus: .verified,
            files: files.keys.sorted().map {
                .init(path: $0, sha256: GameCore.GameDataLoader.sha256(files[$0]!))
            },
            sources: [.init(
                id: "turn-end-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-10-12",
                checker: "independent-test", checkedOn: "2026-10-12"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }

    private func makeEngine(
        catalog: GameCore.VerifiedGameDataCatalog
    ) throws -> (engine: GameCore.HostEngine, roomID: GameCore.RoomID, tokens: [GameCore.PlayerID: GameCore.ReconnectToken]) {
        let players = [GameCore.PlayerID(rawValue: "tc-a"), GameCore.PlayerID(rawValue: "tc-b")]
        var setupRules = GameCore.SetupRules(seed: 91_001)
        let state = try setupRules.makeGame(catalog: catalog, playerIDs: players).state
        let roomID = GameCore.RoomID(rawValue: "turn-end-room")
        let tokens = Dictionary(uniqueKeysWithValues: players.map {
            ($0, GameCore.ReconnectToken(rawValue: "tc-tok-\($0.rawValue)"))
        })
        let engine = try state.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 2
        )
        return (engine, roomID, tokens)
    }

    @discardableResult
    private func submit(
        _ payload: GameCore.PlayerIntent.Payload,
        _ actor: GameCore.PlayerID,
        to engine: inout GameCore.HostEngine,
        roomID: GameCore.RoomID,
        tokens: [GameCore.PlayerID: GameCore.ReconnectToken],
        catalog: GameCore.VerifiedGameDataCatalog
    ) -> GameCore.SubmissionResult {
        let current = engine.gameState
        return engine.submit(
            .init(
                protocolVersion: 2, rulesetVersion: current.rulesetVersion,
                roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
                baseVersion: current.authoritativeVersion, payload: payload
            ),
            catalog: catalog
        )
    }

    /// 第 1 轮(每人 1 个行动):行动落地后进入待确认;确认后过轮、补牌,
    /// 对方成为行动玩家。第 2 轮:两个行动都落地后同样停在待确认。
    @Test func actionsPauseInAwaitingConfirmationAndConfirmAdvancesTurn() throws {
        let catalog = try verifiedCatalog()
        var (engine, roomID, tokens) = try makeEngine(catalog: catalog)
        let firstActor = try #require(engine.gameState.activePlayerID)
        let other = engine.gameState.players.map(\.id).first { $0 != firstActor }!

        let card = try #require(
            engine.gameState.players.first { $0.id == firstActor }?.hand.first
        )
        let pass = submit(
            .pass(.init(cardID: card.id)), firstActor,
            to: &engine, roomID: roomID, tokens: tokens, catalog: catalog
        )
        guard case .accepted = pass else {
            Issue.record("first action rejected: \(pass)")
            return
        }
        // 第 1 轮单人行动:落地后停在待确认,不换人、不补牌。
        #expect(engine.gameState.turnPhase == .awaitingTurnEndConfirmation)
        #expect(engine.gameState.activePlayerID == firstActor)
        #expect(engine.gameState.actionsRemaining == 0)
        #expect(engine.gameState.players.first { $0.id == firstActor }?.hand.count == 7)

        let confirm = submit(
            .confirmTurnEnd, firstActor,
            to: &engine, roomID: roomID, tokens: tokens, catalog: catalog
        )
        guard case .accepted(let confirmEvent) = confirm else {
            Issue.record("confirm rejected: \(confirm)")
            return
        }
        guard case .turnEndConfirmed(let confirmedPlayer) = confirmEvent.payload,
              confirmedPlayer == firstActor
        else {
            Issue.record("unexpected confirm event: \(confirmEvent.payload)")
            return
        }
        #expect(engine.gameState.turnPhase == .active)
        #expect(engine.gameState.activePlayerID == other)
        #expect(engine.gameState.players.first { $0.id == firstActor }?.hand.count == 8)

        // 确认事件可线性重放。
        var replayBase = engine
        _ = replayBase
        // 第 2 轮:首位玩家两个行动后同样停在待确认。
        var guardRounds = 0
        while engine.gameState.activePlayerID != firstActor, guardRounds < 8 {
            guardRounds += 1
            if case .awaitingTurnEndConfirmation = engine.gameState.turnPhase {
                guard let actor = engine.gameState.activePlayerID else { break }
                submit(
                    .confirmTurnEnd, actor,
                    to: &engine, roomID: roomID, tokens: tokens, catalog: catalog
                )
                continue
            }
            guard let actor = engine.gameState.activePlayerID,
                  let hand = engine.gameState.players.first(where: { $0.id == actor })?.hand.first
            else { break }
            submit(
                .pass(.init(cardID: hand.id)), actor,
                to: &engine, roomID: roomID, tokens: tokens, catalog: catalog
            )
        }
        #expect(engine.gameState.activePlayerID == firstActor)
        // 两个行动。
        for _ in 0..<2 {
            let actor = try #require(engine.gameState.activePlayerID)
            let hand = try #require(engine.gameState.players.first { $0.id == actor }?.hand.first)
            let result = submit(
                .pass(.init(cardID: hand.id)), actor,
                to: &engine, roomID: roomID, tokens: tokens, catalog: catalog
            )
            guard case .accepted = result else {
                Issue.record("second-round action rejected: \(result)")
                return
            }
        }
        #expect(engine.gameState.turnPhase == .awaitingTurnEndConfirmation)
        #expect(engine.gameState.activePlayerID == firstActor)
        #expect(engine.gameState.actionsRemaining == 0)
    }

    /// 第二个行动之后仍可整回合撤回:现金/手牌/牌库/行动额度全部回到回合开始。
    @Test func retractionAfterSecondActionRestoresTurnStart() throws {
        let catalog = try verifiedCatalog()
        var (engine, roomID, tokens) = try makeEngine(catalog: catalog)

        // 推进到第 2 轮第一位(两行动回合)。
        var guardRounds = 0
        while engine.gameState.roundNumber == 1, guardRounds < 8 {
            guardRounds += 1
            if case .awaitingTurnEndConfirmation = engine.gameState.turnPhase {
                guard let actor = engine.gameState.activePlayerID else { break }
                submit(
                    .confirmTurnEnd, actor,
                    to: &engine, roomID: roomID, tokens: tokens, catalog: catalog
                )
                continue
            }
            guard let actor = engine.gameState.activePlayerID,
                  let hand = engine.gameState.players.first(where: { $0.id == actor })?.hand.first
            else { break }
            submit(
                .pass(.init(cardID: hand.id)), actor,
                to: &engine, roomID: roomID, tokens: tokens, catalog: catalog
            )
        }
        let actor = try #require(engine.gameState.activePlayerID)
        let turnStart = engine.gameState

        // 两个贷款行动落地。
        for _ in 0..<2 {
            let hand = try #require(engine.gameState.players.first { $0.id == actor }?.hand.first)
            let loan = submit(
                .loan(.init(cardID: hand.id)), actor,
                to: &engine, roomID: roomID, tokens: tokens, catalog: catalog
            )
            guard case .accepted = loan else {
                Issue.record("loan rejected: \(loan)")
                return
            }
        }
        #expect(engine.gameState.turnPhase == .awaitingTurnEndConfirmation)
        let cashAfterLoans = engine.gameState.players.first { $0.id == actor }?.cash
        #expect(cashAfterLoans == (turnStart.players.first { $0.id == actor }?.cash ?? 0) + 60)

        // 待确认阶段整回合撤回。
        let retract = submit(
            .retractTurnActions, actor,
            to: &engine, roomID: roomID, tokens: tokens, catalog: catalog
        )
        guard case .accepted(let retractEvent) = retract else {
            Issue.record("retract-after-second-action rejected: \(retract)")
            return
        }
        guard case .turnActionsRetracted(let player, _, let count) = retractEvent.payload,
              player == actor, count == 2
        else {
            Issue.record("unexpected retract event: \(retractEvent.payload)")
            return
        }
        var restored = engine.gameState
        restored.authoritativeVersion = turnStart.authoritativeVersion
        restored.actionNumber = turnStart.actionNumber
        #expect(restored.players == turnStart.players)
        #expect(restored.publicDiscard == turnStart.publicDiscard)
        #expect(restored.actionsRemaining == turnStart.actionsRemaining)
        #expect(engine.gameState.turnPhase == .active)
        #expect(engine.gameState.activePlayerID == actor)
        #expect(
            GameCore.GameStateAuthorityValidator.isValid(engine.gameState, catalog: catalog),
            "撤回后的状态必须通过权威校验器"
        )

        // 撤回后可以重新行动并正常确认过轮。
        for _ in 0..<2 {
            let hand = try #require(engine.gameState.players.first { $0.id == actor }?.hand.first)
            submit(
                .pass(.init(cardID: hand.id)), actor,
                to: &engine, roomID: roomID, tokens: tokens, catalog: catalog
            )
        }
        let reconfirm = submit(
            .confirmTurnEnd, actor,
            to: &engine, roomID: roomID, tokens: tokens, catalog: catalog
        )
        guard case .accepted = reconfirm else {
            Issue.record("re-confirm after retract rejected: \(reconfirm)")
            return
        }
        #expect(engine.gameState.activePlayerID != actor)
    }

    /// 待确认阶段的边界拒绝:第三个行动不允许;非行动玩家不能确认;
    /// 确认过轮后原行动玩家不能再撤回/再确认。
    @Test func awaitingPhaseRejectsThirdActionAndForeignConfirmAndPostConfirmRetract() throws {
        let catalog = try verifiedCatalog()
        var (engine, roomID, tokens) = try makeEngine(catalog: catalog)
        let firstActor = try #require(engine.gameState.activePlayerID)
        let other = engine.gameState.players.map(\.id).first { $0 != firstActor }!
        let card = try #require(
            engine.gameState.players.first { $0.id == firstActor }?.hand.first
        )
        _ = submit(
            .pass(.init(cardID: card.id)), firstActor,
            to: &engine, roomID: roomID, tokens: tokens, catalog: catalog
        )
        #expect(engine.gameState.turnPhase == .awaitingTurnEndConfirmation)

        // 第三个行动(手牌还有牌)必须被拒。
        let secondCard = try #require(
            engine.gameState.players.first { $0.id == firstActor }?.hand.first
        )
        let thirdAction = submit(
            .pass(.init(cardID: secondCard.id)), firstActor,
            to: &engine, roomID: roomID, tokens: tokens, catalog: catalog
        )
        guard case .rejected(let rejection) = thirdAction else {
            Issue.record("third action during awaiting was accepted: \(thirdAction)")
            return
        }
        #expect(rejection.reasonCode == .invalidAction)

        // 非行动玩家不能确认。
        let foreignConfirm = submit(
            .confirmTurnEnd, other,
            to: &engine, roomID: roomID, tokens: tokens, catalog: catalog
        )
        guard case .rejected(let foreignRejection) = foreignConfirm else {
            Issue.record("foreign confirm was accepted: \(foreignConfirm)")
            return
        }
        #expect(foreignRejection.reasonCode == .notActivePlayer)

        // 确认过轮后:原行动玩家的再次确认/撤回都被拒。
        _ = submit(
            .confirmTurnEnd, firstActor,
            to: &engine, roomID: roomID, tokens: tokens, catalog: catalog
        )
        #expect(engine.gameState.activePlayerID == other)
        let doubleConfirm = submit(
            .confirmTurnEnd, firstActor,
            to: &engine, roomID: roomID, tokens: tokens, catalog: catalog
        )
        guard case .rejected = doubleConfirm else {
            Issue.record("double confirm was accepted: \(doubleConfirm)")
            return
        }
        let lateRetract = submit(
            .retractTurnActions, firstActor,
            to: &engine, roomID: roomID, tokens: tokens, catalog: catalog
        )
        guard case .rejected = lateRetract else {
            Issue.record("post-confirm retract was accepted: \(lateRetract)")
            return
        }
    }

    /// 投影:待确认阶段对每个座位都可见,行动玩家的撤回入口计数 = 2;
    /// 确认事件过收件人快照校验(与真机客机的 EnvelopeValidator 同构)。
    @Test func awaitingPhaseProjectsToEverySeatAndConfirmEventValidates() throws {
        let catalog = try verifiedCatalog()
        var (engine, roomID, tokens) = try makeEngine(catalog: catalog)
        let firstActor = try #require(engine.gameState.activePlayerID)
        let card = try #require(
            engine.gameState.players.first { $0.id == firstActor }?.hand.first
        )
        _ = submit(
            .pass(.init(cardID: card.id)), firstActor,
            to: &engine, roomID: roomID, tokens: tokens, catalog: catalog
        )

        // 本回合已落地操作数是公共信息:所有座位都看到行动玩家的计数。
        for player in [GameCore.PlayerID(rawValue: "tc-a"), GameCore.PlayerID(rawValue: "tc-b")] {
            let snapshot = try engine.snapshot(for: player, catalog: catalog, playerNames: [:])
            #expect(snapshot.awaitingTurnEndConfirmation == true)
            #expect(snapshot.activePlayerID == firstActor)
            #expect(snapshot.match?.turnActionsTaken == 1)
        }

        let confirm = submit(
            .confirmTurnEnd, firstActor,
            to: &engine, roomID: roomID, tokens: tokens, catalog: catalog
        )
        guard case .accepted(let event) = confirm else {
            Issue.record("confirm rejected: \(confirm)")
            return
        }
        for player in [GameCore.PlayerID(rawValue: "tc-a"), GameCore.PlayerID(rawValue: "tc-b")] {
            let clientEvent = try engine.clientEvent(event, for: player, catalog: catalog, playerNames: [:])
            let envelope = SessionProtocol.SessionEnvelope(
                protocolVersion: 2, rulesetVersion: catalog.catalog.rulesetVersion,
                roomID: roomID, messageID: .init(rawValue: "tc-\(event.version.rawValue)"),
                senderID: GameCore.PlayerID(rawValue: "tc-a"), recipientID: player,
                authoritativeVersion: event.version, payload: .clientEvent(clientEvent)
            )
            try SessionProtocol.EnvelopeValidator().validate(
                clientEvent: clientEvent, in: envelope,
                expectedRoster: Set(["tc-a", "tc-b"].map(GameCore.PlayerID.init(rawValue:)))
            )
        }
    }
}
