import Foundation
import Testing

@testable import IndustrialCityBirmingham

/// 运河新手短局(RULES.md §11)引擎规则测试。
struct ShortCanalRulesTests {

    @Test func standardStateOmitsMatchModeKeyAndRoundTripsCanonicalBytes() throws {
        let catalog = try verifiedCatalog()
        var rules = GameCore.SetupRules(seed: 5)
        let state = try rules.makeGame(
            catalog: catalog,
            playerIDs: (1...2).map { .init(rawValue: "p\($0)") }
        ).state

        let original = try state.canonicalBytes()
        let json = try #require(String(data: original, encoding: .utf8))
        // 标准局 canonical JSON 不得出现 matchMode 键(缺键解码为 .standard)。
        #expect(json.contains("\"matchMode\"") == false)

        let decoded = try JSONDecoder().decode(GameCore.GameState.self, from: original)
        #expect(decoded.matchMode == .standard)
        #expect(decoded == state)
        #expect(try decoded.canonicalBytes() == original)
    }

    @Test func shortCanalStateEncodesMatchModeKeyAndDecodesBack() throws {
        let catalog = try verifiedCatalog()
        var rules = GameCore.SetupRules(seed: 5)
        var state = try rules.makeGame(
            catalog: catalog,
            playerIDs: (1...2).map { .init(rawValue: "p\($0)") }
        ).state
        state.matchMode = .shortCanal

        let original = try state.canonicalBytes()
        let json = try #require(String(data: original, encoding: .utf8))
        #expect(json.contains("\"matchMode\":\"shortCanal\""))

        let decoded = try JSONDecoder().decode(GameCore.GameState.self, from: original)
        #expect(decoded.matchMode == .shortCanal)
        #expect(decoded == state)
        #expect(try decoded.canonicalBytes() == original)
    }

    // MARK: - 辅助(与 TurnScoringRulesTests.verifiedCatalog 同款)

    @Test func shortCanalStateMustStayInCanalEraWithoutIntermission() throws {
        let catalog = try verifiedCatalog()
        func shortState() throws -> GameCore.GameState {
            var rules = GameCore.SetupRules(seed: 9)
            var state = try rules.makeGame(
                catalog: catalog, playerIDs: (1...2).map { .init(rawValue: "p\($0)") }
            ).state
            state.matchMode = .shortCanal
            return state
        }
        // 干净的短局开局状态合法。
        #expect(GameCore.GameStateAuthorityValidator.isValid(try shortState(), catalog: catalog))
        // 短局不得进入铁路时代(夹具清掉底牌,除模式外其余条款全合法)。
        var railed = try shortState()
        railed.era = .rail
        for playerIndex in railed.players.indices {
            if let bottom = railed.players[playerIndex].privateBottomDiscard {
                railed.players[playerIndex].privateBottomDiscard = nil
                railed.standardDrawDeck.append(bottom)
            }
        }
        #expect(GameCore.GameStateAuthorityValidator.isValid(railed, catalog: catalog) == false)
        // 短局不得进入时代间暂停(夹具按 validTurnPhase 的 eraIntermission 条款配齐)。
        var paused = try shortState()
        paused.roundNumber = paused.canalRoundCapacity
        paused.actionsRemaining = 0
        paused.turnsCompletedInRound = 0
        paused.turnPhase = .eraIntermission(.init(
            settledEra: .canal,
            awards: paused.players.map {
                .init(playerID: $0.id, linkPoints: 0, industryPoints: 0, incomeLevel: 0)
            },
            confirmedPlayerIDs: []
        ))
        #expect(GameCore.GameStateAuthorityValidator.isValid(paused, catalog: catalog) == false)
        // 标准局不受新条款影响(多解出来的 .standard 与今天等价)。
        var standard = try shortState()
        standard.matchMode = .standard
        #expect(GameCore.GameStateAuthorityValidator.isValid(standard, catalog: catalog))
    }

    private func verifiedCatalog() throws -> GameCore.VerifiedGameDataCatalog {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "IndustrialCityBirmingham/GameData/v2018.11")
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
            rulesetVersion: catalog.rulesetVersion, verificationStatus: .verified,
            files: try files.keys.sorted().map { path in
                .init(path: path, sha256: GameCore.GameDataLoader.sha256(try #require(files[path])))
            },
            sources: [.init(
                id: "short-canal-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-10-15",
                checker: "independent-test", checkedOn: "2026-10-15"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }
}
