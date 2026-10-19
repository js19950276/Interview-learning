import Foundation
import Testing

@testable import IndustrialCityBirmingham

/// 确定性 RNG:种子固定 → 对局序列完全可复现。
/// (仅此一份定义;SimulationFuzzTests 复用,不得重复声明。)
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

struct SimulationRunnerTests {
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
                id: "sim-runner-tests", url: "https://example.invalid/rules",
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
        let players = (1...4).map { GameCore.PlayerID(rawValue: "sim-p\($0)") }
        var setupRules = GameCore.SetupRules(seed: 20_243)
        return try setupRules.makeGame(catalog: catalog, playerIDs: players).state
    }

    /// 宿主/模拟双路径同步推进 30 步,每步后状态必须完全一致(含版本与 actionNumber)。
    @Test func simulatedSequenceMatchesHostEngineStateExactly() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let roomID = GameCore.RoomID(rawValue: "sim-room")
        let tokens = Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "sim-token-\($0.id.rawValue)"))
        })
        var host = try state.makeHostEngine(
            roomID: roomID, reconnectTokens: tokens, protocolVersion: 2
        )
        var sim = state
        var rng = SplitMix64(seed: 44)

        for step in 0..<30 {
            let current = try #require(host.gameState.activePlayerID)
            switch host.gameState.turnPhase {
            case .active, .forcedSale:
                let result = try GameCore.FastActionEnumerator.enumerate(
                    state: host.gameState, actorID: current, catalog: catalog
                )
                guard let payload = result.payloads.randomElement(using: &rng) else {
                    Issue.record("step \(step): 无可枚举动作"); return
                }
                try GameCore.SimulationRunner.apply(
                    payload, actorID: current, roomID: roomID, to: &sim, catalog: catalog
                )
                let intent = GameCore.PlayerIntent(
                    protocolVersion: 2, rulesetVersion: host.gameState.rulesetVersion,
                    roomID: roomID, senderID: current,
                    reconnectToken: try #require(tokens[current]),
                    baseVersion: host.gameState.authoritativeVersion, payload: payload
                )
                guard case .accepted = host.submit(intent, catalog: catalog) else {
                    Issue.record("step \(step): 宿主拒绝了枚举动作"); return
                }
            case .awaitingTurnEndConfirmation:
                try GameCore.SimulationRunner.apply(
                    .confirmTurnEnd, actorID: current, roomID: roomID, to: &sim, catalog: catalog
                )
                let r = host.submit(.init(
                    protocolVersion: 2, rulesetVersion: host.gameState.rulesetVersion, roomID: roomID,
                    senderID: current, reconnectToken: try #require(tokens[current]),
                    baseVersion: host.gameState.authoritativeVersion, payload: .confirmTurnEnd
                ), catalog: catalog)
                guard case .accepted = r else { Issue.record("turn confirm 被拒"); return }
            case .eraIntermission(let inter):
                guard let p = host.gameState.players.map(\.id)
                    .first(where: { inter.confirmedPlayerIDs.contains($0) == false }) else {
                    Issue.record("intermission 卡死"); return
                }
                try GameCore.SimulationRunner.apply(
                    .confirmEraIntermission, actorID: p, roomID: roomID, to: &sim, catalog: catalog
                )
                let r = host.submit(.init(
                    protocolVersion: 2, rulesetVersion: host.gameState.rulesetVersion, roomID: roomID,
                    senderID: p, reconnectToken: try #require(tokens[p]),
                    baseVersion: host.gameState.authoritativeVersion, payload: .confirmEraIntermission
                ), catalog: catalog)
                guard case .accepted = r else { Issue.record("era confirm 被拒"); return }
            case .ended:
                return
            }
            guard sim == host.gameState else {
                Issue.record("step \(step): 模拟与宿主状态分叉"); return
            }
        }
    }

    @Test func retractionIsUnsupportedInSimulation() throws {
        let catalog = try verifiedCatalog()
        var state = try freshFourPlayerState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        #expect(throws: GameCore.SimulationRunner.SimulationError.self) {
            try GameCore.SimulationRunner.apply(
                .retractTurnActions, actorID: actor,
                roomID: .init(rawValue: "x"), to: &state, catalog: catalog
            )
        }
    }

    @Test func illegalPayloadRejectedInSimulationToo() throws {
        let catalog = try verifiedCatalog()
        var state = try freshFourPlayerState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        // 手牌之外的卡做 pass:宿主会拒(missingDiscardCard),模拟侧必须抛错。
        let fakeCard = "not-in-any-hand"
        #expect(throws: (any Error).self) {
            try GameCore.SimulationRunner.apply(
                .pass(.init(cardID: fakeCard)), actorID: actor,
                roomID: .init(rawValue: "x"), to: &state, catalog: catalog
            )
        }
        // 状态不得被部分写入。
        let pristine = try freshFourPlayerState(catalog: catalog)
        #expect(state == pristine)
    }
}
