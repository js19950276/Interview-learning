import Foundation
import Testing

@testable import IndustrialCityBirmingham

struct MonteCarloTreeSearchTests {
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
                id: "mcts-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-10-20",
                checker: "independent-test", checkedOn: "2026-10-20"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }

    private func freshFourPlayerState(catalog: GameCore.VerifiedGameDataCatalog) throws -> GameCore.GameState {
        let players = (1...4).map { GameCore.PlayerID(rawValue: "mcts-p\($0)") }
        var setupRules = GameCore.SetupRules(seed: 20_502)
        return try setupRules.makeGame(catalog: catalog, playerIDs: players).state
    }

    private func tokens(for state: GameCore.GameState) -> [GameCore.PlayerID: GameCore.ReconnectToken] {
        Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "mcts-token-\($0.id.rawValue)"))
        })
    }

    @Test func chooseActionReturnsLegalPayloadOnFreshState() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let decision = try GameCore.MonteCarloTreeSearch.chooseAction(
            state: state, actorID: actor, catalog: catalog,
            configuration: .init(simulations: 8, explorationConstant: 1.25, timeLimitMs: nil, seed: 7)
        )
        var host = try state.makeHostEngine(
            roomID: .init(rawValue: "mcts-room"),
            reconnectTokens: tokens(for: state), protocolVersion: 2
        )
        let result = host.submit(.init(
            protocolVersion: 2, rulesetVersion: state.rulesetVersion, roomID: .init(rawValue: "mcts-room"),
            senderID: actor, reconnectToken: try #require(tokens(for: state)[actor]),
            baseVersion: state.authoritativeVersion, payload: decision.payload
        ), catalog: catalog)
        guard case .accepted = result else {
            Issue.record("MCTS 决策被宿主拒绝: \(decision.payload) -> \(result)")
            return
        }
        #expect(decision.totalVisits >= 1)
        #expect(decision.elapsedMs >= 0)
        #expect(decision.topCandidates.isEmpty == false)
    }

    @Test func deterministicWithSameSeed() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let a = try GameCore.MonteCarloTreeSearch.chooseAction(
            state: state, actorID: actor, catalog: catalog,
            configuration: .init(simulations: 8, explorationConstant: 1.25, timeLimitMs: nil, seed: 42)
        )
        let b = try GameCore.MonteCarloTreeSearch.chooseAction(
            state: state, actorID: actor, catalog: catalog,
            configuration: .init(simulations: 8, explorationConstant: 1.25, timeLimitMs: nil, seed: 42)
        )
        #expect(a.payload == b.payload)
        #expect(a.totalVisits == b.totalVisits)
    }

    @Test func timeLimitStopsSearchEarly() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let decision = try GameCore.MonteCarloTreeSearch.chooseAction(
            state: state, actorID: actor, catalog: catalog,
            configuration: .init(simulations: 100_000, explorationConstant: 1.25, timeLimitMs: 900, seed: 1)
        )
        // 预算生效:远小于满额模拟也必须返回合法动作。
        #expect(decision.totalVisits >= 1)
        #expect(decision.elapsedMs < 5_000)
    }

    @Test func forcedSalePhaseChoosesLegalForcedSale() throws {
        let catalog = try verifiedCatalog()
        // 强卖状态构造:与 FastActionEnumeratorTests 同一技法(seed 10_099)。
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

        let decision = try GameCore.MonteCarloTreeSearch.chooseAction(
            state: state, actorID: debtor, catalog: catalog,
            configuration: .init(simulations: 4, explorationConstant: 1.25, timeLimitMs: nil, seed: 3)
        )
        guard case .forcedSale = decision.payload else {
            Issue.record("强卖阶段决策必须是强卖意图,却是 \(decision.payload)"); return
        }
        var host = try state.makeHostEngine(
            roomID: .init(rawValue: "mcts-fs-room"),
            reconnectTokens: tokens(for: state), protocolVersion: 2
        )
        let result = host.submit(.init(
            protocolVersion: 2, rulesetVersion: state.rulesetVersion, roomID: .init(rawValue: "mcts-fs-room"),
            senderID: debtor, reconnectToken: try #require(tokens(for: state)[debtor]),
            baseVersion: state.authoritativeVersion, payload: decision.payload
        ), catalog: catalog)
        guard case .accepted = result else {
            Issue.record("强卖决策被宿主拒绝: \(result)"); return
        }
    }
}
