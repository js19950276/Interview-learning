import Foundation
import Testing

@testable import IndustrialCityBirmingham

/// P1 Task 3:MCTS 驱动整局冒烟(iOS Debug 小预算;标准预算的性能剖面在
/// tools/p1-profile 的 macOS CLI,模拟器不做性能口径)。
struct MCTSFullGameTests {
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
                id: "mcts-fullgame-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-10-20",
                checker: "independent-test", checkedOn: "2026-10-20"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }

    @Test func mctsDrivenFourPlayerGameReachesEndLegally() throws {
        let catalog = try verifiedCatalog()
        let players = (1...4).map { GameCore.PlayerID(rawValue: "full-p\($0)") }
        var setupRules = GameCore.SetupRules(seed: 40_001)
        var state = try setupRules.makeGame(catalog: catalog, playerIDs: players).state
        let roomID = GameCore.RoomID(rawValue: "full-room")
        let config = GameCore.MCTSConfiguration(
            simulations: 2, explorationConstant: 1.25, timeLimitMs: nil, seed: 0
        )
        var steps = 0
        while state.turnPhase != .ended {
            steps += 1
            guard steps < 2_000 else {
                Issue.record("对局超出安全步数上限"); return
            }
            switch state.turnPhase {
            case .active, .forcedSale:
                guard let actor = state.activePlayerID else {
                    Issue.record("active 阶段无行动者"); return
                }
                let decision = try GameCore.MonteCarloTreeSearch.chooseAction(
                    state: state, actorID: actor, catalog: catalog, configuration: config
                )
                try GameCore.SimulationRunner.apply(
                    decision.payload, actorID: actor, roomID: roomID, to: &state, catalog: catalog
                )
            case .awaitingTurnEndConfirmation:
                try GameCore.SimulationRunner.apply(
                    .confirmTurnEnd, actorID: state.activePlayerID!, roomID: roomID,
                    to: &state, catalog: catalog
                )
            case .eraIntermission(let inter):
                guard let p = state.players.map(\.id)
                    .first(where: { inter.confirmedPlayerIDs.contains($0) == false }) else {
                    Issue.record("intermission 卡死"); return
                }
                try GameCore.SimulationRunner.apply(
                    .confirmEraIntermission, actorID: p, roomID: roomID, to: &state, catalog: catalog
                )
            case .ended:
                break
            }
        }
        #expect(state.finalStandings?.isEmpty == false)
        print("P1_FULLGAME steps=\(steps)")
    }
}
