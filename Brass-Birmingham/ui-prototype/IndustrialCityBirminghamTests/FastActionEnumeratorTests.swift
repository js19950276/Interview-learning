import Foundation
import Testing

@testable import IndustrialCityBirmingham

struct FastActionEnumeratorTests {
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
                id: "enumerator-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-10-11",
                checker: "independent-test", checkedOn: "2026-10-11"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }

    private func freshFourPlayerState(catalog: GameCore.VerifiedGameDataCatalog) throws -> GameCore.GameState {
        let players = (1...4).map { GameCore.PlayerID(rawValue: "enum-p\($0)") }
        var setupRules = GameCore.SetupRules(seed: 20_242)
        return try setupRules.makeGame(catalog: catalog, playerIDs: players).state
    }

    /// HostEngine 全量提交:对 state 的每个枚举动作,在 host 副本上提交,断言全部被接受。
    private func assertAllAccepted(
        _ state: GameCore.GameState,
        payloads: [GameCore.PlayerIntent.Payload],
        catalog: GameCore.VerifiedGameDataCatalog,
        roomID: GameCore.RoomID,
        tokens: [GameCore.PlayerID: GameCore.ReconnectToken]
    ) throws {
        guard let actor = state.activePlayerID else {
            Issue.record("active player required"); return
        }
        var host = try state.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 2
        )
        for (index, payload) in payloads.enumerated() {
            var trial = host
            let intent = GameCore.PlayerIntent(
                protocolVersion: 2, rulesetVersion: state.rulesetVersion,
                roomID: roomID, senderID: actor,
                reconnectToken: try #require(tokens[actor]),
                baseVersion: state.authoritativeVersion, payload: payload
            )
            let result = trial.submit(intent, catalog: catalog)
            guard case .accepted = result else {
                Issue.record("payload[\(index)] rejected by HostEngine: \(payload) -> \(result)")
                continue
            }
        }
    }

    @Test func freshStateEnumeratesUniqueNonEmptyLegalActions() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let result = try GameCore.FastActionEnumerator.enumerate(state: state, actorID: actor, catalog: catalog)
        #expect(result.payloads.isEmpty == false)
        #expect(result.truncated == false)
        let keys = Set(result.payloads.map { String(describing: $0) })
        #expect(keys.count == result.payloads.count)
    }

    @Test func enumerationCoversAvailabilityEngineCardActionPairs() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let result = try GameCore.FastActionEnumerator.enumerate(state: state, actorID: actor, catalog: catalog)
        let availability = try GameCore.SnapshotActionAvailability.make(
            state: state, recipient: actor, catalog: catalog
        )
        // 正向:可用性引擎说可完成的 (卡, 动作) 对,枚举器必须至少给出一个完整 payload。
        for (cardID, kinds) in availability.byCardID {
            for kind in kinds {
                let has = result.payloads.contains { payload in
                    pair(of: payload) == (kind, cardID)
                }
                #expect(has, "枚举缺失 \(kind.rawValue)+\(cardID)")
            }
        }
        // 反向:枚举手里的 (动作, 卡) 对必须都在可用性集合内。
        for payload in result.payloads {
            let (kind, cardID) = pair(of: payload)
            #expect(availability.byCardID[cardID ?? ""]?.contains(kind) == true,
                    "枚举多出不合法对 \(kind.rawValue)+\(cardID ?? "nil")")
        }
    }

    /// payload → (ActionKind, cardID);枚举器不产出确认类动作,此处不需要处理它们。
    private func pair(of payload: GameCore.PlayerIntent.Payload)
        -> (GameCore.ActionKind, String?) {
        switch payload {
        case .pass(let i): return (.pass, i.cardID)
        case .build(let i): return (.build, i.cardID)
        case .network(let i): return (.network, i.cardID)
        case .develop(let i): return (.develop, i.cardID)
        case .sell(let i): return (.sell, i.cardID)
        case .loan(let i): return (.loan, i.cardID)
        case .scout(let i): return (.scout, i.cardIDs.first)
        case .forcedSale: return (.forcedSale, nil)
        case .confirmEraIntermission, .confirmTurnEnd, .retractTurnActions:
            return (.pass, "IMPOSSIBLE")
        }
    }

    @Test func allEnumeratedPayloadsAreAcceptedByHostEngine() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let result = try GameCore.FastActionEnumerator.enumerate(state: state, actorID: actor, catalog: catalog)
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "enum-token-\($0.id.rawValue)"))
        })
        try assertAllAccepted(
            state, payloads: result.payloads, catalog: catalog,
            roomID: .init(rawValue: "enum-room"), tokens: tokens
        )
    }

    @Test func forcedSalePhaseEnumeratesAcceptedForcedSaleIntents() throws {
        let catalog = try verifiedCatalog()
        // 强卖状态构造复刻 GameRulesEngineTests(seed 10_099)
        let players = [GameCore.PlayerID(rawValue: "debtor"), GameCore.PlayerID(rawValue: "other")]
        var setupRules = GameCore.SetupRules(seed: 10_099)
        var state = try setupRules.makeGame(catalog: catalog, playerIDs: players).state
        let debtor = state.playerOrder[0]
        let debtorIndex = try #require(state.players.firstIndex { $0.id == debtor })
        let stackIndex = try #require(state.players[debtorIndex].industryStacks.firstIndex {
            $0.industryDefinitionID == "manufacturer"
        })
        let canonicalTile = try #require(state.players[debtorIndex].industryStacks[stackIndex].tiles.first)
        state.players[debtorIndex].industryStacks[stackIndex].tiles.removeFirst()
        state.players[debtorIndex].cash = 0
        state.players[debtorIndex].incomePosition = 0
        let location = try #require(catalog.catalog.board.locations.first { location in
            location.industrySlots.contains { $0.contains("manufacturer") }
        })
        let slotIndex = try #require(location.industrySlots.firstIndex { $0.contains("manufacturer") })
        state.boardIndustryPlacements = [.init(
            placementID: "forced-sale-proof", locationID: location.id, slotIndex: slotIndex,
            ownerID: debtor, tile: canonicalTile
        )]
        _ = try GameCore.GameRulesEngine.resolveRoundEnd(state: &state, catalog: catalog)
        guard case .forcedSale = state.turnPhase else {
            Issue.record("round end must create a pending forced sale"); return
        }

        let result = try GameCore.FastActionEnumerator.enumerate(state: state, actorID: debtor, catalog: catalog)
        #expect(result.payloads.isEmpty == false)
        for payload in result.payloads {
            guard case .forcedSale = payload else {
                Issue.record("强卖阶段只应枚举强卖意图,却出现 \(payload)"); continue
            }
        }
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "fs-token-\($0.id.rawValue)"))
        })
        try assertAllAccepted(
            state, payloads: result.payloads, catalog: catalog,
            roomID: .init(rawValue: "fs-room"), tokens: tokens
        )
    }

    @Test func nonActivePhasesAndPlayersEnumerateEmpty() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let bystander = try #require(state.players.first { $0.id != actor }?.id)

        // 非行动玩家:返回空。
        let wrongActor = try GameCore.FastActionEnumerator.enumerate(
            state: state, actorID: bystander, catalog: catalog
        )
        #expect(wrongActor.payloads.isEmpty)

        // ended:终局状态返回空。
        var ended = state
        ended.turnPhase = .ended
        let endedResult = try GameCore.FastActionEnumerator.enumerate(
            state: ended, actorID: actor, catalog: catalog
        )
        #expect(endedResult.payloads.isEmpty)

        // eraIntermission:时代结算阶段返回空(手工置阶段;该阶段任何座位都无普通动作)。
        var intermission = state
        intermission.turnPhase = .eraIntermission(.init(
            settledEra: .canal, awards: [], confirmedPlayerIDs: []
        ))
        let intermissionResult = try GameCore.FastActionEnumerator.enumerate(
            state: intermission, actorID: actor, catalog: catalog
        )
        #expect(intermissionResult.payloads.isEmpty)
    }
}
