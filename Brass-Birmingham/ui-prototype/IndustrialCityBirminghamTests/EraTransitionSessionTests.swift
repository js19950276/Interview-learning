import Foundation
import Testing

@testable import IndustrialCityBirmingham

/// 复现运河→铁路边界处的会话层问题:
/// 主机提交跨时代行动后,新状态必须过权威校验器,
/// 每位玩家的投影快照必须过 RecipientSnapshotValidator(协议 2)。
struct EraTransitionSessionTests {
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
                id: "era-transition-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-09-16",
                checker: "independent-test", checkedOn: "2026-09-16"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }

    @Test func canalToRailBoundaryProducesValidStateAndPerPlayerSnapshots() throws {
        let catalog = try verifiedCatalog()
        let seed = UInt64(77_001)
        let players = (1...3).map { GameCore.PlayerID(rawValue: "era-p\($0)") }
        var setupRules = GameCore.SetupRules(seed: seed)
        let initialState = try setupRules.makeGame(catalog: catalog, playerIDs: players).state
        let roomID = GameCore.RoomID(rawValue: "era-room")
        let tokens = Dictionary(uniqueKeysWithValues: players.map {
            ($0, GameCore.ReconnectToken(rawValue: "era-token-\($0.rawValue)"))
        })
        var engine = try initialState.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 2
        )
        var lastEvent: GameCore.AuthoritativeGameEvent?
        var rounds = 0

        while engine.gameState.era == .canal {
            guard rounds < 400 else {
                Issue.record("canal era did not finish within the safety bound")
                return
            }
            let state = engine.gameState
            if case .eraIntermission(let intermission) = state.turnPhase {
                for player in state.players.map(\.id)
                where intermission.confirmedPlayerIDs.contains(player) == false {
                    let confirm = engine.submit(.init(
                        protocolVersion: 2, rulesetVersion: state.rulesetVersion,
                        roomID: roomID, senderID: player,
                        reconnectToken: try #require(tokens[player]),
                        baseVersion: engine.gameState.authoritativeVersion,
                        payload: .confirmEraIntermission
                    ), catalog: catalog)
                    guard case .accepted(let confirmEvent) = confirm else {
                        Issue.record("era confirmation rejected for \(player.rawValue): \(confirm)")
                        return
                    }
                    lastEvent = confirmEvent
                }
                continue
            }
            guard state.turnPhase == .active, let actor = state.activePlayerID else {
                Issue.record("unexpected non-active phase in canal era: \(state.turnPhase)")
                return
            }
            let card = try #require(state.players.first { $0.id == actor }?.hand.first)
            let result = engine.submit(.init(
                protocolVersion: 2,
                rulesetVersion: state.rulesetVersion,
                roomID: roomID,
                senderID: actor,
                reconnectToken: try #require(tokens[actor]),
                baseVersion: state.authoritativeVersion,
                payload: .pass(.init(cardID: card.id))
            ), catalog: catalog)
            guard case .accepted(let event) = result else {
                Issue.record("intent rejected at version \(state.authoritativeVersion.rawValue): \(result)")
                return
            }
            lastEvent = event
            if state.roundNumber == state.canalRoundCapacity, state.era == .canal {
                rounds += 1
            }
            if engine.gameState.era == .rail {
                rounds = 999
            }
        }
        guard engine.gameState.era == .rail else {
            Issue.record("did not reach rail era")
            return
        }
        let railState = engine.gameState

        // 1) 新状态必须通过权威校验器(持久化保存同样以此为门槛)。
        guard GameCore.GameStateAuthorityValidator.isValid(railState, catalog: catalog) else {
            Issue.record("post-transition rail state FAILED the authority validator")
            return
        }

        // 2) 每位玩家的投影快照必须通过协议 2 的收件人校验。
        let event = try #require(lastEvent)
        for player in players {
            let clientEvent = try engine.clientEvent(
                event, for: player, catalog: catalog,
                playerNames: Dictionary(uniqueKeysWithValues: players.map { ($0, $0.rawValue) })
            )
            let context = GameCore.RecipientSnapshotValidationContext(
                protocolVersion: 2, rulesetVersion: catalog.catalog.rulesetVersion,
                roomID: roomID, recipient: player, roster: Set(players),
                authoritativeVersion: event.version
            )
            do {
                try GameCore.RecipientSnapshotValidator.validate(clientEvent.snapshot, context: context)
            } catch {
                Issue.record("snapshot for \(player.rawValue) failed validation: \(error)")
            }
        }
    }
    @Test func railTransitionWithLinksAndIndustriesOnBoardStaysValid() throws {
        let catalog = try verifiedCatalog()
        let seed = UInt64(78_001)
        let players = (1...3).map { GameCore.PlayerID(rawValue: "rl-\($0)") }
        var setupRules = GameCore.SetupRules(seed: seed)
        var state = try setupRules.makeGame(catalog: catalog, playerIDs: players).state
        let roomID = GameCore.RoomID(rawValue: "rail-link-room")
        let tokens = Dictionary(uniqueKeysWithValues: players.map {
            ($0, GameCore.ReconnectToken(rawValue: "rl-tok-\($0.rawValue)"))
        })
        var engine = try state.makeHostEngine(roomID: roomID, reconnectTokens: tokens, protocolVersion: 2)

        enum ReproError: Swift.Error { case bad }
        // 第 1 轮第一位:铺一条运河线(真实对局特征)。
        func submit(_ payload: GameCore.PlayerIntent.Payload, _ actor: GameCore.PlayerID) throws -> Bool {
            let current = engine.gameState
            let result = engine.submit(.init(
                protocolVersion: 2, rulesetVersion: current.rulesetVersion,
                roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
                baseVersion: current.authoritativeVersion, payload: payload
            ), catalog: catalog)
            if case .accepted = result { return true }
            print("RLDBG rejected:", result)
            return false
        }

        // 找一条运河合法线路:直接用查询引擎拿完整 payload。
        let first = engine.gameState
        guard let actor0 = first.activePlayerID,
              let card0 = first.players.first(where: { $0.id == actor0 })?.hand.first
        else { throw ReproError.bad }

        let netResponse = try GameCore.LegalActionQueryEngine.respond(
            to: .init(requestID: "rl-net", baseVersion: first.authoritativeVersion,
                      draft: .init(action: .network, cardID: card0.id, selections: [])),
            actorID: actor0, state: first, catalog: catalog
        )
        var selections: [GameCore.LegalChoiceValue] = []
        var response = netResponse
        for _ in 0..<8 {
            if let payload = response.completePayload, case .network = payload {
                _ = try submit(payload, actor0)
                break
            }
            guard let next = response.nextChoices.first else { break }
            selections.append(next.value)
            response = try GameCore.LegalActionQueryEngine.respond(
                to: .init(requestID: "rl-net", baseVersion: first.authoritativeVersion,
                          draft: .init(action: .network, cardID: card0.id, selections: selections)),
                actorID: actor0, state: first, catalog: catalog
            )
            if case .network(let intent) = response.completePayload {
                _ = try submit(.network(intent), actor0)
                break
            }
        }

        // 其余全部跳过推进到时代结算。
        while case .active = engine.gameState.turnPhase {
            let current = engine.gameState
            guard let actor = current.activePlayerID,
                  let card = current.players.first(where: { $0.id == actor })?.hand.first
            else { break }
            guard try submit(.pass(.init(cardID: card.id)), actor) else { break }
        }

        guard case .eraIntermission = engine.gameState.turnPhase else {
            Issue.record("expected intermission, got \(engine.gameState.turnPhase)")
            return
        }
        for player in players {
            // 经由 host 提交(与真实对局一致)。
            guard try submit(.confirmEraIntermission, player) else {
                Issue.record("confirm rejected for \(player.rawValue)")
                return
            }
            if case .active = engine.gameState.turnPhase { break }
        }
        guard case .active = engine.gameState.turnPhase, engine.gameState.era == .rail else {
            Issue.record("expected rail active after confirms, got \(engine.gameState.turnPhase) era=\(engine.gameState.era)")
            return
        }

        // 关键断言:铁路状态必须通过权威校验器,且下一个行动不再被拒。
        let railValid = GameCore.GameStateAuthorityValidator.isValid(engine.gameState, catalog: catalog)
        #expect(railValid)
        // 官方规则:运河连线计分后全部撤下,连线片退回主人(余量回补)。
        #expect(engine.gameState.placedLinks.isEmpty)
        let linkBuilder = try #require(engine.gameState.players.first { $0.id == actor0 })
        #expect(linkBuilder.linksRemaining == 14)

        let rail = engine.gameState
        let nextActor = try #require(rail.activePlayerID)
        let nextCard = try #require(rail.players.first(where: { $0.id == nextActor })?.hand.first)
        let passResult = engine.submit(.init(
            protocolVersion: 2, rulesetVersion: rail.rulesetVersion,
            roomID: roomID, senderID: nextActor, reconnectToken: tokens[nextActor]!,
            baseVersion: rail.authoritativeVersion,
            payload: .pass(.init(cardID: nextCard.id))
        ), catalog: catalog)
        if case .rejected(let rejection) = passResult {
            Issue.record("rail first action rejected: \(rejection)")
        }
        if case .internalFailure(let failure) = passResult {
            Issue.record("rail first action internalFailure: \(failure)")
        }
        var passAccepted = false
        if case .accepted = passResult { passAccepted = true }
        #expect(passAccepted)
    }

    /// 复现实机报错:玩家侦察拿到万能牌后留到运河时代结束,
    /// 全员确认过渡时 prepareRailEra 不得因万能牌在手而抛错。
    @Test func heldWildCardsSurviveEraTransition() throws {
        let catalog = try verifiedCatalog()
        var setupRules = GameCore.SetupRules(seed: 79_001)
        let players = [GameCore.PlayerID(rawValue: "hw-1"), GameCore.PlayerID(rawValue: "hw-2")]
        var state = try setupRules.makeGame(catalog: catalog, playerIDs: players).state
        let roomID = GameCore.RoomID(rawValue: "wild-room")
        let tokens = Dictionary(uniqueKeysWithValues: players.map {
            ($0, GameCore.ReconnectToken(rawValue: "hw-tok-\($0.rawValue)"))
        })
        var engine = try state.makeHostEngine(roomID: roomID, reconnectTokens: tokens, protocolVersion: 2)
        func isWild(_ card: GameCore.CardInstance) -> Bool {
            card.definitionID == "wild-location" || card.definitionID == "wild-industry"
        }
        func submit(_ payload: GameCore.PlayerIntent.Payload, _ actor: GameCore.PlayerID) throws -> GameCore.SubmissionResult {
            let current = engine.gameState
            return engine.submit(.init(
                protocolVersion: 2, rulesetVersion: current.rulesetVersion,
                roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
                baseVersion: current.authoritativeVersion, payload: payload
            ), catalog: catalog)
        }

        // 第一手:玩家1弃3张普通牌侦察,两张万能牌进手牌。
        let first = engine.gameState
        let actor1 = try #require(first.activePlayerID)
        let hand = try #require(first.players.first(where: { $0.id == actor1 })?.hand)
        let scoutCards = hand.filter { isWild($0) == false }.prefix(3).map(\.id)
        let scoutResult = try submit(.scout(.init(cardIDs: Array(scoutCards))), actor1)
        guard case .accepted = scoutResult else {
            Issue.record("scout rejected: \(scoutResult)")
            return
        }
        let afterScout = engine.gameState
        let heldWilder = afterScout.players.first(where: { $0.id == actor1 })?.hand.filter(isWild).count
        #expect(heldWilder == 2)

        // 其余行动全部跳过(优先弃普通牌;只剩万能牌时弃万能牌,回奖池),
        // 推进到时代结算。
        while case .active = engine.gameState.turnPhase {
            let current = engine.gameState
            guard let actor = current.activePlayerID,
                  let hand = current.players.first(where: { $0.id == actor })?.hand,
                  let discard = hand.first(where: { isWild($0) == false }) ?? hand.first
            else {
                Issue.record("pass loop stalled: phase=\(current.turnPhase)")
                return
            }
            let passOutcome = try submit(.pass(.init(cardID: discard.id)), actor)
            guard case .accepted = passOutcome else {
                Issue.record("pass rejected for \(actor.rawValue) at v\(current.authoritativeVersion.rawValue): \(passOutcome)")
                return
            }
        }
        guard case .eraIntermission = engine.gameState.turnPhase else {
            Issue.record("expected intermission, got \(engine.gameState.turnPhase)")
            return
        }

        // 全员确认:最后一位确认触发 prepareRailEra,不得报错。
        for player in players {
            let result = try submit(.confirmEraIntermission, player)
            guard case .accepted = result else {
                Issue.record("confirm rejected for \(player.rawValue): \(result)")
                return
            }
        }
        guard engine.gameState.era == .rail else {
            Issue.record("era is \(engine.gameState.era) after confirms")
            return
        }
        // 万能牌应回到奖池,新发的8张手牌不含万能牌。
        let railState = engine.gameState
        #expect(GameCore.GameStateAuthorityValidator.isValid(railState, catalog: catalog))
        #expect(railState.wildLocationPool.count == 4)
        #expect(railState.wildIndustryPool.count == 4)
        for player in railState.players {
            #expect(player.hand.count == 8)
            #expect(player.hand.contains(where: isWild) == false)
        }
    }

    @Test func ordinaryIntentsAreRejectedDuringEraIntermission() throws {
        let catalog = try verifiedCatalog()
        var setupRules = GameCore.SetupRules(seed: 99_001)
        let players = [GameCore.PlayerID(rawValue: "ip1"), GameCore.PlayerID(rawValue: "ip2")]
        var state = try setupRules.makeGame(catalog: catalog, playerIDs: players).state
        let roomID = GameCore.RoomID(rawValue: "intermission-guard")
        let tokens = Dictionary(uniqueKeysWithValues: players.map {
            ($0, GameCore.ReconnectToken(rawValue: "tok-\($0.rawValue)"))
        })
        var engine = try state.makeHostEngine(roomID: roomID, reconnectTokens: tokens, protocolVersion: 2)
        // 推进到运河末轮最后一位,让回合进入结算确认。
        while case .active = engine.gameState.turnPhase {
            let current = engine.gameState
            guard let actor = current.activePlayerID,
                  let card = current.players.first(where: { $0.id == actor })?.hand.first
            else { break }
            let result = engine.submit(.init(
                protocolVersion: 2, rulesetVersion: current.rulesetVersion,
                roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
                baseVersion: current.authoritativeVersion,
                payload: .pass(.init(cardID: card.id))
            ), catalog: catalog)
            guard case .accepted = result else { break }
        }
        guard case .eraIntermission = engine.gameState.turnPhase else {
            Issue.record("expected era intermission, got unexpected phase")
            return
        }
        // 结算暂停期间提交普通行动(跳过)必须被拒绝,否则会破坏暂停不变量。
        let intermission = engine.gameState
        let actor = try #require(intermission.activePlayerID)
        let result = engine.submit(.init(
            protocolVersion: 2, rulesetVersion: intermission.rulesetVersion,
            roomID: roomID, senderID: actor, reconnectToken: tokens[actor]!,
            baseVersion: intermission.authoritativeVersion,
            payload: .pass(.init(cardID: "any-card"))
        ), catalog: catalog)
        guard case .rejected = result else {
            Issue.record("ordinary intent during intermission must be rejected")
            return
        }
        #expect(engine.gameState == intermission)
    }
}
