import Foundation
import Testing

@testable import IndustrialCityBirmingham

/// P2 Task 3:MCTS 评估器协议——缺省(nil)与启发式实现决策逐位一致;
/// 远程实现的行为由 Task 4/5 集成验证。
struct MCTSEvaluatorTests {
    private func verifiedCatalog() throws -> GameCore.VerifiedGameDataCatalog {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "IndustrialCityBirmingham/GameData/v2018.11")
        let catalog = try GameCore.GameDataLoader.decodeCatalog(
            rulesetVersion: "v2018.11",
            mapData: try Data(contentsOf: directory.appending(path: "map.json")),
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
                id: "evaluator-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-10-22",
                checker: "independent-test", checkedOn: "2026-10-22"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }

    @Test func heuristicEvaluatorMatchesDefaultBehaviorBitForBit() throws {
        let catalog = try verifiedCatalog()
        let players = (1...4).map { GameCore.PlayerID(rawValue: "ev-p\($0)") }
        var setupRules = GameCore.SetupRules(seed: 20_701)
        let state = try setupRules.makeGame(catalog: catalog, playerIDs: players).state
        let actor = try #require(state.activePlayerID)
        var nilConfig = GameCore.MCTSConfiguration(
            simulations: 12, explorationConstant: 1.25, timeLimitMs: nil, seed: 314
        )
        nilConfig.evaluator = nil
        var heuristicConfig = nilConfig
        heuristicConfig.evaluator = GameCore.HeuristicEvaluation()

        let a = try GameCore.MonteCarloTreeSearch.chooseAction(
            state: state, actorID: actor, catalog: catalog, configuration: nilConfig
        )
        let b = try GameCore.MonteCarloTreeSearch.chooseAction(
            state: state, actorID: actor, catalog: catalog, configuration: heuristicConfig
        )
        #expect(a.payload == b.payload)
        #expect(a.totalVisits == b.totalVisits)
        #expect(a.topCandidates == b.topCandidates)
    }

    @Test func heuristicPriorsAreUniformWeights() throws {
        let catalog = try verifiedCatalog()
        let players = (1...4).map { GameCore.PlayerID(rawValue: "ev-p\($0)") }
        var setupRules = GameCore.SetupRules(seed: 20_702)
        let state = try setupRules.makeGame(catalog: catalog, playerIDs: players).state
        let evaluator = GameCore.HeuristicEvaluation()
        let payloads: [GameCore.PlayerIntent.Payload] = [
            .pass(.init(cardID: "c1")),
            .loan(.init(cardID: "c1")),
            .pass(.init(cardID: "c2")),
        ]
        let priors = try evaluator.priors(for: payloads, state: state, catalog: catalog)
        #expect(priors.count == 3)
        #expect(priors.allSatisfy { $0 == 1.0 }, "启发式先验=等权(与 P1 均匀先验数值一致)")
        #expect(priors.allSatisfy { $0 >= 0 })
    }

    @Test func remoteEvaluationFailsHardWithoutServer() throws {
        // Review Focus 5:服务不可达 → 抛错,绝不静默降级。
        let evaluator = GameCore.RemoteEvaluation(client: GameCore.InferenceClient(host: "127.0.0.1", port: 9), catalog: try verifiedCatalog())
        #expect(throws: (any Error).self) {
            _ = try evaluator.utilities(
                state: GameCore.GameState.legacyCompatible(
                    .init(roomID: .init(rawValue: "x"), players: [], activePlayerID: .init(rawValue: "x"),
                          turn: 1, actionNumber: 0, authoritativeVersion: .init(rawValue: 0), discardPile: []),
                    rulesetVersion: "v2018.11"
                ),
                incomeTrack: []
            )
        }
    }
}
