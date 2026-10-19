import Foundation
import Testing

@testable import IndustrialCityBirmingham

/// 复现用户报告:运河时代同一玩家在同一城市最多 1 个产业。
/// 官方规则书 v2018.11 没有任何城市例外(含伯明翰)。
/// 全路径驱动:真实 makeGame → HostEngine.submit 两次建造,不注入板块,
/// 卡牌用真实实例搬移以保持权威校验器的卡牌守恒。
struct CanalOneBuildingPerCityFullFlowTests {

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
                id: "canal-limit-flow-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-10-19",
                checker: "independent-test", checkedOn: "2026-10-19"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }

    /// 建立 2 人运河时代对局,给行动玩家两张真实万能产业牌,并把回合推进到
    /// 第 2 回合(每回合 2 个行动),使其能在同一回合内连续尝试两次建造。
    /// `cashOverride` 在建引擎前注资(校验器只要求现金非负)。
    private func makeEngine(
        catalog: GameCore.VerifiedGameDataCatalog,
        cashOverride: Int? = nil
    ) throws -> (engine: GameCore.HostEngine, actor: GameCore.PlayerID, roomID: GameCore.RoomID) {
        var setupRules = GameCore.SetupRules(seed: 7)
        let players = (1...2).map { GameCore.PlayerID(rawValue: "flow-p\($0)") }
        var state = try setupRules.makeGame(catalog: catalog, playerIDs: players).state
        let actor = try #require(state.activePlayerID)
        let actorIndex = try #require(state.players.firstIndex(where: { $0.id == actor }))
        // 从手牌/抽牌堆/万能池收集两张真实 wild-industry 实例(保持卡牌守恒)。
        var collected: [GameCore.CardInstance] = []
        for index in state.players.indices {
            let kept = state.players[index].hand.filter { card in
                if card.definitionID == "wild-industry", collected.count < 2 {
                    collected.append(card)
                    return false
                }
                return true
            }
            state.players[index].hand = kept
        }
        if collected.count < 2 {
            let kept = state.standardDrawDeck.filter { card in
                if card.definitionID == "wild-industry", collected.count < 2 {
                    collected.append(card)
                    return false
                }
                return true
            }
            state.standardDrawDeck = kept
        }
        if collected.count < 2 {
            let keep = state.wildIndustryPool.filter { card in
                if collected.count < 2 {
                    collected.append(card)
                    return false
                }
                return true
            }
            state.wildIndustryPool = keep
        }
        state.players[actorIndex].hand.append(contentsOf: collected)
        if let cashOverride {
            state.players[actorIndex].cash = cashOverride
        }
        state.roundNumber = 2
        state.actionsRemaining = 2
        let roomID = GameCore.RoomID(rawValue: "canal-limit-flow")
        let tokens = Dictionary(uniqueKeysWithValues: players.map {
            ($0, GameCore.ReconnectToken(rawValue: "token-\($0.rawValue)"))
        })
        let engine = try state.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 2
        )
        return (engine, actor, roomID)
    }

    private func buildIntent(
        cardID: String,
        locationID: String,
        industryDefinitionID: String,
        slotIndex: Int,
        actor: GameCore.PlayerID,
        roomID: GameCore.RoomID,
        state: GameCore.GameState
    ) -> GameCore.PlayerIntent {
        .init(
            protocolVersion: 2,
            rulesetVersion: state.rulesetVersion,
            roomID: roomID,
            senderID: actor,
            reconnectToken: .init(rawValue: "token-\(actor.rawValue)"),
            baseVersion: state.authoritativeVersion,
            payload: .build(.init(
                cardID: cardID, locationID: locationID,
                industryDefinitionID: industryDefinitionID,
                slotIndex: slotIndex, resourceSources: []
            ))
        )
    }

    @Test func secondOwnBuildInSameCanalCityIsRejected() throws {
        let catalog = try verifiedCatalog()
        let made = try makeEngine(catalog: catalog)
        var engine = made.engine
        let actor = made.actor
        let roomID = made.roomID
        let wildCards = try #require(
            engine.gameState.players.first(where: { $0.id == actor })?.hand
                .filter { $0.definitionID == "wild-industry" }
        )
        #expect(wildCards.count >= 2)
        // 起始 £17:棉纺厂 L1 £12 + 煤矿 L1 £5,两笔都无煤/铁资源需求,
        // 资金足够,排除"因缺钱被拒"的假阳性。
        #expect(engine.gameState.players.first(where: { $0.id == actor })?.cash == 17)

        // 行动 1:棉纺厂 L1 建在 belper 槽 0。
        let first = engine.submit(
            buildIntent(
                cardID: wildCards[0].id, locationID: "belper",
                industryDefinitionID: "cotton-mill", slotIndex: 0,
                actor: actor, roomID: roomID, state: engine.gameState
            ),
            catalog: catalog
        )
        guard case .accepted(let firstEvent) = first else {
            Issue.record("第一次建造意外被拒: \(first)")
            return
        }
        #expect(engine.gameState.boardIndustryPlacements.contains {
            $0.ownerID == actor && $0.locationID == "belper"
        })

        // 行动 2:同城煤矿 L1 建在 belper 槽 1 → 必须被拒(运河时代同城限 1 个)。
        let second = engine.submit(
            buildIntent(
                cardID: wildCards[1].id, locationID: "belper",
                industryDefinitionID: "coal-mine", slotIndex: 1,
                actor: actor, roomID: roomID, state: engine.gameState
            ),
            catalog: catalog
        )
        if case .accepted = second {
            Issue.record("BUG:运河时代同城第二座产业被接受: \(firstEvent.version) 之后")
        } else if case .internalFailure(let failure) = second {
            Issue.record("第二次建造触发内部失败而非规则拒绝: \(failure)")
        }

        // UI 目标枚举(BuildRules.legalBuildTargets)同样不得再提供 belper。
        let state = engine.gameState
        let player = try #require(state.players.first(where: { $0.id == actor }))
        let coalTile = try #require(
            player.industryStacks.first(where: { $0.industryDefinitionID == "coal-mine" })?.tiles.first
        )
        let targets = GameCore.BuildRules.legalBuildTargets(
            actorID: actor, cardID: wildCards[1].id, tile: coalTile,
            state: state, catalog: catalog
        )
        let belperTargets = targets.filter { $0.locationID == "belper" }
        #expect(belperTargets.isEmpty, "同城仍被列为合法目标: \(belperTargets)")
    }

    /// 官方规则书 v2018.11(Canal Era Building):运河时代每人每地点最多 1 个产业,
    /// 规则书全文没有伯明翰例外。伯明翰同城的第二座自有产业必须被拒。
    @Test func canalBirminghamAllowsOnlyOneOwnIndustry() throws {
        let catalog = try verifiedCatalog()
        let made = try makeEngine(catalog: catalog, cashOverride: 50)
        var engine = made.engine
        let actor = made.actor
        let roomID = made.roomID
        let wildCards = try #require(
            engine.gameState.players.first(where: { $0.id == actor })?.hand
                .filter { $0.definitionID == "wild-industry" }
        )
        #expect(wildCards.count >= 2)

        // 行动 1:棉纺厂 L1(无煤铁需求)建在伯明翰槽 0。
        let first = engine.submit(
            buildIntent(
                cardID: wildCards[0].id, locationID: "birmingham",
                industryDefinitionID: "cotton-mill", slotIndex: 0,
                actor: actor, roomID: roomID, state: engine.gameState
            ),
            catalog: catalog
        )
        guard case .accepted = first else {
            Issue.record("第一次建造意外被拒: \(first)")
            return
        }

        // 行动 2:制造厂 L1 同城槽 1 → 必须被拒。限建校验先于资源校验执行,
        // 故意图无需携带真实煤源(开局伯明翰未连通商人点,市场购煤本就不可用)。
        let second = engine.submit(
            .init(
                protocolVersion: 2,
                rulesetVersion: engine.gameState.rulesetVersion,
                roomID: roomID,
                senderID: actor,
                reconnectToken: .init(rawValue: "token-\(actor.rawValue)"),
                baseVersion: engine.gameState.authoritativeVersion,
                payload: .build(.init(
                    cardID: wildCards[1].id, locationID: "birmingham",
                    industryDefinitionID: "manufacturer", slotIndex: 1,
                    resourceSources: []
                ))
            ),
            catalog: catalog
        )
        if case .accepted = second {
            Issue.record("BUG:运河时代伯明翰第二座自有产业被接受")
        } else if case .internalFailure(let failure) = second {
            Issue.record("第二次建造触发内部失败而非规则拒绝: \(failure)")
        }

        // 直接校验层同样必须拒绝,且拒绝理由是运河限建。
        #expect(throws: GameCore.BuildRuleError.canalLocationLimit) {
            try GameCore.BuildRules.validate(
                .init(
                    cardID: wildCards[1].id, locationID: "birmingham",
                    industryDefinitionID: "manufacturer", slotIndex: 1,
                    resourceSources: []
                ),
                actorID: actor, state: engine.gameState, catalog: catalog
            )
        }
    }
}
