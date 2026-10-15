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

    @Test func shortCanalSetupInsertsMatchModeSelectedAndKeepsTheDealIdentical() throws {
        let catalog = try verifiedCatalog()
        let playerIDs = [GameCore.PlayerID(rawValue: "p1"), GameCore.PlayerID(rawValue: "p2")]

        var standardRules = GameCore.SetupRules(seed: 77)
        let standard = try standardRules.makeGame(catalog: catalog, playerIDs: playerIDs)
        var shortRules = GameCore.SetupRules(seed: 77)
        let short = try shortRules.makeGame(catalog: catalog, playerIDs: playerIDs, mode: .shortCanal)

        #expect(short.state.matchMode == .shortCanal)
        #expect(standard.state.matchMode == .standard)
        // 不带 mode 的调用与显式 .standard 的事件序列完全相同(没有新事件)。
        var explicitRules = GameCore.SetupRules(seed: 77)
        let explicit = try explicitRules.makeGame(
            catalog: catalog, playerIDs: playerIDs, mode: .standard
        )
        #expect(explicit.events == standard.events)
        // 短局只多一条事件:紧跟 gameCreated 的 matchModeSelected(.shortCanal)。
        #expect(short.events.count == standard.events.count + 1)
        guard case .matchModeSelected(let mode) = short.events[1].payload else {
            Issue.record("second setup event must be matchModeSelected")
            return
        }
        #expect(mode == .shortCanal)
        // 同种子下,开局/发牌/顺位与标准局完全一致。
        #expect(short.state.players.map { $0.hand } == standard.state.players.map { $0.hand })
        #expect(short.state.playerOrder == standard.state.playerOrder)
        #expect(short.state.standardDrawDeck == standard.state.standardDrawDeck)
        // 短局事件重放回同一状态。
        #expect(try GameCore.SetupRules.replay(short.events, catalog: catalog) == short.state)
    }

    @Test func setupReplayRejectsMisplacedOrExplicitStandardMatchModeEvents() throws {
        let catalog = try verifiedCatalog()
        let playerIDs = [GameCore.PlayerID(rawValue: "p1"), GameCore.PlayerID(rawValue: "p2")]
        var rules = GameCore.SetupRules(seed: 77)
        let standard = try rules.makeGame(catalog: catalog, playerIDs: playerIDs)

        func renumbered(_ events: [GameCore.SetupEvent]) -> [GameCore.SetupEvent] {
            events.enumerated().map { .init(sequence: $0.offset, payload: $0.element.payload) }
        }
        // 显式 .standard 视为非法(缺事件才是 standard)。
        var explicit = standard.events
        explicit.insert(
            .init(sequence: 1, payload: .matchModeSelected(.standard)), at: 1
        )
        #expect(throws: GameCore.SetupError.self) {
            _ = try GameCore.SetupRules.replay(renumbered(explicit), catalog: catalog)
        }
        // 位置错(出现在 turnStateInitialized 之后)同样拒绝。
        var misplaced = standard.events
        misplaced.insert(
            .init(sequence: 2, payload: .matchModeSelected(.shortCanal)), at: 3
        )
        #expect(throws: GameCore.SetupError.self) {
            _ = try GameCore.SetupRules.replay(renumbered(misplaced), catalog: catalog)
        }
    }

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
