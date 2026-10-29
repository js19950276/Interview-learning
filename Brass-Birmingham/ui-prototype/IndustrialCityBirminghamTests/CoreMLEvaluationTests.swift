import Foundation
import Testing

@testable import IndustrialCityBirmingham

/// P3:端上 CoreML 评估——模型已入 App bundle,真实推理的行为测试。
struct CoreMLEvaluationTests {
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
                id: "coreml-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-10-29",
                checker: "independent-test", checkedOn: "2026-10-29"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }

    private func freshState(catalog: GameCore.VerifiedGameDataCatalog) throws -> GameCore.GameState {
        let players = (1...4).map { GameCore.PlayerID(rawValue: "cml-p\($0)") }
        var setup = GameCore.SetupRules(seed: 20_801)
        return try setup.makeGame(catalog: catalog, playerIDs: players).state
    }

    @Test func bundledModelProducesFiniteUtilitiesAndPriors() throws {
        let catalog = try verifiedCatalog()
        let evaluator = try GameCore.CoreMLEvaluation(catalog: catalog)
        let state = try freshState(catalog: catalog)
        let utilities = try evaluator.utilities(
            state: state, incomeTrack: catalog.catalog.incomeTrack.entries
        )
        #expect(utilities.count == 4)
        #expect(utilities.values.allSatisfy { $0.isFinite })
        #expect(utilities.values.allSatisfy { $0 >= 0 && $0 <= 1.0001 },
                "sigmoid 输出应在 [0,1]")
        let payloads = try GameCore.FastActionEnumerator.enumerate(
            state: state, actorID: state.activePlayerID!, catalog: catalog
        ).payloads
        let priors = try evaluator.priors(for: payloads, state: state, catalog: catalog)
        #expect(priors.count == payloads.count)
        #expect(priors.allSatisfy { $0.isFinite && $0 >= 0 })
        let total = priors.reduce(0, +)
        #expect(abs(total - 1.0) < 0.01, "先验应归一(和=\(total))")
    }

    @Test func coreMLGuidedDecisionIsLegalOnDevice() throws {
        let catalog = try verifiedCatalog()
        let evaluator = try GameCore.CoreMLEvaluation(catalog: catalog)
        let state = try freshState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let config = GameCore.MCTSConfiguration(
            simulations: 12, explorationConstant: 1.25,
            timeLimitMs: nil, seed: 0, evaluator: evaluator
        )
        let decision = try GameCore.MonteCarloTreeSearch.chooseAction(
            state: state, actorID: actor, catalog: catalog, configuration: config
        )
        var host = try state.makeHostEngine(
            roomID: .init(rawValue: "cml-room"),
            reconnectTokens: Dictionary(uniqueKeysWithValues: state.players.map {
                ($0.id, GameCore.ReconnectToken(rawValue: "cml-\($0.id.rawValue)"))
            }), protocolVersion: 2
        )
        let result = host.submit(.init(
            protocolVersion: 2, rulesetVersion: state.rulesetVersion,
            roomID: .init(rawValue: "cml-room"), senderID: actor,
            reconnectToken: .init(rawValue: "cml-\(actor.rawValue)"),
            baseVersion: state.authoritativeVersion, payload: decision.payload
        ), catalog: catalog)
        guard case .accepted = result else {
            Issue.record("CoreML 引导决策被拒: \(result)"); return
        }
        print("P3_CML_DECISION elapsedMs=\(decision.elapsedMs) top=\(decision.topCandidates.first ?? "-")")
        // 性能参考(非门禁):端上单步应在 5s 内。
        #expect(decision.elapsedMs < 5_000)
    }
}
