import Foundation
import Testing

@testable import IndustrialCityBirmingham

/// 回合操作撤回:当前行动玩家可在本回合内回到回合开始状态,
/// 版本链/actionNumber 照常严格 +1,客机经快照自然收敛。
struct TurnRetractionTests {
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
                id: "turn-retraction-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-09-21",
                checker: "independent-test", checkedOn: "2026-09-21"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }

    /// 引擎推进到第 2 轮第一位(2 操作回合),返回其回合开始时的权威状态副本。
    private func makeRoundTwoEngine(
        catalog: GameCore.VerifiedGameDataCatalog
    ) throws -> (engine: GameCore.HostEngine, turnStart: GameCore.GameState, roomID: GameCore.RoomID, tokens: [GameCore.PlayerID: GameCore.ReconnectToken], actor: GameCore.PlayerID) {
        let players = (1...3).map { GameCore.PlayerID(rawValue: "tr-\($0)") }
        var setupRules = GameCore.SetupRules(seed: 81_001)
        let state = try setupRules.makeGame(catalog: catalog, playerIDs: players).state
        let roomID = GameCore.RoomID(rawValue: "retract-room")
        let tokens = Dictionary(uniqueKeysWithValues: players.map {
            ($0, GameCore.ReconnectToken(rawValue: "tr-tok-\($0.rawValue)"))
        })
        var engine = try state.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 2
        )
        // 第 1 轮每人 1 个操作:全部跳过,进入第 2 轮。
        while engine.gameState.roundNumber == 1 {
            if TurnEndDriving.confirmIfAwaiting(&engine, roomID: roomID, tokens: tokens, catalog: catalog) {
                continue
            }
            let current = engine.gameState
            guard let actor = current.activePlayerID,
                  let card = current.players.first(where: { $0.id == actor })?.hand.first
            else { throw RecroError.bad }
            let result = engine.submit(.init(
                protocolVersion: 2, rulesetVersion: current.rulesetVersion,
                roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
                baseVersion: current.authoritativeVersion,
                payload: .pass(.init(cardID: card.id))
            ), catalog: catalog)
            guard case .accepted = result else { throw RecroError.bad }
        }
        guard engine.gameState.roundNumber == 2,
              engine.gameState.turnPhase == .active,
              let actor = engine.gameState.activePlayerID
        else { throw RecroError.bad }
        return (engine, engine.gameState, roomID, tokens, actor)
    }

    private enum RecroError: Swift.Error { case bad }

    @Test func retractionRestoresTurnStartStateAndKeepsVersionChain() throws {
        let catalog = try verifiedCatalog()
        var (engine, turnStart, roomID, tokens, actor) = try makeRoundTwoEngine(catalog: catalog)
        let handCard = try #require(
            engine.gameState.players.first(where: { $0.id == actor })?.hand.first
        )

        // 第 1 个操作:贷款 £30。
        let loan = engine.submit(.init(
            protocolVersion: 2, rulesetVersion: engine.gameState.rulesetVersion,
            roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
            baseVersion: engine.gameState.authoritativeVersion,
            payload: .loan(.init(cardID: handCard.id))
        ), catalog: catalog)
        guard case .accepted = loan else {
            Issue.record("loan rejected: \(loan)")
            return
        }
        let afterLoan = engine.gameState
        #expect(afterLoan.players.first(where: { $0.id == actor })?.cash
                == turnStart.players.first(where: { $0.id == actor })!.cash + 30)

        // 撤回:回到回合开始(现金/手牌/弃牌堆/牌库/剩余操作数全部还原)。
        let retract = engine.submit(.init(
            protocolVersion: 2, rulesetVersion: engine.gameState.rulesetVersion,
            roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
            baseVersion: engine.gameState.authoritativeVersion,
            payload: .retractTurnActions
        ), catalog: catalog)
        guard case .accepted(let retractEvent) = retract else {
            Issue.record("retract rejected: \(retract)")
            return
        }
        guard case .turnActionsRetracted(let retracedPlayer, _, let actionCount) = retractEvent.payload,
              retracedPlayer == actor, actionCount == 1
        else {
            Issue.record("unexpected retract event: \(retractEvent.payload)")
            return
        }
        let restored = engine.gameState
        let restoredPlayer = try #require(restored.players.first(where: { $0.id == actor }))
        let startPlayer = try #require(turnStart.players.first(where: { $0.id == actor }))
        #expect(restoredPlayer.cash == startPlayer.cash)
        #expect(restoredPlayer.incomePosition == startPlayer.incomePosition)
        #expect(restoredPlayer.hand.map(\.id) == startPlayer.hand.map(\.id))
        #expect(restored.actionsRemaining == turnStart.actionsRemaining)
        #expect(restored.publicDiscard.count == turnStart.publicDiscard.count)
        #expect(restored.standardDrawDeck.count == turnStart.standardDrawDeck.count)
        // 版本链/actionNumber 严格递增:贷款 +1、撤回 +1。
        #expect(restored.authoritativeVersion.rawValue == turnStart.authoritativeVersion.rawValue + 2)
        #expect(restored.actionNumber == turnStart.actionNumber + 2)
        // 铁证:除版本链字段外,撤回后的权威状态与回合开始逐字段完全一致。
        // 因此撤回后的任何建造,扣费与"从未贷款"完全相同。
        var expectedTurnStart = turnStart
        expectedTurnStart.authoritativeVersion = restored.authoritativeVersion
        expectedTurnStart.actionNumber = restored.actionNumber
        #expect(restored == expectedTurnStart)
        // 权威校验器仍通过,撤回提示归零。
        #expect(GameCore.GameStateAuthorityValidator.isValid(restored, catalog: catalog))
        let snapshot = try engine.snapshot(for: actor, catalog: catalog)
        #expect(snapshot.match?.turnActionsTaken == 0)

        // 撤回后可正常重做两个操作(贷款 + 跳过),回合照常结束。
        let redoCard = try #require(
            restored.players.first(where: { $0.id == actor })?.hand.first
        )
        let redoLoan = engine.submit(.init(
            protocolVersion: 2, rulesetVersion: restored.rulesetVersion,
            roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
            baseVersion: engine.gameState.authoritativeVersion,
            payload: .loan(.init(cardID: redoCard.id))
        ), catalog: catalog)
        guard case .accepted = redoLoan else {
            Issue.record("redo loan rejected: \(redoLoan)")
            return
        }
        let midSnapshot = try engine.snapshot(for: actor, catalog: catalog)
        #expect(midSnapshot.match?.turnActionsTaken == 1)
        let passCard = try #require(
            engine.gameState.players.first(where: { $0.id == actor })?.hand.first
        )
        let redoPass = engine.submit(.init(
            protocolVersion: 2, rulesetVersion: engine.gameState.rulesetVersion,
            roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
            baseVersion: engine.gameState.authoritativeVersion,
            payload: .pass(.init(cardID: passCard.id))
        ), catalog: catalog)
        guard case .accepted = redoPass else {
            Issue.record("redo pass rejected: \(redoPass)")
            return
        }
        // 新流程:第二个操作落地后停在待确认,此时仍可撤回;
        // 确认过轮后回合才交给下一位,锚点随之前移。
        #expect(engine.gameState.turnPhase == .awaitingTurnEndConfirmation)
        let turnEndConfirm = engine.submit(.init(
            protocolVersion: 2, rulesetVersion: engine.gameState.rulesetVersion,
            roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
            baseVersion: engine.gameState.authoritativeVersion,
            payload: .confirmTurnEnd
        ), catalog: catalog)
        guard case .accepted = turnEndConfirm else {
            Issue.record("turn-end confirm after redo rejected: \(turnEndConfirm)")
            return
        }
        // 回合已交给下一位:此时撤回必须被拒(锚点属于新行动玩家)。
        let nextActor = try #require(engine.gameState.activePlayerID)
        let staleRetract = engine.submit(.init(
            protocolVersion: 2, rulesetVersion: engine.gameState.rulesetVersion,
            roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
            baseVersion: engine.gameState.authoritativeVersion,
            payload: .retractTurnActions
        ), catalog: catalog)
        guard case .rejected = staleRetract else {
            Issue.record("retract after turn passed must be rejected: \(staleRetract)")
            return
        }
        // 下一位自己回合开始,无可撤回内容。
        let noOpRetract = engine.submit(.init(
            protocolVersion: 2, rulesetVersion: engine.gameState.rulesetVersion,
            roomID: roomID, senderID: nextActor, reconnectToken: tokens[nextActor]!,
            baseVersion: engine.gameState.authoritativeVersion,
            payload: .retractTurnActions
        ), catalog: catalog)
        guard case .rejected = noOpRetract else {
            Issue.record("retract with zero actions taken must be rejected: \(noOpRetract)")
            return
        }
        _ = nextActor
    }

    /// 复现实机反馈:贷款→撤回→建造,建造必须收取全额费用(板块+资源),
    /// 且玩家现金/收入/手牌必须与"没发生过贷款"完全一致。
    @Test func loanRetractThenBuildChargesFullCost() throws {
        let catalog = try verifiedCatalog()
        var (engine, _, roomID, tokens, actor) = try makeRoundTwoEngine(catalog: catalog)

        func submit(_ payload: GameCore.PlayerIntent.Payload) -> GameCore.SubmissionResult {
            let current = engine.gameState
            return engine.submit(.init(
                protocolVersion: 2, rulesetVersion: current.rulesetVersion,
                roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
                baseVersion: current.authoritativeVersion, payload: payload
            ), catalog: catalog)
        }

        // 贷款然后撤回。
        let loanCard = try #require(
            engine.gameState.players.first(where: { $0.id == actor })?.hand.first
        )
        guard case .accepted = submit(.loan(.init(cardID: loanCard.id))) else {
            Issue.record("loan rejected")
            return
        }
        guard case .accepted = submit(.retractTurnActions) else {
            Issue.record("retract rejected")
            return
        }
        let baseline = engine.gameState
        let baselineCash = try #require(
            baseline.players.first(where: { $0.id == actor })?.cash
        )

        // 经查询引擎完整走一次建造(与实机同路径)。
        guard let buildCard = baseline.players.first(where: { $0.id == actor })?.hand.first
        else { throw RecroError.bad }
        var selections: [GameCore.LegalChoiceValue] = []
        var response = try GameCore.LegalActionQueryEngine.respond(
            to: .init(requestID: "rb", baseVersion: baseline.authoritativeVersion,
                      draft: .init(action: .build, cardID: buildCard.id, selections: [])),
            actorID: actor, state: baseline, catalog: catalog
        )
        var buildPayload: GameCore.PlayerIntent.Payload?
        for _ in 0..<10 {
            if let payload = response.completePayload {
                buildPayload = payload
                break
            }
            guard let next = response.nextChoices.first else { break }
            selections.append(next.value)
            response = try GameCore.LegalActionQueryEngine.respond(
                to: .init(requestID: "rb", baseVersion: baseline.authoritativeVersion,
                          draft: .init(action: .build, cardID: buildCard.id, selections: selections)),
                actorID: actor, state: baseline, catalog: catalog
            )
        }
        guard case .build(let buildIntent) = buildPayload else {
            Issue.record("no completable build found in round 2")
            return
        }
        // 查询引擎的确认面板增量 = 期望扣费(现金减少额)。
        let expectedCashDelta = try #require(response.confirmation).cashDelta
        #expect(expectedCashDelta < 0, "build must cost cash, got \(expectedCashDelta)")

        guard case .accepted = submit(.build(buildIntent)) else {
            Issue.record("build rejected")
            return
        }
        let afterCash = try #require(
            engine.gameState.players.first(where: { $0.id == actor })?.cash
        )
        let actualDelta = afterCash - baselineCash
        #expect(actualDelta == expectedCashDelta,
                "cash delta \(actualDelta) != expected \(expectedCashDelta) (loan residue suspected)")
        // 建造后现金不得为负,且权威状态过校验。
        #expect(afterCash >= 0)
        #expect(GameCore.GameStateAuthorityValidator.isValid(engine.gameState, catalog: catalog))
    }

    /// 会话层复现:经 SessionCoordinator(实机同路径)执行贷款→撤回→建造,
    /// 主机快照里的现金扣减必须与确认面板一致。
    @Test func sessionLoanRetractBuildChargesFullCost() async throws {
        let catalog = try verifiedCatalog()
        // 直接用引擎把第 1 轮打完,再以该状态构造主机协调器。
        var setupRules = GameCore.SetupRules(seed: 82_001)
        let players = [GameCore.PlayerID(rawValue: "sh"), GameCore.PlayerID(rawValue: "sg")]
        var state = try setupRules.makeGame(catalog: catalog, playerIDs: players).state
        let tokens = Dictionary(uniqueKeysWithValues: players.map {
            ($0, GameCore.ReconnectToken(rawValue: "sh-tok-\($0.rawValue)"))
        })
        let roomID = GameCore.RoomID(rawValue: "sh-room")
        var engine = try state.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 2
        )
        while engine.gameState.roundNumber == 1 {
            if TurnEndDriving.confirmIfAwaiting(&engine, roomID: roomID, tokens: tokens, catalog: catalog) {
                continue
            }
            let current = engine.gameState
            guard let actor = current.activePlayerID,
                  let card = current.players.first(where: { $0.id == actor })?.hand.first
            else { throw RecroError.bad }
            guard case .accepted = engine.submit(.init(
                protocolVersion: 2, rulesetVersion: current.rulesetVersion,
                roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
                baseVersion: current.authoritativeVersion,
                payload: .pass(.init(cardID: card.id))
            ), catalog: catalog) else { throw RecroError.bad }
        }
        guard engine.gameState.roundNumber == 2,
              let actor = engine.gameState.activePlayerID
        else { throw RecroError.bad }
        let hostActor = GameCore.PlayerID(rawValue: "sh")
        // 确保主机座位恰为第 2 轮先手;否则换种子重试太复杂,直接断言。
        guard actor == hostActor else {
            Issue.record("seed 82_001 did not make sh the round-2 leader; pick another seed")
            return
        }

        let coordinator = try SessionCoordinator(
            configuration: .init(
                protocolVersion: 2, rulesetVersion: engine.gameState.rulesetVersion,
                roomID: roomID, playerID: hostActor,
                reconnectToken: tokens[hostActor]!, hostPlayerID: hostActor
            ),
            restored: .init(
                state: engine.state, gameState: engine.gameState, eventWindows: [:],
                peersNeedingRecovery: [], commitSequence: 1
            ),
            transport: LoopbackTransportHub().makeTransport(peerID: hostActor),
            rulesMode: .verified(catalog)
        )

        // 贷款。
        let snapshot0 = try #require(await coordinator.snapshot)
        let loanCard = try #require(
            snapshot0.players.first(where: { $0.id == hostActor })?.hand?.first
        )
        try await coordinator.submit(.loan(.init(cardID: loanCard)))
        // 撤回。
        try await coordinator.submit(.retractTurnActions)
        let afterRetract = try #require(await coordinator.snapshot)
        #expect(afterRetract.match?.turnActionsTaken == 0)

        // 建造(实机同路径:合法查询→完整意图→提交)。
        let buildCard = try #require(
            afterRetract.players.first(where: { $0.id == hostActor })?.hand?.first
        )
        try await coordinator.requestLegalOptions(
            requestID: "sess-build",
            draft: .init(action: .build, cardID: buildCard, selections: [])
        )
        var response = try #require(await coordinator.lastLegalResponse)
        var selections: [GameCore.LegalChoiceValue] = []
        for _ in 0..<10 {
            if response.completePayload != nil { break }
            guard let next = response.nextChoices.first else { break }
            selections.append(next.value)
            try await coordinator.requestLegalOptions(
                requestID: "sess-build",
                draft: .init(action: .build, cardID: buildCard, selections: selections)
            )
            response = try #require(await coordinator.lastLegalResponse)
        }
        guard case .build(let buildIntent) = response.completePayload else {
            Issue.record("no completable build found")
            return
        }
        let expectedCashDelta = try #require(response.confirmation).cashDelta
        let baselineCash = try #require(
            afterRetract.match?.players.first(where: { $0.id == hostActor })?.cash
        )
        try await coordinator.submit(.build(buildIntent))
        let afterBuild = try #require(await coordinator.snapshot)
        let afterCash = try #require(
            afterBuild.match?.players.first(where: { $0.id == hostActor })?.cash
        )
        #expect(afterCash - baselineCash == expectedCashDelta,
                "session cash delta \(afterCash - baselineCash) != confirmation \(expectedCashDelta)")
    }

    @Test func retractionRejectedForNonActivePlayer() throws {
        let catalog = try verifiedCatalog()
        let (varEngine, _, roomID, tokens, actor) = try makeRoundTwoEngine(catalog: catalog)
        var engine = varEngine
        let bystander = try #require(
            engine.gameState.players.map(\.id).first(where: { $0 != actor })
        )
        let result = engine.submit(.init(
            protocolVersion: 2, rulesetVersion: engine.gameState.rulesetVersion,
            roomID: roomID, senderID: bystander, reconnectToken: tokens[bystander]!,
            baseVersion: engine.gameState.authoritativeVersion,
            payload: .retractTurnActions
        ), catalog: catalog)
        guard case .rejected = result else {
            Issue.record("non-active player retract must be rejected: \(result)")
            return
        }
    }

    @Test func retractedEventProjectsValidSnapshotsForEveryRecipient() throws {
        let catalog = try verifiedCatalog()
        var (engine, _, roomID, tokens, actor) = try makeRoundTwoEngine(catalog: catalog)
        let card = try #require(
            engine.gameState.players.first(where: { $0.id == actor })?.hand.first
        )
        guard case .accepted = engine.submit(.init(
            protocolVersion: 2, rulesetVersion: engine.gameState.rulesetVersion,
            roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
            baseVersion: engine.gameState.authoritativeVersion,
            payload: .pass(.init(cardID: card.id))
        ), catalog: catalog) else {
            Issue.record("pass rejected")
            return
        }
        var retractEvent: GameCore.AuthoritativeGameEvent?
        if case .accepted(let event) = engine.submit(.init(
            protocolVersion: 2, rulesetVersion: engine.gameState.rulesetVersion,
            roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
            baseVersion: engine.gameState.authoritativeVersion,
            payload: .retractTurnActions
        ), catalog: catalog) {
            retractEvent = event
        }
        let event = try #require(retractEvent)
        let roster = Set(engine.gameState.players.map(\.id))
        for player in roster {
            let clientEvent = try engine.clientEvent(
                event, for: player, catalog: catalog,
                playerNames: Dictionary(uniqueKeysWithValues: roster.map { ($0, $0.rawValue) })
            )
            let context = GameCore.RecipientSnapshotValidationContext(
                protocolVersion: 2, rulesetVersion: catalog.catalog.rulesetVersion,
                roomID: roomID, recipient: player, roster: roster,
                authoritativeVersion: event.version
            )
            do {
                try GameCore.RecipientSnapshotValidator.validate(clientEvent.snapshot, context: context)
            } catch {
                Issue.record("snapshot for \(player.rawValue) failed validation: \(error)")
            }
        }
    }
}
