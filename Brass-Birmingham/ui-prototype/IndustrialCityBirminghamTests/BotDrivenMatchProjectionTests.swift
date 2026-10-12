import Foundation
import Testing

@testable import IndustrialCityBirmingham

#if DEBUG
/// 引擎级全自动对局:机器人按合法动作查询协议打完整局,
/// 每个权威事件落地后,所有座位的 clientEvent 投影都必须通过
/// RecipientSnapshotValidator——任何一个座位投影违约都会让真机/
/// 模拟器上的客机静默丢弃事件、对局冻结(2026-10-11 双模拟器复现)。
struct BotDrivenMatchProjectionTests {
    private struct Seat {
        let id: GameCore.PlayerID
        let token: GameCore.ReconnectToken
    }

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
                id: "bot-match-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-09-16",
                checker: "independent-test", checkedOn: "2026-09-16"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }

    /// 与 SnapshotActionAvailability 相同的迭代协议:查询→补选择→completePayload。
    private func walk(
        action: GameCore.ActionKind,
        cardID: String?,
        bot: inout ScriptHarnessBot,
        state: GameCore.GameState,
        actor: GameCore.PlayerID,
        catalog: GameCore.VerifiedGameDataCatalog
    ) throws -> GameCore.PlayerIntent.Payload? {
        var draft = GameCore.LegalActionDraft(action: action, cardID: cardID, selections: [])
        for _ in 0..<24 {
            let response: GameCore.LegalActionResponse
            do {
                response = try GameCore.LegalActionQueryEngine.respond(
                    to: .init(
                        requestID: "bot-walk", baseVersion: state.authoritativeVersion, draft: draft
                    ),
                    actorID: actor, state: state, catalog: catalog
                )
            } catch {
                return nil
            }
            if let payload = response.completePayload { return payload }
            guard let choice = bot.pickChoice(response.nextChoices) else { return nil }
            draft.selections.append(choice.value)
        }
        return nil
    }

    @Test func botMatchKeepsEveryProjectionRecipientSafe() throws {
        let catalog = try verifiedCatalog()
        for seed in [UInt64(79_001), 80_001, 81_001] {
            try runBotMatch(engineSeed: seed, botSeed: seed, catalog: catalog)
        }
    }

    /// 精确复现 2026-10-11 双模拟器 REPRO3 局:引擎种子=1(harness 默认),
    /// 机器人种子=房间号派生。该局在 v22(guest networkBuilt)让真机
    /// EnvelopeValidator 抛 snapshotPrivacyViolation、对局冻结。
    @Test func harnessRepro3RoomReplayStaysRecipientSafe() throws {
        let catalog = try verifiedCatalog()
        try runBotMatch(
            engineSeed: 1,
            botSeed: ScriptHarnessBot.defaultSeed(roomID: "REPRO3"),
            catalog: catalog
        )
    }

    private func runBotMatch(
        engineSeed: UInt64,
        botSeed: UInt64,
        catalog: GameCore.VerifiedGameDataCatalog
    ) throws {
        let players = [
            Seat(id: .init(rawValue: "host"), token: .init(rawValue: "tok-host")),
            Seat(id: .init(rawValue: "guest"), token: .init(rawValue: "tok-guest")),
        ]
        let roomID = GameCore.RoomID(rawValue: "bot-match")
        var setup = GameCore.SetupRules(seed: engineSeed)
        let initialState = try setup.makeGame(
            catalog: catalog, playerIDs: players.map(\.id)
        ).state
        var engine = try initialState.makeHostEngine(
            roomID: roomID,
            reconnectTokens: Dictionary(uniqueKeysWithValues: players.map { ($0.id, $0.token) }),
            protocolVersion: 2
        )
        var bot = ScriptHarnessBot(seed: botSeed)

        func submit(
            _ payload: GameCore.PlayerIntent.Payload, _ actor: GameCore.PlayerID
        ) throws -> GameCore.SubmissionResult {
            let current = engine.gameState
            return engine.submit(
                .init(
                    protocolVersion: 2, rulesetVersion: current.rulesetVersion,
                    roomID: roomID, senderID: actor, reconnectToken: players.first(where: { $0.id == actor })!.token,
                    baseVersion: current.authoritativeVersion, payload: payload
                ),
                catalog: catalog
            )
        }

        /// 事件落地后,立刻校验每个座位的投影(与真机客机的 EnvelopeValidator 同构),
        /// 并跑会话级转移守卫(强制出售债务人/旁观者隐私等)。
        func validateProjections(
            _ event: GameCore.AuthoritativeGameEvent
        ) throws {
            for seat in players {
                let clientEvent = try engine.clientEvent(
                    event, for: seat.id, catalog: catalog, playerNames: [:]
                )
                let envelope = SessionProtocol.SessionEnvelope(
                    protocolVersion: 2, rulesetVersion: catalog.catalog.rulesetVersion,
                    roomID: roomID, messageID: .init(rawValue: "bot-\(event.version.rawValue)"),
                    senderID: players[0].id, recipientID: seat.id,
                    authoritativeVersion: event.version, payload: .clientEvent(clientEvent)
                )
                do {
                    try GameCore.RecipientSnapshotValidator.validate(
                        clientEvent.snapshot,
                        context: .init(
                            protocolVersion: 2, rulesetVersion: catalog.catalog.rulesetVersion,
                            roomID: roomID, recipient: seat.id,
                            roster: Set(players.map(\.id)),
                            authoritativeVersion: event.version
                        )
                    )
                    try SessionProtocol.EnvelopeValidator().validate(
                        clientEvent: clientEvent,
                        in: envelope,
                        expectedRoster: Set(players.map(\.id))
                    )
                } catch {
                    Issue.record(
                        "seed=\(engineSeed) v=\(event.version.rawValue) actor=\(event.actor.rawValue) payload=\(SessionDiagnostics.describe(event.payload)) recipient=\(seat.id.rawValue) 违反收件人快照校验: \(error)"
                    )
                    throw error
                }
            }
        }

        var steps = 0
        while steps < 500, engine.gameState.turnPhase != .ended {
            steps += 1
            let state = engine.gameState
            switch state.turnPhase {
            case .ended:
                break
            case .awaitingTurnEndConfirmation:
                guard let actor = state.activePlayerID,
                      case .accepted(let event) = try submit(.confirmTurnEnd, actor)
                else {
                    Issue.record("seed=\(engineSeed) 回合结束确认被拒")
                    return
                }
                try validateProjections(event)
            case .eraIntermission(let intermission):
                for seat in players where intermission.confirmedPlayerIDs.contains(seat.id) == false {
                    guard case .accepted(let event) = try submit(.confirmEraIntermission, seat.id) else {
                        Issue.record("seed=\(engineSeed) 时代确认被拒")
                        return
                    }
                    try validateProjections(event)
                }
            case .forcedSale(let pending):
                guard let payload = try walk(
                    action: .forcedSale, cardID: nil, bot: &bot,
                    state: state, actor: pending.playerID, catalog: catalog
                ) else {
                    Issue.record("seed=\(engineSeed) 强制出售 v\(state.authoritativeVersion.rawValue) 无合法完成路径")
                    return
                }
                guard case .accepted(let event) = try submit(payload, pending.playerID) else {
                    Issue.record("seed=\(engineSeed) 强制出售提交被拒")
                    return
                }
                try validateProjections(event)
            case .active:
                guard let actor = state.activePlayerID else { return }
                let availability = try GameCore.SnapshotActionAvailability.make(
                    state: state, recipient: actor, catalog: catalog
                )
                var payload: GameCore.PlayerIntent.Payload?
                for _ in 0..<6 {
                    guard let pick = bot.pickAction(byCardID: availability.byCardID) else { break }
                    if let found = try walk(
                        action: pick.action, cardID: pick.cardID, bot: &bot,
                        state: state, actor: actor, catalog: catalog
                    ) {
                        payload = found
                        break
                    }
                }
                if payload == nil {
                    guard let passCardID = bot.pickPassCard(availability.trivialOptions) else {
                        Issue.record("seed=\(engineSeed) v\(state.authoritativeVersion.rawValue) 无任何可行动作")
                        return
                    }
                    payload = .pass(.init(cardID: passCardID))
                }
                let result = try submit(payload!, actor)
                guard case .accepted(let event) = result else {
                    if case .rejected(let rejection) = result {
                        Issue.record(
                            "seed=\(engineSeed) v\(state.authoritativeVersion.rawValue) 合法查询产出的动作被拒: \(SessionDiagnostics.describe(payload!)) reason=\(rejection.reasonCode)"
                        )
                    }
                    return
                }
                try validateProjections(event)
            }
        }
        #expect(
            engine.gameState.turnPhase == .ended,
            "seed=\(engineSeed) \(steps) 步内未终局,最后阶段=\(engine.gameState.turnPhase)"
        )
    }
}
#endif
